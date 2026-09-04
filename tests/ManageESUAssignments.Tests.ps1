$scriptPaths = @(
    (Join-Path $PSScriptRoot '..\Scripts\ManageESUAssignments.ps1'),
    (Join-Path $PSScriptRoot '..\Scripts\ManageESUAssignmentsFR.ps1')
)

function Import-FunctionsUnderTest {
    param(
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Unable to parse '$Path': $($parseErrors.Message -join '; ')"
    }

    foreach ($functionName in @(
        'AssignESULicense',
        'Get-AzureADBearerToken',
        'Resolve-ARCServerName',
        'Resolve-LicenseSubscriptionId',
        'Test-AzureResourceAccess',
        'Test-CSVRowData',
        'Write-Logfile'
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)

        if ($null -eq $functionAst) {
            throw "Function '$functionName' was not found in '$Path'."
        }

        $bodyText = $functionAst.Body.Extent.Text
        $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
        Set-Item -Path "Function:\global:$functionName" -Value ([scriptblock]::Create($bodyText))
    }
}

foreach ($scriptPath in $scriptPaths) {
    Describe "Bulk assignment helpers in $(Split-Path $scriptPath -Leaf)" {
        BeforeEach {
            Import-FunctionsUnderTest -Path $scriptPath
            $script:CONFIG = @{
                ApiVersion = 'unexpected-generic-version'
                LicenseApiVersion = '2023-06-20-preview'
                LicenseProfileApiVersion = '2023-06-20-preview'
            }

            Mock Write-Host {}
        }

        It 'does not emit log messages to the success stream' {
            $output = @(Write-Logfile -message 'test message' -level INFO)

            $output.Count | Should Be 0
        }

        It 'emits exactly one false Boolean when an access check fails' {
            Mock Invoke-RestMethod { throw 'mocked access failure' }

            $output = @(Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000001' `
                -resourceGroupName 'server-rg' `
                -resourceName 'server-01' `
                -resourceType 'Microsoft.HybridCompute/machines/licenseProfiles' `
                -bearerToken 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should BeOfType System.Boolean
            $output[0] | Should Be $false
        }

        It 'emits exactly one Boolean from CSV validation' {
            $row = [pscustomobject]@{
                LicenseName = 'license-01'
                licenseResourceGroupName = 'license-rg'
                ServerResourceGroupName = 'server-rg'
                Name = 'server-01'
                AssignESULicense = 'True'
            }

            $output = @(Test-CSVRowData -row $row -rowNumber 1)

            $output.Count | Should Be 1
            $output[0] | Should BeOfType System.Boolean
            $output[0] | Should Be $true
        }

        It 'accepts ARCServerName as the server-name CSV column' {
            $row = [pscustomobject]@{
                LicenseName = 'license-01'
                licenseResourceGroupName = 'license-rg'
                ServerResourceGroupName = 'server-rg'
                ARCServerName = 'server-01'
                AssignESULicense = 'True'
            }

            Resolve-ARCServerName -row $row | Should Be 'server-01'
            Test-CSVRowData -row $row -rowNumber 1 | Should Be $true
        }

        It 'rejects unsupported license and Arc server names' {
            $invalidLicenseRow = [pscustomobject]@{
                LicenseName = 'license/01'
                licenseResourceGroupName = 'license-rg'
                ServerResourceGroupName = 'server-rg'
                Name = 'server-01'
                AssignESULicense = 'True'
            }
            $invalidServerRow = [pscustomobject]@{
                LicenseName = 'license-01'
                licenseResourceGroupName = 'license-rg'
                ServerResourceGroupName = 'server-rg'
                Name = ('s' * 55)
                AssignESULicense = 'True'
            }

            Test-CSVRowData -row $invalidLicenseRow -rowNumber 1 | Should Be $false
            Test-CSVRowData -row $invalidServerRow -rowNumber 2 | Should Be $false
        }

        It 'uses the requested authentication retry count and delay' {
            Mock Invoke-WebRequest { throw 'mocked authentication failure' }
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

        It 'resolves the license subscription using CSV, parameter, then Arc priority' {
            $csvRow = [pscustomobject]@{
                LicenseSubscriptionId = '00000000-0000-0000-0000-000000000003'
            }
            $emptyCsvRow = [pscustomobject]@{
                LicenseSubscriptionId = ''
            }

            $fromCsv = Resolve-LicenseSubscriptionId `
                -row $csvRow `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001'
            $fromParameter = Resolve-LicenseSubscriptionId `
                -row $emptyCsvRow `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001'
            $fromArcServer = Resolve-LicenseSubscriptionId `
                -row $emptyCsvRow `
                -licenseSubscriptionId '' `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001'

            $fromCsv | Should Be '00000000-0000-0000-0000-000000000003'
            $fromParameter | Should Be '00000000-0000-0000-0000-000000000002'
            $fromArcServer | Should Be '00000000-0000-0000-0000-000000000001'
        }

        It 'uses the configured API version for each supported access-check resource type' {
            Mock Invoke-RestMethod {}

            $licenseProfileResult = Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000001' `
                -resourceGroupName 'server-rg' `
                -resourceName 'server-01' `
                -resourceType 'Microsoft.HybridCompute/machines/licenseProfiles' `
                -bearerToken 'placeholder-token'

            $licenseResult = Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000002' `
                -resourceGroupName 'license-rg' `
                -resourceName 'license-01' `
                -resourceType 'Microsoft.HybridCompute/licenses' `
                -bearerToken 'placeholder-token'

            $licenseProfileResult | Should Be $true
            $licenseResult | Should Be $true
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                $Uri -eq 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-01/licenseProfiles/default?api-version=2023-06-20-preview' -and
                $Method -eq 'GET'
            }
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                $Uri -eq 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01?api-version=2023-06-20-preview' -and
                $Method -eq 'GET'
            }
        }

        It 'rejects unsupported access-check resource types without sending a request' {
            Mock Invoke-RestMethod {}

            $output = @(Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000001' `
                -resourceGroupName 'server-rg' `
                -resourceName 'server-01' `
                -resourceType 'Microsoft.HybridCompute/unknown' `
                -bearerToken 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should Be $false
            Assert-MockCalled Invoke-RestMethod 0 -ParameterFilter {
                $Uri -match 'Microsoft\.HybridCompute/unknown'
            }
        }

        It 'returns one false Boolean and sends no PUT when resource access fails' {
            Mock Test-AzureResourceAccess { $false }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'license-01' `
                -ARCServerName 'server-01' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should BeOfType System.Boolean
            $output[0] | Should Be $false
            Assert-MockCalled Invoke-RestMethod 0 -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'performs read-only validation but sends no PUT during dry-run' {
            Mock Test-AzureResourceAccess { $true }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'license-01' `
                -ARCServerName 'server-01' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token' `
                -dryRun)

            $output.Count | Should Be 1
            $output[0] | Should Be $true
            Assert-MockCalled Test-AzureResourceAccess 2
            Assert-MockCalled Invoke-RestMethod 0 -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'does not log subscription IDs during dry-run' {
            Mock Test-AzureResourceAccess { $true }
            Mock Invoke-RestMethod {}
            Mock Write-Logfile {}

            $result = AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'license-01' `
                -ARCServerName 'server-01' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token' `
                -dryRun

            $result | Should Be $true
            Assert-MockCalled Write-Logfile 0 -ParameterFilter {
                $message -match '00000000-0000-0000-0000-00000000000[12]'
            }
        }

        It 'unlinks without requiring access to the previously assigned license' {
            Mock Test-AzureResourceAccess { $resourceType -eq 'Microsoft.HybridCompute/machines/licenseProfiles' }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'license-01' `
                -ARCServerName 'server-01' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token' `
                -unassign)

            $output.Count | Should Be 1
            $output[0] | Should Be $true
            Assert-MockCalled Test-AzureResourceAccess 1
            Assert-MockCalled Test-AzureResourceAccess 1 -ParameterFilter {
                $resourceType -eq 'Microsoft.HybridCompute/machines/licenseProfiles'
            }
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                $Method -eq 'PUT' -and $Body -notmatch 'assignedLicense'
            }
        }

        It 'uses the documented license-profile API version and explicit license subscription' {
            Mock Test-AzureResourceAccess { $true }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'license-01' `
                -ARCServerName 'server-01' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should Be $true
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                $Uri -eq 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-01/licenseProfiles/default?api-version=2023-06-20-preview' -and
                $Method -eq 'PUT' -and
                $Body -match '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01'
            }
        }

        It 'assigns a Windows Server 2016-named license with a generation-neutral cross-subscription body' {
            Mock Test-AzureResourceAccess { $true }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'windows-server-2016-standard-8-vcore' `
                -ARCServerName 'server-2016' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should Be $true
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                if ($Method -ne 'PUT' -or $Uri -ne 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-2016/licenseProfiles/default?api-version=2023-06-20-preview') {
                    return $false
                }

                $payload = $Body | ConvertFrom-Json
                @($payload.PSObject.Properties).Count -eq 2 -and
                    @($payload.PSObject.Properties.Name) -contains 'location' -and
                    @($payload.PSObject.Properties.Name) -contains 'properties' -and
                    @($payload.properties.PSObject.Properties.Name) -contains 'esuProfile' -and
                    @($payload.properties.esuProfile.PSObject.Properties.Name) -contains 'assignedLicense' -and
                    $payload.properties.esuProfile.assignedLicense -eq '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/windows-server-2016-standard-8-vcore' -and
                    $Body -notmatch 'target'
            }
        }

        It 'unlinks a Windows Server 2016-named license with an empty generation-neutral ESU profile' {
            Mock Test-AzureResourceAccess { $resourceType -eq 'Microsoft.HybridCompute/machines/licenseProfiles' }
            Mock Invoke-RestMethod {}

            $output = @(AssignESULicense `
                -arcServerSubscriptionId '00000000-0000-0000-0000-000000000001' `
                -licenseSubscriptionId '00000000-0000-0000-0000-000000000002' `
                -licenseResourceGroupName 'license-rg' `
                -licenseName 'windows-server-2016-standard-8-vcore' `
                -ARCServerName 'server-2016' `
                -serverResourceGroupName 'server-rg' `
                -location 'eastus' `
                -token 'placeholder-token' `
                -unassign)

            $output.Count | Should Be 1
            $output[0] | Should Be $true
            Assert-MockCalled Test-AzureResourceAccess 1
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                if ($Method -ne 'PUT' -or $Uri -notmatch '/subscriptions/00000000-0000-0000-0000-000000000001/.+/machines/server-2016/licenseProfiles/default') {
                    return $false
                }

                $payload = $Body | ConvertFrom-Json
                @($payload.PSObject.Properties).Count -eq 2 -and
                    @($payload.PSObject.Properties.Name) -contains 'location' -and
                    @($payload.PSObject.Properties.Name) -contains 'properties' -and
                    @($payload.properties.PSObject.Properties.Name) -contains 'esuProfile' -and
                    @($payload.properties.esuProfile.PSObject.Properties).Count -eq 0 -and
                    $Body -notmatch 'assignedLicense|target'
            }
        }

        It 'uses only preflight reads granted by the repository custom role' {
            $rolePath = Join-Path $PSScriptRoot '..\Custom Roles\ARC ESU License Administrator.json'
            $roleActions = (Get-Content -Path $rolePath -Raw | ConvertFrom-Json).properties.actions
            $scriptContent = Get-Content -Path $scriptPath -Raw

            ($roleActions -contains 'Microsoft.HybridCompute/machines/licenseProfiles/read') | Should Be $true
            ($roleActions -contains 'Microsoft.HybridCompute/licenses/read') | Should Be $true
            ($roleActions -contains 'Microsoft.HybridCompute/machines/read') | Should Be $false
            ($scriptContent -match 'Microsoft\.Authorization/roleAssignments') | Should Be $false
            ($scriptContent -match '-resourceType\s+"Microsoft\.HybridCompute/machines"') | Should Be $false
        }
    }
}

$subscriptionId = '00000000-0000-0000-0000-000000000001'
$validCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assignments-valid-$PID.csv"
$alternateNameCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assignments-alternate-name-$PID.csv"
$invalidCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assignments-invalid-$PID.csv"

@'
LicenseName,licenseResourceGroupName,ServerResourceGroupName,Name,AssignESULicense
license-01,license-rg,server-rg,server-01,True
'@ | Set-Content -Path $validCsvPath

@'
LicenseName,licenseResourceGroupName,ServerResourceGroupName,ARCServerName,AssignESULicense
license-01,license-rg,server-rg,server-01,True
'@ | Set-Content -Path $alternateNameCsvPath

@'
LicenseName,licenseResourceGroupName,ServerResourceGroupName,Name,AssignESULicense
,license-rg,server-rg,server-01,True
'@ | Set-Content -Path $invalidCsvPath

function Invoke-AssignmentScenario {
    param(
        [string]$Path,
        [string]$CsvPath,
        [ValidateSet('InvalidCsv', 'DryRunValidationFailure', 'SuccessfulDryRun', 'SuccessfulWhatIf', 'SuccessfulAssignment', 'AssignmentRestFailure')]
        [string]$Scenario,
        [string]$LogFilePath
    )

    $escapedPath = $Path.Replace("'", "''")
    $escapedCsvPath = $CsvPath.Replace("'", "''")
    $restBehavior = switch ($Scenario) {
        'DryRunValidationFailure' { "throw 'mocked resource validation failure'" }
        'SuccessfulDryRun' { '$null' }
        'SuccessfulWhatIf' { "if (`$Method -eq 'PUT') { [Environment]::Exit(9) }" }
        'SuccessfulAssignment' { '$null' }
        'AssignmentRestFailure' { "if (`$Method -eq 'PUT') { throw 'mocked assignment failure' }" }
        default { '[Environment]::Exit(9)' }
    }
    $dryRunArgument = if ($Scenario -in @('DryRunValidationFailure', 'SuccessfulDryRun')) { '-DryRun' } else { '' }
    if ($Scenario -eq 'SuccessfulWhatIf') { $dryRunArgument = '-WhatIf' }
    $logFileArgument = if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
        ''
    } else {
        $escapedLogFilePath = $LogFilePath.Replace("'", "''")
        "-logFileName '$escapedLogFilePath'"
    }

    $command = @"
function global:Clear-Host {}
function global:Write-Progress {}
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    $restBehavior
}
`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedPath' -arcServerSubscriptionId '$subscriptionId' -location 'eastus' -csvFilePath '$escapedCsvPath' -userToken `$token $dryRunArgument $logFileArgument
exit `$LASTEXITCODE
"@

    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

foreach ($scriptPath in $scriptPaths) {
    Describe "Bulk assignment process behavior in $(Split-Path $scriptPath -Leaf)" {
        It 'returns exit code 1 when a CSV row is invalid' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $invalidCsvPath -Scenario InvalidCsv

            $result.ExitCode | Should Be 1
            if ((Split-Path $scriptPath -Leaf) -eq 'ManageESUAssignmentsFR.ps1') {
                $result.Output | Should Match 'Opérations échouées : 1'
                $result.Output | Should Match 'Opérations ignorées : 0'
            } else {
                $result.Output | Should Match 'Failed operations: 1'
                $result.Output | Should Match 'Skipped operations: 0'
            }
        }

        It 'returns exit code 1 when dry-run resource validation fails' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $validCsvPath -Scenario DryRunValidationFailure

            $result.ExitCode | Should Be 1
        }

        It 'processes an ARCServerName-only CSV successfully' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $alternateNameCsvPath -Scenario SuccessfulDryRun

            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'server-01'
        }

        It 'performs read-only validation without mutation during WhatIf' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $validCsvPath -Scenario SuccessfulWhatIf

            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'What if:'
        }

        It 'counts a successful assignment and returns exit code 0' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $validCsvPath -Scenario SuccessfulAssignment

            $result.ExitCode | Should Be 0
            if ((Split-Path $scriptPath -Leaf) -eq 'ManageESUAssignmentsFR.ps1') {
                $result.Output | Should Match 'Opérations réussies : 1'
                $result.Output | Should Match 'Opérations échouées : 0'
            } else {
                $result.Output | Should Match 'Successful operations: 1'
                $result.Output | Should Match 'Failed operations: 0'
            }
        }

        It 'counts a failed assignment and returns exit code 1' {
            $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $validCsvPath -Scenario AssignmentRestFailure

            $result.ExitCode | Should Be 1
            if ((Split-Path $scriptPath -Leaf) -eq 'ManageESUAssignmentsFR.ps1') {
                $result.Output | Should Match 'Opérations réussies : 0'
                $result.Output | Should Match 'Opérations échouées : 1'
            } else {
                $result.Output | Should Match 'Successful operations: 0'
                $result.Output | Should Match 'Failed operations: 1'
            }
        }

        It 'captures each summary message once when transcript logging is enabled' {
            $logFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assignment-transcript-$PID-$([System.IO.Path]::GetRandomFileName()).txt"

            try {
                $result = Invoke-AssignmentScenario -Path $scriptPath -CsvPath $validCsvPath -Scenario SuccessfulDryRun -LogFilePath $logFilePath
                $transcript = Get-Content -Path $logFilePath -Raw

                $result.ExitCode | Should Be 0
                if ((Split-Path $scriptPath -Leaf) -eq 'ManageESUAssignmentsFR.ps1') {
                    @($transcript | Select-String -Pattern 'Opérations réussies : 1' -AllMatches).Matches.Count | Should Be 1
                } else {
                    @($transcript | Select-String -Pattern 'Successful operations: 1' -AllMatches).Matches.Count | Should Be 1
                }
            } finally {
                Remove-Item -Path $logFilePath -ErrorAction SilentlyContinue
            }
        }
    }
}

Remove-Item -Path $validCsvPath, $alternateNameCsvPath, $invalidCsvPath -ErrorAction SilentlyContinue