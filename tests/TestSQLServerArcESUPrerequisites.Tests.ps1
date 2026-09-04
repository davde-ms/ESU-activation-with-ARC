$scriptPath = Join-Path $PSScriptRoot '..\Scripts\sql\TestSQLServerArcESUPrerequisites.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$overrideSubscriptionId = '00000000-0000-0000-0000-000000000002'
$tenantId = '00000000-0000-0000-0000-000000000003'
$appId = '00000000-0000-0000-0000-000000000004'

function Import-PrerequisiteFunction {
    param([string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '; ') }
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $functionAst) { throw "Function '$Name' not found." }
    $body = $functionAst.Body.Extent.Text
    Set-Item -Path "Function:\global:$Name" -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

function Invoke-PrerequisiteScenario {
    param(
        [string]$Arguments,
        [string]$Scenario = 'Eligible',
        [string]$TracePath
    )
    $escapedScript = $scriptPath.Replace("'", "''")
    $escapedTrace = $TracePath.Replace("'", "''")
    $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-prereq-export-$PID-$([guid]::NewGuid()).csv"
    $escapedExport = $exportPath.Replace("'", "''")
    $stale = [datetime]::UtcNow.AddHours(-25).ToString('o')
    $fresh = [datetime]::UtcNow.AddHours(-1).ToString('o')
    $machineOverrides = switch ($Scenario) {
        'Disconnected' { "`$properties.status = 'Disconnected'" }
        'MonitorMode' { "`$properties.agentConfiguration.mode = 'Monitor'" }
        'Linux' { "`$properties.osName = 'linux'" }
        'NativeAzureVm' { "`$properties | Add-Member -NotePropertyName detectedProperties -NotePropertyValue ([pscustomobject]@{ cloudProvider = 'Azure' })" }
        default { '' }
    }
    $machineLocation = if ($Scenario -eq 'MissingLocation') { '$null' } else { "'eastus'" }
    $machineResponse = if ($Scenario -eq 'MissingMachine') { "throw '404 NotFound'" } else {
        "return [pscustomobject]@{ id = '/subscriptions/$subscriptionId/resourceGroups/arc-rg/providers/Microsoft.HybridCompute/machines/sql-01'; location = $machineLocation; properties = `$properties }"
    }
    $arcDataProviderResponse = switch ($Scenario) {
        'UnsupportedRegion' { "return [pscustomobject]@{ registrationState = 'Registered'; resourceTypes = @([pscustomobject]@{ resourceType = 'sqlServerInstances'; locations = @('westus') }) }" }
        'IndeterminateRegion' { "return [pscustomobject]@{ registrationState = 'Registered'; resourceTypes = @() }" }
        default { "return [pscustomobject]@{ registrationState = 'Registered'; resourceTypes = @([pscustomobject]@{ resourceType = 'sqlServerInstances'; locations = @('East US') }) }" }
    }
    $extensionVersionProperty = switch ($Scenario) {
        'MissingExtensionVersion' { '' }
        'OldExtensionVersion' { "typeHandlerVersion = '1.1.3000.0';" }
        'UnknownExtensionVersion' { "typeHandlerVersion = '1.1.9999.999';" }
        default { "typeHandlerVersion = '1.1.3518.465';" }
    }
    $extensionResponse = if ($Scenario -eq 'AbsentExtension') { "throw '404 NotFound'" } else {
        @"
return [pscustomobject]@{ properties = [pscustomobject]@{ publisher = 'Microsoft.AzureData'; type = 'WindowsAgent.SqlServer'; $extensionVersionProperty provisioningState = 'Succeeded'; enableAutomaticUpgrade = `$true; settings = [pscustomobject]@{ LicenseType = 'Paid'; SqlManagement = [pscustomobject]@{ IsEnabled = `$true }; enableExtendedSecurityUpdates = `$false; esuLastUpdatedTimestamp = '$fresh' } } }
"@
    }
    $nextLink = if ($Scenario -eq 'HostileNextLink') { 'https://attacker.example/steal?page=2' } else { 'https://management.azure.com/mock?page=2' }
    $instanceValues = switch ($Scenario) {
        'Ineligible' { "@((New-Instance 'sql-2019' '15.0.1' 'Enterprise' '$fresh' '$fresh'))" }
        'Mixed' { "@((New-Instance 'sql-2014' '12.0.1' 'Standard' '$fresh' '$fresh'), (New-Instance 'sql-2016' 'SQL Server 2016' 'Enterprise' '$fresh' '$fresh'))" }
        'Stale' { "@((New-Instance 'sql-2016' '13.0.1' 'Standard' '$stale' `$null))" }
        default { "@((New-Instance 'sql-2016' '13.0.1' 'Standard' '$fresh' '$fresh'))" }
    }
    $command = @"
function global:New-Instance(`$name, `$version, `$edition, `$inventory, `$usage) {
    [pscustomobject]@{ id = "/subscriptions/$subscriptionId/resourceGroups/arc-rg/providers/Microsoft.AzureArcData/sqlServerInstances/`$name"; name = `$name; properties = [pscustomobject]@{ containerResourceId = "/subscriptions/$subscriptionId/resourceGroups/arc-rg/providers/Microsoft.HybridCompute/machines/sql-01/"; version = `$version; edition = `$edition; hostType = 'VirtualMachine'; vCore = 8; lastInventoryUploadTime = `$inventory; lastUsageUploadTime = `$usage; status = 'Connected'; serviceType = 'Engine' } }
}
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$ErrorAction)
    Add-Content -LiteralPath '$escapedTrace' -Value "`$Method|`$Uri"
    if (`$Method -ne 'GET') { throw "Mutation attempted: `$Method" }
    if (`$Uri -match '/providers/Microsoft\.HybridCompute\?') { return [pscustomobject]@{ registrationState = 'Registered' } }
    if (`$Uri -match '/providers/Microsoft\.AzureArcData\?') { $arcDataProviderResponse }
    if (`$Uri -match '/extensions/WindowsAgent\.SqlServer') { $extensionResponse }
    if (`$Uri -match '/machines/sql-01\?') { `$properties = [pscustomobject]@{ status = 'Connected'; agentConfiguration = [pscustomobject]@{ mode = 'Full' }; osName = 'windows' }; $machineOverrides; $machineResponse }
    if (`$Uri -match 'page=2') { return [pscustomobject]@{ value = $instanceValues; nextLink = `$null } }
    if (`$Uri -match 'sqlServerInstances') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = '/subscriptions/$subscriptionId/resourceGroups/other-rg/providers/Microsoft.AzureArcData/sqlServerInstances/other'; name = 'other'; properties = [pscustomobject]@{ containerResourceId = '/subscriptions/$subscriptionId/resourceGroups/other-rg/providers/Microsoft.HybridCompute/machines/other'; version = '13.0'; edition = 'Enterprise' } }); nextLink = '$nextLink' } }
    throw "Unexpected URI: `$Uri"
}
`$token = [pscustomobject]@{ ExpiresOn = (Get-Date).AddMinutes(10); Token = ConvertTo-SecureString 'fictitious-token' -AsPlainText -Force }
& '$escapedScript' $Arguments -userToken `$token -exportCsvPath '$escapedExport'
exit `$LASTEXITCODE
"@
    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1
    $exported = if (Test-Path -LiteralPath $exportPath) { @(Import-Csv -LiteralPath $exportPath) } else { @() }
    Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output); Exported = $exported }
}

Describe 'TestSQLServerArcESUPrerequisites parsing and input contracts' {
    It 'parses without errors and exposes mutually exclusive parameter sets' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        $command = Get-Command $scriptPath
        (@($command.ParameterSets.Name) -contains 'SingleMachine') | Should Be $true
        (@($command.ParameterSets.Name) -contains 'Csv') | Should Be $true
    }

    It 'aggregates CSV errors and rejects case-insensitive duplicates' {
        Import-PrerequisiteFunction ConvertTo-PrerequisitePlan
        $rows = @(
            [pscustomobject]@{ SubscriptionId = 'bad'; ServerResourceGroupName = 'other-rg'; ARCServerName = 'other-01' },
            [pscustomobject]@{ SubscriptionId = $subscriptionId; ServerResourceGroupName = 'arc-rg'; ARCServerName = 'sql-01' },
            [pscustomobject]@{ SubscriptionId = $subscriptionId.ToUpperInvariant(); ServerResourceGroupName = 'ARC-RG'; ARCServerName = 'SQL-01' }
        )
        $message = try { ConvertTo-PrerequisitePlan -Rows $rows -DefaultSubscriptionId $subscriptionId; '' } catch { $_.Exception.Message }
        $message | Should Match 'invalid SubscriptionId'
        $message | Should Match 'duplicates machine'
    }

    It 'uses a CSV row subscription override and otherwise falls back to the command subscription' {
        Import-PrerequisiteFunction ConvertTo-PrerequisitePlan
        $plans = @(ConvertTo-PrerequisitePlan -Rows @(
            [pscustomobject]@{ SubscriptionId = ''; ServerResourceGroupName = 'arc-rg'; ARCServerName = 'sql-01' },
            [pscustomobject]@{ SubscriptionId = $overrideSubscriptionId; ServerResourceGroupName = 'arc-rg'; ARCServerName = 'sql-02' }
        ) -DefaultSubscriptionId $subscriptionId)
        $plans[0].SubscriptionId | Should Be $subscriptionId
        $plans[1].SubscriptionId | Should Be $overrideSubscriptionId
    }
}

Describe 'TestSQLServerArcESUPrerequisites pure classification' {
    BeforeEach {
        Import-PrerequisiteFunction Get-ObjectValue
        Import-PrerequisiteFunction Get-SqlInstanceClassification
        Import-PrerequisiteFunction Get-Freshness
    }

    It 'classifies SQL 2014 and 2016 production editions as eligible' {
        foreach ($case in @(@('12.0.1', 'Standard'), @('SQL Server 2016', 'Enterprise'))) {
            $result = Get-SqlInstanceClassification -Instance ([pscustomobject]@{ name = 'sql'; id = '/fake'; properties = [pscustomobject]@{ version = $case[0]; edition = $case[1] } })
            $result.Eligibility | Should Be 'Eligible'
        }
    }

    It 'classifies unsupported versions and editions separately' {
        $unsupportedVersion = Get-SqlInstanceClassification -Instance ([pscustomobject]@{ name = 'sql'; properties = [pscustomobject]@{ version = '15.0'; edition = 'Enterprise' } })
        $developer = Get-SqlInstanceClassification -Instance ([pscustomobject]@{ name = 'sql'; properties = [pscustomobject]@{ version = '13.0'; edition = 'Developer' } })
        $unsupportedVersion.Eligibility | Should Be 'Ineligible'
        $developer.Eligibility | Should Be 'ExternalConfirmationRequired'
    }

    It 'makes stale and missing timestamps warning classifications' {
        $instances = @([pscustomobject]@{ InventoryTimestamp = [datetime]::UtcNow.AddHours(-25).ToString('o'); UsageTimestamp = $null })
        Get-Freshness -Instances $instances -PropertyName InventoryTimestamp | Should Be 'Stale'
        Get-Freshness -Instances $instances -PropertyName UsageTimestamp | Should Be 'Unknown'
    }
}

Describe 'TestSQLServerArcESUPrerequisites read-only ARM behavior' {
    BeforeEach { $script:tracePath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-prereq-trace-$PID-$([guid]::NewGuid()).txt" }
    AfterEach { Remove-Item -LiteralPath $script:tracePath -ErrorAction SilentlyContinue }

    It 'uses exact API versions, follows pagination, correlates by container resource ID, and returns stable fields' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -TracePath $script:tracePath
        $requests = @(Get-Content -LiteralPath $script:tracePath)
        $result.ExitCode | Should Be 0
        $requests -join "`n" | Should Match '/machines/sql-01\?api-version=2026-07-15'
        $requests -join "`n" | Should Match '/extensions/WindowsAgent.SqlServer\?api-version=2026-07-15'
        $requests -join "`n" | Should Match 'sqlServerInstances\?api-version=2026-01-01'
        $requests -join "`n" | Should Match 'mock\?page=2'
        ($requests | Where-Object { $_ -notmatch '^GET\|' }).Count | Should Be 0
        $object = $result.Exported[0]
        $object.RegionSupported | Should Be 'True'
        $object.ReadyForESUEnablement | Should Be 'True'
        $object.EligibleInstances | Should Match 'sql-2016\|13.0.1\|Standard\|Eligible'
        @($object.PSObject.Properties.Name) -join ',' | Should Be 'SubscriptionId,ResourceGroupName,MachineName,MachineResourceId,MachineExists,ConnectionStatus,AgentMode,OperatingSystem,Location,HybridComputeRegistered,AzureArcDataRegistered,RegionSupported,ExtensionState,ExtensionVersion,ExtensionSupported,AutomaticUpgradeEnabled,LicenseType,SqlManagementEnabled,ESUEnabled,ESULastUpdatedTimestamp,EligibleInstances,IneligibleInstances,MixedEligibleVersions,HostType,DetectedCores,InventoryFreshness,UsageFreshness,BlockingIssues,Warnings,ExternalChecks,ReadyForExtensionInstall,ReadyForESUEnablement'
        $object.ExternalChecks | Should Match 'NotVerifiableByARM:'
    }

    It 'reports mixed eligible versions and a separate-meter warning' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario Mixed -TracePath $script:tracePath
        $object = $result.Exported[0]
        $object.MixedEligibleVersions | Should Be 'True'
        $object.Warnings -join ' ' | Should Match 'separate ESU meter'
    }

    It 'keeps stale or missing timestamps warning-only for otherwise eligible inventory' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario Stale -TracePath $script:tracePath
        $object = $result.Exported[0]
        $object.InventoryFreshness | Should Be 'Stale'
        $object.UsageFreshness | Should Be 'Unknown'
        $object.ReadyForESUEnablement | Should Be 'True'
    }

    It 'blocks unsupported inventory' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario Ineligible -TracePath $script:tracePath
        $object = $result.Exported[0]
        $object.ReadyForESUEnablement | Should Be 'False'
        $object.IneligibleInstances | Should Match 'sql-2019\|15.0.1\|Enterprise\|Ineligible'
    }

    It 'separately reports extension-install readiness when the extension is absent' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario AbsentExtension -TracePath $script:tracePath
        $object = $result.Exported[0]
        $object.ExtensionState | Should Be 'Absent'
        $object.ReadyForExtensionInstall | Should Be 'True'
        $object.ReadyForESUEnablement | Should Be 'False'
    }

    It 'blocks disconnected, monitor-mode, and non-Windows machines' {
        foreach ($scenario in @('Disconnected', 'MonitorMode', 'Linux')) {
            Remove-Item -LiteralPath $script:tracePath -ErrorAction SilentlyContinue
            $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario $scenario -TracePath $script:tracePath
            $object = $result.Exported[0]
            $object.ReadyForESUEnablement | Should Be 'False'
            [string]::IsNullOrWhiteSpace($object.BlockingIssues) | Should Be $false
        }
    }

    It 'blocks native Azure VMs that require the SQL IaaS Agent extension' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario NativeAzureVm -TracePath $script:tracePath
        $object = $result.Exported[0]
        $object.ReadyForExtensionInstall | Should Be 'False'
        $object.ReadyForESUEnablement | Should Be 'False'
        $object.BlockingIssues | Should Match 'SQL IaaS Agent'
    }

    It 'blocks missing, unsupported, and indeterminate machine locations' {
        foreach ($scenario in @('MissingLocation', 'UnsupportedRegion', 'IndeterminateRegion')) {
            Remove-Item -LiteralPath $script:tracePath -ErrorAction SilentlyContinue
            $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario $scenario -TracePath $script:tracePath
            $object = $result.Exported[0]
            $object.ReadyForExtensionInstall | Should Be 'False'
            $object.ReadyForESUEnablement | Should Be 'False'
            [string]::IsNullOrWhiteSpace($object.BlockingIssues) | Should Be $false
        }
    }

    It 'reports unsupported and indeterminate regions distinctly' {
        $unsupported = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario UnsupportedRegion -TracePath $script:tracePath
        $unsupported.Exported[0].RegionSupported | Should Be 'False'
        Remove-Item -LiteralPath $script:tracePath -ErrorAction SilentlyContinue
        $indeterminate = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario IndeterminateRegion -TracePath $script:tracePath
        [string]::IsNullOrWhiteSpace($indeterminate.Exported[0].RegionSupported) | Should Be $true
    }

    It 'blocks extension versions outside or missing from the frozen 12-month baseline' {
        foreach ($scenario in @('OldExtensionVersion', 'UnknownExtensionVersion', 'MissingExtensionVersion')) {
            Remove-Item -LiteralPath $script:tracePath -ErrorAction SilentlyContinue
            $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario $scenario -TracePath $script:tracePath
            $object = $result.Exported[0]
            $object.ExtensionSupported | Should Be 'False'
            $object.ReadyForESUEnablement | Should Be 'False'
            $object.BlockingIssues | Should Match '12-month supported release baseline|version is missing'
        }
    }

    It 'returns exit 1 when the requested machine is not found' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario MissingMachine -TracePath $script:tracePath
        $result.ExitCode | Should Be 1
        $result.Exported[0].MachineExists | Should Be 'False'
    }

    It 'rejects a hostile nextLink before forwarding authenticated headers' {
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -Scenario HostileNextLink -TracePath $script:tracePath
        $requests = @(Get-Content -LiteralPath $script:tracePath)
        $result.ExitCode | Should Be 1
        ($requests -join "`n") | Should Not Match 'attacker\.example'
        $result.Exported[0].BlockingIssues | Should Match 'management\.azure\.com'
    }
}

Describe 'TestSQLServerArcESUPrerequisites authentication safety' {
    It 'validates all CSV rows before attempting authentication or HTTP calls' {
        $csv = Join-Path ([System.IO.Path]::GetTempPath()) "sql-prereq-invalid-$PID.csv"
        @"
SubscriptionId,ServerResourceGroupName,ARCServerName
bad,arc-rg,sql-01
"@ | Set-Content -LiteralPath $csv
        $command = "function global:Invoke-WebRequest { [Environment]::Exit(9) }; function global:Invoke-RestMethod { [Environment]::Exit(9) }; & '$($scriptPath.Replace("'", "''"))' -subscriptionId '$subscriptionId' -csvFilePath '$($csv.Replace("'", "''"))' -tenantId '$tenantId' -appID '$appId' -clientSecret 'fictitious-secret'; exit `$LASTEXITCODE"
        $null = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should Be 1
        Remove-Item -LiteralPath $csv -ErrorAction SilentlyContinue
    }

    It 'never writes client secrets, secure token contents, or authorization headers' {
        $trace = Join-Path ([System.IO.Path]::GetTempPath()) "sql-prereq-secret-$PID.txt"
        $result = Invoke-PrerequisiteScenario -Arguments "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'" -TracePath $trace
        $text = $result.Output | Out-String
        $text | Should Not Match 'fictitious-token|Authorization|Bearer'
        Remove-Item -LiteralPath $trace -ErrorAction SilentlyContinue
    }
}