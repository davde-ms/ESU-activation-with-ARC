$subscriptionId = '00000000-0000-0000-0000-000000000001'
$targetCsvPath = Join-Path ([System.IO.Path]::GetTempPath()) "esu-should-process-target-$PID.csv"

@'
Name,Cores,IsVirtual,AgentVersion,ServerResourceGroupName,AssignESULicense,ESUException,Target,InvoiceId,ProgramYear
server-2016,8,Virtual,1.62,server-rg,True,,Windows Server 2016,,
'@ | Set-Content -Path $targetCsvPath

$scriptCases = @(
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\windows\AssignESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01' -location 'eastus'"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\windows\CreateESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -location 'eastus' -state Deactivated -edition Standard -coreType vCore -coreCount 8"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\windows\DeleteESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01'"
    }
)

function Invoke-SingleScriptWhatIf {
    param(
        [string]$Path,
        [string]$Arguments
    )

    $escapedPath = $Path.Replace("'", "''")
    $command = @"
function global:Invoke-RestMethod { [Environment]::Exit(9) }
`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedPath' $Arguments -userToken `$token -WhatIf
exit `$LASTEXITCODE
"@

    & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command *> $null
    return $LASTEXITCODE
}

function Invoke-TargetScriptWhatIf {
    param(
        [string]$Path,
        [string]$Arguments
    )

    $escapedPath = $Path.Replace("'", "''")
    $command = @"
function global:Invoke-RestMethod {
    param(`$Uri, `$Method)
    if (`$Method -eq 'GET') {
        return [pscustomobject]@{ value = @(); nextLink = `$null }
    }
    [Environment]::Exit(9)
}
`$token = [pscustomobject]@{
    ExpiresOn = (Get-Date).AddMinutes(5)
    Token = ConvertTo-SecureString 'placeholder-token' -AsPlainText -Force
}
& '$escapedPath' $Arguments -userToken `$token -WhatIf
exit `$LASTEXITCODE
"@

    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

foreach ($scriptCase in $scriptCases) {
    $scriptName = Split-Path $scriptCase.Path -Leaf

    Describe "ShouldProcess behavior in $scriptName" {
        It 'exposes WhatIf and Confirm parameters' {
            $command = Get-Command $scriptCase.Path

            $command.Parameters.ContainsKey('WhatIf') | Should Be $true
            $command.Parameters.ContainsKey('Confirm') | Should Be $true
        }

        It 'sends no REST request during WhatIf' {
            Invoke-SingleScriptWhatIf -Path $scriptCase.Path -Arguments $scriptCase.Arguments | Should Be 0
        }
    }
}

Describe 'Planned target-aware ShouldProcess behavior in CreateESULicense.ps1' {
    $path = Join-Path $PSScriptRoot '..\Scripts\windows\CreateESULicense.ps1'
    $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-2016' -location 'eastus' -state Deactivated -edition Standard -coreType vCore -coreCount 8 -target 'Windows Server 2016'"

    It '[Phase 2] exposes the target parameter for explicit WhatIf calls' {
        (Get-Command $path).Parameters.ContainsKey('target') | Should Be $true
    }

    It '[Phase 2] previews the explicit target without sending a REST request' {
        $result = Invoke-TargetScriptWhatIf -Path $path -Arguments $arguments

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'What if:.*Windows Server 2016'
    }
}

Describe 'Planned target-aware ShouldProcess behavior in ManageESULicenses.ps1' {
    $path = Join-Path $PSScriptRoot '..\Scripts\windows\ManageESULicenses.ps1'
    $arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -location 'eastus' -state Deactivated -edition Standard -csvFilePath '$($targetCsvPath.Replace("'", "''"))' -target 'Windows Server 2016'"

    It '[Phase 3] exposes the target parameter for explicit WhatIf calls' {
        (Get-Command $path).Parameters.ContainsKey('target') | Should Be $true
    }

    It '[Phase 4] previews the effective target without sending a mutation request' {
        $result = Invoke-TargetScriptWhatIf -Path $path -Arguments $arguments

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'What if:.*Windows Server 2016'
    }
}

Remove-Item -LiteralPath $targetCsvPath -ErrorAction SilentlyContinue