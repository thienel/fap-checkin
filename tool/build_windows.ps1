[CmdletBinding()]
param(
  [ValidateSet('debug', 'profile', 'release')]
  [string]$Mode = 'debug'
)

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
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  & flutter build windows "--$Mode" "--dart-define-from-file=$firebaseConfig"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $executable = Join-Path $projectRoot "build\windows\x64\runner\$($Mode.Substring(0, 1).ToUpper())$($Mode.Substring(1))\fap_check_attendance.exe"
  if (-not (Test-Path -LiteralPath $executable)) {
    throw "Build completed but the executable was not found at: $executable"
  }

  Write-Host "Windows executable: $executable"
} finally {
  Pop-Location
}
