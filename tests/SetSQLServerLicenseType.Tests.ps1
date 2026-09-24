$scriptPath = Join-Path $PSScriptRoot '..\Scripts\sql\SetSQLServerLicenseType.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$tenantId = '00000000-0000-0000-0000-000000000002'
$appId = '00000000-0000-0000-0000-000000000003'
$csvHeader = 'SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,AttestSoftwareAssurance,AcceptPaygBilling,ConsentToRecurringPAYG,ConfirmCoreBasedEnterpriseLicense'

function Invoke-LicenseScenario {
    param(
        [ValidateSet('Empty', 'Missing', 'AlreadyPaid', 'AlreadyLicenseOnly', 'Enterprise', 'NoInventory', 'EsuEnabled', 'ExistingConsent', 'Async', 'VerificationMismatch', 'MonitorMode', 'WrongIdentity', 'SecondHostPaid', 'DriftOtherValue', 'DriftSameValue', 'DriftSetting')]
        [string]$Scenario = 'Empty',
        [string]$AdditionalArguments = '-LicenseType Paid -AttestSoftwareAssurance',
        [string]$CsvContent,
        [switch]$ServicePrincipal
    )

    $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-license-record-$PID-$([guid]::NewGuid().ToString('N')).jsonl"
    $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-license-input-$PID-$([guid]::NewGuid().ToString('N')).csv"
    if (-not [string]::IsNullOrWhiteSpace($CsvContent)) { Set-Content -LiteralPath $csvPath -Value $CsvContent }

    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $escapedRecordPath = $recordPath.Replace("'", "''")
    $escapedCsvPath = $csvPath.Replace("'", "''")
    $authenticationArguments = if ($ServicePrincipal) {
        "-tenantId '$tenantId' -appID '$appId' -clientSecret 'fictitious-client-secret'"
    } else {
        '-userToken $token'
    }
    $targetArguments = if ([string]::IsNullOrWhiteSpace($CsvContent)) {
        "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01' $AdditionalArguments"
    } else {
        "-subscriptionId '$subscriptionId' -csvFilePath '$escapedCsvPath' $AdditionalArguments"
    }

    $command = @"
`$global:mockScenario = '$Scenario'
`$global:requestCounts = @{}
`$global:updatedBodies = @{}
`$global:extensionGets = @{}

function global:New-MockWebResponse {
    param([int]`$StatusCode, [object]`$Content, [hashtable]`$Headers = @{})
    `$serialized = if (`$null -eq `$Content) { '' } elseif (`$Content -is [string]) { `$Content } else { `$Content | ConvertTo-Json -Depth 100 -Compress }
    return [pscustomobject]@{ StatusCode = `$StatusCode; Content = `$serialized; Headers = `$Headers }
}

function global:New-MockSettings {
    param([string]`$MachineName)
    `$settings = [ordered]@{
        SqlManagement = [ordered]@{ IsEnabled = `$true; Nested = [ordered]@{ FutureFlag = 'preserve-me' } }
        LicenseType = ''
        ExcludedSqlInstances = @('ARCHIVE', 'LEGACY')
        enableExtendedSecurityUpdates = (`$global:mockScenario -eq 'EsuEnabled')
        esuLastUpdatedTimestamp = '2026-08-01T00:00:00.000Z'
        AzureDefender = [ordered]@{ IsEnabled = `$true; Rules = @([ordered]@{ Name = 'A'; Value = 1 }) }
    }
    if (`$global:mockScenario -eq 'Missing') { `$settings.Remove('LicenseType') }
    if (`$global:mockScenario -eq 'AlreadyPaid' -or (`$global:mockScenario -eq 'SecondHostPaid' -and `$MachineName -eq 'server-02')) { `$settings.LicenseType = 'Paid' }
    if (`$global:mockScenario -eq 'AlreadyLicenseOnly') { `$settings.LicenseType = 'LicenseOnly' }
    if (`$global:mockScenario -eq 'ExistingConsent') { `$settings.ConsentToRecurringPAYG = [ordered]@{ Consented = `$true; ConsentTimestamp = '2025-01-01T00:00:00Z' } }
    # Drift scenarios change the extension only on reads after preflight (before the PUT).
    if (`$global:extensionGets[`$MachineName] -ge 2 -and -not `$global:updatedBodies.ContainsKey(`$MachineName)) {
        if (`$global:mockScenario -eq 'DriftOtherValue') { `$settings.LicenseType = 'PAYG'; `$settings.enableExtendedSecurityUpdates = `$true }
        if (`$global:mockScenario -eq 'DriftSameValue') { `$settings.LicenseType = 'Paid' }
        if (`$global:mockScenario -eq 'DriftSetting') { `$settings.esuLastUpdatedTimestamp = '2026-09-01T00:00:00.000Z' }
    }
    return `$settings
}

function global:New-MockExtension {
    param([string]`$MachineName = 'server-01', [switch]`$Final)
    `$settings = New-MockSettings -MachineName `$MachineName
    if (`$Final -and `$global:updatedBodies.ContainsKey(`$MachineName)) {
        `$settings = `$global:updatedBodies[`$MachineName].properties.settings | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100 -DateKind String
        if (`$global:mockScenario -eq 'VerificationMismatch') { `$settings.LicenseType = '' }
    }
    return [ordered]@{
        id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$MachineName/extensions/WindowsAgent.SqlServer"
        name = 'WindowsAgent.SqlServer'
        type = 'Microsoft.HybridCompute/machines/extensions'
        location = 'westus2'
        tags = @{ owner = 'dba-team' }
        properties = [ordered]@{
            publisher = if (`$global:mockScenario -eq 'WrongIdentity') { 'Contoso.Unsupported' } else { 'Microsoft.AzureData' }
            type = 'WindowsAgent.SqlServer'
            typeHandlerVersion = '1.1.3518.465'
            autoUpgradeMinorVersion = `$true
            enableAutomaticUpgrade = `$true
            provisioningState = 'Succeeded'
            instanceView = @{ typeHandlerVersion = '1.1.3518.465' }
            protectedSettings = @{ secret = 'must-not-copy' }
            settings = `$settings
        }
    }
}

function global:New-MockInstance {
    param([string]`$MachineName, [string]`$Name, [string]`$Version, [string]`$Edition)
    return [ordered]@{
        id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.AzureArcData/sqlServerInstances/`$MachineName-`$Name"
        name = `$Name
        properties = [ordered]@{
            containerResourceId = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$MachineName"
            version = `$Version
            edition = `$Edition
            hostType = 'Virtual Machine'
            vCore = 8
        }
    }
}

function global:Start-Sleep {
    param([int]`$Seconds)
}

function global:Invoke-WebRequest {
    param(`$Uri, `$Method, `$Headers, `$Body, `$ContentType, `$ErrorAction, `$SkipHttpErrorCheck)
    [pscustomobject]@{ Uri = [string]`$Uri; Method = [string]`$Method; Body = [string]`$Body } | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath '$escapedRecordPath'
    `$key = "`$Method `$Uri"
    if (-not `$global:requestCounts.ContainsKey(`$key)) { `$global:requestCounts[`$key] = 0 }
    `$global:requestCounts[`$key]++

    if ([string]`$Uri -like 'https://login.microsoftonline.com/*') { return New-MockWebResponse 200 @{ access_token = 'fictitious-access-token' } }
    if ([string]`$Uri -eq 'https://management.azure.com/operations/license-01') {
        if (`$global:requestCounts[`$key] -eq 1) { return New-MockWebResponse 202 @{ status = 'InProgress' } @{ 'Retry-After' = '0' } }
        return New-MockWebResponse 200 @{ status = 'Succeeded' }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.(HybridCompute|AzureArcData)\?api-version=2021-04-01$') {
        return New-MockWebResponse 200 @{ registrationState = 'Registered' }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.AzureArcData/sqlServerInstances\?api-version=2026-01-01$') {
        if (`$global:mockScenario -eq 'NoInventory') { return New-MockWebResponse 200 @{ value = @() } }
        `$edition = if (`$global:mockScenario -eq 'Enterprise') { 'Enterprise' } else { 'Standard' }
        `$instances = @()
        foreach (`$machine in @('server-01', 'server-02')) {
            `$instances += New-MockInstance -MachineName `$machine -Name 'MSSQLSERVER' -Version 'SQL Server 2016' -Edition `$edition
            `$instances += New-MockInstance -MachineName `$machine -Name 'SQL2022' -Version 'SQL Server 2022' -Edition 'Standard'
        }
        return New-MockWebResponse 200 @{ value = `$instances }
    }
    if ([string]`$Uri -match '/machines/([^/?]+)/extensions/WindowsAgent\.SqlServer\?api-version=2026-07-15$') {
        `$machine = `$Matches[1]
        if ([string]`$Method -eq 'PUT') {
            `$global:updatedBodies[`$machine] = `$Body | ConvertFrom-Json -Depth 100 -DateKind String
            if (`$global:mockScenario -eq 'Async') { return New-MockWebResponse 202 `$null @{ 'Azure-AsyncOperation' = 'https://management.azure.com/operations/license-01' } }
            return New-MockWebResponse 200 (New-MockExtension -MachineName `$machine)
        }
        if (-not `$global:extensionGets.ContainsKey(`$machine)) { `$global:extensionGets[`$machine] = 0 }
        `$global:extensionGets[`$machine]++
        return New-MockWebResponse 200 (New-MockExtension -MachineName `$machine -Final)
    }
    if ([string]`$Uri -match '/machines/([^/?]+)\?api-version=2026-07-15$') {
        `$machine = `$Matches[1]
        return New-MockWebResponse 200 @{
            id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$machine"
            location = 'westus2'
            properties = @{ status = 'Connected'; osName = 'Windows Server 2016'; agentConfiguration = @{ configMode = if (`$global:mockScenario -eq 'MonitorMode') { 'monitor' } else { 'full' } }; detectedProperties = @{ cloudProvider = 'N/A' } }
        }
    }
    return New-MockWebResponse 404 @{ error = @{ code = 'UnexpectedMockUri'; message = [string]`$Uri } }
}

`$token = [pscustomobject]@{ ExpiresOn = (Get-Date).AddMinutes(30); Token = ConvertTo-SecureString 'fictitious-user-token' -AsPlainText -Force }
& '$escapedScriptPath' $targetArguments $authenticationArguments -Confirm:`$false
exit `$LASTEXITCODE
"@

    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit(20000)
        if (-not $completed) { $process.Kill($true); $process.WaitForExit() }
        $output = $standardOutputTask.GetAwaiter().GetResult() + $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = if ($completed) { $process.ExitCode } else { 124 }
        if (-not $completed) { $output += "`nScenario process exceeded 20 seconds." }
        $process.Dispose()
        $calls = if (Test-Path -LiteralPath $recordPath) { @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output -replace '\s+', ' ')
            Calls = $calls
            Puts = @($calls | Where-Object Method -eq 'PUT')
        }
    } finally {
        Remove-Item -LiteralPath $recordPath, $csvPath -ErrorAction SilentlyContinue
    }
}

function Get-PutSetting {
    param([object]$Result, [int]$Index = 0)
    return ($Result.Puts[$Index].Body | ConvertFrom-Json -Depth 100 -DateKind String).properties.settings
}

Describe 'SetSQLServerLicenseType command and local validation' {
    It 'exposes single and CSV parameter sets, the three license values, and confirmation controls' {
        $command = Get-Command $scriptPath
        (@($command.ParameterSets | Where-Object Name -eq 'Single').Count -eq 1) | Should Be $true
        (@($command.ParameterSets | Where-Object Name -eq 'Csv').Count -eq 1) | Should Be $true
        foreach ($name in @('WhatIf', 'Confirm', 'DryRun', 'AttestSoftwareAssurance', 'AcceptPaygBilling', 'ConsentToRecurringPAYG', 'ConfirmCoreBasedEnterpriseLicense')) {
            (@($command.Parameters.Keys) -contains $name) | Should Be $true
        }
        $validValues = $command.Parameters.LicenseType.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object ValidValues
        ($validValues -join ',') | Should Be 'Paid,PAYG,LicenseOnly'
        (@($command.Parameters.Keys) -contains 'Force') | Should Be $false
    }

    It 'requires the matching acknowledgement for each license type before authentication' {
        $paid = Invoke-LicenseScenario -AdditionalArguments '-LicenseType Paid'
        $paid.ExitCode | Should Be 1
        $paid.Output | Should Match 'AttestSoftwareAssurance must be TRUE for Paid'
        $paid.Calls.Count | Should Be 0
        $payg = Invoke-LicenseScenario -AdditionalArguments '-LicenseType PAYG'
        $payg.ExitCode | Should Be 1
        $payg.Output | Should Match 'AcceptPaygBilling must be TRUE for PAYG'
        $payg.Calls.Count | Should Be 0
    }

    It 'rejects acknowledgements that belong to a different license type before authentication' {
        foreach ($arguments in @(
            '-LicenseType Paid -AttestSoftwareAssurance -AcceptPaygBilling',
            '-LicenseType Paid -AttestSoftwareAssurance -ConsentToRecurringPAYG',
            '-LicenseType PAYG -AcceptPaygBilling -AttestSoftwareAssurance',
            '-LicenseType PAYG -AcceptPaygBilling -ConfirmCoreBasedEnterpriseLicense',
            '-LicenseType LicenseOnly -AttestSoftwareAssurance',
            '-LicenseType LicenseOnly -ConsentToRecurringPAYG'
        )) {
            $result = Invoke-LicenseScenario -AdditionalArguments $arguments
            $result.ExitCode | Should Be 1
            $result.Calls.Count | Should Be 0
        }
    }

    It 'rejects a CSV batch with any invalid row before authentication' {
        $csv = @"
$csvHeader
$subscriptionId,server-rg,server-01,Paid,TRUE,FALSE,FALSE,FALSE
$subscriptionId,server-rg,server-02,PAYG,FALSE,FALSE,FALSE,FALSE
"@
        $result = Invoke-LicenseScenario -CsvContent $csv -AdditionalArguments ''
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Row 3'
        $result.Calls.Count | Should Be 0
    }

    It 'rejects CSV files with unsupported license or billing-like columns' {
        $csv = @"
$csvHeader,AcceptPaygBillingOverride
$subscriptionId,server-rg,server-01,Paid,TRUE,FALSE,FALSE,FALSE,TRUE
"@
        $result = Invoke-LicenseScenario -CsvContent $csv -AdditionalArguments ''
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'unsupported columns'
        $result.Calls.Count | Should Be 0
    }
}

Describe 'SetSQLServerLicenseType changes only an empty LicenseType' {
    It 'sets Paid on an empty host, preserves every other setting and tag, and shows the attestation warning' {
        $result = Invoke-LicenseScenario
        $result.ExitCode | Should Be 0
        $result.Puts.Count | Should Be 1
        $settings = Get-PutSetting -Result $result
        $settings.LicenseType | Should Be 'Paid'
        $settings.enableExtendedSecurityUpdates | Should Be $false
        $settings.esuLastUpdatedTimestamp | Should Be '2026-08-01T00:00:00.000Z'
        $settings.SqlManagement.Nested.FutureFlag | Should Be 'preserve-me'
        ($null -eq $settings.PSObject.Properties['ConsentToRecurringPAYG']) | Should Be $true
        $body = $result.Puts[0].Body | ConvertFrom-Json -Depth 100
        $body.tags.owner | Should Be 'dba-team'
        ($null -eq $body.properties.PSObject.Properties['protectedSettings']) | Should Be $true
        $result.Output | Should Match 'ATTESTATION'
        $result.Output | Should Match 'HOST-WIDE'
        $result.Output | Should Match 'SQL2022'
    }

    It 'treats a missing LicenseType property as empty' {
        $result = Invoke-LicenseScenario -Scenario Missing
        $result.ExitCode | Should Be 0
        (Get-PutSetting -Result $result).LicenseType | Should Be 'Paid'
    }

    It 'never overwrites an existing LicenseType' {
        $different = Invoke-LicenseScenario -Scenario AlreadyLicenseOnly
        $different.ExitCode | Should Be 1
        $different.Output | Should Match 'never overwrites'
        $different.Puts.Count | Should Be 0
        $same = Invoke-LicenseScenario -Scenario AlreadyPaid
        $same.ExitCode | Should Be 0
        $same.Output | Should Match 'AlreadyCompliant'
        $same.Puts.Count | Should Be 0
    }

    It 'sets PAYG only with billing acceptance and warns about CSP consent when it is not requested' {
        $result = Invoke-LicenseScenario -AdditionalArguments '-LicenseType PAYG -AcceptPaygBilling'
        $result.ExitCode | Should Be 0
        $settings = Get-PutSetting -Result $result
        $settings.LicenseType | Should Be 'PAYG'
        ($null -eq $settings.PSObject.Properties['ConsentToRecurringPAYG']) | Should Be $true
        $result.Output | Should Match 'BILLING'
        $result.Output | Should Match 'CSP'
    }

    It 'records ConsentToRecurringPAYG only when requested with PAYG' {
        $result = Invoke-LicenseScenario -AdditionalArguments '-LicenseType PAYG -AcceptPaygBilling -ConsentToRecurringPAYG'
        $result.ExitCode | Should Be 0
        $settings = Get-PutSetting -Result $result
        $settings.ConsentToRecurringPAYG.Consented | Should Be $true
        ([string]$settings.ConsentToRecurringPAYG.ConsentTimestamp) | Should Match '^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $result.Output | Should Match 'RECURRING BILLING CONSENT'
        $result.Output | Should Match 'reinstalling the extension'
    }

    It 'leaves an existing ConsentToRecurringPAYG unchanged' {
        $result = Invoke-LicenseScenario -Scenario ExistingConsent -AdditionalArguments '-LicenseType PAYG -AcceptPaygBilling -ConsentToRecurringPAYG'
        $result.ExitCode | Should Be 0
        ([string](Get-PutSetting -Result $result).ConsentToRecurringPAYG.ConsentTimestamp) | Should Be '2025-01-01T00:00:00Z'
        $result.Output | Should Match 'already recorded'
    }

    It 'requires the core-based Enterprise confirmation for Paid when Enterprise is reported' {
        $blocked = Invoke-LicenseScenario -Scenario Enterprise
        $blocked.ExitCode | Should Be 1
        $blocked.Output | Should Match 'Server\+CAL'
        $blocked.Puts.Count | Should Be 0
        $confirmed = Invoke-LicenseScenario -Scenario Enterprise -AdditionalArguments '-LicenseType Paid -AttestSoftwareAssurance -ConfirmCoreBasedEnterpriseLicense'
        $confirmed.ExitCode | Should Be 0
        $confirmed.Puts.Count | Should Be 1
        $payg = Invoke-LicenseScenario -Scenario Enterprise -AdditionalArguments '-LicenseType PAYG -AcceptPaygBilling'
        $payg.ExitCode | Should Be 0
    }

    It 'requires the core-based Enterprise confirmation for Paid when no inventory is available' {
        $blocked = Invoke-LicenseScenario -Scenario NoInventory
        $blocked.ExitCode | Should Be 1
        $blocked.Output | Should Match 'No SQL Server inventory'
        $blocked.Puts.Count | Should Be 0
        $licenseOnly = Invoke-LicenseScenario -Scenario NoInventory -AdditionalArguments '-LicenseType LicenseOnly'
        $licenseOnly.ExitCode | Should Be 0
        $licenseOnly.Output | Should Match 'cannot be listed'
        (Get-PutSetting -Result $licenseOnly).LicenseType | Should Be 'LicenseOnly'
    }

    It 'refuses LicenseOnly while ESU is enabled' {
        $result = Invoke-LicenseScenario -Scenario EsuEnabled -AdditionalArguments '-LicenseType LicenseOnly'
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'canceled before LicenseType'
        $result.Puts.Count | Should Be 0
    }

    It 'previews with every warning and no PUT during a dry run' {
        $result = Invoke-LicenseScenario -AdditionalArguments '-LicenseType PAYG -AcceptPaygBilling -DryRun'
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Previewed'
        $result.Output | Should Match 'BILLING'
        $result.Puts.Count | Should Be 0
        $whatIf = Invoke-LicenseScenario -AdditionalArguments '-LicenseType Paid -AttestSoftwareAssurance -WhatIf'
        $whatIf.ExitCode | Should Be 0
        $whatIf.Output | Should Match 'Previewed'
        $whatIf.Puts.Count | Should Be 0
    }

    It 'starts no change when any CSV target fails preflight' {
        $csv = @"
$csvHeader
$subscriptionId,server-rg,server-01,Paid,TRUE,FALSE,FALSE,FALSE
$subscriptionId,server-rg,server-02,PAYG,FALSE,TRUE,FALSE,FALSE
"@
        $result = Invoke-LicenseScenario -Scenario SecondHostPaid -CsvContent $csv -AdditionalArguments ''
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'NotStarted'
        $result.Puts.Count | Should Be 0
    }

    It 're-reads the extension before the PUT and never writes over changes made after preflight' {
        $overwrite = Invoke-LicenseScenario -Scenario DriftOtherValue
        $overwrite.ExitCode | Should Be 1
        $overwrite.Output | Should Match 'never overwrites'
        $overwrite.Puts.Count | Should Be 0
        $same = Invoke-LicenseScenario -Scenario DriftSameValue
        $same.ExitCode | Should Be 0
        $same.Output | Should Match 'another process after preflight'
        $same.Puts.Count | Should Be 0
        $drift = Invoke-LicenseScenario -Scenario DriftSetting
        $drift.ExitCode | Should Be 1
        $drift.Output | Should Match 'changed after preflight'
        $drift.Puts.Count | Should Be 0
    }

    It 'fails verification when the final LicenseType does not match' {
        $result = Invoke-LicenseScenario -Scenario VerificationMismatch
        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'did not converge'
    }

    It 'polls trusted asynchronous operations and supports service principal authentication' {
        $result = Invoke-LicenseScenario -Scenario Async -ServicePrincipal
        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Uri -eq 'https://management.azure.com/operations/license-01').Count | Should Be 2
        @($result.Calls | Where-Object Uri -like 'https://login.microsoftonline.com/*').Count | Should Be 1
    }

    It 'blocks monitor-mode agents and unexpected extension identities without mutation' {
        foreach ($scenario in @('MonitorMode', 'WrongIdentity')) {
            $result = Invoke-LicenseScenario -Scenario $scenario
            $result.ExitCode | Should Be 1
            $result.Puts.Count | Should Be 0
        }
    }
}
