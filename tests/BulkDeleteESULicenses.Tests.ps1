$scriptPath = Join-Path $PSScriptRoot '..\Scripts\windows\BulkDeleteESULicenses.ps1'
$subscriptionId = '00000000-0000-0000-0000-000000000001'
$licenseIdPrefix = "/subscriptions/$subscriptionId/resourceGroups/rg-esu/providers/Microsoft.HybridCompute/licenses"
$profileIdPrefix = "/subscriptions/$subscriptionId/resourceGroups/rg-arc/providers/Microsoft.HybridCompute/machines"

function Import-BulkDeleteFunctions {
    param(
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors.Count -gt 0) {
        throw "Unable to parse '$Path': $($parseErrors.Message -join '; ')"
    }

    $functionAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($functionAst in $functionAsts) {
        $bodyText = $functionAst.Body.Extent.Text
        $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
        Set-Item -Path "Function:\global:$($functionAst.Name)" -Value ([scriptblock]::Create($bodyText))
    }
}

function Get-TestServer {
    param(
        [string]$Name = 'srv-01'
    )

    [pscustomobject]@{
        LicenseId = "$licenseIdPrefix/esu-01"
        ProfileId = "$profileIdPrefix/$Name/licenseProfiles/default"
        ServerSubscriptionId = $subscriptionId
        ServerResourceGroupName = 'rg-arc'
        ServerName = $Name
        ServerLocation = 'eastus'
    }
}

function Get-TestProfile {
    param(
        [string]$AssignedLicense = "$licenseIdPrefix/esu-01",
        [string]$Location = 'eastus',
        [object]$SoftwareAssurance,
        [object]$ProductProfile,
        [object]$Tags
    )

    $properties = [ordered]@{
        esuProfile = [pscustomobject]@{ assignedLicense = $AssignedLicense }
    }
    if ($null -ne $SoftwareAssurance) { $properties.softwareAssurance = $SoftwareAssurance }
    if ($null -ne $ProductProfile) { $properties.productProfile = $ProductProfile }

    $licenseProfile = [ordered]@{
        properties = [pscustomobject]$properties
    }
    if (-not [string]::IsNullOrWhiteSpace($Location)) { $licenseProfile.location = $Location }
    if ($null -ne $Tags) { $licenseProfile.tags = $Tags }

    return [pscustomobject]$licenseProfile
}

Describe 'BulkDeleteESULicenses helpers' {
    BeforeEach {
        Import-BulkDeleteFunctions -Path $scriptPath
        $script:CONFIG = @{
            HybridComputeApiVersion = '2026-09-01'
            ResourceGraphApiVersion = '2024-04-01'
            ManagementEndpoint = 'https://management.azure.com'
            AzureResourceUrl = 'https://management.azure.com/'
            LoginEndpoint = 'https://login.microsoftonline.com'
            RequiredCSVColumns = @('LicenseName', 'LicenseResourceGroupName')
            ResourceGraphPageSize = 1000
            UnlinkVerificationAttempts = 3
            UnlinkVerificationDelaySeconds = 0
        }
        $global:BulkDeleteProfileUnlinked = $false
        $global:BulkDeleteRequestBodies = @()

        Mock Write-Host {}
        Mock Start-Sleep {}
    }

    It 'builds a Resource Graph query limited to license profiles assigned in the license subscription' {
        $query = Get-ResourceGraphAssignmentQuery -licenseSubscriptionId '0000000A-0000-0000-0000-000000000001'

        $query | Should Match "type =~ 'microsoft.hybridcompute/machines/licenseprofiles'"
        $query | Should Match 'properties\.esuProfile\.assignedLicense'
        $query | Should Match "startswith '/subscriptions/0000000a-0000-0000-0000-000000000001/'"
    }

    It 'parses Arc license profile resource IDs and rejects malformed IDs' {
        $parsed = ConvertFrom-ArmResourceId -resourceId "$profileIdPrefix/srv-01/licenseProfiles/default"

        $parsed.SubscriptionId | Should Be $subscriptionId
        $parsed.ResourceGroupName | Should Be 'rg-arc'
        $parsed.ResourceName | Should Be 'srv-01'
        ConvertFrom-ArmResourceId -resourceId '/subscriptions/x/providers/y' | Should BeNullOrEmpty
    }

    It 'gives the CSV LicenseSubscriptionId precedence over the parameter' {
        $rowWithSubscription = [pscustomobject]@{ LicenseName = 'esu-01'; LicenseResourceGroupName = 'rg-esu'; LicenseSubscriptionId = '00000000-0000-0000-0000-000000000009' }
        $rowWithoutSubscription = [pscustomobject]@{ LicenseName = 'esu-01'; LicenseResourceGroupName = 'rg-esu'; LicenseSubscriptionId = '' }

        Resolve-LicenseSubscriptionId -row $rowWithSubscription -licenseSubscriptionId $subscriptionId | Should Be '00000000-0000-0000-0000-000000000009'
        Resolve-LicenseSubscriptionId -row $rowWithoutSubscription -licenseSubscriptionId $subscriptionId | Should Be $subscriptionId
        Resolve-LicenseSubscriptionId -row $rowWithoutSubscription -licenseSubscriptionId '' | Should BeNullOrEmpty
    }

    It 'validates CSV rows' {
        $validRow = [pscustomobject]@{ LicenseName = 'esu-01'; LicenseResourceGroupName = 'rg-esu' }
        $invalidNameRow = [pscustomobject]@{ LicenseName = 'esu/01'; LicenseResourceGroupName = 'rg-esu' }
        $invalidSubscriptionRow = [pscustomobject]@{ LicenseName = 'esu-01'; LicenseResourceGroupName = 'rg-esu'; LicenseSubscriptionId = 'not-a-guid' }

        Test-LicenseCsvRow -row $validRow -rowNumber 1 -licenseSubscriptionId $subscriptionId | Should Be $true
        Test-LicenseCsvRow -row $validRow -rowNumber 1 -licenseSubscriptionId '' | Should Be $false
        Test-LicenseCsvRow -row $invalidNameRow -rowNumber 2 -licenseSubscriptionId $subscriptionId | Should Be $false
        Test-LicenseCsvRow -row $invalidSubscriptionRow -rowNumber 3 -licenseSubscriptionId $subscriptionId | Should Be $false
    }

    It 'includes Windows Server 2012 and 2012 R2 by default and excludes Windows Server 2016' {
        $tokens = $null
        $parseErrors = $null
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        $targetParameter = $scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'target' }
        $defaultTargets = @($targetParameter.DefaultValue.SafeGetValue())
        $defaultTargets.Count | Should Be 2
        ($defaultTargets -join '|') | Should Be 'Windows Server 2012|Windows Server 2012 R2'

        $selected = @('Windows Server 2012', 'Windows Server 2012 R2')
        Test-LicenseTargetIncluded -licenseTarget 'Windows Server 2012' -target $selected | Should Be $true
        Test-LicenseTargetIncluded -licenseTarget 'Windows Server 2012 R2' -target $selected | Should Be $true
        Test-LicenseTargetIncluded -licenseTarget 'Windows Server 2016' -target $selected | Should Be $false
        Test-LicenseTargetIncluded -licenseTarget '' -target $selected | Should Be $false
    }

    It 'flags Software Assurance and product profile settings as blocking' {
        $softwareAssuranceProfile = Get-TestProfile -SoftwareAssurance ([pscustomobject]@{ softwareAssuranceCustomer = $false })
        $productProfile = Get-TestProfile -ProductProfile ([pscustomobject]@{ productType = 'WindowsServer'; subscriptionStatus = 'Enabled'; productFeatures = @() })

        (@(Get-LicenseProfileBlockingSetting -licenseProfile $softwareAssuranceProfile) -join '|') | Should Be 'softwareAssurance.softwareAssuranceCustomer=False'
        (@(Get-LicenseProfileBlockingSetting -licenseProfile $productProfile) -join '|') | Should Be 'productProfile.productType|productProfile.subscriptionStatus'
    }

    It 'redacts subscription and other IDs from Azure error messages' {
        $errorRecord = $null
        try {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', $response)
        } catch {
            $errorRecord = $_
            $errorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new("{""error"":{""code"":""AuthorizationFailed"",""message"":""The client '00000000-0000-0000-0000-000000000003' does not have authorization over scope '/subscriptions/$subscriptionId/resourceGroups/rg-esu'.""}}")
        }

        $message = Get-RestErrorMessage -errorRecord $errorRecord

        $message | Should Match '^HTTP 403 - '
        $message | Should Match 'AuthorizationFailed'
        $message | Should Match '/subscriptions/<redacted-id>/resourceGroups/rg-esu'
        $message | Should Not Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    }

    It 'does not flag an ESU-only or empty product profile' {
        $esuOnlyProfile = Get-TestProfile
        $emptyProductProfile = Get-TestProfile -ProductProfile ([pscustomobject]@{})

        @(Get-LicenseProfileBlockingSetting -licenseProfile $esuOnlyProfile).Count | Should Be 0
        @(Get-LicenseProfileBlockingSetting -licenseProfile $emptyProductProfile).Count | Should Be 0
    }

    It 'builds the documented unlink body and preserves profile tags' {
        $withoutTags = Get-UnlinkRequestBody -location 'eastus' -tags $null | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $withTags = Get-UnlinkRequestBody -location 'westus' -tags ([pscustomobject]@{ owner = 'ops' }) | ConvertTo-Json -Depth 10 | ConvertFrom-Json

        $withoutTags.location | Should Be 'eastus'
        @($withoutTags.properties.esuProfile.PSObject.Properties).Count | Should Be 0
        $withoutTags.PSObject.Properties['tags'] | Should BeNullOrEmpty
        $withoutTags.properties.PSObject.Properties['softwareAssurance'] | Should BeNullOrEmpty
        $withoutTags.properties.PSObject.Properties['productProfile'] | Should BeNullOrEmpty
        $withTags.tags.owner | Should Be 'ops'
    }

    It 'follows Resource Graph skip tokens and scopes every page to the license subscription' {
        Mock Invoke-RestMethod {
            $global:BulkDeleteRequestBodies += $Body
            if ($global:BulkDeleteRequestBodies.Count -eq 1) {
                return [pscustomobject]@{
                    '$skipToken' = 'page-2'
                    resultTruncated = 'false'
                    data = @([pscustomobject]@{ id = "$profileIdPrefix/srv-01/licenseProfiles/default"; location = 'eastus'; assignedLicense = "$licenseIdPrefix/esu-01".ToLowerInvariant() })
                }
            }
            return [pscustomobject]@{
                resultTruncated = 'false'
                data = @([pscustomobject]@{ id = "$profileIdPrefix/srv-02/licenseProfiles/default"; location = 'westus'; assignedLicense = "$licenseIdPrefix/esu-02".ToLowerInvariant() })
            }
        } -ParameterFilter { $Method -eq 'POST' }

        $assignments = @(Get-ResourceGraphLicenseAssignment -licenseSubscriptionId $subscriptionId -bearerToken 'placeholder-token')

        $assignments.Count | Should Be 2
        $assignments[0].ServerName | Should Be 'srv-01'
        $assignments[1].ServerName | Should Be 'srv-02'
        $assignments[1].ServerLocation | Should Be 'westus'
        $firstRequest = $global:BulkDeleteRequestBodies[0] | ConvertFrom-Json
        $secondRequest = $global:BulkDeleteRequestBodies[1] | ConvertFrom-Json
        ($firstRequest.subscriptions -join '|') | Should Be $subscriptionId
        $secondRequest.options.'$skipToken' | Should Be 'page-2'
    }

    It 'fails Resource Graph discovery when results are truncated without a continuation token' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{ resultTruncated = 'true'; data = @() }
        } -ParameterFilter { $Method -eq 'POST' }

        { Get-ResourceGraphLicenseAssignment -licenseSubscriptionId $subscriptionId -bearerToken 'placeholder-token' } | Should Throw 'truncated'
    }

    It 'follows nextLink when listing licenses' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*page=2*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'esu-02' }) }
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ name = 'esu-01' }); nextLink = 'https://management.azure.com/next?page=2' }
        } -ParameterFilter { $Method -eq 'GET' }

        $licenses = @(Get-ESULicenseList -subscriptionId $subscriptionId -resourceGroupName 'rg-esu' -bearerToken 'placeholder-token')

        $licenses.Count | Should Be 2
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 1 -ParameterFilter { $Uri -like '*/resourceGroups/rg-esu/providers/Microsoft.HybridCompute/licenses`?api-version=2026-09-01' }
    }

    It 'previews an unlink without sending a PUT' {
        Mock Invoke-RestMethod { Get-TestProfile } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod { throw 'PUT must not be sent' } -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -bearerToken 'placeholder-token' -preview

        $result.Outcome | Should Be 'WouldUnlink'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'skips a server whose profile has Software Assurance settings without sending a PUT' {
        Mock Invoke-RestMethod { Get-TestProfile -SoftwareAssurance ([pscustomobject]@{ softwareAssuranceCustomer = $true }) } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod { throw 'PUT must not be sent' } -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -bearerToken 'placeholder-token'

        $result.Outcome | Should Be 'Blocked'
        $result.Message | Should Match 'softwareAssurance'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'leaves a server unchanged when it is no longer assigned to the license' {
        Mock Invoke-RestMethod { Get-TestProfile -AssignedLicense "$licenseIdPrefix/another-license" } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod { throw 'PUT must not be sent' } -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -bearerToken 'placeholder-token'

        $result.Outcome | Should Be 'AlreadyUnlinked'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'matches the assigned license ID case-insensitively' {
        Test-LicenseIdMatch -assignedLicense "$licenseIdPrefix/esu-01".ToLowerInvariant() -licenseId "$licenseIdPrefix/esu-01" | Should Be $true
        Test-LicenseIdMatch -assignedLicense '' -licenseId "$licenseIdPrefix/esu-01" | Should Be $false
    }

    It 'unlinks with the profile location and verifies the result' {
        Mock Invoke-RestMethod {
            if ($global:BulkDeleteProfileUnlinked) { return Get-TestProfile -AssignedLicense '' -Location 'westeurope' }
            return Get-TestProfile -Location 'westeurope' -Tags ([pscustomobject]@{ owner = 'ops' })
        } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod {
            $global:BulkDeleteRequestBodies += $Body
            $global:BulkDeleteProfileUnlinked = $true
        } -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -fallbackLocation 'eastus' -bearerToken 'placeholder-token'

        $result.Outcome | Should Be 'Unlinked'
        $request = $global:BulkDeleteRequestBodies[0] | ConvertFrom-Json
        $request.location | Should Be 'westeurope'
        $request.tags.owner | Should Be 'ops'
        @($request.properties.esuProfile.PSObject.Properties).Count | Should Be 0
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 1 -ParameterFilter { $Method -eq 'PUT' -and $Uri -like '*/machines/srv-01/licenseProfiles/default?api-version=2026-09-01' }
    }

    It 'uses -location only when the profile has no location' {
        Mock Invoke-RestMethod {
            if ($global:BulkDeleteProfileUnlinked) { return Get-TestProfile -AssignedLicense '' -Location '' }
            return Get-TestProfile -Location ''
        } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod {
            $global:BulkDeleteRequestBodies += $Body
            $global:BulkDeleteProfileUnlinked = $true
        } -ParameterFilter { $Method -eq 'PUT' }

        $withFallback = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -fallbackLocation 'eastus2' -bearerToken 'placeholder-token'

        $withFallback.Outcome | Should Be 'Unlinked'
        ($global:BulkDeleteRequestBodies[0] | ConvertFrom-Json).location | Should Be 'eastus2'
    }

    It 'fails without a request when neither the profile nor -location provides a location' {
        Mock Invoke-RestMethod { Get-TestProfile -Location '' } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod { throw 'PUT must not be sent' } -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -bearerToken 'placeholder-token'

        $result.Outcome | Should Be 'Failed'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'PUT' }
    }

    It 'fails when the license is still assigned after every verification attempt' {
        Mock Invoke-RestMethod { Get-TestProfile } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod {} -ParameterFilter { $Method -eq 'PUT' }

        $result = Invoke-ESULicenseUnlink -server (Get-TestServer) -licenseId "$licenseIdPrefix/esu-01" -bearerToken 'placeholder-token'

        $result.Outcome | Should Be 'Failed'
        $result.Message | Should Match 'still assigned after 3 verification'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 4 -ParameterFilter { $Method -eq 'GET' }
    }

    It 'keeps the license when any server cannot be unlinked' {
        Mock Invoke-ESULicenseUnlink {
            [pscustomobject]@{ ServerName = $server.ServerName; ServerResourceGroupName = 'rg-arc'; Outcome = $(if ($server.ServerName -eq 'srv-02') { 'Blocked' } else { 'Unlinked' }); Message = 'mocked' }
        }
        Mock Invoke-RestMethod { throw 'DELETE must not be sent' } -ParameterFilter { $Method -eq 'DELETE' }
        $planItem = ConvertTo-LicensePlanItem -licenseName 'esu-01' -licenseResourceGroupName 'rg-esu' -licenseSubscriptionId $subscriptionId
        $planItem.Servers.Add((Get-TestServer -Name 'srv-01'))
        $planItem.Servers.Add((Get-TestServer -Name 'srv-02'))

        Invoke-LicenseDecommission -planItem $planItem -bearerToken 'placeholder-token'

        $planItem.Status | Should Be 'Failed'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'deletes the license after every server is unlinked' {
        Mock Invoke-ESULicenseUnlink {
            [pscustomobject]@{ ServerName = $server.ServerName; ServerResourceGroupName = 'rg-arc'; Outcome = 'Unlinked'; Message = 'mocked' }
        }
        Mock Invoke-RestMethod {} -ParameterFilter { $Method -eq 'DELETE' }
        $planItem = ConvertTo-LicensePlanItem -licenseName 'esu-01' -licenseResourceGroupName 'rg-esu' -licenseSubscriptionId $subscriptionId
        $planItem.Servers.Add((Get-TestServer))

        Invoke-LicenseDecommission -planItem $planItem -bearerToken 'placeholder-token'

        $planItem.Status | Should Be 'Deleted'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 1 -ParameterFilter { $Method -eq 'DELETE' -and $Uri -like '*/licenses/esu-01?api-version=2026-09-01' }
    }

    It 'does not delete the license during preview' {
        Mock Invoke-ESULicenseUnlink {
            [pscustomobject]@{ ServerName = $server.ServerName; ServerResourceGroupName = 'rg-arc'; Outcome = 'WouldUnlink'; Message = 'mocked' }
        }
        Mock Invoke-RestMethod { throw 'DELETE must not be sent' } -ParameterFilter { $Method -eq 'DELETE' }
        $planItem = ConvertTo-LicensePlanItem -licenseName 'esu-01' -licenseResourceGroupName 'rg-esu' -licenseSubscriptionId $subscriptionId
        $planItem.Servers.Add((Get-TestServer))

        Invoke-LicenseDecommission -planItem $planItem -bearerToken 'placeholder-token' -preview

        $planItem.Status | Should Be 'WouldDelete'
        Assert-MockCalled Invoke-RestMethod -Scope It -Exactly 0 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'reports a failed delete request without throwing' {
        Mock Invoke-RestMethod { throw 'mocked delete failure' } -ParameterFilter { $Method -eq 'DELETE' }
        $planItem = ConvertTo-LicensePlanItem -licenseName 'esu-01' -licenseResourceGroupName 'rg-esu' -licenseSubscriptionId $subscriptionId

        Invoke-LicenseDecommission -planItem $planItem -bearerToken 'placeholder-token'

        $planItem.Status | Should Be 'Failed'
        $planItem.Message | Should Match 'delete request failed'
    }

    It 'writes one inventory row per assigned server and one row for a license without assignments' {
        $license = [pscustomobject]@{
            id = "$licenseIdPrefix/esu-01"
            name = 'esu-01'
            location = 'eastus'
            tags = [pscustomobject]@{ owner = 'ops' }
            properties = [pscustomobject]@{
                licenseType = 'ESU'
                licenseDetails = [pscustomobject]@{ state = 'Deactivated'; target = 'Windows Server 2012 R2'; edition = 'Standard'; type = 'vCore'; processors = 16; assignedLicenses = 2; immutableId = '11111111-1111-1111-1111-111111111111' }
            }
        }
        $assigned = ConvertTo-LicensePlanItem -license $license
        $assigned.Servers.Add((Get-TestServer -Name 'srv-01'))
        $assigned.Servers.Add((Get-TestServer -Name 'srv-02'))
        $unassigned = ConvertTo-LicensePlanItem -licenseName 'esu-02' -licenseResourceGroupName 'rg-esu' -licenseSubscriptionId $subscriptionId

        $rows = @(ConvertTo-InventoryRow -planItems @($assigned, $unassigned) -exportedAtUtc '2026-10-26T00:00:00Z')

        $rows.Count | Should Be 3
        $rows[0].LicenseResourceGroupName | Should Be 'rg-esu'
        $rows[0].Target | Should Be 'Windows Server 2012 R2'
        $rows[0].Processors | Should Be 16
        $rows[0].TagsJson | Should Be '{"owner":"ops"}'
        $rows[1].ServerName | Should Be 'srv-02'
        $rows[2].ServerName | Should BeNullOrEmpty
        $rows[2].PlannedAction | Should Be 'Delete license (no assignment found)'
    }
}

$scenarioTemplate = @'
$global:Unlinked = $false
$scenario = '__SCENARIO__'
$sub = '00000000-0000-0000-0000-000000000001'

function global:Get-MockLicense {
    param($name, $target)
    [pscustomobject]@{
        id = "/subscriptions/$sub/resourceGroups/rg-esu/providers/Microsoft.HybridCompute/licenses/$name"
        name = $name
        location = 'eastus'
        properties = [pscustomobject]@{
            licenseType = 'ESU'
            licenseDetails = [pscustomobject]@{ state = 'Deactivated'; target = $target; edition = 'Standard'; type = 'vCore'; processors = 8; assignedLicenses = 0; immutableId = '11111111-1111-1111-1111-111111111111' }
        }
    }
}

$global:Licenses = @(
    (Get-MockLicense 'esu-ws2012r2-01' 'Windows Server 2012 R2'),
    (Get-MockLicense 'esu-ws2016-01' 'Windows Server 2016'),
    (Get-MockLicense 'esu-ws2012-02' 'Windows Server 2012')
)

function global:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $Body)
    $verb = [string]$Method

    if ($verb -eq 'POST' -and $Uri -like '*/providers/Microsoft.ResourceGraph/resources*') {
        return [pscustomobject]@{
            resultTruncated = 'false'
            data = @([pscustomobject]@{
                id = "/subscriptions/$sub/resourceGroups/rg-arc/providers/Microsoft.HybridCompute/machines/srv-01/licenseProfiles/default"
                location = 'eastus'
                assignedLicense = "/subscriptions/$sub/resourcegroups/rg-esu/providers/microsoft.hybridcompute/licenses/esu-ws2012r2-01"
            })
        }
    }
    if ($verb -eq 'GET' -and $Uri -match '/providers/Microsoft\.HybridCompute/licenses\?') {
        return [pscustomobject]@{ value = $global:Licenses }
    }
    if ($verb -eq 'GET' -and $Uri -match '/licenses/[^/?]+\?') {
        $name = ($Uri -split '/licenses/')[1].Split('?')[0]
        $match = $global:Licenses | Where-Object { $_.name -eq $name }
        if ($match) { return $match }
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $response)
    }
    if ($verb -eq 'GET' -and $Uri -like '*/licenseProfiles/default*') {
        $assigned = if ($global:Unlinked) { $null } else { "/subscriptions/$sub/resourceGroups/rg-esu/providers/Microsoft.HybridCompute/licenses/esu-ws2012r2-01" }
        $properties = [ordered]@{ esuProfile = [pscustomobject]@{ assignedLicense = $assigned } }
        if ($scenario -eq 'blocked') { $properties.softwareAssurance = [pscustomobject]@{ softwareAssuranceCustomer = $true } }
        return [pscustomobject]@{ location = 'eastus'; properties = [pscustomobject]$properties }
    }
    if ($verb -in @('PUT', 'PATCH', 'DELETE')) {
        if ($scenario -in @('whatif', 'dryrun')) {
            Write-Host 'MUTATION-ATTEMPTED'
            [Environment]::Exit(9)
        }
        if ($verb -eq 'PUT') {
            $global:Unlinked = $true
            Write-Host "PUT-CALLED $Uri"
            return [pscustomobject]@{}
        }
        if ($verb -eq 'DELETE') {
            Write-Host "DELETE-CALLED $Uri"
            return $null
        }
    }

    Write-Host "UNEXPECTED-REQUEST $verb $Uri"
    [Environment]::Exit(8)
}
function global:Start-Sleep {}

$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '__SCRIPT__' __ARGUMENTS__ -userToken $token
exit $LASTEXITCODE
'@

function Invoke-BulkDeleteScenario {
    param(
        [ValidateSet('whatif', 'dryrun', 'live', 'blocked')]
        [string]$Scenario,
        [string]$Arguments
    )

    $command = $scenarioTemplate.Replace('__SCENARIO__', $Scenario).Replace('__SCRIPT__', $scriptPath.Replace("'", "''")).Replace('__ARGUMENTS__', $Arguments)
    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

Describe 'BulkDeleteESULicenses end-to-end behavior with mocked REST calls' {
    $inventoryPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-bulk-delete-inventory-$PID.csv"
    $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-bulk-delete-$PID.csv"
    $escapedInventoryPath = $inventoryPath.Replace("'", "''")
    $escapedCsvPath = $csvPath.Replace("'", "''")

    @'
LicenseName,LicenseResourceGroupName,LicenseSubscriptionId
esu-ws2012r2-01,rg-esu,
esu-missing,rg-esu,
'@ | Set-Content -Path $csvPath

    AfterEach {
        Remove-Item -LiteralPath $inventoryPath -ErrorAction SilentlyContinue
    }

    It 'exposes WhatIf and Confirm with high confirmation impact' {
        $command = Get-Command $scriptPath
        $cmdletBinding = $command.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }

        $command.Parameters.ContainsKey('WhatIf') | Should Be $true
        $command.Parameters.ContainsKey('Confirm') | Should Be $true
        $cmdletBinding.ConfirmImpact | Should Be 'High'
    }

    It 'previews discovery mode with WhatIf, excludes Windows Server 2016, and writes the inventory without mutations' {
        $result = Invoke-BulkDeleteScenario -Scenario whatif -Arguments "-licenseSubscriptionId '$subscriptionId' -licenseResourceGroupName 'rg-esu' -inventoryFilePath '$escapedInventoryPath' -WhatIf"

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'What if:.*esu-ws2012r2-01'
        $result.Output | Should Not Match 'MUTATION-ATTEMPTED'
        $result.Output | Should Match "Target 'Windows Server 2016' is not selected"
        $result.Output | Should Not Match '00000000-0000-0000-0000-000000000001'

        $inventory = @(Import-Csv -Path $inventoryPath)
        $inventory.Count | Should Be 2
        ($inventory | Where-Object { $_.LicenseName -eq 'esu-ws2012r2-01' }).ServerName | Should Be 'srv-01'
        ($inventory | Where-Object { $_.LicenseName -eq 'esu-ws2016-01' }) | Should BeNullOrEmpty
    }

    It 'returns exit code 2 in CSV dry-run mode when a listed license is missing, without mutations' {
        $result = Invoke-BulkDeleteScenario -Scenario dryrun -Arguments "-licenseSubscriptionId '$subscriptionId' -csvFilePath '$escapedCsvPath' -inventoryFilePath '$escapedInventoryPath' -DryRun"

        $result.ExitCode | Should Be 2
        $result.Output | Should Not Match 'MUTATION-ATTEMPTED'
        $result.Output | Should Match "esu-missing.*The license was not found"
        $result.Output | Should Match 'would be deleted'
    }

    It 'unlinks, verifies, and deletes each selected license in a confirmed live run' {
        $result = Invoke-BulkDeleteScenario -Scenario live -Arguments "-licenseSubscriptionId '$subscriptionId' -inventoryFilePath '$escapedInventoryPath' -Confirm:`$false"

        $result.ExitCode | Should Be 0
        ([regex]::Matches($result.Output, 'PUT-CALLED')).Count | Should Be 1
        $result.Output | Should Match 'DELETE-CALLED .*/licenses/esu-ws2012r2-01\?'
        $result.Output | Should Match 'DELETE-CALLED .*/licenses/esu-ws2012-02\?'
        $result.Output | Should Not Match 'DELETE-CALLED .*/licenses/esu-ws2016-01\?'
    }

    It 'keeps a license whose server has other license profile settings and returns exit code 2' {
        $result = Invoke-BulkDeleteScenario -Scenario blocked -Arguments "-licenseSubscriptionId '$subscriptionId' -inventoryFilePath '$escapedInventoryPath' -Confirm:`$false"

        $result.ExitCode | Should Be 2
        $result.Output | Should Not Match 'PUT-CALLED'
        $result.Output | Should Not Match 'DELETE-CALLED .*/licenses/esu-ws2012r2-01\?'
        $result.Output | Should Match 'DELETE-CALLED .*/licenses/esu-ws2012-02\?'
    }

    Remove-Item -LiteralPath $csvPath -ErrorAction SilentlyContinue
}
