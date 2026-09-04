$scriptPath = Join-Path $PSScriptRoot '..\Scripts\sql\CheckSQLServerESUStatus.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$overrideSubscriptionId = '00000000-0000-0000-0000-000000000002'
$tenantId = '00000000-0000-0000-0000-000000000003'
$appId = '00000000-0000-0000-0000-000000000004'

function Import-StatusFunction {
    param([string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $functionAst) { throw "Function '$Name' not found." }
    $body = $functionAst.Body.Extent.Text
    Set-Item -Path "Function:\global:$Name" -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

function Invoke-StatusScenario {
    param(
        [ValidateSet('Healthy', 'Disabled', 'Stale', 'FailedExtension', 'Disconnected', 'Mixed', 'RawString', 'RawInvalid', 'MissingMachine', 'PartialFailure', 'HostileNextLink', 'HostilePort', 'RepeatedNextLink', 'UnknownVersion', 'AbsentExtension', 'PassiveDR', 'AllIneligible', 'Developer', 'ConflictingMetering', 'TransientRetry', 'SecretFailure')]
        [string]$Scenario = 'Healthy',
        [string]$CsvContent,
        [switch]$ServicePrincipal
    )

    $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-status-record-$PID-$([guid]::NewGuid().ToString('N')).jsonl"
    $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-status-input-$PID-$([guid]::NewGuid().ToString('N')).csv"
    $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-status-export-$PID-$([guid]::NewGuid().ToString('N')).csv"
    if ($CsvContent) { Set-Content -LiteralPath $csvPath -Value $CsvContent }
    $targetArguments = if ($CsvContent) {
        "-subscriptionId '$subscriptionId' -csvFilePath '$($csvPath.Replace("'", "''"))'"
    }
    else {
        "-subscriptionId '$subscriptionId' -serverResourceGroupName 'arc-rg' -ARCServerName 'sql-01'"
    }
    $authArguments = if ($ServicePrincipal) {
        "-tenantId '$tenantId' -appID '$appId' -clientSecret 'fictitious-client-secret'"
    }
    else {
        '-userToken $token'
    }
    $fresh = [datetime]::UtcNow.AddHours(-1).ToString('o')
    $stale = [datetime]::UtcNow.AddHours(-25).ToString('o')
    $escapedScript = $scriptPath.Replace("'", "''")
    $escapedRecord = $recordPath.Replace("'", "''")
    $escapedExport = $exportPath.Replace("'", "''")

    $command = @"
`$global:scenario = '$Scenario'
`$global:sqlPage = 0
`$global:transientAttempts = 0
function global:Write-Call(`$Uri, `$Method, `$IsAuthentication) {
    [pscustomobject]@{ Uri = [string]`$Uri; Method = [string]`$Method; IsAuthentication = `$IsAuthentication } | ConvertTo-Json -Compress | Add-Content -LiteralPath '$escapedRecord'
}
function global:Start-Sleep {
    param(`$Seconds)
    Write-Call ([string]`$Seconds) 'SLEEP' `$false
}
function global:New-Instance(`$machine, `$name, `$version, `$edition, `$inventory, `$usage, `$hostType = 'VirtualMachine', `$cores = 8, `$environment = 'Production', `$isDisasterRecovery = `$null) {
    [pscustomobject]@{ id = "/subscriptions/$subscriptionId/resourceGroups/arc-rg/providers/Microsoft.AzureArcData/sqlServerInstances/`$name"; name = `$name; properties = [pscustomobject]@{ containerResourceId = "/subscriptions/$subscriptionId/resourceGroups/arc-rg/providers/Microsoft.HybridCompute/machines/`$machine/"; version = `$version; edition = `$edition; environment = `$environment; serviceType = 'Engine'; status = 'Connected'; hostType = `$hostType; cores = `$cores; lastInventoryUploadTime = `$inventory; lastUsageUploadTime = `$usage; isDisasterRecovery = `$isDisasterRecovery; billingType = 'PAYG'; automaticPatching = `$false } }
}
function global:Invoke-WebRequest {
    param(`$Uri, `$Method, `$ContentType, `$Body, `$ErrorAction)
    Write-Call `$Uri `$Method `$true
    [pscustomobject]@{ Content = '{"access_token":"fictitious-access-token"}' }
}
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$ErrorAction)
    Write-Call `$Uri `$Method `$false
    if (`$Method -ne 'GET') { throw "Mutation attempted: `$Method" }
    if (`$Uri -match '/providers/Microsoft\.HybridCompute\?') { return [pscustomobject]@{ registrationState = 'Registered' } }
    if (`$Uri -match '/providers/Microsoft\.AzureArcData\?') { return [pscustomobject]@{ registrationState = 'Registered' } }
    if (`$Uri -match 'sqlServerInstances') {
        if (`$global:scenario -eq 'TransientRetry' -and `$global:transientAttempts -eq 0) {
            `$global:transientAttempts++
            `$exception = [System.Exception]::new('429 response included Authorization: Bearer fictitious-access-token')
            `$exception | Add-Member -MemberType NoteProperty -Name Response -Value ([pscustomobject]@{ StatusCode = 429; Headers = @{ 'x-ms-retry-after-ms' = '0' } })
            throw `$exception
        }
        `$global:sqlPage++
        if (`$global:sqlPage -eq 1) {
            `$next = switch (`$global:scenario) {
                'HostileNextLink' { 'https://attacker.example/steal?page=2' }
                'HostilePort' { 'https://management.azure.com:444/mock?page=2' }
                default { 'https://management.azure.com/mock?page=2' }
            }
            return [pscustomobject]@{ value = @((New-Instance 'other' 'other-instance' '13.0' 'Enterprise' '$fresh' '$fresh')); nextLink = `$next }
        }
    }
    if (`$Uri -eq 'https://management.azure.com/mock?page=2') {
        `$values = switch (`$global:scenario) {
            'Mixed' { @((New-Instance 'sql-01' 'sql-2014' '12.0.1' 'Standard' '$fresh' '$fresh'), (New-Instance 'sql-01' 'sql-2016' '13.0.1' 'Enterprise' '$fresh' '$fresh')) }
            'Stale' { @((New-Instance 'sql-01' 'sql-2016' '13.0.1' 'Standard' '$stale' `$null)) }
            'PassiveDR' { @((New-Instance 'sql-01' 'sql-2016' '13.0.1' 'Standard' '$fresh' '$fresh' 'VirtualMachine' 8 'Production' `$true)) }
            'AllIneligible' { @((New-Instance 'sql-01' 'sql-2019' 'SQL Server 2019' 'Enterprise' '$fresh' '$fresh'), (New-Instance 'sql-01' 'sql-express' 'SQL Server 2016' 'Express' '$fresh' '$fresh')) }
            'Developer' { @((New-Instance 'sql-01' 'sql-dev' 'SQL Server 2016' 'Developer' '$fresh' '$fresh' 'VirtualMachine' 8 'NonProduction')) }
            'ConflictingMetering' { @((New-Instance 'sql-01' 'sql-a' 'SQL Server 2016' 'Standard' '$fresh' '$fresh' 'VirtualMachine' 8), (New-Instance 'sql-01' 'sql-b' 'SQL Server 2016' 'Enterprise' '$fresh' '$fresh' 'Physical Server' 16)) }
            default { @((New-Instance 'sql-01' 'sql-2016' '13.0.1' 'Standard' '$fresh' '$fresh')) }
        }
        `$next = if (`$global:scenario -eq 'RepeatedNextLink') { 'https://management.azure.com/mock?page=2' } else { `$null }
        return [pscustomobject]@{ value = `$values; nextLink = `$next }
    }
    if (`$Uri -match '/machines/([^/?]+)\?api-version=2026-07-15$') {
        `$machine = `$Matches[1]
        if (`$global:scenario -eq 'MissingMachine' -or (`$global:scenario -eq 'PartialFailure' -and `$machine -eq 'sql-bad')) { throw '404 NotFound' }
        if (`$global:scenario -eq 'SecretFailure') { throw '500 Authorization: Bearer fictitious-access-token client_secret=fictitious-client-secret' }
        `$status = if (`$global:scenario -eq 'Disconnected') { 'Disconnected' } else { 'Connected' }
        return [pscustomobject]@{ location = 'eastus'; properties = [pscustomobject]@{ status = `$status; agentConfiguration = [pscustomobject]@{ mode = 'Full' }; osName = 'Windows Server 2022'; detectedProperties = [pscustomobject]@{ cloudProvider = 'VMware' } } }
    }
    if (`$Uri -match '/machines/([^/?]+)/extensions/WindowsAgent\.SqlServer\?api-version=2026-07-15$') {
        if (`$global:scenario -eq 'AbsentExtension') { throw '404 NotFound' }
        `$state = if (`$global:scenario -eq 'FailedExtension') { 'Failed' } else { 'Succeeded' }
        `$version = if (`$global:scenario -eq 'UnknownVersion') { '1.1.9999.999' } else { '1.1.3518.465' }
        `$esu = switch (`$global:scenario) { 'Disabled' { `$false }; 'RawString' { 'TrUe' }; 'RawInvalid' { 'enabled' }; default { `$true } }
        return [pscustomobject]@{ properties = [pscustomobject]@{ publisher = 'Microsoft.AzureData'; type = 'WindowsAgent.SqlServer'; provisioningState = `$state; typeHandlerVersion = `$version; enableAutomaticUpgrade = `$true; settings = [pscustomobject]@{ LicenseType = 'Paid'; SqlManagement = [pscustomobject]@{ IsEnabled = `$true }; enableExtendedSecurityUpdates = `$esu; esuLastUpdatedTimestamp = '$fresh'; AutomaticPatching = [pscustomobject]@{ IsEnabled = `$false } } } }
    }
    throw "Unexpected URI: `$Uri"
}
`$token = [pscustomobject]@{ ExpiresOn = (Get-Date).AddMinutes(30); Token = ConvertTo-SecureString 'fictitious-user-token' -AsPlainText -Force }
& '$escapedScript' $targetArguments $authArguments -exportCsvPath '$escapedExport'
exit `$LASTEXITCODE
"@

    try {
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1
        $calls = if (Test-Path $recordPath) { @(Get-Content $recordPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        $exported = if (Test-Path $exportPath) { @(Import-Csv $exportPath) } else { @() }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output); Calls = $calls; Exported = $exported }
    }
    finally {
        Remove-Item $recordPath, $csvPath, $exportPath -ErrorAction SilentlyContinue
    }
}

Describe 'CheckSQLServerESUStatus parsing and input' {
    It 'parses and exposes mutually exclusive single and CSV parameter sets' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        $command = Get-Command $scriptPath
        (@($command.ParameterSets.Name) -contains 'SingleMachine') | Should Be $true
        (@($command.ParameterSets.Name) -contains 'Csv') | Should Be $true
    }

    It 'aggregates invalid CSV rows, rejects duplicates, and applies subscription overrides' {
        Import-StatusFunction Test-SubscriptionId
        Import-StatusFunction Test-ResourceGroupName
        Import-StatusFunction Test-MachineName
        Import-StatusFunction ConvertTo-StatusPlan
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "sql-status-validation-$PID.csv"
        @"
SubscriptionId,ServerResourceGroupName,ARCServerName
bad,arc-rg,sql-bad
$overrideSubscriptionId,arc-rg,sql-01
$($overrideSubscriptionId.ToUpperInvariant()),ARC-RG,SQL-01
"@ | Set-Content $path
        $result = ConvertTo-StatusPlan -ParameterSetName Csv -DefaultSubscriptionId $subscriptionId -Path $path
        ($result.Errors -join ' ') | Should Match 'Row 2:.*SubscriptionId'
        ($result.Errors -join ' ') | Should Match 'Row 4:.*Duplicate'
        $result.Items[0].SubscriptionId | Should Be $overrideSubscriptionId
        Remove-Item $path
    }

    It 'validates every CSV row before authentication or ARM requests' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName
bad,arc-rg,sql-01
"@
        $result = Invoke-StatusScenario -CsvContent $csv
        $result.ExitCode | Should Be 1
        $result.Calls.Count | Should Be 0
    }
}

Describe 'CheckSQLServerESUStatus ARM and correlation behavior' {
    It 'uses exact APIs, trusted pagination, multi-instance correlation, and GET only' {
        $result = Invoke-StatusScenario -Scenario Mixed
        $requests = $result.Calls.Uri -join "`n"
        $result.ExitCode | Should Be 0
        $requests | Should Match '/machines/sql-01\?api-version=2026-07-15'
        $requests | Should Match '/extensions/WindowsAgent.SqlServer\?api-version=2026-07-15'
        $requests | Should Match 'sqlServerInstances\?api-version=2026-01-01'
        $requests | Should Match 'mock\?page=2'
        @($result.Calls | Where-Object { -not $_.IsAuthentication -and $_.Method -ne 'GET' }).Count | Should Be 0
        $result.Exported[0].EligibleInstances | Should Match 'sql-2014.*sql-2016'
        $result.Exported[0].EligibleInstances | Should Not Match 'other-instance'
        $result.Exported[0].MixedEligibleVersions | Should Be 'True'
        $result.Exported[0].Warnings | Should Match 'separate ESU meter'
    }

    It 'rejects an untrusted nextLink before sending credentials to it' {
        $result = Invoke-StatusScenario -Scenario HostileNextLink
        $result.ExitCode | Should Be 1
        ($result.Calls.Uri -join ' ') | Should Not Match 'attacker\.example'
        $result.Exported[0].Reasons | Should Match 'management\.azure\.com'
    }

    It 'rejects a non-default ARM port and a repeated pagination link before another request' {
        $port = Invoke-StatusScenario -Scenario HostilePort
        $repeat = Invoke-StatusScenario -Scenario RepeatedNextLink
        $port.ExitCode | Should Be 1
        ($port.Calls.Uri -join ' ') | Should Not Match 'management\.azure\.com:444'
        $port.Exported[0].Reasons | Should Match 'default port'
        $repeat.ExitCode | Should Be 1
        @($repeat.Calls | Where-Object Uri -eq 'https://management.azure.com/mock?page=2').Count | Should Be 1
        $repeat.Exported[0].Reasons | Should Match 'previously visited'
    }

    It 'retries a transient GET using the retry header and then succeeds' {
        $result = Invoke-StatusScenario -Scenario TransientRetry
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Uri -match 'sqlServerInstances').Count | Should Be 2
        @($result.Calls | Where-Object Method -eq 'SLEEP').Count | Should Be 1
        ($result.Output | Out-String) | Should Not Match 'fictitious-access-token|Authorization|Bearer'
    }

    It 'uses a CSV row subscription override in provider, inventory, machine, and extension URIs' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName
$overrideSubscriptionId,arc-rg,sql-01
"@
        $result = Invoke-StatusScenario -CsvContent $csv
        $armCalls = @($result.Calls | Where-Object { -not $_.IsAuthentication })
        $subscriptionScopedCalls = @($armCalls | Where-Object Uri -match '/subscriptions/')
        @($subscriptionScopedCalls | Where-Object Uri -match "/subscriptions/$overrideSubscriptionId/").Count | Should Be $subscriptionScopedCalls.Count
        @($subscriptionScopedCalls | Where-Object Uri -match "/subscriptions/$subscriptionId/").Count | Should Be 0
    }
}

Describe 'CheckSQLServerESUStatus classifications' {
    It 'classifies enabled fresh status as Healthy and disabled status as NotEnabled' {
        $healthy = Invoke-StatusScenario Healthy
        $disabled = Invoke-StatusScenario Disabled
        $healthy.Exported[0].Classification | Should Be 'Healthy'
        $healthy.Exported[0].ESUEnabled | Should Be 'True'
        $disabled.Exported[0].Classification | Should Be 'NotEnabled'
        $disabled.Exported[0].ESUEnabled | Should Be 'False'
    }

    It 'returns all ineligible resources and keeps the host status uncertain' {
        $result = Invoke-StatusScenario AllIneligible
        $result.Exported[0].Instances | Should Match 'sql-2019.*UnsupportedVersion'
        $result.Exported[0].Instances | Should Match 'sql-express.*IneligibleEdition'
        $result.Exported[0].IneligibleInstances | Should Match 'sql-2019.*sql-express'
        $result.Exported[0].EligibleInstances | Should BeNullOrEmpty
        $result.Exported[0].Classification | Should Be 'Unknown'
    }

    It 'distinguishes Developer and stale or missing usage uncertainty per instance' {
        $developer = Invoke-StatusScenario Developer
        $stale = Invoke-StatusScenario Stale
        $developer.Exported[0].Instances | Should Match 'DeveloperNonProductionUncertain.*NonProduction'
        $developer.Exported[0].UncertainInstances | Should Match 'DeveloperNonProductionUncertain'
        $stale.Exported[0].Instances | Should Match 'InventoryOrUsageUncertain.*Stale.*Unknown'
        $stale.Exported[0].EligibleInstances | Should Match 'sql-2016'
        $stale.Exported[0].Classification | Should Be 'Warning'
    }

    It 'reports explicit passive DR and environment evidence without using billingType' {
        $result = Invoke-StatusScenario PassiveDR
        $result.Exported[0].PassiveDRState | Should Be 'True'
        $result.Exported[0].Environments | Should Be 'Production'
        $result.Exported[0].Instances | Should Match 'Production'
    }

    It 'classifies conflicting host type and core evidence as uncertain' {
        $result = Invoke-StatusScenario ConflictingMetering
        $result.Exported[0].HostType | Should BeNullOrEmpty
        $result.Exported[0].DetectedCores | Should BeNullOrEmpty
        $result.Exported[0].HostTypeEvidenceStatus | Should Be 'Conflict'
        $result.Exported[0].DetectedCoresEvidenceStatus | Should Be 'Conflict'
        $result.Exported[0].MeteringEvidenceStatus | Should Be 'UncertainConflict'
        $result.Exported[0].Warnings | Should Match 'Conflicting host type.*Conflicting detected core'
    }

    It 'returns correlated instances when the SQL extension is absent' {
        $result = Invoke-StatusScenario AbsentExtension
        $result.Exported[0].ExtensionInstalled | Should Be 'False'
        $result.Exported[0].Instances | Should Match 'sql-2016.*SupportedEligible'
        $result.Exported[0].Classification | Should Be 'NotEnabled'
    }

    It 'normalizes raw Boolean and string ESU values while preserving the raw representation' {
        $boolean = Invoke-StatusScenario Healthy
        $string = Invoke-StatusScenario RawString
        $invalid = Invoke-StatusScenario RawInvalid
        $boolean.Exported[0].ESURawValue | Should Be 'True'
        $string.Exported[0].ESURawValue | Should Be 'TrUe'
        $string.Exported[0].ESUEnabled | Should Be 'True'
        $invalid.Exported[0].Classification | Should Be 'Unknown'
    }

    It 'classifies stale inventory warning-only, failed extension as Error, and disconnected state as Warning' {
        $staleResult = Invoke-StatusScenario Stale
        $failed = Invoke-StatusScenario FailedExtension
        $disconnected = Invoke-StatusScenario Disconnected
        $staleResult.Exported[0].Classification | Should Be 'Warning'
        $staleResult.Exported[0].InventoryFreshness | Should Be 'Stale'
        $failed.Exported[0].Classification | Should Be 'Error'
        $failed.Exported[0].Reasons | Should Match 'provisioning state'
        $disconnected.Exported[0].Classification | Should Be 'Warning'
        $disconnected.Exported[0].Warnings | Should Match 'Disconnected'
    }

    It 'reports unknown extension-version support without making an exact-version-only claim' {
        $result = Invoke-StatusScenario UnknownVersion
        $result.Exported[0].ExtensionVersionSupport | Should Be 'Unknown'
        $result.Exported[0].Classification | Should Be 'Warning'
        $result.Exported[0].Warnings | Should Match 'current explicit supported baseline'
    }
}

Describe 'CheckSQLServerESUStatus failure and authentication safety' {
    It 'continues after a target failure and exits 1 when any target cannot be evaluated' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName
$subscriptionId,arc-rg,sql-bad
$subscriptionId,arc-rg,sql-01
"@
        $result = Invoke-StatusScenario -Scenario PartialFailure -CsvContent $csv
        $result.ExitCode | Should Be 1
        $result.Exported.Count | Should Be 2
        ($result.Exported | Where-Object MachineName -eq 'sql-bad').Evaluated | Should Be 'False'
        ($result.Exported | Where-Object MachineName -eq 'sql-01').Evaluated | Should Be 'True'
    }

    It 'supports service principal authentication without exposing secrets or authorization headers' {
        $result = Invoke-StatusScenario -ServicePrincipal
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object IsAuthentication).Count | Should Be 1
        ($result.Output | Out-String) | Should Not Match 'fictitious-client-secret|fictitious-access-token|Authorization|Bearer'
    }

    It 'redacts exception details when a failing ARM response contains credentials' {
        $result = Invoke-StatusScenario SecretFailure
        $result.ExitCode | Should Be 1
        ($result.Output | Out-String) | Should Not Match 'fictitious-access-token|fictitious-client-secret|Authorization|Bearer'
        $result.Exported[0].Reasons | Should Not Match 'fictitious-access-token|fictitious-client-secret|Authorization|Bearer'
        $result.Exported[0].Reasons | Should Match 'HTTP 500'
    }

    It 'never invokes an ARM mutation method in all status scenarios' {
        foreach ($scenario in @('Healthy', 'Disabled', 'Stale', 'FailedExtension', 'Disconnected', 'Mixed', 'RawString', 'PartialFailure')) {
            $csv = if ($scenario -eq 'PartialFailure') { "SubscriptionId,ServerResourceGroupName,ARCServerName`n$subscriptionId,arc-rg,sql-bad`n$subscriptionId,arc-rg,sql-01" } else { $null }
            $result = Invoke-StatusScenario -Scenario $scenario -CsvContent $csv
            @($result.Calls | Where-Object { -not $_.IsAuthentication -and $_.Method -ne 'GET' }).Count | Should Be 0
        }
    }
}