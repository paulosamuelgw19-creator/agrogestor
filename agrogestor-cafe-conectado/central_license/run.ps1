$ErrorActionPreference = 'Stop'
$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ServerDir

$PythonPath = Join-Path $ServerDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $PythonPath)) {
    py -3 -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível criar o ambiente Python do painel central.' }
}
$PythonVersionText = (& $PythonPath -c "import sys; print('.'.join(str(part) for part in sys.version_info[:3]))").Trim()
if ($LASTEXITCODE -ne 0 -or [version]$PythonVersionText -lt [version]'3.11') {
    throw 'O painel central exige Python 3.11 ou superior.'
}
$RequirementsHash = (Get-FileHash -LiteralPath 'requirements.txt' -Algorithm SHA256).Hash
$InstalledHashPath = Join-Path $ServerDir '.venv\.requirements-sha256'
$InstalledRequirementsHash = if (Test-Path -LiteralPath $InstalledHashPath) { (Get-Content -LiteralPath $InstalledHashPath -Raw).Trim() } else { '' }
if ($InstalledRequirementsHash -ne $RequirementsHash) {
    & $PythonPath -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível instalar as dependências do painel central.' }
    Set-Content -LiteralPath $InstalledHashPath -Value $RequirementsHash -NoNewline -Encoding ascii
}

if (-not (Test-Path -LiteralPath '.env')) {
    Copy-Item '.env.example' '.env'
    $Jwt = (& $PythonPath -c "import secrets; print(secrets.token_urlsafe(48))").Trim()
    $ApiKey = (& $PythonPath -c "import secrets; print(secrets.token_urlsafe(48))").Trim()
    $EnvText = Get-Content '.env' -Raw
    $EnvText = $EnvText.Replace('REPLACE_WITH_A_RANDOM_SECRET_OF_AT_LEAST_32_CHARACTERS', $Jwt)
    $EnvText = $EnvText.Replace('REPLACE_WITH_A_DIFFERENT_RANDOM_SECRET_OF_AT_LEAST_32_CHARACTERS', $ApiKey)
    Set-Content -LiteralPath '.env' -Value $EnvText -Encoding utf8
    Write-Host 'Arquivo .env privado criado com chaves aleatórias.'
}

$DataDir = (& $PythonPath -c "from license_server.app import DATA_DIR; print(DATA_DIR)").Trim()
& $PythonPath -m license_server.cli init-admin
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível criar o administrador central.' }

$EnvLines = Get-Content '.env' | Where-Object { $_ -match '^\s*AGROGESTOR_LICENSE_(DATA_DIR|BIND_HOST|BIND_PORT)=' }
foreach ($Line in $EnvLines) {
    $Parts = $Line -split '=', 2
    [Environment]::SetEnvironmentVariable($Parts[0], $Parts[1], 'Process')
}
$HostValue = if ($env:AGROGESTOR_LICENSE_BIND_HOST) { $env:AGROGESTOR_LICENSE_BIND_HOST } else { '127.0.0.1' }
$PortValue = if ($env:AGROGESTOR_LICENSE_BIND_PORT) { $env:AGROGESTOR_LICENSE_BIND_PORT } else { '8770' }
if ($HostValue -ne '127.0.0.1') { throw 'Por segurança, mantenha o painel em 127.0.0.1 e use Tailscale Serve para acesso remoto.' }
& $PythonPath -m uvicorn license_server.app:app --host $HostValue --port $PortValue
