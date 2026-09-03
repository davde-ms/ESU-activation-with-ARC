$subscriptionId = '00000000-0000-0000-0000-000000000001'
$scriptCases = @(
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\AssignESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -serverResourceGroupName 'server-rg' -ARCServerName 'server-01' -location 'eastus'"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\CreateESULicense.ps1'
        Arguments = "-subscriptionId '$subscriptionId' -licenseResourceGroupName 'license-rg' -licenseName 'license-01' -location 'eastus' -state Deactivated -edition Standard -coreType vCore -coreCount 8"
    },
    @{
        Path = Join-Path $PSScriptRoot '..\Scripts\DeleteESULicense.ps1'
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