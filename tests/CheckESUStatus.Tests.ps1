$scriptPath = Join-Path $PSScriptRoot '..\Scripts\CheckESUStatus.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$overrideSubscriptionId = '00000000-0000-0000-0000-000000000002'
$statusCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-status-$PID.csv"
$invalidStatusCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-status-invalid-$PID.csv"
$requestTracePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-status-requests-$PID.txt"

@"
Name,ARCServerName,ServerResourceGroupName,SubscriptionId
server-name,,server-rg,$overrideSubscriptionId
,server-arc,server-rg,
"@ | Set-Content -Path $statusCsvPath

@'
Name,ARCServerName,ServerResourceGroupName,SubscriptionId
,,server-rg,
'@ | Set-Content -Path $invalidStatusCsvPath

function Import-CheckStatusFunction {
    param(
        [string]$Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Unable to parse '$scriptPath': $($parseErrors.Message -join '; ')"
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true)

    if ($null -eq $functionAst) {
        throw "Function '$Name' was not found in '$scriptPath'."
    }

    $bodyText = $functionAst.Body.Extent.Text
    $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
    Set-Item -Path "Function:\global:$Name" -Value ([scriptblock]::Create($bodyText))
}

function Invoke-StatusScenario {
    param(
        [string]$Arguments,
        [ValidateSet('Licensed', 'MixedCsv', 'RestFailure')]
        [string]$Scenario
    )

    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $escapedTracePath = $requestTracePath.Replace("'", "''")
    $responseBody = switch ($Scenario) {
        'RestFailure' { "throw 'mocked REST failure'" }
        'MixedCsv' {
            @"
Add-Content -Path '$escapedTracePath' -Value `$Uri
if (`$Uri -match '/server-name/licenseProfiles/') {
    return [pscustomobject]@{
        location = 'eastus'
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'
            esuProfile = [pscustomobject]@{
                assignedLicense = '/subscriptions/$overrideSubscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01'
            }
        }
    }
}
return [pscustomobject]@{
    location = 'eastus'
    properties = [pscustomobject]@{
        provisioningState = 'Succeeded'
        esuProfile = [pscustomobject]@{}
    }
}
"@
        }
        default {
            @"
return [pscustomobject]@{
    location = 'eastus'
    properties = [pscustomobject]@{
        provisioningState = 'Succeeded'
        esuProfile = [pscustomobject]@{
            assignedLicense = '/subscriptions/$subscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01'
        }
    }
}
"@
        }
    }

    $command = @"
function global:Clear-Host {}
function global:Write-Progress {}
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers)
    $responseBody
}
`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' $Arguments -userToken `$token
exit `$LASTEXITCODE
"@

    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

Describe 'CheckESUStatus parameter and retry contracts' {
    It 'retains location as an optional compatibility parameter' {
        $command = Get-Command -Name $scriptPath

        $command.Parameters['location'].Attributes.Mandatory | Should Be $false
    }

    It 'uses the requested authentication retry count and delay' {
        Import-CheckStatusFunction -Name Get-AzureADBearerToken
        Import-CheckStatusFunction -Name Write-Logfile
        $script:CONFIG = @{
            AzureResourceUrl = 'https://management.azure.com/'
            LoginEndpoint = 'https://login.microsoftonline.com'
        }

        Mock Invoke-WebRequest { throw 'mocked authentication failure' }
        Mock Write-Logfile {}
        Mock Start-Sleep {}

        $result = Get-AzureADBearerToken `
            -appID '00000000-0000-0000-0000-000000000003' `
            -clientSecret 'placeholder-secret' `
            -tenantId '00000000-0000-0000-0000-000000000002' `
            -retryCount 2 `
            -retryDelaySeconds 7

        $result | Should BeNullOrEmpty
        Assert-MockCalled Invoke-WebRequest 2
        Assert-MockCalled Start-Sleep 1 -ParameterFilter { $Seconds -eq 7 }
    }
}

Describe 'CheckESUStatus process behavior' {
    BeforeEach {
        Remove-Item -Path $requestTracePath -ErrorAction SilentlyContinue
    }

    It 'checks one server without requiring location and reports licensed status' {
        $result = Invoke-StatusScenario `
            -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01'" `
            -Scenario Licensed

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Total servers checked: 1'
        $result.Output | Should Match 'Servers with assigned ESU license resource IDs: 1'
        $result.Output | Should Match 'Servers with errors: 0'
    }

    It 'supports both server-name columns and per-row subscription overrides' {
        $result = Invoke-StatusScenario `
            -Arguments "-subscriptionId '$subscriptionId' -csvFilePath '$statusCsvPath'" `
            -Scenario MixedCsv

        $requests = @(Get-Content -Path $requestTracePath)
        $result.ExitCode | Should Be 0
        $requests.Count | Should Be 2
        $requests[0] | Should Match "/subscriptions/$overrideSubscriptionId/.+/server-name/licenseProfiles/"
        $requests[1] | Should Match "/subscriptions/$subscriptionId/.+/server-arc/licenseProfiles/"
        $result.Output | Should Match 'Servers with assigned ESU license resource IDs: 1'
        $result.Output | Should Match 'Servers without ESU licenses: 1'
    }

    It 'returns exit code 1 when a status REST request fails' {
        $result = Invoke-StatusScenario `
            -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01'" `
            -Scenario RestFailure

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Servers with errors: 1'
    }

    It 'counts an invalid CSV row as an error and returns exit code 1' {
        $result = Invoke-StatusScenario `
            -Arguments "-subscriptionId '$subscriptionId' -csvFilePath '$invalidStatusCsvPath'" `
            -Scenario Licensed

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Total servers checked: 1'
        $result.Output | Should Match 'Servers with errors: 1'
    }

    It 'returns exit code 1 when CSV export fails' {
        $missingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "missing-esu-export-$PID"
        Remove-Item -Path $missingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        $exportPath = Join-Path $missingDirectory 'status.csv'

        $result = Invoke-StatusScenario `
            -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01' -exportCsvPath '$exportPath'" `
            -Scenario Licensed

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Failed to export results to CSV'
    }
}

Remove-Item -Path $statusCsvPath, $invalidStatusCsvPath, $requestTracePath -ErrorAction SilentlyContinue
