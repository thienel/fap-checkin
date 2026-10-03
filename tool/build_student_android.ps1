[CmdletBinding()]
param(
  [switch]$PrepareOnly,
  [switch]$Install,
  [string]$DeviceId
)
$ErrorActionPreference = 'Stop'
$studentProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$studentModuleRoot = Join-Path $studentProjectRoot 'student-mobile'
$env:PUB_CACHE = Join-Path $studentProjectRoot '.pub-cache'
$env:GRADLE_USER_HOME = Join-Path $studentProjectRoot '.tool-cache\gradle'
$env:TEMP = Join-Path $studentProjectRoot '.tool-cache\temp'
$env:TMP = $env:TEMP
$studentKeyDir = Join-Path $studentProjectRoot '.tool-cache\android'
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE,$env:GRADLE_USER_HOME,$env:TEMP,$studentKeyDir | Out-Null
$studentKey = Join-Path $studentKeyDir 'student-debug.keystore'
if (-not (Test-Path -LiteralPath $studentKey)) {
  & keytool -genkeypair -keystore $studentKey -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
  if ($LASTEXITCODE -ne 0) { throw 'Could not generate the local Android debug signing key.' }
}
& keytool -list -v -keystore $studentKey -storepass android -alias androiddebugkey
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the Android debug signing key.' }
if ($PrepareOnly) { return }
$studentConfig = Join-Path $studentModuleRoot 'firebase.mobile.json'
if (-not (Test-Path -LiteralPath $studentConfig)) { throw 'Missing student-mobile/firebase.mobile.json. See student-mobile/README.md.' }
$studentSettings = Get-Content -LiteralPath $studentConfig -Raw | ConvertFrom-Json
if ($studentSettings.FIREBASE_APP_ID -notmatch ':android:') { throw 'Mobile config must contain a Firebase Android app ID.' }
if ([string]::IsNullOrWhiteSpace($studentSettings.GOOGLE_SERVER_CLIENT_ID)) { throw 'Missing GOOGLE_SERVER_CLIENT_ID (Web OAuth client ID).' }
$desktopConfig = Join-Path $studentProjectRoot 'firebase.desktop.json'
if (Test-Path -LiteralPath $desktopConfig) {
  $desktopSettings = Get-Content -LiteralPath $desktopConfig -Raw | ConvertFrom-Json
  if ($studentSettings.FIREBASE_PROJECT_ID -ne $desktopSettings.FIREBASE_PROJECT_ID) { throw 'Mobile and desktop Firebase projects do not match.' }
}
Push-Location $studentModuleRoot
try {
  & flutter.bat pub get
  if ($LASTEXITCODE -ne 0) { throw 'Mobile dependency installation failed.' }
  & flutter.bat build apk --debug "--dart-define-from-file=$studentConfig"
  if ($LASTEXITCODE -ne 0) { throw 'Student Android build failed.' }
  $studentApk = Join-Path $studentModuleRoot 'build\app\outputs\flutter-apk\app-debug.apk'
  $studentArtifacts = Join-Path $studentProjectRoot 'artifacts'
  New-Item -ItemType Directory -Force -Path $studentArtifacts | Out-Null
  $studentOutput = Join-Path $studentArtifacts 'fap-student-debug.apk'
  Copy-Item -LiteralPath $studentApk -Destination $studentOutput -Force
  Write-Host "Student APK: $studentOutput"
  if ($Install) {
    $studentAdb = if (Get-Command adb -ErrorAction SilentlyContinue) { 'adb' }
      elseif ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }
      else { throw 'ADB not found. Set ANDROID_HOME or add platform-tools to PATH.' }
    $studentAdbArgs = @()
    if ($DeviceId) { $studentAdbArgs += @('-s', $DeviceId) }
    & $studentAdb @studentAdbArgs install -r $studentOutput
    if ($LASTEXITCODE -ne 0) { throw 'APK installation failed. Enable USB debugging and authorize this computer.' }
  }
} finally { Pop-Location }
