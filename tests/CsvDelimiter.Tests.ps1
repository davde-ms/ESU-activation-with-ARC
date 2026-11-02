$scriptsRoot = Join-Path $PSScriptRoot '..\Scripts'
$referencePath = Join-Path $scriptsRoot 'windows\ManageESULicenses.ps1'

function Get-DelimitedCsvFunctionAst {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Unable to parse '$Path': $($parseErrors.Message -join '; ')"
    }
    return $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Import-DelimitedCsv'
    }, $true)
}

Describe 'CSV delimiter rollout consistency' {
    It 'routes every production CSV import through delimiter detection' {
        $importsChecked = 0
        foreach ($file in Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -Recurse) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should Be 0
            $imports = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Import-Csv'
            }, $true)
            foreach ($command in $imports) {
                $ancestor = $command.Parent
                while ($null -ne $ancestor -and $ancestor -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $ancestor = $ancestor.Parent
                }
                ($null -ne $ancestor) | Should Be $true
                $ancestor.Name | Should Be 'Import-DelimitedCsv'
                $importsChecked++
            }
        }
        $importsChecked | Should Be 10
    }

    It 'keeps the same detection function in every CSV input script' {
        $expectedScripts = @(
            'windows\ManageESULicenses.ps1'
            'windows\BulkDeleteESULicenses.ps1'
            'windows\CheckESUStatus.ps1'
            'windows\ManageESUAssignments.ps1'
            'windows\ManageESUAssignmentsFR.ps1'
            'sql\CheckSQLServerESUStatus.ps1'
            'sql\InstallSQLServerArcExtension.ps1'
            'sql\SetSQLServerESUSubscription.ps1'
            'sql\SetSQLServerLicenseType.ps1'
            'sql\TestSQLServerArcESUPrerequisites.ps1'
        )
        $referenceBody = (Get-DelimitedCsvFunctionAst -Path $referencePath).Body.Extent.Text -replace "`r`n", "`n"
        foreach ($relativePath in $expectedScripts) {
            $functionAst = Get-DelimitedCsvFunctionAst -Path (Join-Path $scriptsRoot $relativePath)
            ($null -ne $functionAst) | Should Be $true
            ($functionAst.Body.Extent.Text -replace "`r`n", "`n") | Should Be $referenceBody
        }
    }
}

Describe 'Standalone CSV delimiter detection' {
    BeforeEach {
        $functionAst = Get-DelimitedCsvFunctionAst -Path $referencePath
        $bodyText = $functionAst.Body.Extent.Text
        Set-Item -Path 'Function:\global:Import-DelimiterTestCsv' -Value ([scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2)))
        $requiredColumns = @('Name', 'Cores', 'IsVirtual', 'AgentVersion')
    }

    It 'preserves multiple rows, quoted delimiters, newlines and escaped quotes for both separators' {
        foreach ($delimiter in @(',', ';')) {
            $path = Join-Path $TestDrive 'quoted.csv'
            $rows = @(
                [pscustomobject]@{
                    Name = 'server-01'
                    Cores = '8'
                    IsVirtual = 'Virtual'
                    AgentVersion = '1.34'
                    Note = "Fictitious, note; with `"quotes`"`nand a new line"
                }
                [pscustomobject]@{
                    Name = 'server-02'
                    Cores = '16'
                    IsVirtual = 'Physical'
                    AgentVersion = '1.62'
                    Note = ''
                }
            )
            $rows | Export-Csv -LiteralPath $path -Delimiter $delimiter -NoTypeInformation

            $actual = @(Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns)

            $actual.Count | Should Be 2
            $actual[0].Note | Should Be $rows[0].Note
            $actual[1].Name | Should Be 'server-02'
            $actual[1].Cores | Should Be '16'
        }
    }

    It 'accepts case-insensitive headers and UTF-8 files with or without a BOM' {
        foreach ($delimiter in @(',', ';')) {
            foreach ($encoding in @('utf8', 'utf8BOM')) {
                $path = Join-Path $TestDrive 'encoding.csv'
                [pscustomobject]@{ name = 'server-01'; CORES = '8'; isvirtual = 'Virtual'; agentversion = '1.34' } |
                    Export-Csv -LiteralPath $path -Delimiter $delimiter -NoTypeInformation -Encoding $encoding

                $actual = @(Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns)

                $actual.Count | Should Be 1
                $actual[0].Name | Should Be 'server-01'
            }
        }
    }

    It 'preserves LiteralPath handling of brackets in file names' {
        $path = Join-Path $TestDrive 'servers[1].csv'
        @('Name;Cores;IsVirtual;AgentVersion', 'server-01;8;Virtual;1.34') | Set-Content -LiteralPath $path

        $actual = @(Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns)

        $actual.Count | Should Be 1
        $actual[0].Name | Should Be 'server-01'
    }

    It 'preserves Path imports using a wildcard that matches one file' {
        $path = Join-Path $TestDrive 'wildcard-1.csv'
        @('Name;Cores;IsVirtual;AgentVersion', 'server-01;8;Virtual;1.34') | Set-Content -LiteralPath $path

        $actual = @(Import-DelimiterTestCsv -Path (Join-Path $TestDrive 'wildcard-*.csv') -RequiredColumns $requiredColumns)

        $actual.Count | Should Be 1
        $actual[0].Name | Should Be 'server-01'
    }

    It 'reports only missing columns from the closest header match' {
        foreach ($delimiter in @(',', ';')) {
            $path = Join-Path $TestDrive 'missing.csv'
            [pscustomobject]@{ Name = 'server-01'; Cores = '8' } |
                Export-Csv -LiteralPath $path -Delimiter $delimiter -NoTypeInformation
            $message = ''
            try {
                Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns
            } catch {
                $message = $_.Exception.Message
            }

            $message | Should Match 'missing required column\(s\): IsVirtual, AgentVersion\.'
            $message | Should Not Match 'column\(s\): Name'
        }
    }

    It 'rejects unsupported tab separators and header names with whitespace' {
        $path = Join-Path $TestDrive 'unsupported.csv'
        @("Name`tCores`tIsVirtual`tAgentVersion", "server-01`t8`tVirtual`t1.34") | Set-Content -LiteralPath $path
        { Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns } |
            Should Throw 'Name, Cores, IsVirtual, AgentVersion'

        @('" Name",Cores,IsVirtual,AgentVersion', 'server-01,8,Virtual,1.34') | Set-Content -LiteralPath $path
        { Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns } |
            Should Throw 'missing required column(s): Name.'
    }

    It 'reports file access errors rather than treating them as empty input' {
        $path = Join-Path $TestDrive 'does-not-exist.csv'

        { Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns } |
            Should Throw 'CSV import failed:'
    }

    It 'reports parsing errors when neither interpretation can be parsed' {
        $path = Join-Path $TestDrive 'duplicate-headers.csv'
        @('Name,Name;Other;Other,Name;Other;Other', 'a,b;c;d,e;f;g') | Set-Content -LiteralPath $path

        { Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns } |
            Should Throw 'CSV import failed:'
    }

    It 'accepts a valid interpretation even when the other delimiter produces duplicate headers' {
        $path = Join-Path $TestDrive 'one-valid-parse.csv'
        @(
            'Name,Cores,IsVirtual,AgentVersion,Note;Duplicate;Duplicate'
            'server-01,8,Virtual,1.34,example;one;two'
        ) | Set-Content -LiteralPath $path

        $actual = @(Import-DelimiterTestCsv -LiteralPath $path -RequiredColumns $requiredColumns)

        $actual.Count | Should Be 1
        $actual[0].Name | Should Be 'server-01'
    }

    AfterAll {
        Remove-Item -Path 'Function:\global:Import-DelimiterTestCsv'
    }
}
