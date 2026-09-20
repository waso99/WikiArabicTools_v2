$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Modules\WikitextParser.ps1')
. (Join-Path $root 'Modules\TextTranslator.ps1')

$testCachePath = Join-Path $env:TEMP "TestTextTranslationCache_$([guid]::NewGuid()).json"
$script:TextTranslationCachePath = $testCachePath

try {
    @{
        'Buccaneering Period'='فترة البوكانير'
        'Pirate Round'='جولة القراصنة'
        'Post-Spanish Succession'='ما بعد حرب الخلافة الإسبانية'
    } | ConvertTo-Json -Depth 5 | Set-Content $testCachePath -Encoding UTF8

    function Invoke-GeminiPlainTextTranslations {
        param([Parameter(Mandatory)][string[]]$Texts)
        $result = @{}
        foreach ($t in $Texts) {
            # Mock translation by prefixing with ARABIC
            # Also simulate a missing placeholder case to test validation
            if ($t -match "FAIL_MISSING_PLACEHOLDER") {
                $result[$t] = "ARABIC text without placeholder"
            } else {
                $result[$t] = "ARABIC " + $t
            }
        }
        return $result
    }

    $input = @(
        ';Buccaneering Period',
        'Text',
        '<ref> ;Do not translate this</ref>',
        '<nowiki>;Do not translate this</nowiki>',
        ';Pirate Round',
        '; English [[Article]]',
        '; English [[Article|English label]]',
        '; English [[Article#Section|English label]]',
        '; English {{Template}} [[Article]]',
        '; English [[Article]] and [[Second article]]',
        '; English [[Article|{{lang|en|English}}]]',
        '; English {{outer|value={{{parameter}}}}}',
        '; English {{outer|value=<nowiki>}}</nowiki>}}',
        '; FAIL_MISSING_PLACEHOLDER [[Test]]'
    ) -join "`n"
    $out = Convert-WikipediaVisibleText -Text $input

    if($out -notmatch ';فترة البوكانير'){
        Write-Host "NOT MATCHED! OUT WAS: $out"
        throw 'Buccaneering Period terminology is incorrect.'
    }
    if($out -notmatch ';جولة القراصنة'){throw 'Pirate Round terminology is incorrect.'}
    if($out -notmatch '<ref> ;Do not translate this</ref>'){throw 'Protected ref content was modified.'}
    if($out -notmatch '<nowiki>;Do not translate this</nowiki>'){throw 'Protected nowiki content was modified.'}

    # Verify Bug 2 placeholder safety
    if($out -notmatch ';ARABIC  English \[\[Article\]\]'){throw 'Failed case 1: Single link'}
    if($out -notmatch ';ARABIC  English \[\[Article\|English label\]\]'){throw 'Failed case 2: Piped link'}
    if($out -notmatch ';ARABIC  English \[\[Article#Section\|English label\]\]'){throw 'Failed case 3: Section link'}
    if($out -notmatch ';ARABIC  English \{\{Template\}\} \[\[Article\]\]'){throw 'Failed case 4: Template and link'}
    if($out -notmatch ';ARABIC  English \[\[Article\]\] and \[\[Second article\]\]'){throw 'Failed case 5: Multiple links'}
    if($out -notmatch ';ARABIC  English \[\[Article\|\{\{lang\|en\|English\}\}\]\]'){throw 'Failed case 6: Nested template inside link'}
    if($out -notmatch ';ARABIC  English \{\{outer\|value=\{\{\{parameter\}\}\}\}\}'){throw 'Failed case 7: Parameter syntax'}
    if($out -notmatch ';ARABIC  English \{\{outer\|value=<nowiki>\}\}</nowiki>\}\}'){throw 'Failed case 8: Protected token inside template'}

    # Missing placeholder must fallback to original english string
    if($out -notmatch '; FAIL_MISSING_PLACEHOLDER \[\[Test\]\]'){throw 'Failed case 9: Validation fallback on missing placeholder'}

    # BUG #5: $matches must not collide with PowerShell's automatic $Matches variable
    $bug5Input = @(
        ';English term'
        ';مصطلح عربي'
        ';English term (مصطلح عربي)'
        ';English term — مصطلح عربي'
        ';English term [[Article]]'
        ';مصطلح عربي [[Article]]'
    ) -join "`n"

    $bug5Out = Convert-WikipediaVisibleText -Text $bug5Input

    if($bug5Out -match '\r?\n\r?\n'){
        throw 'Failed BUG #5: unexpected blank line introduced.'
    }
    if(($bug5Out -split "`r?`n").Count -ne 6){
        throw 'Failed BUG #5: definition-list lines were not preserved.'
    }
    if($bug5Out -match ';;'){
        throw 'Failed BUG #5: duplicated definition-list marker detected.'
    }

    Write-Host 'BUG #5 regression test passed.' -ForegroundColor Green
    # BUG #6: Triple-brace template parameters must be protected
    # as complete Wikitext tokens before visible-text translation.
    $bug6Input = @(
        ';AuditBug6 {{{parameter}}}'
        ';AuditBug6 {{{parameter}}} and {{{another}}}'
        ';AuditBug6 {{{parameter|default={{Template}}}}}'
        ';AuditBug6 {{Template|value=test}}'
    ) -join "`n"

    $bug6Out = Convert-WikipediaVisibleText -Text $bug6Input

    # The mock Gemini translator returns the input prefixed with "ARABIC ".
    # Therefore the original Wikitext must reappear exactly in the output.
    if($bug6Out -notmatch ';ARABIC AuditBug6 \{\{\{parameter\}\}\}'){
        throw 'Failed BUG #6.1: Single triple-brace parameter was not preserved.'
    }

    if($bug6Out -notmatch ';ARABIC AuditBug6 \{\{\{parameter\}\}\} and \{\{\{another\}\}\}'){
        throw 'Failed BUG #6.2: Multiple triple-brace parameters were not preserved.'
    }

    if($bug6Out -notmatch ';ARABIC AuditBug6 \{\{\{parameter\|default=\{\{Template\}\}\}\}\}'){
        throw 'Failed BUG #6.3: Triple-brace parameter with nested template was not preserved.'
    }

    if($bug6Out -notmatch ';ARABIC AuditBug6 \{\{Template\|value=test\}\}'){
        throw 'Failed BUG #6.4: Ordinary template protection was regressed.'
    }

    Write-Host 'BUG #6 regression test passed.' -ForegroundColor Green

    Write-Host 'Visible-text regression tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path $testCachePath) { Remove-Item $testCachePath -Force }
}
