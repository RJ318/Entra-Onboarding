#Requires -Version 7.0
<#
.SYNOPSIS
    One-command demo: offline dry runs on the sample and edge-case files. No tenant, no sign-in, no changes.
.EXAMPLE
    pwsh ./tools/demo.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "`n=== 1) Sample new hires: duplicates, accents, and two bad rows ===" -ForegroundColor Cyan
./Invoke-Onboarding.ps1 -CsvPath ./sample/new-hires.csv -Offline -ExistingUpnsPath ./sample/existing-upns.txt

Write-Host "`n=== 2) Edge cases: casing, padding, long names, leap years, bad data ===" -ForegroundColor Cyan
./Invoke-Onboarding.ps1 -CsvPath ./sample/edge-cases.csv -Offline -ExistingUpnsPath ./sample/edge-cases-existing.txt

Write-Host @"

Next steps
  Run the tests:        Invoke-Pester ./tests -Output Detailed
  Try your own file:    ./Invoke-Onboarding.ps1 -CsvPath <your.csv> -Offline
  Connected dry run:    ./Invoke-Onboarding.ps1 -CsvPath <your.csv> -WhatIf   (needs Microsoft.Graph and a test tenant)
"@ -ForegroundColor DarkGray
