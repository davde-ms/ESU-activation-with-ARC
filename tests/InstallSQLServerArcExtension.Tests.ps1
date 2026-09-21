$scriptPath = Join-Path $PSScriptRoot '..\Scripts\sql\InstallSQLServerArcExtension.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$overrideSubscriptionId = '00000000-0000-0000-0000-000000000004'
$tenantId = '00000000-0000-0000-0000-000000000002'
$appId = '00000000-0000-0000-0000-000000000003'

function Invoke-InstallScenario {
    param(
        [ValidateSet('Missing', 'Existing', 'Conflict', 'Async', 'CreatedPending', 'FinalMismatch', 'AutoUpgradeMismatch', 'EsuEnabled', 'RuntimeFailure', 'ProviderFailure', 'CapabilityMissing', 'CapabilityIndeterminate', 'TransientGet', 'TransientPut', 'UnsafeNextLink')]
        [string]$Scenario = 'Missing',
        [string]$AdditionalArguments,
        [string]$CsvContent,
        [switch]$ServicePrincipal
    )

    $recordPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-extension-record-$PID-$([guid]::NewGuid().ToString('N')).jsonl"
    $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "sql-extension-input-$PID-$([guid]::NewGuid().ToString('N')).csv"
    if (-not [string]::IsNullOrWhiteSpace($CsvContent)) {
        Set-Content -LiteralPath $csvPath -Value $CsvContent
    }

    $escapedScriptPath = $scriptPath.Replace("'", "''")
    $escapedRecordPath = $recordPath.Replace("'", "''")
    $escapedCsvPath = $csvPath.Replace("'", "''")
    $authenticationArguments = if ($ServicePrincipal) {
        "-tenantId '$tenantId' -appID '$appId' -clientSecret 'fictitious-client-secret'"
    } else {
        '-userToken $token'
    }
    $targetArguments = if ([string]::IsNullOrWhiteSpace($CsvContent)) {
        "-subscriptionId '$subscriptionId' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01'"
    } else {
        "-subscriptionId '$subscriptionId' -csvFilePath '$escapedCsvPath'"
    }
    $effectiveAdditionalArguments = [string]$AdditionalArguments
    if ([string]::IsNullOrWhiteSpace($CsvContent)) {
        if ($effectiveAdditionalArguments -notmatch '(?i)(^|\s)-LicenseType(?:\s|:)') {
            $effectiveAdditionalArguments += " -LicenseType 'Paid'"
        }
        if ($effectiveAdditionalArguments -notmatch '(?i)(^|\s)-ConfirmExternalPrerequisites(?:\s|:)') {
            $effectiveAdditionalArguments += ' -ConfirmExternalPrerequisites'
        }
    }

    $command = @"
`$global:mockScenario = '$Scenario'
`$global:installedMachines = @{}
`$global:preflightExtensionGets = @{}
`$global:finalExtensionGets = @{}
`$global:requestCounts = @{}

function global:New-MockWebResponse {
    param([int]`$StatusCode, [object]`$Content, [hashtable]`$Headers = @{})
    `$serializedContent = if (`$null -eq `$Content) { '' } elseif (`$Content -is [string]) { `$Content } else { `$Content | ConvertTo-Json -Depth 20 -Compress }
    return [pscustomobject]@{ StatusCode = `$StatusCode; Content = `$serializedContent; Headers = `$Headers }
}

function global:New-MockExtension {
    param(
        [string]`$LicenseType = 'Paid',
        [bool]`$SqlManagementEnabled = `$true,
        [bool]`$AutomaticUpgradeEnabled = `$true,
        [bool]`$EsuEnabled = `$false,
        [string]`$ProvisioningState = 'Succeeded',
        [string]`$Publisher = 'Microsoft.AzureData',
        [string]`$ExtensionType = 'WindowsAgent.SqlServer'
    )
    return @{
        location = 'westus2'
        properties = @{
            publisher = `$Publisher
            type = `$ExtensionType
            provisioningState = `$ProvisioningState
            enableAutomaticUpgrade = `$AutomaticUpgradeEnabled
            settings = @{
                SqlManagement = @{ IsEnabled = `$SqlManagementEnabled }
                LicenseType = `$LicenseType
                ExcludedSqlInstances = @()
                enableExtendedSecurityUpdates = `$EsuEnabled
            }
        }
    }
}

function global:Start-Sleep {
    param([int]`$Seconds)

    [pscustomobject]@{ Uri = ''; Method = 'SLEEP'; Body = [string]`$Seconds; IsAuthentication = `$false } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath '$escapedRecordPath'
}

function global:Invoke-WebRequest {
    param(`$Uri, `$Method, `$Headers, `$Body, `$ContentType, `$ErrorAction, `$SkipHttpErrorCheck)

    [pscustomobject]@{
        Uri = [string]`$Uri
        Method = [string]`$Method
        Body = [string]`$Body
        IsAuthentication = ([string]`$Uri -like 'https://login.microsoftonline.com/*')
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath '$escapedRecordPath'

    `$requestKey = "`$Method `$Uri"
    if (-not `$global:requestCounts.ContainsKey(`$requestKey)) { `$global:requestCounts[`$requestKey] = 0 }
    `$global:requestCounts[`$requestKey]++

    if ([string]`$Uri -like 'https://login.microsoftonline.com/*') {
        return New-MockWebResponse -StatusCode 200 -Content @{ access_token = 'fictitious-access-token' }
    }
    if ([string]`$Uri -eq 'https://management.azure.com/operations/install-01') {
        if (`$global:mockScenario -eq 'Async' -and `$global:requestCounts[`$requestKey] -eq 1) {
            return New-MockWebResponse -StatusCode 202 -Content @{ status = 'InProgress' } -Headers @{ 'Retry-After' = '0' }
        }
        return New-MockWebResponse -StatusCode 200 -Content @{ status = 'Succeeded' }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.HybridCompute\?api-version=2021-04-01$') {
        `$state = if (`$global:mockScenario -eq 'ProviderFailure') { 'NotRegistered' } else { 'Registered' }
        return New-MockWebResponse -StatusCode 200 -Content @{ namespace = 'Microsoft.HybridCompute'; registrationState = `$state; resourceTypes = @() }
    }
    if ([string]`$Uri -match '/providers/Microsoft\.AzureArcData\?api-version=2021-04-01$') {
        `$resourceTypes = if (`$global:mockScenario -eq 'CapabilityMissing') {
            @()
        } elseif (`$global:mockScenario -eq 'CapabilityIndeterminate') {
            @(@{ resourceType = 'sqlServerInstances'; locations = @() })
        } else {
            @(@{ resourceType = 'sqlServerInstances'; locations = @('West US 2') })
        }
        `$nextLink = if (`$global:mockScenario -eq 'UnsafeNextLink') { 'https://example.invalid/providers?page=2' } else { `$null }
        return New-MockWebResponse -StatusCode 200 -Content @{
            namespace = 'Microsoft.AzureArcData'
            registrationState = 'Registered'
            resourceTypes = `$resourceTypes
            nextLink = `$nextLink
        }
    }
    if ([string]`$Uri -match '/machines/([^/?]+)/extensions/WindowsAgent\.SqlServer\?api-version=2026-07-15$') {
        `$machineName = `$Matches[1]
        if ([string]`$Method -eq 'PUT') {
            if (`$global:mockScenario -eq 'RuntimeFailure' -and `$machineName -eq 'server-01') {
                return New-MockWebResponse -StatusCode 500 -Content @{ error = @{ code = 'MockFailure'; message = 'fictitious runtime failure' } }
            }
            if (`$global:mockScenario -eq 'TransientPut' -and `$global:requestCounts[`$requestKey] -eq 1) {
                return New-MockWebResponse -StatusCode 503 -Content @{ error = @{ code = 'ServiceUnavailable' } } -Headers @{ 'Retry-After' = '0' }
            }
            `$global:installedMachines[`$machineName] = `$true
            if (`$global:mockScenario -eq 'Async') {
                return New-MockWebResponse -StatusCode 202 -Content `$null -Headers @{ Location = 'https://management.azure.com/operations/install-01' }
            }
            return New-MockWebResponse -StatusCode 201 -Content (New-MockExtension)
        }

        if (`$global:installedMachines.ContainsKey(`$machineName)) {
            if (-not `$global:finalExtensionGets.ContainsKey(`$machineName)) { `$global:finalExtensionGets[`$machineName] = 0 }
            `$global:finalExtensionGets[`$machineName]++
            if (`$global:mockScenario -eq 'CreatedPending' -and `$global:finalExtensionGets[`$machineName] -eq 1) {
                return New-MockWebResponse -StatusCode 200 -Content (New-MockExtension -ProvisioningState 'Creating') -Headers @{ 'Retry-After' = '0' }
            }
            `$enabled = `$global:mockScenario -ne 'FinalMismatch'
            `$automaticUpgrade = `$global:mockScenario -ne 'AutoUpgradeMismatch'
            `$esuEnabled = `$global:mockScenario -eq 'EsuEnabled'
            return New-MockWebResponse -StatusCode 200 -Content (New-MockExtension -SqlManagementEnabled `$enabled -AutomaticUpgradeEnabled `$automaticUpgrade -EsuEnabled `$esuEnabled)
        }
        if (`$global:mockScenario -eq 'Existing') {
            return New-MockWebResponse -StatusCode 200 -Content (New-MockExtension)
        }
        if (`$global:mockScenario -eq 'Conflict') {
            return New-MockWebResponse -StatusCode 200 -Content (New-MockExtension -Publisher 'Fictitious.Publisher' -ExtensionType 'OtherExtension')
        }
        return New-MockWebResponse -StatusCode 404 -Content @{ error = @{ code = 'ResourceNotFound' } }
    }
    if ([string]`$Uri -match '/machines/([^/?]+)\?api-version=2026-07-15$') {
        `$machineName = `$Matches[1]
        if (`$global:mockScenario -eq 'TransientGet' -and `$global:requestCounts[`$requestKey] -eq 1) {
            return New-MockWebResponse -StatusCode 429 -Content @{ error = @{ code = 'TooManyRequests' } } -Headers @{ 'Retry-After' = '0' }
        }
        return New-MockWebResponse -StatusCode 200 -Content @{
            id = "/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/`$machineName"
            name = `$machineName
            location = 'westus2'
            properties = @{
                status = 'Connected'
                osName = 'Windows Server 2022'
                agentConfiguration = @{ mode = 'Full' }
                detectedProperties = @{ cloudProvider = 'VMware' }
            }
        }
    }
    return New-MockWebResponse -StatusCode 404 -Content @{ error = @{ code = 'UnexpectedMockUri'; message = [string]`$Uri } }
}

`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(30)
    Token = ConvertTo-SecureString 'fictitious-user-token' -AsPlainText -Force
}

& '$escapedScriptPath' $targetArguments $authenticationArguments $effectiveAdditionalArguments -Confirm:`$false
exit `$LASTEXITCODE
"@

    try {
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedCommand"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $completed = $process.WaitForExit(15000)
        if (-not $completed) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        $exitCode = if ($completed) { $process.ExitCode } else { 124 }
        if (-not $completed) { $output += "`nScenario process exceeded 15 seconds." }
        $process.Dispose()
        $calls = if (Test-Path -LiteralPath $recordPath) {
            @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        } else {
            @()
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Calls = $calls }
    } finally {
        Remove-Item -LiteralPath $recordPath, $csvPath -ErrorAction SilentlyContinue
    }
}

Describe 'InstallSQLServerArcExtension command contract' {
    It 'has mutually exclusive single-machine and CSV parameter sets' {
        $command = Get-Command $scriptPath
        $single = $command.ParameterSets | Where-Object Name -eq 'Single'
        $csv = $command.ParameterSets | Where-Object Name -eq 'Csv'

        $single | Should Not BeNullOrEmpty
        $csv | Should Not BeNullOrEmpty
        (@($single.Parameters.Name) -contains 'ARCServerName') | Should Be $true
        (@($single.Parameters.Name) -contains 'csvFilePath') | Should Be $false
        (@($csv.Parameters.Name) -contains 'csvFilePath') | Should Be $true
        (@($csv.Parameters.Name) -contains 'ARCServerName') | Should Be $false
        (@($command.Parameters.Keys) -contains 'WhatIf') | Should Be $true
        (@($command.Parameters.Keys) -contains 'Confirm') | Should Be $true
        (@($command.Parameters.Keys) -contains 'DryRun') | Should Be $true
    }

    It 'accepts each explicit license type' {
        foreach ($licenseType in @('Paid', 'PAYG', 'LicenseOnly')) {
            $result = Invoke-InstallScenario -AdditionalArguments "-LicenseType '$licenseType' -DryRun"
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'Previewed'
        }
    }
}

Describe 'InstallSQLServerArcExtension request and idempotency behavior' {
    It 'uses exact machine, provider, and extension URIs and the machine location in an object-built body' {
        $result = Invoke-InstallScenario

        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 1
        $put = $result.Calls | Where-Object Method -eq 'PUT' | Select-Object -First 1
        $put.Uri | Should Be "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-01/extensions/WindowsAgent.SqlServer?api-version=2026-07-15"
        $body = $put.Body | ConvertFrom-Json
        $body.location | Should Be 'westus2'
        $body.properties.publisher | Should Be 'Microsoft.AzureData'
        $body.properties.type | Should Be 'WindowsAgent.SqlServer'
        $body.properties.enableAutomaticUpgrade | Should Be $true
        $body.properties.settings.SqlManagement.IsEnabled | Should Be $true
        $body.properties.settings.LicenseType | Should Be 'Paid'
        @($body.properties.settings.ExcludedSqlInstances).Count | Should Be 0
        $put.Body | Should Not Match 'enableExtendedSecurityUpdates|esuLastUpdatedTimestamp'
        @($result.Calls | Where-Object Uri -eq "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-01?api-version=2026-07-15").Count | Should Be 1
        @($result.Calls | Where-Object Uri -eq "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.HybridCompute?api-version=2021-04-01").Count | Should Be 1
        @($result.Calls | Where-Object Uri -eq "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.AzureArcData?api-version=2021-04-01").Count | Should Be 1
    }

    It 'returns AlreadyInstalled and sends no PUT for the expected existing identity' {
        $result = Invoke-InstallScenario -Scenario Existing

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'AlreadyInstalled'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'fails a conflicting existing identity without mutation' {
        $result = Invoke-InstallScenario -Scenario Conflict

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'identity conflicts'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'performs final GET verification and fails a settings mismatch' {
        $result = Invoke-InstallScenario -Scenario FinalMismatch

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Final extension verification failed[\s\S]*SqlManagement.IsEnabled'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 1
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 2
    }

    It 'fails final verification when automatic upgrade is not enabled' {
        $result = Invoke-InstallScenario -Scenario AutoUpgradeMismatch

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Final extension verification failed[\s\S]*enableAutomaticUpgrade'
    }

    It 'fails final verification when ESU was accidentally enabled' {
        $result = Invoke-InstallScenario -Scenario EsuEnabled

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Final extension verification failed[\s\S]*enableExtendedSecurityUpdates'
    }
}

Describe 'InstallSQLServerArcExtension validation and preview safety' {
    It 'rejects a missing external-prerequisite acknowledgement before authentication or ARM' {
        $result = Invoke-InstallScenario -AdditionalArguments '-ConfirmExternalPrerequisites:$false'

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'ConfirmExternalPrerequisites must be TRUE'
        $result.Calls.Count | Should Be 0
    }

    It 'aggregates invalid CSV rows before authentication and sends no Azure request' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
$subscriptionId,server-rg,server-01,Paid,TRUE
not-a-guid,server-rg,server-02,Unknown,FALSE
"@
        $result = Invoke-InstallScenario -CsvContent $csv

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'Row 3:.*SubscriptionId.*LicenseType.*ConfirmExternalPrerequisites'
        $result.Calls.Count | Should Be 0
    }

    It 'performs read-only preflight but sends no PUT in DryRun' {
        $result = Invoke-InstallScenario -AdditionalArguments '-DryRun'

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Previewed'
        (@($result.Calls | Where-Object Method -eq 'GET').Count -gt 0) | Should Be $true
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'performs read-only preflight but sends no PUT in WhatIf' {
        $result = Invoke-InstallScenario -AdditionalArguments '-WhatIf'

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'What if:.*WindowsAgent.SqlServer'
        $result.Output | Should Match 'Previewed'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'stops all targets before mutation when provider preflight fails' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
$subscriptionId,server-rg,server-01,Paid,TRUE
$subscriptionId,server-rg,server-02,PAYG,TRUE
"@
        $result = Invoke-InstallScenario -Scenario ProviderFailure -CsvContent $csv

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'not[\s\S]*registered'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }

    It 'fails when regional capability metadata is missing or indeterminate' {
        foreach ($scenario in @('CapabilityMissing', 'CapabilityIndeterminate')) {
            $result = Invoke-InstallScenario -Scenario $scenario
            $normalizedOutput = $result.Output -replace '\s+', ' '

            $result.ExitCode | Should Be 1
            $normalizedOutput | Should Match 'capability metadata does not include|regional capability is indeterminate'
            @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
        }
    }

    It 'rejects an untrusted nextLink before mutation' {
        $result = Invoke-InstallScenario -Scenario UnsafeNextLink

        $result.ExitCode | Should Be 1
        $result.Output | Should Match 'untrusted nextLink URL'
        @($result.Calls | Where-Object Method -eq 'PUT').Count | Should Be 0
    }
}

Describe 'InstallSQLServerArcExtension authentication and subscription behavior' {
    It 'uses service principal authentication and does not expose the secret' {
        $result = Invoke-InstallScenario -ServicePrincipal -AdditionalArguments '-DryRun'

        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object IsAuthentication).Count | Should Be 1
        $result.Output | Should Not Match 'fictitious-client-secret|fictitious-access-token'
    }

    It 'uses a nonempty CSV subscription override for every row URI' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
$overrideSubscriptionId,override-rg,server-02,PAYG,TRUE
"@
        $result = Invoke-InstallScenario -CsvContent $csv -AdditionalArguments '-DryRun'

        $result.ExitCode | Should Be 0
        $armCalls = @($result.Calls | Where-Object { -not $_.IsAuthentication })
        @($armCalls | Where-Object { $_.Uri -match "/subscriptions/$overrideSubscriptionId/" }).Count | Should Be $armCalls.Count
        @($armCalls | Where-Object { $_.Uri -match "/subscriptions/$subscriptionId/" }).Count | Should Be 0
    }
}

Describe 'InstallSQLServerArcExtension asynchronous and bulk execution behavior' {
    It 'accepts 202, polls the service URL, and verifies the final resource' {
        $result = Invoke-InstallScenario -Scenario Async

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'Succeeded'
        @($result.Calls | Where-Object Uri -eq 'https://management.azure.com/operations/install-01').Count | Should Be 2
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 2
        (@($result.Calls | Where-Object Method -eq 'SLEEP').Count -gt 0) | Should Be $true
    }

    It 'polls a nonterminal extension after a successful 200 or 201 PUT response' {
        $result = Invoke-InstallScenario -Scenario CreatedPending

        $result.ExitCode | Should Be 0
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/extensions/WindowsAgent.SqlServer' }).Count | Should Be 3
        (@($result.Calls | Where-Object Method -eq 'SLEEP').Count -gt 0) | Should Be $true
    }

    It 'retries transient GET and idempotent PUT responses and honors Retry-After without waiting' {
        $getResult = Invoke-InstallScenario -Scenario TransientGet
        $putResult = Invoke-InstallScenario -Scenario TransientPut

        $getResult.ExitCode | Should Be 0
        @($getResult.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/machines/server-01\?api-version=' }).Count | Should Be 2
        @($getResult.Calls | Where-Object Method -eq 'SLEEP').Count | Should Be 1
        $putResult.ExitCode | Should Be 0
        @($putResult.Calls | Where-Object Method -eq 'PUT').Count | Should Be 2
        @($putResult.Calls | Where-Object Method -eq 'SLEEP').Count | Should Be 1
    }

    It 'continues independent rows after a runtime PUT failure and returns exit code 1' {
        $csv = @"
SubscriptionId,ServerResourceGroupName,ARCServerName,LicenseType,ConfirmExternalPrerequisites
$subscriptionId,server-rg,server-01,Paid,TRUE
$subscriptionId,server-rg,server-02,Paid,TRUE
"@
        $result = Invoke-InstallScenario -Scenario RuntimeFailure -CsvContent $csv
        $normalizedOutput = $result.Output -replace '\s+', ' '

        $result.ExitCode | Should Be 1
        @($result.Calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/machines/server-01/' }).Count | Should Be 4
        @($result.Calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/machines/server-02/' }).Count | Should Be 1
        @($result.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match '/machines/server-02/extensions/' }).Count | Should Be 2
        ($normalizedOutput -match 'Planned:\s*2; Succeeded:\s*1; Already installed:\s*0; Previewed:\s*0; Declined:\s*0; Failed:\s*1; Not started:\s*0') | Should Be $true
    }
}