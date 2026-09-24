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

$firebaseBuildCache = Join-Path $projectRoot 'build\windows\x64'
$firebaseSdkExtraction = Join-Path $firebaseBuildCache 'extracted'
$firebaseSdkExtracted = Join-Path $firebaseSdkExtraction 'firebase_cpp_sdk_windows'
$firebaseSdkBuildConfig = 'Debug'
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
  & flutter run -d windows "--dart-define-from-file=$firebaseConfig"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
}
