# Contributing

## PowerShell compatibility

- Target PowerShell 7.x.
- Preserve public parameters, aliases, accepted values, CSV columns, output objects, exit codes, and both authentication paths unless a breaking change is explicitly approved.
- Do not use a live Azure tenant for automated validation. Mock authentication and REST calls.

## Encoding

Store PowerShell and Markdown files as UTF-8 without a byte-order mark (BOM). This matches the existing repository and PowerShell 7's UTF-8 behavior. `PSUseBOMForUnicodeEncodedFile` is excluded because its Windows PowerShell compatibility recommendation conflicts with this repository's PowerShell 7 target.

## Static analysis baseline

Run the repository profile with:

```powershell
Invoke-ScriptAnalyzer -Path .\Scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The profile excludes existing categories that require separate compatibility decisions: global state, `Write-Host` output, singular public command names, and the BOM rule described above. Informational formatting rules are outside the warning baseline.

The accepted analyzer baseline is zero error or warning findings. `tests/PSScriptAnalyzer.Tests.ps1` enforces that baseline, so any new finding fails the test.

## Validation

Parse every changed `.ps1` file, run the analyzer profile, and run the focused and full Pester suites. If PSScriptAnalyzer is unavailable, report that instead of installing it implicitly.