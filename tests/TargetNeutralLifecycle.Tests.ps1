$subscriptionId = '00000000-0000-0000-0000-000000000001'
$licenseName = 'windows-server-2016-standard-8-vcore'
$assignScriptPath = Join-Path $PSScriptRoot '..\Scripts\AssignESULicense.ps1'
$deleteScriptPath = Join-Path $PSScriptRoot '..\Scripts\DeleteESULicense.ps1'

function Invoke-TargetNeutralLifecycleScript {
    param(
        [string]$Path,
        [string]$Arguments,
        [string]$TracePath,
        [switch]$Preview
    )

    $escapedPath = $Path.Replace("'", "''")
    $escapedTracePath = $TracePath.Replace("'", "''")
    $whatIfArgument = if ($Preview) { '-WhatIf' } else { '' }
    $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method, `$Headers, `$Body)
    [pscustomobject]@{
        Uri = `$Uri
        Method = `$Method
        Body = `$Body
    } | ConvertTo-Json -Depth 8 | Set-Content -Path '$escapedTracePath'
    return [pscustomobject]@{
        ContractMarker = 'unchanged-output'
        ProvisioningState = 'Succeeded'
    }
}
`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedPath' $Arguments -userToken `$token $whatIfArgument
exit `$LASTEXITCODE
"@

    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
    $trace = if (Test-Path -Path $TracePath) {
        Get-Content -Path $TracePath -Raw | ConvertFrom-Json
    } else {
        $null
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Trace = $trace
    }
}

Describe 'Standalone target-neutral lifecycle contracts' {
    It 'keeps assign target-neutral for a Windows Server 2016-named license' {
        $tracePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-assign-2016-$PID.json"

        try {
            $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName '$licenseName' -serverResourceGroupName 'server-rg' -ARCServerName 'server-2016' -location 'eastus'"
            $result = Invoke-TargetNeutralLifecycleScript -Path $assignScriptPath -Arguments $arguments -TracePath $tracePath
            $payload = $result.Trace.Body | ConvertFrom-Json

            $result.ExitCode | Should Be 0
            $result.Trace.Method | Should Be 'PUT'
            $result.Trace.Uri | Should Be "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/server-rg/providers/Microsoft.HybridCompute/machines/server-2016/licenseProfiles/default?api-version=2023-06-20-preview"
            @($payload.PSObject.Properties).Count | Should Be 2
            @($payload.PSObject.Properties.Name) -contains 'location' | Should Be $true
            @($payload.PSObject.Properties.Name) -contains 'properties' | Should Be $true
            @($payload.properties.PSObject.Properties.Name) -contains 'esuProfile' | Should Be $true
            @($payload.properties.esuProfile.PSObject.Properties.Name) -contains 'assignedLicense' | Should Be $true
            $payload.properties.esuProfile.assignedLicense | Should Be "/subscriptions/$subscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/$licenseName"
            $result.Trace.Body | Should Not Match 'target'
        } finally {
            Remove-Item -Path $tracePath -ErrorAction SilentlyContinue
        }
    }

    It 'keeps unlink target-neutral for a Windows Server 2016-named license' {
        $tracePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-unlink-2016-$PID.json"

        try {
            $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName '$licenseName' -serverResourceGroupName 'server-rg' -ARCServerName 'server-2016' -location 'eastus' -unassign"
            $result = Invoke-TargetNeutralLifecycleScript -Path $assignScriptPath -Arguments $arguments -TracePath $tracePath
            $payload = $result.Trace.Body | ConvertFrom-Json

            $result.ExitCode | Should Be 0
            $result.Trace.Method | Should Be 'PUT'
            @($payload.PSObject.Properties).Count | Should Be 2
            @($payload.PSObject.Properties.Name) -contains 'location' | Should Be $true
            @($payload.PSObject.Properties.Name) -contains 'properties' | Should Be $true
            @($payload.properties.PSObject.Properties.Name) -contains 'esuProfile' | Should Be $true
            @($payload.properties.esuProfile.PSObject.Properties).Count | Should Be 0
            $result.Trace.Body | Should Not Match 'assignedLicense|target'
        } finally {
            Remove-Item -Path $tracePath -ErrorAction SilentlyContinue
        }
    }

    It 'deletes a Windows Server 2016-named license through the target-neutral license URI' {
        $tracePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-delete-2016-$PID.json"

        try {
            $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName '$licenseName'"
            $result = Invoke-TargetNeutralLifecycleScript -Path $deleteScriptPath -Arguments $arguments -TracePath $tracePath

            $result.ExitCode | Should Be 0
            $result.Trace.Method | Should Be 'DELETE'
            $result.Trace.Uri | Should Be "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/license-rg/providers/Microsoft.HybridCompute/licenses/${licenseName}?api-version=2023-06-20-preview"
            $result.Trace.Body | Should BeNullOrEmpty
        } finally {
            Remove-Item -Path $tracePath -ErrorAction SilentlyContinue
        }
    }

    It 'requires no target parameter and preserves ShouldProcess on assign and delete' {
        foreach ($path in @($assignScriptPath, $deleteScriptPath)) {
            $command = Get-Command -Name $path

            $command.Parameters.ContainsKey('target') | Should Be $false
            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }
    }

    It 'preserves delete billing guidance and previews deletion without an HTTP request' {
        $tracePath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-delete-whatif-$PID.json"

        try {
            $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName '$licenseName'"
            $result = Invoke-TargetNeutralLifecycleScript -Path $deleteScriptPath -Arguments $arguments -TracePath $tracePath -Preview
            $scriptContent = Get-Content -Path $deleteScriptPath -Raw

            $result.ExitCode | Should Be 0
            $result.Trace | Should BeNullOrEmpty
            $result.Output | Should Match 'What if:.*Delete ESU license'
            $scriptContent | Should Match 'Deleting a license will stop the monthly billing for the ESU associated with that license\.'
        } finally {
            Remove-Item -Path $tracePath -ErrorAction SilentlyContinue
        }
    }
}