$scriptPath = Join-Path $PSScriptRoot '..\Scripts\ManageESULicenses.ps1'

function Import-ManageESULicensesFunctions {
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

    foreach ($functionName in @('ConvertTo-ESULicensePlan', 'CountResources')) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)

        if ($null -eq $functionAst) {
            throw "Function '$functionName' was not found in '$scriptPath'."
        }

        $bodyText = $functionAst.Body.Extent.Text
        $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
        Set-Item -Path "Function:\global:$functionName" -Value ([scriptblock]::Create($bodyText))
    }
}

Describe 'ManageESULicenses customer safety helpers' {
    BeforeEach {
        Import-ManageESULicensesFunctions
        $global:subscriptionId = '00000000-0000-0000-0000-000000000001'
    }

    It 'normalizes valid virtual and physical core counts in the preview plan' {
        $rows = @(
            [pscustomobject]@{
                Name = 'virtual-01'
                Cores = '9'
                IsVirtual = 'Virtual'
                AgentVersion = '1.34'
                ServerResourceGroupName = 'server-rg'
                AssignESULicense = 'True'
                ESUException = ''
            },
            [pscustomobject]@{
                Name = 'physical-01'
                Cores = '6'
                IsVirtual = 'Physical'
                AgentVersion = '1.35'
                ServerResourceGroupName = 'server-rg'
                AssignESULicense = ''
                ESUException = ''
            }
        )

        $plan = @(ConvertTo-ESULicensePlan -csvData $rows -edition Standard -licenseNamePrefix 'ESU-' -licenseNameSuffix '')

        $plan.Count | Should Be 2
        $plan[0].CoreType | Should Be 'vCore'
        $plan[0].CoreCount | Should Be 10
        $plan[0].AssignmentAction | Should Be 'Assign'
        $plan[1].CoreType | Should Be 'pCore'
        $plan[1].CoreCount | Should Be 16
        $plan[1].AssignmentAction | Should Be 'None'
    }

    It 'reports every invalid row before execution' {
        $rows = @(
            [pscustomobject]@{
                Name = 'bad-cores'
                Cores = 'not-a-number'
                IsVirtual = 'Virtual'
                AgentVersion = '1.34'
                ServerResourceGroupName = 'server-rg'
                AssignESULicense = 'True'
            },
            [pscustomobject]@{
                Name = 'bad-type'
                Cores = '8'
                IsVirtual = 'Unknown'
                AgentVersion = '1.34'
                ServerResourceGroupName = 'server-rg'
                AssignESULicense = 'True'
            }
        )

        $message = $null
        try {
            ConvertTo-ESULicensePlan -csvData $rows -edition Standard
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "Row 2, column 'Cores'"
        $message | Should Match "Row 3, column 'IsVirtual'"
    }

    It 'rejects unsupported and over-limit licensing combinations' {
        $virtualDatacenter = [pscustomobject]@{
            Name = 'virtual-dc'
            Cores = '8'
            IsVirtual = 'Virtual'
            AgentVersion = '1.34'
            ServerResourceGroupName = 'server-rg'
            AssignESULicense = 'True'
        }
        $overLimit = [pscustomobject]@{
            Name = 'too-many-cores'
            Cores = '10001'
            IsVirtual = 'Physical'
            AgentVersion = '1.34'
            ServerResourceGroupName = 'server-rg'
            AssignESULicense = ''
        }

        $virtualMessage = $null
        $limitMessage = $null
        try {
            ConvertTo-ESULicensePlan -csvData @($virtualDatacenter) -edition Datacenter
        } catch {
            $virtualMessage = $_.Exception.Message
        }
        try {
            ConvertTo-ESULicensePlan -csvData @($overLimit) -edition Standard
        } catch {
            $limitMessage = $_.Exception.Message
        }

        $virtualMessage | Should Match 'virtual-core licenses must use Standard edition'
        $limitMessage | Should Match 'exceeds the 10,000-core limit'
    }

    It 'rejects invalid generated license and assignment server names' {
        $invalidLicenseName = [pscustomobject]@{
            Name = 'server/name'
            Cores = '8'
            IsVirtual = 'Virtual'
            AgentVersion = '1.34'
            ServerResourceGroupName = ''
            AssignESULicense = ''
        }
        $longServerName = [pscustomobject]@{
            Name = 'server-name-that-is-longer-than-fifty-four-characters-for-arc'
            Cores = '8'
            IsVirtual = 'Virtual'
            AgentVersion = '1.34'
            ServerResourceGroupName = 'server-rg'
            AssignESULicense = 'True'
        }

        $message = $null
        try {
            ConvertTo-ESULicensePlan -csvData @($invalidLicenseName, $longServerName) -edition Standard -licenseNamePrefix 'ESU-' -licenseNameSuffix ''
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "final license name 'ESU-server/name'"
        $message | Should Match 'Azure Arc server names used for assignment or unlinking must be 1-54 characters'
    }

    It 'follows resource-list pagination when enforcing the resource-group limit' {
        $script:requestCount = 0
        Mock Invoke-RestMethod {
            $script:requestCount++
            if ($script:requestCount -eq 1) {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{ name = 'existing-01'; type = 'Microsoft.HybridCompute/licenses' })
                    nextLink = 'https://management.azure.com/next-page'
                }
            }

            return [pscustomobject]@{
                value = @([pscustomobject]@{ name = 'existing-02'; type = 'Microsoft.HybridCompute/licenses' })
                nextLink = $null
            }
        }
        $plans = @(
            [pscustomobject]@{ LicenseName = 'existing-01'; CreationAction = 'CreateOrModify' },
            [pscustomobject]@{ LicenseName = 'new-01'; CreationAction = 'CreateOrModify' }
        )

        $result = @(CountResources -token 'placeholder-token' -licenseResourceGroupName 'license-rg' -licensePlans $plans)

        $result[0] | Should Be 2
        $result[1] | Should Be 1
        Assert-MockCalled Invoke-RestMethod 2
    }
}

Describe 'ManageESULicenses process safety' {
    $validCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-valid-$PID.csv"
    $invalidCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-invalid-$PID.csv"
    $mixedAgentCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-agent-versions-$PID.csv"
    $activeCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-active-$PID.csv"

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException
server-01,8,Virtual,1.34,server-rg,True,
'@ | Set-Content -Path $validCsvPath

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException
server-01,invalid,Virtual,1.34,server-rg,True,
'@ | Set-Content -Path $invalidCsvPath

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException
server-current,8,Virtual,1.34,server-rg,True,
server-old,8,Virtual,1.33,server-rg,True,
'@ | Set-Content -Path $mixedAgentCsvPath

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException
server-assign,8,Virtual,1.34,server-rg,True,
server-unlink,8,Virtual,1.34,server-rg,False,
'@ | Set-Content -Path $activeCsvPath

    function Invoke-ManageESULicensesScenario {
        param(
            [string]$CsvPath,
            [switch]$DryRun
        )

        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $CsvPath.Replace("'", "''")
        $dryRunArgument = if ($DryRun) { '-DryRun' } else { '' }
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method)
    if (`$Method -eq 'GET') {
        return [pscustomobject]@{ value = @(); nextLink = `$null }
    }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -programYear 'Year 1' -userToken `$authToken $dryRunArgument
exit `$LASTEXITCODE
"@

        & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command *> $null
        return $LASTEXITCODE
    }

    It 'rejects an invalid CSV before any REST request' {
        Invoke-ManageESULicensesScenario -CsvPath $invalidCsvPath | Should Be 1
    }

    It 'performs read-only validation without mutation during dry-run' {
        Invoke-ManageESULicensesScenario -CsvPath $validCsvPath -DryRun | Should Be 0
    }

    It 'does not preview assignment for an agent-version skip during dry-run' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $mixedAgentCsvPath.Replace("'", "''")
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -programYear 'Year 1' -userToken `$authToken -DryRun
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'Skipped for agent version: 1'
        $output | Should Match 'Previewed or declined operations: 2'
    }

    It 'completes mocked live creation, assignment, and unlink operations' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $activeCsvPath.Replace("'", "''")
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    if (`$Method -eq 'PUT' -and `$Uri -match '/providers/Microsoft\.HybridCompute/licenses/[^?]+\?api-version=2025-02-19-preview$') {
        return [pscustomobject]@{ id = `$Uri }
    }
    if (`$Method -eq 'PUT' -and `$Uri -match '/providers/Microsoft\.HybridCompute/machines/[^/]+/licenseProfiles/default\?api-version=2025-02-19-preview$') {
        return [pscustomobject]@{ id = `$Uri }
    }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -programYear 'Year 1' -userToken `$authToken
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'Licenses created or modified: 2'
        $output | Should Match 'Assignments completed: 1'
        $output | Should Match 'Unlinks completed: 1'
        $output | Should Match 'Failures: 0'
    }

    It 'previews both creation and dependent assignment during WhatIf' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $validCsvPath.Replace("'", "''")
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -programYear 'Year 1' -userToken `$authToken -WhatIf
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        @($output | Select-String -Pattern 'What if:' -AllMatches).Matches.Count | Should Be 2
    }

    Remove-Item -Path $validCsvPath, $invalidCsvPath, $mixedAgentCsvPath, $activeCsvPath -ErrorAction SilentlyContinue
}