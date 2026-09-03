$subscriptionId = '00000000-0000-0000-0000-000000000001'
$tenantId = '00000000-0000-0000-0000-000000000002'
$appId = '00000000-0000-0000-0000-000000000003'
$csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assignments-$PID.csv"

@'
LicenseName,licenseResourceGroupName,ServerResourceGroupName,Name,AssignESULicense
license-01,license-rg,server-rg,server-01,True
'@ | Set-Content -Path $csvPath

$scriptCases = @(
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\AssignESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01' -location 'eastus'"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\CreateESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -location 'eastus' -state 'Deactivated' -edition 'Standard' -coreType 'vCore' -coreCount 8"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\DeleteESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01'"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\ManageESUAssignments.ps1'
        Arguments = "-arcServerSubscriptionId '$subscriptionId' -location 'eastus' -csvFilePath '$csvPath'"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\ManageESUAssignmentsFR.ps1'
        Arguments = "-arcServerSubscriptionId '$subscriptionId' -location 'eastus' -csvFilePath '$csvPath'"
    }
)

function Invoke-AuthenticationScenario {
    param(
        [string]$Path,
        [string]$Arguments,
        [ValidateSet('MissingCredentials', 'ExpiredToken', 'TokenAcquisitionFailure')]
        [string]$Scenario
    )

    $escapedPath = $Path.Replace("'", "''")
    $scenarioSetup = switch ($Scenario) {
        'MissingCredentials' { '' }
        'ExpiredToken' {
            @"
`$expiredToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(-5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
"@
        }
        'TokenAcquisitionFailure' {
            @"
function global:Invoke-WebRequest { throw 'mocked token acquisition failure' }
function global:Start-Sleep {}
function global:Invoke-RestMethod { [Environment]::Exit(9) }
"@
        }
    }

    $scenarioArguments = switch ($Scenario) {
        'ExpiredToken' { '-userToken $expiredToken' }
        'TokenAcquisitionFailure' { "-tenantId '$tenantId' -appID '$appId' -clientSecret 'placeholder-secret'" }
        default { '' }
    }

    $command = @"
& {
$scenarioSetup
    & '$escapedPath' $Arguments $scenarioArguments
    exit `$LASTEXITCODE
}
"@

    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command *> $null
    return $LASTEXITCODE
}

foreach ($scriptCase in $scriptCases) {
    $scriptName = Split-Path $scriptCase.Path -Leaf

    Describe "Authentication exits in $scriptName" {
        It 'returns exit code 1 when credentials are missing' {
            $exitCode = Invoke-AuthenticationScenario `
                -Path $scriptCase.Path `
                -Arguments $scriptCase.Arguments `
                -Scenario MissingCredentials

            $exitCode | Should Be 1
        }

        It 'returns exit code 1 when the user token is expired' {
            $exitCode = Invoke-AuthenticationScenario `
                -Path $scriptCase.Path `
                -Arguments $scriptCase.Arguments `
                -Scenario ExpiredToken

            $exitCode | Should Be 1
        }

        It 'returns exit code 1 without reaching REST when token acquisition fails' {
            $exitCode = Invoke-AuthenticationScenario `
                -Path $scriptCase.Path `
                -Arguments $scriptCase.Arguments `
                -Scenario TokenAcquisitionFailure

            $exitCode | Should Be 1
        }
    }
}

Remove-Item -Path $csvPath -ErrorAction SilentlyContinue