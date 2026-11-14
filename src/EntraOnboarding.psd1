@{
    RootModule        = 'EntraOnboarding.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5d0f3c2a-8b7e-4f1d-9a61-2c4e7b9d3f10'
    Author            = 'Ravi S. Jethva'
    Description       = 'CSV-driven new-hire provisioning for Microsoft Entra ID through Microsoft Graph, with validation, UPN collision handling, -WhatIf, and an audit log.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Import-OnboardingConfig', 'ConvertTo-UpnSafeName', 'New-UniqueUpn', 'New-TemporaryPassword',
        'Test-NewHireRecord', 'Get-OnboardingPlan', 'New-GraphAdapter', 'Invoke-OnboardingPlan', 'Export-OnboardingLog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('EntraID', 'AzureAD', 'MicrosoftGraph', 'Onboarding', 'Microsoft365')
        }
    }
}
