$ErrorActionPreference = 'Stop'
$PilotServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $PilotServerDir
$PilotEnvPath = Join-Path $PilotServerDir '.env'
if (-not (Test-Path -LiteralPath $PilotEnvPath)) {
    $PilotRandomBytes = New-Object byte[] 48
    $PilotRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $PilotRng.GetBytes($PilotRandomBytes) } finally { $PilotRng.Dispose() }
    $PilotSecret = [Convert]::ToBase64String($PilotRandomBytes)
    $PilotEnv = Get-Content -LiteralPath (Join-Path $PilotServerDir '.env.example') -Raw
    $PilotEnv = $PilotEnv.Replace('AGROGESTOR_DATA_DIR=./data', 'AGROGESTOR_DATA_DIR=./data-piloto')
    $PilotEnv = $PilotEnv.Replace('AGROGESTOR_V2_ENABLED=false', 'AGROGESTOR_V2_ENABLED=true')
    $PilotEnv = $PilotEnv.Replace('AGROGESTOR_BIND_PORT=8765', 'AGROGESTOR_BIND_PORT=8766')
    $PilotEnv = $PilotEnv.Replace('REPLACE_WITH_A_RANDOM_SECRET_OF_AT_LEAST_32_CHARACTERS', $PilotSecret)
    Set-Content -LiteralPath $PilotEnvPath -Value $PilotEnv -Encoding utf8
}
$PilotExistingEnv = Get-Content -LiteralPath $PilotEnvPath -Raw
if ($PilotExistingEnv -notmatch '(?m)^AGROGESTOR_DATA_DIR=\./data-piloto\s*$' -or
    $PilotExistingEnv -notmatch '(?m)^AGROGESTOR_BIND_PORT=8766\s*$' -or
    $PilotExistingEnv -notmatch '(?m)^AGROGESTOR_V2_ENABLED=true\s*$') {
    throw 'Este iniciador exige dados exclusivos em ./data-piloto, porta 8766 e v2 habilitado. Confira a configuração desta cópia.'
}
$env:AGROGESTOR_DATA_DIR = './data-piloto'
$env:AGROGESTOR_V2_ENABLED = 'true'
$env:AGROGESTOR_BIND_PORT = '8766'
$env:AGROGESTOR_BIND_HOST = '127.0.0.1'
Write-Host 'AgroGestor v2: piloto isolado. O servidor anterior e seus dados não serão substituídos.'
& (Join-Path $PilotServerDir 'run.ps1')
