$analyzerAvailable = $null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)

Describe 'PSScriptAnalyzer warning baseline' {
    It 'contains only the accepted legacy warnings' -Skip:(-not $analyzerAvailable) {
        $settingsPath = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'
        $scriptsPath = Join-Path $PSScriptRoot '..\Scripts'
        $findings = @(Invoke-ScriptAnalyzer -Path $scriptsPath -Recurse -Settings $settingsPath)

        $findings.Count | Should Be 2
        @($findings | Where-Object {
            $_.ScriptName -ne 'ManageESULicenses.ps1' -or
            $_.RuleName -ne 'PSUseDeclaredVarsMoreThanAssignments' -or
            $_.Message -ne "The variable 'response' is assigned but never used."
        }).Count | Should Be 0
    }
}