# Local Release Validation Script for mapbox_nav_core (PowerShell)
# Usage: ./tool/release_check.ps1

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Starting mapbox_nav_core Release Pre-flight Checks" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$packageDir = Join-Path $PSScriptRoot "..\packages\mapbox_nav_core"
$exampleDir = Join-Path $packageDir "example"

# 1. Package Formatting
Write-Host "`n[1/6] Checking code formatting..." -ForegroundColor Yellow
Push-Location $packageDir
try {
    dart format --output=none --set-exit-if-changed .
    Write-Host "Formatting clean!" -ForegroundColor Green
} finally {
    Pop-Location
}

# 2. Package Static Analysis
Write-Host "`n[2/6] Running static analysis on package..." -ForegroundColor Yellow
Push-Location $packageDir
try {
    flutter analyze
    Write-Host "Package static analysis clean!" -ForegroundColor Green
} finally {
    Pop-Location
}

# 3. Package Tests
Write-Host "`n[3/6] Running package tests (unit & stress suites)..." -ForegroundColor Yellow
Push-Location $packageDir
try {
    flutter test test
    Write-Host "All package tests passed!" -ForegroundColor Green
} finally {
    Pop-Location
}

# 4. Example App Analysis
Write-Host "`n[4/6] Analyzing example application..." -ForegroundColor Yellow
Push-Location $exampleDir
try {
    flutter pub get
    flutter analyze
    flutter test
    Write-Host "Example app clean and tested!" -ForegroundColor Green
} finally {
    Pop-Location
}

# 5. Pub.dev Dry-run Validation
Write-Host "`n[5/6] Validating package publish archive (dry-run)..." -ForegroundColor Yellow
Push-Location $packageDir
try {
    dart pub publish --dry-run
    Write-Host "Publish dry-run succeeded!" -ForegroundColor Green
} finally {
    Pop-Location
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "ALL PRE-RELEASE CHECKS PASSED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan
