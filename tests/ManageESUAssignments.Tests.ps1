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
        'Resolve-LicenseSubscriptionId',
        'Test-AzureResourceAccess',
        'Test-CSVRowData',
        'Test-ServicePrincipalPermissions',
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
                MachineApiVersion = '2023-06-20-preview'
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
                -resourceType 'Microsoft.HybridCompute/machines' `
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

        It 'emits exactly one false Boolean when permission validation fails' {
            Mock Invoke-RestMethod { throw 'mocked permission failure' }

            $output = @(Test-ServicePrincipalPermissions `
                -subscriptionId '00000000-0000-0000-0000-000000000001' `
                -bearerToken 'placeholder-token')

            $output.Count | Should Be 1
            $output[0] | Should BeOfType System.Boolean
            $output[0] | Should Be $false
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

            $machineResult = Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000001' `
                -resourceGroupName 'server-rg' `
                -resourceName 'server-01' `
                -resourceType 'Microsoft.HybridCompute/machines' `
                -bearerToken 'placeholder-token'

            $licenseResult = Test-AzureResourceAccess `
                -subscriptionId '00000000-0000-0000-0000-000000000002' `
                -resourceGroupName 'license-rg' `
                -resourceName 'license-01' `
                -resourceType 'Microsoft.HybridCompute/licenses' `
                -bearerToken 'placeholder-token'

            $machineResult | Should Be $true
            $licenseResult | Should Be $true
            Assert-MockCalled Invoke-RestMethod 1 -ParameterFilter {
                $Uri -eq 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-01?api-version=2023-06-20-preview' -and
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
    }
}