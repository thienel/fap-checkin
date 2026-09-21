[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectDrive = Split-Path -Qualifier $projectRoot
if ($projectDrive -ne 'D:') {
  throw "Project must be located on drive D. Current path: $projectRoot"
}

$env:PUB_CACHE = Join-Path $projectRoot '.pub-cache'
$env:TEMP = Join-Path $projectRoot '.tool-cache\temp'
$env:TMP = $env:TEMP
$env:npm_config_cache = Join-Path $projectRoot '.tool-cache\npm'

New-Item -ItemType Directory -Force -Path $env:PUB_CACHE, $env:TEMP | Out-Null

$firebaseConfig = Join-Path $projectRoot 'firebase.desktop.json'
if (-not (Test-Path -LiteralPath $firebaseConfig)) {
  throw "Missing Firebase config: $firebaseConfig"
}

Push-Location $projectRoot
try {
  & flutter run -d windows "--dart-define-from-file=$firebaseConfig"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
