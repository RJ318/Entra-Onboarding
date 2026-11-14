#Requires -Version 7.0
# Pester 5 tests. Run from the repo root:
#   Invoke-Pester ./projects/entra-onboarding/tests -Output Detailed

Describe 'EntraOnboarding' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/EntraOnboarding.psd1') -Force
        $script:root = Join-Path $PSScriptRoot '..'
        $script:config = Import-OnboardingConfig -Path (Join-Path $script:root 'config/onboarding-config.json')

        function script:New-ValidRecord {
            [pscustomobject]@{
                FirstName = 'Maria'; LastName = 'Alvarez'; Department = 'Finance'; JobTitle = 'Staff Accountant'
                EmployeeType = 'Employee'; StartDate = '2026-10-05'; ManagerUpn = 'dana.brooks@contoso.com'; UsageLocation = 'US'
            }
        }

        # A fake Microsoft Graph: records every call, returns predictable objects.
        function script:New-FakeGraph {
            param(
                [string[]]$Skus = @('SPE_E3', 'SPE_F1'),
                [string[]]$MissingGroups = @()
            )
            $calls = [System.Collections.Generic.List[string]]::new()
            @{
                Calls      = $calls
                GetSkus    = { $calls.Add('GetSkus'); foreach ($s in $Skus) { [pscustomobject]@{ SkuPartNumber = $s; SkuId = "sku-$s" } } }.GetNewClosure()
                NewUser    = { param($Body) $calls.Add("NewUser:$($Body.userPrincipalName)"); [pscustomobject]@{ Id = "id-$($Body.mailNickname)"; Body = $Body } }.GetNewClosure()
                SetLicense = { param($UserId, $SkuId) $calls.Add("SetLicense:${UserId}:${SkuId}") }.GetNewClosure()
                FindGroup  = { param($Name) $calls.Add("FindGroup:$Name"); if ($MissingGroups -contains $Name) { @() } else { @([pscustomobject]@{ Id = "grp-$Name" }) } }.GetNewClosure()
                AddMember  = { param($GroupId, $UserId) $calls.Add("AddMember:${GroupId}:${UserId}") }.GetNewClosure()
                GetUser    = { param($Upn) $calls.Add("GetUser:$Upn"); [pscustomobject]@{ Id = "id-$Upn" } }.GetNewClosure()
                SetManager = { param($UserId, $ManagerId) $calls.Add("SetManager:${UserId}:${ManagerId}") }.GetNewClosure()
            }
        }
    }

    Context 'ConvertTo-UpnSafeName' {
        It 'strips accents' {
            ConvertTo-UpnSafeName 'José' | Should -Be 'jose'
            ConvertTo-UpnSafeName 'Zoë' | Should -Be 'zoe'
        }
        It 'removes apostrophes and spaces' {
            ConvertTo-UpnSafeName "O'Brien" | Should -Be 'obrien'
            ConvertTo-UpnSafeName 'Mary Kate' | Should -Be 'marykate'
        }
        It 'keeps hyphenated surnames' {
            ConvertTo-UpnSafeName 'Smith-Jones' | Should -Be 'smith-jones'
        }
    }

    Context 'New-UniqueUpn' {
        It 'returns first.last when it is free' {
            New-UniqueUpn -FirstName 'Maria' -LastName 'Alvarez' -Domain 'contoso.com' -IsTaken { param($u) $false } |
                Should -Be 'maria.alvarez@contoso.com'
        }
        It 'adds a number when the name is taken' {
            $taken = @('maria.alvarez@contoso.com', 'maria.alvarez2@contoso.com')
            New-UniqueUpn -FirstName 'Maria' -LastName 'Alvarez' -Domain 'contoso.com' -IsTaken { param($u) $taken -contains $u }.GetNewClosure() |
                Should -Be 'maria.alvarez3@contoso.com'
        }
        It 'refuses a name with no usable characters' {
            { New-UniqueUpn -FirstName '---' -LastName 'Smith' -Domain 'contoso.com' -IsTaken { param($u) $false } } |
                Should -Throw "*Can't build a UPN*"
        }
    }

    Context 'New-TemporaryPassword' {
        It 'is 16 characters with upper, lower, digit, and symbol' {
            $p = New-TemporaryPassword
            $p.Length | Should -Be 16
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -Match '[0-9]'
            $p | Should -Match '[!@#$%*?-]'
        }
        It 'never uses look-alike characters' {
            foreach ($i in 1..50) { New-TemporaryPassword | Should -Not -MatchExactly '[OIl01o]' }
        }
        It 'is different every time' {
            $set = foreach ($i in 1..100) { New-TemporaryPassword }
            @($set | Select-Object -Unique) | Should -HaveCount 100
        }
    }

    Context 'Test-NewHireRecord' {
        It 'accepts a complete, valid row' {
            @(Test-NewHireRecord -Record (New-ValidRecord) -Config $config).Count | Should -Be 0
        }
        It 'reports each missing required field' {
            $r = New-ValidRecord; $r.FirstName = ''; $r.JobTitle = ' '
            $problems = @(Test-NewHireRecord -Record $r -Config $config)
            $problems | Should -Contain 'FirstName is required.'
            $problems | Should -Contain 'JobTitle is required.'
        }
        It 'rejects a department with no group mapping' {
            $r = New-ValidRecord; $r.Department = 'Legal'
            (Test-NewHireRecord -Record $r -Config $config) -join ' ' | Should -Match "Department 'Legal'"
        }
        It 'rejects dates that are not yyyy-MM-dd' {
            $r = New-ValidRecord; $r.StartDate = '10/05/2026'
            (Test-NewHireRecord -Record $r -Config $config) -join ' ' | Should -Match 'must be yyyy-MM-dd'
        }
        It 'rejects a malformed manager UPN' {
            $r = New-ValidRecord; $r.ManagerUpn = 'dana brooks'
            (Test-NewHireRecord -Record $r -Config $config) -join ' ' | Should -Match "ManagerUpn 'dana brooks'"
        }
    }

    Context 'Get-OnboardingPlan with the sample CSV' {
        BeforeAll {
            $records = @(Import-Csv (Join-Path $root 'sample/new-hires.csv'))
            $existing = @(Get-Content (Join-Path $root 'sample/existing-upns.txt') | Where-Object { $_ -notmatch '^#' })
            $script:plan = @(Get-OnboardingPlan -Records $records -Config $config -IsTaken { param($u) $existing -contains $u }.GetNewClosure())
        }
        It 'plans every row' {
            $plan | Should -HaveCount 9
        }
        It 'handles collisions with the tenant and inside the same batch' {
            ($plan | Where-Object Row -eq 5).UserPrincipalName | Should -Be 'daniel.chen2@contoso.com'   # daniel.chen exists
            ($plan | Where-Object Row -eq 6).UserPrincipalName | Should -Be 'daniel.chen3@contoso.com'   # second Daniel Chen in this CSV
            ($plan | Where-Object Row -eq 7).UserPrincipalName | Should -Be 'priya.shah2@contoso.com'
        }
        It 'builds clean UPNs from accented and punctuated names' {
            ($plan | Where-Object Row -eq 3).UserPrincipalName | Should -Be 'jose.martinez@contoso.com'
            ($plan | Where-Object Row -eq 4).UserPrincipalName | Should -Be 'aisha.obrien@contoso.com'
            ($plan | Where-Object Row -eq 10).UserPrincipalName | Should -Be 'zoe.lindqvist@contoso.com'
        }
        It 'marks bad rows Invalid and gives them no UPN' {
            $bad = @($plan | Where-Object Status -eq 'Invalid')
            $bad | Should -HaveCount 2
            foreach ($b in $bad) { $b.UserPrincipalName | Should -BeNullOrEmpty }
        }
        It 'maps groups by department and license by employee type' {
            $aisha = $plan | Where-Object Row -eq 4
            $aisha.License | Should -Be 'SPE_F1'
            $aisha.Groups | Should -Contain 'All Staff'
            $aisha.Groups | Should -Contain 'Adobe Creative Cloud Users'
        }
        It 'uses the row UsageLocation, or the config default' {
            ($plan | Where-Object Row -eq 10).UsageLocation | Should -Be 'GB'
            ($plan | Where-Object Row -eq 2).UsageLocation | Should -Be 'US'
        }
    }

    Context 'Invoke-OnboardingPlan against a fake Graph' {
        BeforeAll {
            $script:onePlan = @(Get-OnboardingPlan -Records @(New-ValidRecord) -Config $config)
        }
        It 'creates the user, then license, groups, and manager' {
            $g = New-FakeGraph
            $r = Invoke-OnboardingPlan -Plan $onePlan -Graph $g
            $r.Result | Should -Be 'Created'
            $g.Calls | Should -Contain 'NewUser:maria.alvarez@contoso.com'
            $g.Calls | Should -Contain 'SetLicense:id-maria.alvarez:sku-SPE_E3'
            $g.Calls | Should -Contain 'AddMember:grp-NetSuite Users:id-maria.alvarez'
            $g.Calls | Should -Contain 'SetManager:id-maria.alvarez:id-dana.brooks@contoso.com'
            @($g.Calls | Where-Object { $_ -like 'AddMember:*' }) | Should -HaveCount 4
        }
        It 'forces a password change at first sign-in' {
            $g = New-FakeGraph
            $box = @{}
            $inner = $g.NewUser
            $g.NewUser = { param($Body) $box.Body = $Body; & $inner $Body }.GetNewClosure()
            Invoke-OnboardingPlan -Plan $onePlan -Graph $g | Out-Null
            $box.Body.passwordProfile.forceChangePasswordNextSignIn | Should -BeTrue
            $box.Body.usageLocation | Should -Be 'US'
        }
        It 'skips invalid rows without calling Graph' {
            $r = New-ValidRecord; $r.Department = 'Legal'
            $bad = @(Get-OnboardingPlan -Records @($r) -Config $config)
            $g = New-FakeGraph
            (Invoke-OnboardingPlan -Plan $bad -Graph $g).Result | Should -Be 'Skipped'
            $g.Calls.Count | Should -Be 0
        }
        It 'makes no Graph calls with -WhatIf' {
            $g = New-FakeGraph
            (Invoke-OnboardingPlan -Plan $onePlan -Graph $g -WhatIf).Result | Should -Be 'WhatIf'
            $g.Calls.Count | Should -Be 0
        }
        It 'stops before creating anyone when the license is not in the tenant' {
            $g = New-FakeGraph -Skus @('SPE_F1')
            $r = Invoke-OnboardingPlan -Plan $onePlan -Graph $g
            $r.Result | Should -Be 'Failed'
            $r.Detail | Should -Match "License 'SPE_E3' isn't available"
            @($g.Calls | Where-Object { $_ -like 'NewUser:*' }).Count | Should -Be 0
        }
        It 'reports Partial when a group is missing, and still hands back the password' {
            $g = New-FakeGraph -MissingGroups @('NetSuite Users')
            $r = Invoke-OnboardingPlan -Plan $onePlan -Graph $g
            $r.Result | Should -Be 'Partial'
            $r.Detail | Should -Match "Group 'NetSuite Users' matched 0 groups"
            $r.TemporaryPassword | Should -BeOfType ([securestring])
        }
        It 'returns the password as a SecureString and keeps it out of the audit log' {
            $g = New-FakeGraph
            $r = @(Invoke-OnboardingPlan -Plan $onePlan -Graph $g)
            $r[0].TemporaryPassword | Should -BeOfType ([securestring])
            $plain = $r[0].TemporaryPassword | ConvertFrom-SecureString -AsPlainText
            $logPath = Join-Path ([IO.Path]::GetTempPath()) "onboarding-test-$([guid]::NewGuid()).csv"
            Export-OnboardingLog -Results $r -Path $logPath -Mode 'Test' | Out-Null
            $log = Get-Content -Raw $logPath
            Remove-Item $logPath
            $log | Should -Match 'maria.alvarez@contoso.com'
            $log.Contains($plain) | Should -BeFalse
            $log | Should -Not -Match 'TemporaryPassword'
        }
    }
}
