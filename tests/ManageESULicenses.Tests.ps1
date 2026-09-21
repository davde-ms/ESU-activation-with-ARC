$scriptPath = Join-Path $PSScriptRoot '..\Scripts\windows\ManageESULicenses.ps1'

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

    foreach ($functionName in @('Get-ProgramYearArray', 'ConvertTo-ESULicensePlan', 'CreateESULicense', 'CountResources')) {
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

function Get-ESULicenseRow {
    param(
        [string]$Name = 'server-01',
        [string]$Target = '',
        [string]$AgentVersion = '1.34',
        [string]$InvoiceId = '',
        [string]$ProgramYear = ''
    )

    return [pscustomobject]@{
        Name = $Name
        Cores = '8'
        IsVirtual = 'Virtual'
        AgentVersion = $AgentVersion
        ServerResourceGroupName = 'server-rg'
        AssignESULicense = 'True'
        ESUException = ''
        Target = $Target
        InvoiceId = $InvoiceId
        ProgramYear = $ProgramYear
    }
}

function ConvertTo-PlannedESULicense {
    param(
        [array]$Rows,
        [string]$State = 'Deactivated',
        [string]$Edition = 'Standard',
        [string]$Target = 'Windows Server 2012',
        [string]$InvoiceId = '',
        [string]$ProgramYear = 'Year 1',
        [bool]$InvoiceIdWasBound = $false,
        [bool]$ProgramYearWasBound = $false
    )

    return @(ConvertTo-ESULicensePlan -csvData $Rows -state $State -edition $Edition -licenseNamePrefix 'ESU-' -licenseNameSuffix '' -target $Target -invoiceId $InvoiceId -programYear $ProgramYear -invoiceIdWasBound $InvoiceIdWasBound -programYearWasBound $ProgramYearWasBound)
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

    It 'captures effective state and edition in each validated plan item' {
        $row = Get-ESULicenseRow -Name 'physical-01'
        $row.IsVirtual = 'Physical'
        $plan = @(ConvertTo-PlannedESULicense -Rows @($row) -State Activated -Edition Datacenter)

        $plan[0].State | Should Be 'Activated'
        $plan[0].Edition | Should Be 'Datacenter'
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

    It 'rejects duplicate generated license names' {
        $rows = @(
            (Get-ESULicenseRow -Name 'duplicate'),
            (Get-ESULicenseRow -Name 'duplicate')
        )

        $message = $null
        try {
            ConvertTo-ESULicensePlan -csvData $rows -edition Standard -licenseNamePrefix 'ESU-' -licenseNameSuffix ''
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "duplicate license name 'ESU-duplicate'"
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

Describe 'ManageESULicenses planned target resolution' {
    BeforeEach {
        Import-ManageESULicensesFunctions
    }

    It '[Phase 3] uses Windows Server 2012 when neither row nor parameter supplies a target' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow)

        $plan[0].Target | Should Be 'Windows Server 2012'
    }

    It '[Phase 3] uses the batch target when the row target is empty' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -AgentVersion '1.62') -Target 'Windows Server 2016'

        $plan[0].Target | Should Be 'Windows Server 2016'
    }

    It '[Phase 3] gives a nonempty row target precedence over the batch target' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -Target 'Windows Server 2012 R2') -Target 'Windows Server 2016'

        $plan[0].Target | Should Be 'Windows Server 2012 R2'
    }

    It '[Phase 3] resolves every row independently in a mixed-target input' {
        $rows = @(
            (Get-ESULicenseRow -Name 'server-2012' -Target 'Windows Server 2012'),
            (Get-ESULicenseRow -Name 'server-2012-r2' -Target 'Windows Server 2012 R2'),
            (Get-ESULicenseRow -Name 'server-2016' -Target 'Windows Server 2016' -AgentVersion '1.62')
        )

        $plan = ConvertTo-PlannedESULicense -Rows $rows

        @($plan.Target) -join '|' | Should Be 'Windows Server 2012|Windows Server 2012 R2|Windows Server 2016'
    }
}

Describe 'ManageESULicenses planned transition resolution' {
    BeforeEach {
        Import-ManageESULicensesFunctions
    }

    It '[Phase 3] gives nonempty row transition values precedence over explicitly bound batch values' {
        $row = Get-ESULicenseRow -InvoiceId 'row-invoice' -ProgramYear 'Year 2'
        $plan = ConvertTo-PlannedESULicense -Rows @($row) -InvoiceId 'batch-invoice' -ProgramYear 'Year 3' -InvoiceIdWasBound $true -ProgramYearWasBound $true

        $plan[0].InvoiceId | Should Be 'row-invoice'
        @($plan[0].ProgramYears) -join ',' | Should Be 'Year 1,Year 2'
        $plan[0].TransitionMode | Should Be 'VolumeLicense'
    }

    It '[Phase 3] uses explicitly bound batch transition values as row fallbacks' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow) -InvoiceId 'batch-invoice' -ProgramYear 'Year 3' -InvoiceIdWasBound $true -ProgramYearWasBound $true

        $plan[0].InvoiceId | Should Be 'batch-invoice'
        @($plan[0].ProgramYears) -join ',' | Should Be 'Year 1,Year 2,Year 3'
    }

    It '[Phase 3] supplies implicit Year 1 only when an effective invoice exists' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -InvoiceId 'row-invoice')

        @($plan[0].ProgramYears) -join ',' | Should Be 'Year 1'
    }

    It '[Phase 3] rejects an explicit program year without an effective invoice' {
        $message = $null
        try {
            ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -ProgramYear 'Year 2')
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "column 'ProgramYear'.*invoice"
    }

    It '[Phase 3] leaves transition plan properties empty when no transition applies' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow)

        $plan[0].InvoiceId | Should BeNullOrEmpty
        @($plan[0].ProgramYears).Count | Should Be 0
        $plan[0].TransitionMode | Should Be 'None'
    }

    $unsupported2016Transitions = @(
        @{ Name = 'row invoice'; Row = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62' -InvoiceId 'row-invoice'; Arguments = @{} },
        @{ Name = 'batch invoice'; Row = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62'; Arguments = @{ InvoiceId = 'batch-invoice'; InvoiceIdWasBound = $true } },
        @{ Name = 'row program year'; Row = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62' -ProgramYear 'Year 2'; Arguments = @{} },
        @{ Name = 'batch program year'; Row = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62'; Arguments = @{ ProgramYear = 'Year 2'; ProgramYearWasBound = $true } }
    )

    foreach ($transitionCase in $unsupported2016Transitions) {
        It "[Phase 3] rejects Windows Server 2016 transition input from $($transitionCase.Name)" {
            $arguments = @{
                Rows = @($transitionCase.Row)
            }
            foreach ($key in $transitionCase.Arguments.Keys) {
                $arguments[$key] = $transitionCase.Arguments[$key]
            }
            $message = $null
            try {
                ConvertTo-PlannedESULicense @arguments
            } catch {
                $message = $_.Exception.Message
            }

            $message | Should Match 'Volume Licensing transition.*Windows Server 2016'
        }
    }
}

Describe 'ManageESULicenses planned target-specific agent validation' {
    BeforeEach {
        Import-ManageESULicensesFunctions
    }

    It 'accepts the current Windows Server 2012 minimum agent version 1.34' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -AgentVersion '1.34')

        $plan[0].CreationAction | Should Be 'CreateOrModify'
    }

    It '[Phase 3] accepts Windows Server 2012 R2 at agent version 1.34' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -Target 'Windows Server 2012 R2' -AgentVersion '1.34')

        $plan[0].Target | Should Be 'Windows Server 2012 R2'
        $plan[0].MinimumAgentVersion | Should Be ([version]'1.34')
    }

    It '[Phase 3] rejects Windows Server 2012 and R2 below agent version 1.34' {
        $rows = @(
            (Get-ESULicenseRow -Name 'server-2012' -Target 'Windows Server 2012' -AgentVersion '1.33'),
            (Get-ESULicenseRow -Name 'server-2012-r2' -Target 'Windows Server 2012 R2' -AgentVersion '1.33')
        )
        $message = $null
        try {
            ConvertTo-PlannedESULicense -Rows $rows
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match '1.34'
    }

    It '[Phase 3] accepts Windows Server 2016 at agent version 1.62' {
        $plan = ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62')

        $plan[0].Target | Should Be 'Windows Server 2016'
        $plan[0].MinimumAgentVersion | Should Be ([version]'1.62')
    }

    It '[Phase 3] rejects Windows Server 2016 below agent version 1.62' {
        $message = $null
        try {
            ConvertTo-PlannedESULicense -Rows @(Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.61')
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match '1.62'
    }

    It '[Phase 3] rejects only reserved Windows Server 2012 exception values for Windows Server 2016' {
        $reservedValues = @(
            'WS2012 VISUAL STUDIO DEV TEST',
            'WS2012 DISASTER RECOVERY',
            'WS2012 MULTIPURPOSE'
        )

        foreach ($reservedValue in $reservedValues) {
            $row = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62'
            $row.ESUException = $reservedValue
            $message = $null
            try {
                ConvertTo-PlannedESULicense -Rows @($row)
            } catch {
                $message = $_.Exception.Message
            }

            $message | Should Match "column 'ESUException'.*eligibility.*alter billing"
        }

        $allowedRow = Get-ESULicenseRow -Target 'Windows Server 2016' -AgentVersion '1.62'
        $allowedRow.ESUException = 'WS2012 CUSTOM INFORMATIONAL TAG'
        @(ConvertTo-PlannedESULicense -Rows @($allowedRow)).Count | Should Be 1
    }
}

Describe 'ManageESULicenses planned payload contract' {
    BeforeEach {
        Import-ManageESULicensesFunctions
        $global:creator = 'ManageESULicenses.ps1'
    }

    It '[Phase 4] emits the exact 2012 non-transition payload and endpoint' {
        $script:requestBody = $null
        $script:requestUri = $null
        Mock Invoke-RestMethod {
            $script:requestBody = $Body | ConvertFrom-Json
            $script:requestUri = $Uri
        }

        CreateESULicense -subscriptionId '00000000-0000-0000-0000-000000000001' -token 'placeholder-token' -location 'eastus' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -state Deactivated -edition Standard -coreType vCore -coreCount 8 -ESULicenseException $false -target 'Windows Server 2012' -invoiceId '' -programYears @() -transitionMode None | Out-Null

        $script:requestUri | Should Be 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/license-01?api-version=2026-06-16-preview'
        $script:requestBody.location | Should Be 'eastus'
        $script:requestBody.properties.licenseType | Should Be 'ESU'
        $script:requestBody.properties.licenseDetails.state | Should Be 'Deactivated'
        $script:requestBody.properties.licenseDetails.target | Should Be 'Windows Server 2012'
        $script:requestBody.properties.licenseDetails.edition | Should Be 'Standard'
        $script:requestBody.properties.licenseDetails.Type | Should Be 'vCore'
        $script:requestBody.properties.licenseDetails.Processors | Should Be 8
        ($script:requestBody.properties.licenseDetails.PSObject.Properties.Name -contains 'volumeLicenseDetails') | Should Be $false
        Assert-MockCalled Invoke-RestMethod 1
    }

    It '[Phase 4] emits expanded transition details only for an applicable 2012 R2 plan' {
        $script:requestBody = $null
        Mock Invoke-RestMethod {
            $script:requestBody = $Body | ConvertFrom-Json
        }

        CreateESULicense -subscriptionId '00000000-0000-0000-0000-000000000001' -token 'placeholder-token' -location 'eastus' -licenseResourceGroupName 'license-rg' -licenseName 'license-r2' -state Activated -edition Datacenter -coreType pCore -coreCount 16 -ESULicenseException $false -target 'Windows Server 2012 R2' -invoiceId 'invoice-placeholder' -programYears @('Year 1', 'Year 2', 'Year 3') -transitionMode VolumeLicense | Out-Null

        $details = $script:requestBody.properties.licenseDetails
        $details.target | Should Be 'Windows Server 2012 R2'
        $details.state | Should Be 'Activated'
        $details.Type | Should Be 'pCore'
        $details.Processors | Should Be 16
        @($details.volumeLicenseDetails).Count | Should Be 3
        @($details.volumeLicenseDetails.programYear) -join '|' | Should Be 'Year 1|Year 2|Year 3'
        @($details.volumeLicenseDetails.invoiceId | Select-Object -Unique).Count | Should Be 1
        $details.volumeLicenseDetails[0].invoiceId | Should Be 'invoice-placeholder'
    }

    It '[Phase 4] emits the plan target and no transition property for Windows Server 2016' {
        $script:requestBody = $null
        Mock Invoke-RestMethod {
            $script:requestBody = $Body | ConvertFrom-Json
        }

        CreateESULicense -subscriptionId '00000000-0000-0000-0000-000000000001' -token 'placeholder-token' -location 'eastus' -licenseResourceGroupName 'license-rg' -licenseName 'license-2016' -state Deactivated -edition Standard -coreType vCore -coreCount 8 -ESULicenseException $false -target 'Windows Server 2016' -invoiceId '' -programYears @() -transitionMode None | Out-Null

        $script:requestBody.properties.licenseDetails.target | Should Be 'Windows Server 2016'
        ($script:requestBody.properties.licenseDetails.PSObject.Properties.Name -contains 'volumeLicenseDetails') | Should Be $false
    }

    It '[Phase 4] rejects inconsistent transition data before sending a request' {
        Mock Invoke-RestMethod {}
        $message = $null

        try {
            CreateESULicense -subscriptionId '00000000-0000-0000-0000-000000000001' -token 'placeholder-token' -location 'eastus' -licenseResourceGroupName 'license-rg' -licenseName 'license-2016' -state Deactivated -edition Standard -coreType vCore -coreCount 8 -ESULicenseException $false -target 'Windows Server 2016' -invoiceId 'invoice-placeholder' -programYears @('Year 1') -transitionMode VolumeLicense | Out-Null
        } catch {
            $message = $_.Exception.Message
        }

        $message | Should Match 'Invalid Volume Licensing transition data.*Windows Server 2016'
        Assert-MockCalled Invoke-RestMethod 0 -Scope It
    }
}

Describe 'ManageESULicenses process safety' {
    $validCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-valid-$PID.csv"
    $invalidCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-invalid-$PID.csv"
    $mixedAgentCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-agent-versions-$PID.csv"
    $activeCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-active-$PID.csv"
    $invalidTargetCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-invalid-target-$PID.csv"
    $mixedTargetCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-plan-mixed-target-$PID.csv"

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

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
server-2012,8,Virtual,1.33,server-rg,True,,Windows Server 2012,,
server-2016,8,Virtual,1.61,server-rg,True,,Windows Server 2016,,
'@ | Set-Content -Path $invalidTargetCsvPath

    @'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
server-2012,8,Virtual,1.34,,,,Windows Server 2012,,
server-2012-r2,16,Physical,1.34,,,,Windows Server 2012 R2,invoice-placeholder,Year 2
server-2016,8,Virtual,1.62,,,,Windows Server 2016,,
'@ | Set-Content -Path $mixedTargetCsvPath

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
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken $dryRunArgument
exit `$LASTEXITCODE
"@

        & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command *> $null
        return $LASTEXITCODE
    }

    It 'rejects an invalid CSV before any REST request' {
        Invoke-ManageESULicensesScenario -CsvPath $invalidCsvPath | Should Be 1
    }

    It '[Phase 3] rejects the complete target-aware file before authentication or REST' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $invalidTargetCsvPath.Replace("'", "''")
        $markerPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-preauth-marker-$PID-$([guid]::NewGuid().ToString('N'))"
        $escapedMarkerPath = $markerPath.Replace("'", "''")
        $command = @"
function global:Invoke-WebRequest {
    Set-Content -LiteralPath '$escapedMarkerPath' -Value 'authentication reached'
    throw 'mocked authentication must not run'
}
function global:Invoke-RestMethod {
    Set-Content -LiteralPath '$escapedMarkerPath' -Value 'REST reached'
    throw 'mocked REST must not run'
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -tenantId '00000000-0000-0000-0000-000000000002' -appID '00000000-0000-0000-0000-000000000003' -clientSecret 'placeholder-secret' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath'
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 1
        (Test-Path -LiteralPath $markerPath) | Should Be $false
        $output | Should Match 'Row 2.*1.34'
        $output | Should Match 'Row 3.*1.62'
        Remove-Item -LiteralPath $markerPath -ErrorAction SilentlyContinue
    }

    It 'performs read-only validation without mutation during dry-run' {
        Invoke-ManageESULicensesScenario -CsvPath $validCsvPath -DryRun | Should Be 0
    }

    It '[Phase 3] rejects any below-minimum agent row instead of partially previewing a file' {
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
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken -DryRun
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 1
        $output | Should Match "Row 3, column 'AgentVersion'.*1.34"
    }

    It 'completes mocked live creation, assignment, and unlink operations' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $activeCsvPath.Replace("'", "''")
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    if (`$Method -eq 'PUT' -and `$Uri -match '/providers/Microsoft\.HybridCompute/licenses/[^?]+\?api-version=2026-06-16-preview$') {
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
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'Licenses created or modified: 2'
        $output | Should Match 'Assignments completed: 1'
        $output | Should Match 'Unlinks completed: 1'
        $output | Should Match 'Failures: 0'
    }

    It '[Phase 4] executes each mixed-target plan item with its effective payload values' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $mixedTargetCsvPath.Replace("'", "''")
        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-license-payloads-$PID-$([guid]::NewGuid().ToString('N')).txt"
        $escapedPayloadPath = $payloadPath.Replace("'", "''")
        $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    if (`$Method -eq 'PUT' -and `$Uri -match '/providers/Microsoft\.HybridCompute/licenses/([^?]+)\?api-version=2026-06-16-preview$') {
        `$payload = `$Body | ConvertFrom-Json
        `$details = `$payload.properties.licenseDetails
        `$hasTransition = `$details.PSObject.Properties.Name -contains 'volumeLicenseDetails'
        `$transitionCount = if (`$hasTransition) { @(`$details.volumeLicenseDetails).Count } else { 0 }
        Add-Content -LiteralPath '$escapedPayloadPath' -Value "`$(`$Matches[1])|`$(`$details.state)|`$(`$details.edition)|`$(`$details.target)|`$hasTransition|`$transitionCount"
        return [pscustomobject]@{ id = `$Uri }
    }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken
exit `$LASTEXITCODE
"@

        & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command *> $null
        $payloads = @(Get-Content -LiteralPath $payloadPath)

        $LASTEXITCODE | Should Be 0
        $payloads.Count | Should Be 3
        $payloads[0] | Should Be 'server-2012|Deactivated|Standard|Windows Server 2012|False|0'
        $payloads[1] | Should Be 'server-2012-r2|Deactivated|Standard|Windows Server 2012 R2|True|2'
        $payloads[2] | Should Be 'server-2016|Deactivated|Standard|Windows Server 2016|False|0'
        Remove-Item -LiteralPath $payloadPath -ErrorAction SilentlyContinue
    }

    It 'shows effective state and edition in the validated dry-run plan' {
        $escapedScriptPath = $scriptPath.Replace("'", "''")
        $escapedCsvPath = $validCsvPath.Replace("'", "''")
        $command = @"
    function global:Clear-Host {}
function global:Invoke-RestMethod {
    param(`$Uri, `$Method)
    if (`$Method -eq 'GET') { return [pscustomobject]@{ value = @(); nextLink = `$null } }
    [Environment]::Exit(9)
}
`$authToken = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken -DryRun
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String -Width 4096

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'Validated operation plan'
        $output | Should Match 'Deactivated\s+Standard'
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
& '$escapedScriptPath' -subscriptionId '00000000-0000-0000-0000-000000000001' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$escapedCsvPath' -userToken `$authToken -WhatIf
exit `$LASTEXITCODE
"@

        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        @($output | Select-String -Pattern 'What if:' -AllMatches).Matches.Count | Should Be 2
        $output | Should Match 'Create or modify Deactivated Standard ESU license'
    }

    Remove-Item -Path $validCsvPath, $invalidCsvPath, $mixedAgentCsvPath, $activeCsvPath, $invalidTargetCsvPath, $mixedTargetCsvPath -ErrorAction SilentlyContinue
}