$repositoryRoot = Join-Path $PSScriptRoot '..'

function Get-FinalProjectedColumns {
    param([Parameter(Mandatory)][string]$Path)

    $query = Get-Content -LiteralPath $Path -Raw
    $projectIndex = $query.LastIndexOf('| project')
    $orderIndex = $query.IndexOf('| order by', $projectIndex)
    if ($projectIndex -lt 0 -or $orderIndex -lt 0) { throw "Final projection not found in '$Path'." }

    $projection = $query.Substring($projectIndex + 9, $orderIndex - ($projectIndex + 9)).Trim()
    return @($projection -split ',\s*\r?\n' | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z][A-Za-z0-9]*)') { $Matches[1] }
    })
}

Describe 'SQL Azure Resource Graph CSV queries' {
    $contracts = @(
        @{
            File = 'CheckSQLServerESUStatus.kql'
            Columns = @('SubscriptionId', 'ServerResourceGroupName', 'ARCServerName')
        },
        @{
            File = 'InstallSQLServerArcExtension.kql'
            Columns = @('SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'LicenseType', 'ConfirmExternalPrerequisites')
        },
        @{
            File = 'SetSQLServerESUSubscription.kql'
            Columns = @(
                'SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'Action', 'LicenseType',
                'Environment', 'AcceptBackBilling', 'AcceptLicenseTypeChange',
                'ConfirmNonProductionCoverage', 'ConfirmExternalPrerequisites'
            )
        }
    )

    foreach ($contract in $contracts) {
        It "projects the exact CSV contract for $($contract.File)" {
            $path = Join-Path $repositoryRoot "samples/$($contract.File)"
            (Test-Path -LiteralPath $path -PathType Leaf) | Should Be $true
            ((Get-FinalProjectedColumns -Path $path) -join ',') | Should Be ($contract.Columns -join ',')
            (Get-Content -LiteralPath $path -Raw) | Should Not Match '(?m)^\s*let\s+'
        }
    }

    It 'requires explicit installation choices before returning rows' {
        $query = Get-Content -LiteralPath (Join-Path $repositoryRoot 'samples/InstallSQLServerArcExtension.kql') -Raw
        $query | Should Match "SelectedLicenseType = 'REPLACE_WITH_Paid_PAYG_OR_LicenseOnly'"
        $query | Should Match "ConfirmExternalPrerequisites = 'FALSE'"
    }

    It 'defaults lifecycle billing and prerequisite acknowledgements to false' {
        $query = Get-Content -LiteralPath (Join-Path $repositoryRoot 'samples/SetSQLServerESUSubscription.kql') -Raw
        $query | Should Match "AcceptBackBilling = 'FALSE'"
        $query | Should Match "ConfirmExternalPrerequisites = 'FALSE'"
        $query | Should Match 'summarize\s+EligibleInstanceCount'
        $query | Should Match 'by MachineResourceId'
    }
}