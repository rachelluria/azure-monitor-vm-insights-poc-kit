@{
    RootModule           = 'IISLogRelocation.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'a7c3e2f1-9b4d-4e6a-8c1f-2d5b7e9a0c34'
    Author               = 'azure-monitor-configure-insights'
    CompanyName          = 'azure-monitor-configure-insights'
    Copyright            = '(c) azure-monitor-configure-insights'
    Description          = 'Detects IIS and relocates the inetpub\logs folder (W3C + FailedReqLogFiles) off the OS drive (C:) to a target drive (default E:). Usable interactively via Run Command / runbook and packageable as an Azure Machine Configuration DSC resource.'
    PowerShellVersion    = '5.1'

    FunctionsToExport    = @(
        'Get-IISLogRelocationState',
        'Test-IISLogRelocationCompliance',
        'Set-IISLogRelocation'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    # Exposes the class-based resource to Azure Machine Configuration / DSC.
    DscResourcesToExport = @('IISLogRelocation')

    PrivateData = @{
        PSData = @{
            Tags = @('IIS', 'Logs', 'AzureMachineConfiguration', 'GuestConfiguration', 'DSC', 'Arc')
        }
    }
}
