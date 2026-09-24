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

$firebaseBuildCache = Join-Path $projectRoot 'build\windows\x64'
$firebaseSdkExtraction = Join-Path $firebaseBuildCache 'extracted'
$firebaseSdkExtracted = Join-Path $firebaseSdkExtraction 'firebase_cpp_sdk_windows'
if ($Mode -eq 'debug') {
  $firebaseSdkBuildConfig = 'Debug'
} else {
  $firebaseSdkBuildConfig = 'Release'
}
$firebaseFirestoreLib = Join-Path $firebaseSdkExtracted "libs\windows\VS2019\MD\x64\$firebaseSdkBuildConfig\firebase_firestore.lib"
$firebaseSdkArchives = @(
  Get-ChildItem -LiteralPath $firebaseBuildCache -Filter 'firebase_cpp_sdk_windows_*.zip' -File -ErrorAction SilentlyContinue
)
if (-not (Test-Path -LiteralPath $firebaseFirestoreLib) -and
    ($firebaseSdkArchives.Count -gt 0 -or (Test-Path -LiteralPath $firebaseSdkExtraction))) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $validFirebaseSdkArchives = @()
  foreach ($archive in $firebaseSdkArchives) {
    $zip = $null
    try {
      $zip = [System.IO.Compression.ZipFile]::OpenRead($archive.FullName)
      $expectedLibrary = $zip.GetEntry("firebase_cpp_sdk_windows/libs/windows/VS2019/MD/x64/$firebaseSdkBuildConfig/firebase_firestore.lib")
      if ($null -ne $expectedLibrary -and $expectedLibrary.Length -gt 0) {
        $validFirebaseSdkArchives += $archive.FullName
      }
    } catch {
      # A partial download has no usable central directory and must be fetched again.
    } finally {
      if ($null -ne $zip) { $zip.Dispose() }
    }
  }

  Write-Warning 'Firebase Windows SDK extraction cache is incomplete. Clearing the generated extraction folder.'
  if (Test-Path -LiteralPath $firebaseSdkExtraction) {
    Remove-Item -LiteralPath $firebaseSdkExtraction -Recurse -Force
  }
  foreach ($archive in $firebaseSdkArchives) {
    if ($archive.FullName -notin $validFirebaseSdkArchives) {
      Write-Warning "Removing incomplete Firebase SDK archive: $($archive.Name)"
      Remove-Item -LiteralPath $archive.FullName -Force
    }
  }
}

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
