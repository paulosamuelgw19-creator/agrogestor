param([int]$Porta = 8790, [switch]$Preparar, [switch]$AbrirPainel)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$pythonLocal = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonLocal)) {
    py -3 -m venv (Join-Path $PSScriptRoot '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Instale Python 3.12 ou mais recente e tente novamente.' }
    & $pythonLocal -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel instalar as dependencias.' }
}
$dadosPrivados = if ($env:AGRO_LOCAL_LICENSE_DATA) { $env:AGRO_LOCAL_LICENSE_DATA } else { Join-Path $PSScriptRoot 'dados-privados' }
& $pythonLocal -m fontes.manage check-ready --data $dadosPrivados
$codigoPreparacao = $LASTEXITCODE
if ($Preparar -or $codigoPreparacao -ne 0) {
    & $pythonLocal -m fontes.manage setup --data $dadosPrivados
    if ($LASTEXITCODE -ne 0) { throw 'Configuracao inicial nao concluida.' }
}
# Restrict only this explicitly resolved private directory; never modify the workspace ACL.
$pastaPrivadaResolvida = (Resolve-Path -LiteralPath $dadosPrivados).Path
& $pythonLocal -m fontes.manage protect-data --data $pastaPrivadaResolvida
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel proteger a pasta privada.' }
$env:AGRO_LOCAL_LICENSE_DATA = $pastaPrivadaResolvida
Write-Host "Painel no Windows: http://127.0.0.1:$Porta/"
Write-Host 'Servidor local. Acesso externo exige HTTPS configurado separadamente.'
Write-Host 'Para encerrar: Ctrl+C nesta janela. Instalacoes ativadas continuam funcionando offline.'
if ($AbrirPainel) { Start-Process "http://127.0.0.1:$Porta/" -WindowStyle Hidden }
& $pythonLocal -m uvicorn fontes.app:application --factory --host 127.0.0.1 --port $Porta --no-access-log --proxy-headers --forwarded-allow-ips 127.0.0.1
exit $LASTEXITCODE
