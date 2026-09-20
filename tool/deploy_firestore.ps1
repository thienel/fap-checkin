[CmdletBinding()]
param(
  [switch]$SkipEmulatorCheck
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$firebaseRcPath = Join-Path $projectRoot '.firebaserc'
$desktopConfigPath = Join-Path $projectRoot 'firebase.desktop.json'

if (-not (Test-Path -LiteralPath $firebaseRcPath)) {
  throw "Missing Firebase target file: $firebaseRcPath"
}
if (-not (Test-Path -LiteralPath $desktopConfigPath)) {
  throw "Missing desktop Firebase config: $desktopConfigPath"
}

$firebaseRc = Get-Content -LiteralPath $firebaseRcPath -Raw | ConvertFrom-Json
$desktopConfig = Get-Content -LiteralPath $desktopConfigPath -Raw | ConvertFrom-Json
$targetProject = [string]$firebaseRc.projects.default
$desktopProject = [string]$desktopConfig.FIREBASE_PROJECT_ID

if ([string]::IsNullOrWhiteSpace($targetProject)) {
  throw 'The default project is missing from .firebaserc.'
}
if ($targetProject -ne $desktopProject) {
  throw "Refusing deploy: .firebaserc targets '$targetProject' but the desktop app targets '$desktopProject'."
}
if (-not (Get-Command firebase.cmd -ErrorAction SilentlyContinue)) {
  throw 'firebase.cmd was not found. Install firebase-tools and sign in first.'
}

Push-Location $projectRoot
try {
  if (-not $SkipEmulatorCheck) {
    $rulesTestDependency = Join-Path $projectRoot 'web-checkin\node_modules\@firebase\rules-unit-testing'
    if (-not (Test-Path -LiteralPath $rulesTestDependency)) {
      throw 'Missing Firestore rules test dependency. Run: npm --prefix web-checkin ci'
    }
    $emulatorProject = "demo-$targetProject"
    & firebase.cmd emulators:exec --only firestore --project $emulatorProject 'npm.cmd --prefix web-checkin run test:rules'
    if ($LASTEXITCODE -ne 0) {
      throw 'Firestore permission integration tests failed. Nothing was deployed.'
    }
  }

  Write-Host "Deploying Firestore rules and indexes to: $targetProject"
  & firebase.cmd deploy --only firestore --project $targetProject
  if ($LASTEXITCODE -ne 0) {
    throw "Firestore deploy failed for project '$targetProject'."
  }

  Write-Host "Firestore deployment completed for: $targetProject"
} finally {
  Pop-Location
}
