#Requires -Version 7.0
<#
    EntraOnboarding — CSV-driven new-hire provisioning for Microsoft Entra ID (Azure AD)
    through the Microsoft Graph PowerShell SDK.

    Flow:  Import CSV -> validate each row -> build a plan (UPN, groups, license)
           -> review / dry run -> create users -> write an audit log (never passwords)

    Graph calls go through a small adapter (New-GraphAdapter). Production uses the real
    cmdlets; tests pass a fake adapter, so the whole flow is testable without a tenant.
#>
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-PropValue {
    param($Object, [string]$Name)
    # An empty name (for example a blank Department cell) is "not found", not an error.
    if ($null -eq $Object -or [string]::IsNullOrEmpty($Name)) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-RandomChar {
    param([string]$Set)
    $Set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Set.Length)]
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Import-OnboardingConfig {
    <#
    .SYNOPSIS
        Loads the onboarding config (domain, group mapping, license mapping) and checks required keys.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($key in 'Domain', 'UsageLocation', 'BaseGroups', 'DepartmentGroups', 'LicenseByEmployeeType') {
        if ($null -eq (Get-PropValue $cfg $key)) { throw "Config is missing '$key'." }
    }
    $cfg
}

# ---------------------------------------------------------------------------
# Names and UPNs
# ---------------------------------------------------------------------------
function ConvertTo-UpnSafeName {
    <#
    .SYNOPSIS
        Lower-cases a name and strips accents, spaces, and punctuation so it is safe in a UPN.
    .EXAMPLE
        ConvertTo-UpnSafeName "José"     # jose
        ConvertTo-UpnSafeName "O'Brien"  # obrien
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $decomposed = $Name.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9-]', '').Trim('-')
}

function New-UniqueUpn {
    <#
    .SYNOPSIS
        Builds first.last@domain and adds a number (first.last2, first.last3, ...) until the UPN is free.
    .PARAMETER IsTaken
        Script block that receives a candidate UPN and returns $true if it is already used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][scriptblock]$IsTaken,
        [ValidateRange(1, 500)][int]$MaxAttempts = 50
    )

    $first = ConvertTo-UpnSafeName $FirstName
    $last = ConvertTo-UpnSafeName $LastName
    if (-not $first -or -not $last) { throw "Can't build a UPN from '$FirstName $LastName'." }

    # UPN prefix limit is 64 characters; leave room for a numeric suffix.
    $base = "$first.$last"
    if ($base.Length -gt 60) { $base = $base.Substring(0, 60).TrimEnd('.', '-') }

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $candidate = if ($i -eq 1) { "$base@$Domain" } else { "$base$i@$Domain" }
        if (-not (& $IsTaken $candidate)) { return $candidate }
    }
    throw "No free UPN for '$base' after $MaxAttempts attempts."
}

function New-TemporaryPassword {
    <#
    .SYNOPSIS
        Cryptographically random password with upper, lower, digit, and symbol; no look-alike characters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 64)][int]$Length = 16)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'   # no I, O
    $lower = 'abcdefghijkmnpqrstuvwxyz'   # no l, o
    $digit = '23456789'                   # no 0, 1
    $symbol = '!@#$%*?-'
    $all = $upper + $lower + $digit + $symbol

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $upper, $lower, $digit, $symbol) { $chars.Add((Get-RandomChar $set)) }
    while ($chars.Count -lt $Length) { $chars.Add((Get-RandomChar $all)) }

    # Fisher-Yates shuffle so the guaranteed characters aren't always first
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

# ---------------------------------------------------------------------------
# Validation and planning
# ---------------------------------------------------------------------------
function Test-NewHireRecord {
    <#
    .SYNOPSIS
        Returns a list of problems with one CSV row. An empty list means the row is valid.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Config
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($field in 'FirstName', 'LastName', 'Department', 'JobTitle', 'EmployeeType', 'StartDate') {
        if ([string]::IsNullOrWhiteSpace((Get-PropValue $Record $field))) { $problems.Add("$field is required.") }
    }

    $dept = Get-PropValue $Record 'Department'
    if ($dept -and $null -eq (Get-PropValue $Config.DepartmentGroups $dept)) {
        $problems.Add("Department '$dept' has no group mapping in the config.")
    }

    $type = Get-PropValue $Record 'EmployeeType'
    if ($type -and $null -eq (Get-PropValue $Config.LicenseByEmployeeType $type)) {
        $problems.Add("EmployeeType '$type' has no license mapping in the config.")
    }

    $start = Get-PropValue $Record 'StartDate'
    if ($start) {
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($start, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
        if (-not $ok) { $problems.Add("StartDate '$start' must be yyyy-MM-dd.") }
    }

    $mgr = Get-PropValue $Record 'ManagerUpn'
    if ($mgr -and $mgr -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $problems.Add("ManagerUpn '$mgr' isn't a valid UPN.") }

    $loc = Get-PropValue $Record 'UsageLocation'
    if ($loc -and $loc -notmatch '^[A-Za-z]{2}$') { $problems.Add("UsageLocation '$loc' must be a 2-letter country code.") }

    # Emit each problem on the pipeline (no leading comma), so @(Test-NewHireRecord ...) is a flat list
    # and a valid row produces nothing at all.
    $problems
}

function Get-OnboardingPlan {
    <#
    .SYNOPSIS
        Turns new-hire rows into a reviewable plan: UPN, display name, groups, license, and any validation errors.
    .PARAMETER IsTaken
        Script block that returns $true for a UPN that already exists in the tenant.
        UPNs claimed earlier in the same batch are tracked automatically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)]$Config,
        [scriptblock]$IsTaken = { param($Upn) $false }
    )

    $claimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $external = $IsTaken
    $taken = { param($Upn) $claimed.Contains($Upn) -or [bool](& $external $Upn) }.GetNewClosure()

    $rowNumber = 1   # header is row 1
    foreach ($r in $Records) {
        $rowNumber++
        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($p in (Test-NewHireRecord -Record $r -Config $Config)) { $errors.Add($p) }

        $first = "$(Get-PropValue $r 'FirstName')".Trim()
        $last = "$(Get-PropValue $r 'LastName')".Trim()
        $dept = "$(Get-PropValue $r 'Department')".Trim()
        $type = "$(Get-PropValue $r 'EmployeeType')".Trim()

        $upn = $null
        if ($errors.Count -eq 0) {
            try {
                $upn = New-UniqueUpn -FirstName $first -LastName $last -Domain $Config.Domain -IsTaken $taken
                [void]$claimed.Add($upn)
            }
            catch { $errors.Add($_.Exception.Message) }
        }

        $deptGroups = @(Get-PropValue $Config.DepartmentGroups $dept)
        $usage = "$(Get-PropValue $r 'UsageLocation')".Trim()
        [pscustomobject]@{
            Row               = $rowNumber
            Status            = if ($errors.Count) { 'Invalid' } else { 'Ready' }
            Errors            = $errors -join ' '
            DisplayName       = "$first $last".Trim()
            GivenName         = $first
            Surname           = $last
            UserPrincipalName = $upn
            MailNickname      = if ($upn) { ($upn -split '@')[0] } else { $null }
            Department        = $dept
            JobTitle          = "$(Get-PropValue $r 'JobTitle')".Trim()
            EmployeeType      = $type
            StartDate         = "$(Get-PropValue $r 'StartDate')".Trim()
            ManagerUpn        = "$(Get-PropValue $r 'ManagerUpn')".Trim()
            UsageLocation     = if ($usage) { $usage.ToUpperInvariant() } else { $Config.UsageLocation }
            License           = Get-PropValue $Config.LicenseByEmployeeType $type
            Groups            = @($Config.BaseGroups) + @($deptGroups | Where-Object { $_ })
        }
    }
}

# ---------------------------------------------------------------------------
# Execution against Microsoft Graph
# ---------------------------------------------------------------------------
function New-GraphAdapter {
    <#
    .SYNOPSIS
        The real Microsoft Graph calls, wrapped so tests can swap in fakes.
        Requires: Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    #>
    @{
        GetSkus    = { Get-MgSubscribedSku -All -ErrorAction Stop }
        NewUser    = { param($Body) New-MgUser -BodyParameter $Body -ErrorAction Stop }
        SetLicense = { param($UserId, $SkuId) Set-MgUserLicense -UserId $UserId -AddLicenses @(@{ SkuId = $SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null }
        FindGroup  = { param($Name) @(Get-MgGroup -Filter "displayName eq '$($Name -replace "'", "''")'" -ErrorAction Stop) }
        AddMember  = { param($GroupId, $UserId) New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $UserId -ErrorAction Stop }
        GetUser    = { param($Upn) Get-MgUser -UserId $Upn -ErrorAction Stop }
        SetManager = { param($UserId, $ManagerId) Set-MgUserManagerByRef -UserId $UserId -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$ManagerId" } -ErrorAction Stop }
    }
}

function Invoke-OnboardingPlan {
    <#
    .SYNOPSIS
        Creates the users in a plan: account, license, groups, manager. Supports -WhatIf.
    .OUTPUTS
        One result per plan row. TemporaryPassword is a SecureString and is never written to logs.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [hashtable]$Graph = (New-GraphAdapter)
    )

    $skuIds = @{}
    $groupIds = @{}
    $ready = @($Plan | Where-Object Status -eq 'Ready')
    if ($ready.Count -and -not $WhatIfPreference) {
        foreach ($sku in (& $Graph.GetSkus)) { $skuIds[$sku.SkuPartNumber] = $sku.SkuId }
    }

    foreach ($item in $Plan) {
        $result = [ordered]@{
            Row = $item.Row; UserPrincipalName = $item.UserPrincipalName; DisplayName = $item.DisplayName
            Result = ''; Steps = ''; Detail = ''; TemporaryPassword = $null
        }

        if ($item.Status -ne 'Ready') {
            $result.Result = 'Skipped'; $result.Detail = $item.Errors
            [pscustomobject]$result; continue
        }

        $action = "Create user; license $($item.License); add to $(@($item.Groups).Count) groups" +
            $(if ($item.ManagerUpn) { "; manager $($item.ManagerUpn)" } else { '' })
        if (-not $PSCmdlet.ShouldProcess($item.UserPrincipalName, $action)) {
            $result.Result = 'WhatIf'; $result.Detail = $action
            [pscustomobject]$result; continue
        }

        $steps = [System.Collections.Generic.List[string]]::new()
        $plain = New-TemporaryPassword
        try {
            if ($item.License -and -not $skuIds.ContainsKey($item.License)) {
                throw "License '$($item.License)' isn't available in this tenant."
            }
            $user = & $Graph.NewUser @{
                accountEnabled    = $true
                displayName       = $item.DisplayName
                givenName         = $item.GivenName
                surname           = $item.Surname
                userPrincipalName = $item.UserPrincipalName
                mailNickname      = $item.MailNickname
                department        = $item.Department
                jobTitle          = $item.JobTitle
                usageLocation     = $item.UsageLocation     # required before a license can be assigned
                passwordProfile   = @{ password = $plain; forceChangePasswordNextSignIn = $true }
            }
            $steps.Add('user')

            if ($item.License) {
                & $Graph.SetLicense $user.Id $skuIds[$item.License]
                $steps.Add("license:$($item.License)")
            }

            foreach ($g in @($item.Groups)) {
                if (-not $groupIds.ContainsKey($g)) {
                    $found = @(& $Graph.FindGroup $g)
                    if ($found.Count -ne 1) { throw "Group '$g' matched $($found.Count) groups; expected exactly 1." }
                    $groupIds[$g] = $found[0].Id
                }
                & $Graph.AddMember $groupIds[$g] $user.Id
                $steps.Add("group:$g")
            }

            if ($item.ManagerUpn) {
                $mgr = & $Graph.GetUser $item.ManagerUpn
                & $Graph.SetManager $user.Id $mgr.Id
                $steps.Add('manager')
            }

            $result.Result = 'Created'
            $result.TemporaryPassword = ConvertTo-SecureString -String $plain -AsPlainText -Force
        }
        catch {
            $result.Result = if ($steps.Contains('user')) { 'Partial' } else { 'Failed' }
            $result.Detail = $_.Exception.Message
            if ($steps.Contains('user')) {
                $result.TemporaryPassword = ConvertTo-SecureString -String $plain -AsPlainText -Force
            }
        }
        finally {
            $plain = $null
        }
        $result.Steps = $steps -join ', '
        [pscustomobject]$result
    }
}

function Export-OnboardingLog {
    <#
    .SYNOPSIS
        Writes an audit log CSV of what happened. Passwords are never included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$Path,
        [string]$Mode = 'Live'
    )
    $runBy = try { (Get-MgContext -ErrorAction Stop).Account } catch { [Environment]::UserName }
    $stamp = (Get-Date).ToString('s')
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Results | ForEach-Object {
        [pscustomobject]@{
            Timestamp = $stamp; Mode = $Mode; RunBy = $runBy; Row = $_.Row
            UserPrincipalName = $_.UserPrincipalName; DisplayName = $_.DisplayName
            Result = $_.Result; Steps = $_.Steps; Detail = $_.Detail
        }
    } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    Get-Item -LiteralPath $Path
}

Export-ModuleMember -Function Import-OnboardingConfig, ConvertTo-UpnSafeName, New-UniqueUpn, New-TemporaryPassword,
    Test-NewHireRecord, Get-OnboardingPlan, New-GraphAdapter, Invoke-OnboardingPlan, Export-OnboardingLog
