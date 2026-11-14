#Requires -Version 7.0
<#
.SYNOPSIS
    Provision new hires in Microsoft Entra ID from a CSV.

.DESCRIPTION
    1. Validates every row (required fields, department and license mapping, date format, manager UPN).
    2. Builds a plan: unique UPN (first.last, first.last2, ...), groups, license.
    3. Shows the plan and saves it to CSV for review.
    4. Creates users through Microsoft Graph, or stops at step 3 with -Offline or -WhatIf.
    5. Writes an audit log. Temporary passwords are returned as SecureStrings, never logged.

.EXAMPLE
    # Dry run with no tenant at all — checks the CSV and shows exactly what would be created
    ./Invoke-Onboarding.ps1 -CsvPath ./sample/new-hires.csv -Offline -ExistingUpnsPath ./sample/existing-upns.txt

.EXAMPLE
    # Connected dry run — real collision checks against the tenant, no changes
    ./Invoke-Onboarding.ps1 -CsvPath ./new-hires.csv -WhatIf

.EXAMPLE
    # Live run — capture results so temporary passwords can be handed off securely
    $results = ./Invoke-Onboarding.ps1 -CsvPath ./new-hires.csv
    $results | Where-Object Result -eq 'Created' |
        ForEach-Object { '{0}  {1}' -f $_.UserPrincipalName, ($_.TemporaryPassword | ConvertFrom-SecureString -AsPlainText) }
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/onboarding-config.json'),
    [switch]$Offline,
    [string]$ExistingUpnsPath,
    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/EntraOnboarding.psd1') -Force

$config = Import-OnboardingConfig -Path $ConfigPath
$records = @(Import-Csv -LiteralPath $CsvPath)
if (-not $records.Count) { throw "No rows found in $CsvPath." }

# --- How do we know if a UPN is already taken? ---------------------------------
if ($Offline) {
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($ExistingUpnsPath) {
        Get-Content -LiteralPath $ExistingUpnsPath | Where-Object { $_ -and $_ -notmatch '^\s*#' } |
            ForEach-Object { [void]$existing.Add($_.Trim()) }
    }
    $isTaken = { param($Upn) $existing.Contains($Upn) }.GetNewClosure()
}
else {
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft Graph PowerShell SDK not found. Install-Module Microsoft.Graph -Scope CurrentUser, or use -Offline.'
    }
    # Least privilege for this job: create users, assign licenses, manage group membership, read SKUs.
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Organization.Read.All' -NoWelcome
    $isTaken = { param($Upn) [bool](Get-MgUser -Filter "userPrincipalName eq '$Upn'" -ErrorAction SilentlyContinue) }
}

# --- Plan -----------------------------------------------------------------------
$plan = @(Get-OnboardingPlan -Records $records -Config $config -IsTaken $isTaken)
$ready = @($plan | Where-Object Status -eq 'Ready')
$invalid = @($plan | Where-Object Status -eq 'Invalid')

Write-Host ''
Write-Host ("Onboarding plan: {0} rows · {1} ready · {2} need fixing" -f $plan.Count, $ready.Count, $invalid.Count)
$plan | Format-Table -AutoSize -Wrap Row, Status, UserPrincipalName, Department, License,
    @{ n = 'Groups'; e = { @($_.Groups).Count } }, Errors | Out-String -Width 160 | Write-Host

if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$planPath = Join-Path $LogDirectory "onboarding-plan-$stamp.csv"
$plan | Select-Object Row, Status, Errors, DisplayName, UserPrincipalName, Department, JobTitle, EmployeeType,
    StartDate, ManagerUpn, UsageLocation, License, @{ n = 'Groups'; e = { @($_.Groups) -join '; ' } } |
    Export-Csv -LiteralPath $planPath -NoTypeInformation -Encoding utf8
Write-Host "Plan saved: $planPath"

if ($Offline) {
    Write-Host 'Offline dry run: no changes made.'
    return
}
if (-not $ready.Count) {
    Write-Host 'Nothing to create. Fix the rows above and run again.'
    return
}
if (-not $WhatIfPreference -and -not $Force) {
    if (-not $PSCmdlet.ShouldContinue("Create $($ready.Count) users in $((Get-MgContext).TenantId)?", 'Confirm onboarding')) {
        Write-Host 'Cancelled.'
        return
    }
}

# --- Execute --------------------------------------------------------------------
$results = @(Invoke-OnboardingPlan -Plan $plan -WhatIf:$WhatIfPreference)
$mode = if ($WhatIfPreference) { 'WhatIf' } else { 'Live' }
$log = Export-OnboardingLog -Results $results -Path (Join-Path $LogDirectory "onboarding-log-$stamp.csv") -Mode $mode

$results | Group-Object Result | ForEach-Object { Write-Host ("{0,-8} {1}" -f $_.Name, $_.Count) }
Write-Host "Audit log: $($log.FullName)  (passwords are not in the log)"
$results
