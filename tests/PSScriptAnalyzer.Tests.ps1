$analyzerAvailable = $null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)

Describe 'PSScriptAnalyzer warning baseline' {
    It 'contains no error or warning findings' -Skip:(-not $analyzerAvailable) {
        $settingsPath = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'
        $scriptsPath = Join-Path $PSScriptRoot '..\Scripts'
        $findings = @(Invoke-ScriptAnalyzer -Path $scriptsPath -Recurse -Settings $settingsPath)

        $findings.Count | Should Be 0
    }
}