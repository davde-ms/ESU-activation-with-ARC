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
        },
        @{
            File = 'SetSQLServerLicenseType.kql'
            Columns = @(
                'SubscriptionId', 'ServerResourceGroupName', 'ARCServerName', 'LicenseType',
                'AttestSoftwareAssurance', 'AcceptPaygBilling', 'ConsentToRecurringPAYG',
                'ConfirmCoreBasedEnterpriseLicense'
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
        $query | Should Match "SelectedLicenseType = 'REPLACE_WITH_Paid_OR_LicenseOnly'"
        $query | Should Match "ConfirmExternalPrerequisites = 'FALSE'"
    }

    It 'defaults lifecycle billing and prerequisite acknowledgements to false' {
        $query = Get-Content -LiteralPath (Join-Path $repositoryRoot 'samples/SetSQLServerESUSubscription.kql') -Raw
        $query | Should Match "AcceptBackBilling = 'FALSE'"
        $query | Should Match "ConfirmExternalPrerequisites = 'FALSE'"
        $query | Should Match 'summarize\s+EligibleInstanceCount'
        $query | Should Match 'by MachineResourceId'
    }

    It 'returns only empty LicenseType hosts and defaults license acknowledgements to false' {
        $query = Get-Content -LiteralPath (Join-Path $repositoryRoot 'samples/SetSQLServerLicenseType.kql') -Raw
        $query | Should Match "SelectedLicenseType = 'REPLACE_WITH_Paid_OR_PAYG_OR_LicenseOnly'"
        $query | Should Match 'where isempty\(tostring\(properties\.settings\.LicenseType\)\)'
        foreach ($field in @('AttestSoftwareAssurance', 'AcceptPaygBilling', 'ConsentToRecurringPAYG', 'ConfirmCoreBasedEnterpriseLicense')) {
            $query | Should Match "$field = 'FALSE'"
            $query | Should Match "$field = toupper\($field\)"
            $query | Should Match "$field in \('TRUE', 'FALSE'\)"
        }
        $query | Should Match "resourceGroup matches regex @'\^\[a-zA-Z0-9_\(\)\.-\]\{1,90\}\$' and not\(resourceGroup endswith '\.'\)"
        $query | Should Match "name matches regex @'\^\[a-zA-Z0-9_\.-\]\{1,54\}\$'"
    }

    It 'ships a license sample CSV with the exact script columns' {
        $header = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'samples/SetSQLServerLicenseType.csv') -TotalCount 1)
        $header | Should Be 'SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,AttestSoftwareAssurance,AcceptPaygBilling,ConsentToRecurringPAYG,ConfirmCoreBasedEnterpriseLicense'
    }
}