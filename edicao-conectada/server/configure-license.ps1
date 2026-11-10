$ErrorActionPreference = 'Stop'
$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvPath = Join-Path $ServerDir '.env'
if (-not (Test-Path -LiteralPath $EnvPath)) { throw 'Arquivo server/.env não encontrado. Execute run.ps1 uma vez para inicializar a fazenda.' }

Write-Host 'Provedor central de licenças desta fazenda:'
Write-Host '  1. Firebase (mantém o painel Firebase)'
Write-Host '  2. Windows (painel central auto-hospedado)'
Write-Host '  3. Local (somente demonstração/desenvolvimento)'
$Choice = Read-Host 'Escolha 1, 2 ou 3'
switch ($Choice) {
    '1' { $Provider = 'firebase'; $Base = Read-Host 'URL base das Cloud Functions (ex.: https://us-central1-ID.cloudfunctions.net)' }
    '2' { $Provider = 'windows'; $Base = Read-Host 'URL privada do painel Windows (ex.: https://nome-do-pc.tailnet.ts.net:8444)' }
    '3' { $Provider = 'local'; $Base = ''; $ApiKey = '' }
    default { throw 'Escolha inválida; nenhuma configuração foi alterada.' }
}

if ($Provider -ne 'local') {
    $Uri = $null
    if (-not [Uri]::TryCreate($Base, [UriKind]::Absolute, [ref]$Uri) -or $Uri.Scheme -notin @('https','http')) {
        throw 'Informe uma URL absoluta http:// ou https:// válida.'
    }
    if ($Provider -eq 'firebase' -and $Uri.Scheme -ne 'https') { throw 'Firebase precisa usar HTTPS.' }
    if ($Provider -eq 'windows' -and $Uri.Scheme -eq 'http' -and $Uri.Host -notin @('127.0.0.1','localhost')) {
        throw 'Fora do mesmo PC, o painel Windows exige HTTPS privado pelo Tailscale.'
    }
    $SecureKey = Read-Host 'Chave privada compartilhada do serviço central' -AsSecureString
    $KeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    try { $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($KeyPointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($KeyPointer) }
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey.Length -lt 32) { throw 'A chave precisa ter pelo menos 32 caracteres.' }
}

$Updates = @{
    'AGROGESTOR_LICENSE_PROVIDER' = $Provider
    'AGROGESTOR_LICENSE_API_BASE' = $Base.TrimEnd('/')
    'AGROGESTOR_LICENSE_API_KEY' = $ApiKey
}
$Lines = [System.Collections.Generic.List[string]]::new()
$Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Line in Get-Content -LiteralPath $EnvPath) {
    if ($Line -match '^\s*(AGROGESTOR_LICENSE_PROVIDER|AGROGESTOR_LICENSE_API_BASE|AGROGESTOR_LICENSE_API_KEY)=') {
        $Name = $Matches[1]
        if ($Seen.Add($Name)) { $Lines.Add("$Name=$($Updates[$Name])") }
    } else { $Lines.Add($Line) }
}
foreach ($Name in $Updates.Keys) { if ($Seen.Add($Name)) { $Lines.Add("$Name=$($Updates[$Name])") } }
Set-Content -LiteralPath $EnvPath -Value $Lines -Encoding utf8
Write-Host "Provedor configurado: $Provider. Reinicie o servidor da fazenda para aplicar."
Write-Host 'O segredo foi gravado no arquivo privado server/.env e não foi exibido.'
