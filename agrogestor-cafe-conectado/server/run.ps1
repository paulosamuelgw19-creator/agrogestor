$ErrorActionPreference = 'Stop'
$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ServerDir

$PythonPath = Join-Path $ServerDir '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $PythonPath)) {
    py -3 -m venv .venv
    if ($LASTEXITCODE -ne 0) {
        throw 'Não foi possível criar o ambiente Python do servidor.'
    }
}
$PythonVersionText = (& $PythonPath -c "import sys; print('.'.join(str(part) for part in sys.version_info[:3]))").Trim()
if ($LASTEXITCODE -ne 0 -or [version]$PythonVersionText -lt [version]'3.11') {
    throw 'O servidor exige Python 3.11 ou superior. Atualize o Python do ambiente .venv.'
}

$RequirementsHash = (Get-FileHash -LiteralPath 'requirements.txt' -Algorithm SHA256).Hash
$InstalledHashPath = Join-Path $ServerDir '.venv\.requirements-sha256'
$InstalledRequirementsHash = if (Test-Path -LiteralPath $InstalledHashPath) {
    (Get-Content -LiteralPath $InstalledHashPath -Raw).Trim()
} else {
    ''
}
if ($InstalledRequirementsHash -ne $RequirementsHash) {
    & $PythonPath -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) {
        throw 'Não foi possível instalar as dependências do servidor.'
    }
    Set-Content -LiteralPath $InstalledHashPath -Value $RequirementsHash -NoNewline -Encoding ascii
}

if (-not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
    $Secret = (& '.venv\Scripts\python.exe' -c "import secrets; print(secrets.token_urlsafe(48))").Trim()
    $EnvText = Get-Content '.env' -Raw
    $EnvText = $EnvText.Replace('REPLACE_WITH_A_RANDOM_SECRET_OF_AT_LEAST_32_CHARACTERS', $Secret)
    Set-Content -Path '.env' -Value $EnvText -Encoding utf8
    Write-Host 'Arquivo .env criado e chave privada gerada neste PC.'
}

$DatabasePath = (& $PythonPath -c "from agrogestor_server.app import DB_PATH; print(DB_PATH)").Trim()
if (-not (Test-Path -LiteralPath $DatabasePath)) {
    & $PythonPath -m agrogestor_server.cli init-admin
}

$EnvLines = Get-Content '.env' | Where-Object { $_ -match '^\s*AGROGESTOR_(DATA_DIR|BIND_HOST|BIND_PORT)=' }
foreach ($Line in $EnvLines) {
    $Parts = $Line -split '=', 2
    [Environment]::SetEnvironmentVariable($Parts[0], $Parts[1], 'Process')
}
$HostValue = if ($env:AGROGESTOR_BIND_HOST) { $env:AGROGESTOR_BIND_HOST } else { '127.0.0.1' }
$PortValue = if ($env:AGROGESTOR_BIND_PORT) { $env:AGROGESTOR_BIND_PORT } else { '8765' }
if ($HostValue -ne '127.0.0.1') {
    throw 'Por segurança, o servidor da API deve escutar somente em 127.0.0.1; use Tailscale Serve para o acesso remoto.'
}
& $PythonPath -m uvicorn agrogestor_server.app:app --host $HostValue --port $PortValue
