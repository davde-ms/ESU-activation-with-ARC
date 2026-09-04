$scriptPath = Join-Path $PSScriptRoot '..\Scripts\CreateESULicense.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'

function Invoke-CreateESULicenseScenario {
    param(
        [string]$AdditionalArguments,
        [switch]$RestFailure,
        [switch]$Preview
    )

    $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-create-record-$PID-$([guid]::NewGuid().ToString('N')).json"
    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $escapedRecordPath = $recordPath.Replace("'", "''")
    $restBehavior = if ($RestFailure) {
        "throw 'mocked create failure'"
    } else {
        @"
[pscustomobject]@{
    Uri = [string]`$Uri
    Method = [string]`$Method
    Body = [string]`$Body
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath '$escapedRecordPath'
return 'mocked-create-response'
"@
    }
    $whatIfArgument = if ($Preview) { '-WhatIf' } else { '' }
    $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    $restBehavior
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -location 'eastus' -state Deactivated -edition Standard -coreType vCore -coreCount 8 -userToken `$authToken $AdditionalArguments $whatIfArgument
if (-not `$?) { exit 1 }
exit `$LASTEXITCODE
"@

    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $record = if (Test-Path -LiteralPath $recordPath) {
        Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    } else {
        $null
    }
    Remove-Item -LiteralPath $recordPath -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        Record = $record
    }
}

Describe 'CreateESULicense current Windows Server 2012 contract' {
    It 'defaults to the 2012 payload and current create URI' {
        $result = Invoke-CreateESULicenseScenario

        $result.ExitCode | Should Be 0
        $result.Record.Method | Should Be 'PUT'
        $result.Record.Uri | Should Be "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01?api-version=2026-06-16-preview"
        $body = $result.Record.Body | ConvertFrom-Json
        $body.location | Should Be 'eastus'
        $body.properties.licenseDetails.target | Should Be 'Windows Server 2012'
        $body.properties.licenseDetails.state | Should Be 'Deactivated'
        $body.properties.licenseDetails.edition | Should Be 'Standard'
        $body.properties.licenseDetails.Type | Should Be 'vCore'
        $body.properties.licenseDetails.Processors | Should Be 8
        $body.tags.CreatedBy | Should Be 'CreateESULicense.ps1'
    }

    It 'returns the mocked ARM response on success' {
        $result = Invoke-CreateESULicenseScenario

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'mocked-create-response'
    }

    It 'returns exit code 1 when the create request fails' {
        $result = Invoke-CreateESULicenseScenario -RestFailure

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'mocked create failure'
    }

    It 'sends no REST request during WhatIf' {
        $result = Invoke-CreateESULicenseScenario -Preview

        $result.ExitCode | Should Be 0
        $result.Record | Should BeNullOrEmpty
    }
}

Describe 'CreateESULicense planned target contract' {
    foreach ($target in @('Windows Server 2012', 'Windows Server 2012 R2', 'Windows Server 2016')) {
        It "[Phase 2] accepts and emits the exact target '$target'" {
            $result = Invoke-CreateESULicenseScenario -AdditionalArguments "-target '$target'"

            $result.ExitCode | Should Be 0
            $actualTarget = if ($null -ne $result.Record -and $null -ne $result.Record.Body) {
                ($result.Record.Body | ConvertFrom-Json).properties.licenseDetails.target
            } else {
                $null
            }
            $actualTarget | Should Be $target
            $result.Record.Uri | Should Be "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01?api-version=2026-06-16-preview"
        }
    }

    It '[Phase 2] rejects an invalid target through ValidateSet before authentication or REST' {
        $result = Invoke-CreateESULicenseScenario -AdditionalArguments "-target 'Windows Server 2019'"

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Windows Server 2012.*Windows Server 2012 R2.*Windows Server 2016'
        $result.Record | Should BeNullOrEmpty
    }

    It '[Phase 2] includes the target in verbose payload output without credentials' {
        $result = Invoke-CreateESULicenseScenario -AdditionalArguments "-target 'Windows Server 2016' -Verbose"

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'License request payload for target.*Windows Server 2016'
        $result.Output | Should Not Match 'placeholder-token'
    }
}