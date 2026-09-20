# ============================================
# Test-Syntax.ps1
# Parse every PowerShell source file without executing the project.
# ============================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$files = @(
    Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '[\\/]Cache[\\/]' }
)

$failed = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        $failed++
        Write-Host "SYNTAX FAILED: $($file.FullName)" -ForegroundColor Red
        foreach ($errorRecord in $errors) {
            Write-Host "  $($errorRecord.Message) at line $($errorRecord.Extent.StartLineNumber), column $($errorRecord.Extent.StartColumnNumber)" -ForegroundColor Red
        }
    } else {
        Write-Host "OK: $($file.FullName)" -ForegroundColor Green
    }
}

if ($failed -gt 0) {
    throw "$failed PowerShell file(s) failed syntax validation."
}

Write-Host 'All PowerShell files passed syntax validation.' -ForegroundColor Green
