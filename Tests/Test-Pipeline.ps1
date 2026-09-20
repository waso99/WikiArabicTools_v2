# ============================================
# Test-Pipeline.ps1
# Integration test: verify that the processing pipeline chains
# template → link → visible-text stages correctly, and that
# the output of each stage becomes the input of the next.
# ============================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Load all modules in the same order as WikiArabicTools.ps1
. (Join-Path $root 'Modules\WikitextParser.ps1')
. (Join-Path $root 'Modules\WikipediaFetcher.ps1')
. (Join-Path $root 'Modules\Wikidata.ps1')
. (Join-Path $root 'Modules\LinkTranslator.ps1')
. (Join-Path $root 'Modules\TemplateTranslator.ps1')
. (Join-Path $root 'Modules\TextTranslator.ps1')

$passed = 0
$failed = 0

function Assert-Equal {
    param([string]$TestName, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) {
        $script:passed++
        Write-Host "  PASS: $TestName" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        Write-Host "    Expected:" -ForegroundColor Yellow
        Write-Host $Expected -ForegroundColor Yellow
        Write-Host "    Actual:" -ForegroundColor Yellow
        Write-Host $Actual -ForegroundColor Yellow
    }
}

function Assert-Contains {
    param([string]$TestName, [string]$Substring, [string]$Text)
    if ($Text.Contains($Substring)) {
        $script:passed++
        Write-Host "  PASS: $TestName" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  FAIL: $TestName (substring not found)" -ForegroundColor Red
        Write-Host "    Expected to contain: $Substring" -ForegroundColor Yellow
    }
}

function Assert-NotContains {
    param([string]$TestName, [string]$Substring, [string]$Text)
    if (-not $Text.Contains($Substring)) {
        $script:passed++
        Write-Host "  PASS: $TestName" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "  FAIL: $TestName (substring was found but should not be)" -ForegroundColor Red
        Write-Host "    Should NOT contain: $Substring" -ForegroundColor Yellow
    }
}

# ============================================
# Mock the API-calling functions to avoid network calls.
# These override the dot-sourced functions from the modules.
# ============================================

# Mock Resolve-WikipediaLinksBatch: return Arabic titles for known test links
function Resolve-WikipediaLinksBatch {
    param([Parameter(Mandatory)][array]$EnglishTitles)
    $result = @{}
    foreach ($title in $EnglishTitles) {
        switch ([string]$title) {
            'Golden Age of Piracy' { $result[$title] = @{ QID = 'Q123'; ArabicTitle = 'العصر الذهبي للقرصنة' } }
            'Henry Morgan' { $result[$title] = @{ QID = 'Q456'; ArabicTitle = 'هنري مورغان' } }
            'Blackbeard' { $result[$title] = @{ QID = 'Q789'; ArabicTitle = 'بلاكبيرد' } }
            default { $result[$title] = @{ QID = $null; ArabicTitle = $null } }
        }
    }
    $script:CacheStats = [ordered]@{ QidHits = 0; QidMisses = 0; ArabicHits = 0; ArabicMisses = 0 }
    return $result
}

# Mock Get-ArabicWikidataLabelsBatch: no labels needed for these tests
function Get-ArabicWikidataLabelsBatch {
    param([Parameter(Mandatory)][array]$WikidataIds)
    return @{}
}

# Disable Gemini for visible-text translation
$env:GEMINI_API_KEY = $null

# Seed the text translation cache for deterministic visible-text translation
$cachePath = Join-Path $root 'Cache\TextTranslationCache.json'
$originalCache = if (Test-Path $cachePath) { Get-Content $cachePath -Raw -Encoding UTF8 } else { '{}' }

try {
    @{
        'Early life' = 'حياته المبكرة'
        'Career' = 'مسيرته المهنية'
    } | ConvertTo-Json -Depth 5 | Set-Content $cachePath -Encoding UTF8

    $mapPath = Join-Path $root 'Templates\TemplateMap.json'

    # ============================================
    Write-Host "`n=== Test 1: Pipeline Chaining ===" -ForegroundColor Cyan
    # Template rename + Link translation + Visible text translation
    # must all be present in the final output.
    # ============================================

    $input1 = @'
{{Campaignbox Golden Age of Piracy}}
The [[Golden Age of Piracy]] was led by [[Henry Morgan]].
;Early life
He was born in Wales.
'@

    # Stage 1: Templates
    $result = Convert-WikipediaTemplates -Text $input1 -MapPath $mapPath
    Assert-Contains "Stage 1: template renamed" 'صندوق حملة العصر الذهبي للقرصنة' $result
    Assert-NotContains "Stage 1: original template name gone" '{{Campaignbox Golden Age of Piracy}}' $result
    # Links should still be in English at this point
    Assert-Contains "Stage 1: links still English" '[[Golden Age of Piracy]]' $result

    # Stage 2: Links
    $result = Convert-WikipediaLinks -Text $result
    Assert-Contains "Stage 2: links translated" 'العصر الذهبي للقرصنة' $result
    Assert-Contains "Stage 2: template rename preserved" 'صندوق حملة العصر الذهبي للقرصنة' $result

    # Stage 3: Visible text
    $result = Convert-WikipediaVisibleText -Text $result
    Assert-Contains "Stage 3: visible text translated" 'حياته المبكرة' $result
    Assert-Contains "Stage 3: template rename still preserved" 'صندوق حملة العصر الذهبي للقرصنة' $result
    Assert-Contains "Stage 3: link translation still preserved" 'العصر الذهبي للقرصنة' $result

    # ============================================
    Write-Host "`n=== Test 2: Protected Blocks Survive Pipeline ===" -ForegroundColor Cyan
    # ============================================

    $input2 = @'
<ref>[[Golden Age of Piracy]] source</ref>
<nowiki>{{Campaignbox Golden Age of Piracy}}</nowiki>
<math>E = mc^2</math>
<code>print("hello")</code>
<pre>raw text here</pre>
[[Henry Morgan]] was a pirate.
'@

    $result = Convert-WikipediaTemplates -Text $input2 -MapPath $mapPath
    $result = Convert-WikipediaLinks -Text $result
    $result = Convert-WikipediaVisibleText -Text $result

    Assert-Contains "Protected: <ref> content preserved" '<ref>[[Golden Age of Piracy]] source</ref>' $result
    Assert-Contains "Protected: <nowiki> content preserved" '<nowiki>{{Campaignbox Golden Age of Piracy}}</nowiki>' $result
    Assert-Contains "Protected: <math> content preserved" '<math>E = mc^2</math>' $result
    Assert-Contains "Protected: <code> content preserved" '<code>print("hello")</code>' $result
    Assert-Contains "Protected: <pre> content preserved" '<pre>raw text here</pre>' $result
    Assert-Contains "Protected: real link still translated" 'هنري مورغان' $result

    # ============================================
    Write-Host "`n=== Test 3: Plain Text (No Templates/Links) ===" -ForegroundColor Cyan
    # ============================================

    $input3 = 'Just plain text with no wikitext markup.'
    $result = Convert-WikipediaTemplates -Text $input3 -MapPath $mapPath
    $result = Convert-WikipediaLinks -Text $result
    $result = Convert-WikipediaVisibleText -Text $result
    Assert-Equal "Plain text passes through unchanged" $input3 $result

    # ============================================
    Write-Host "`n=== Test 4: Template with Links Inside ===" -ForegroundColor Cyan
    # ============================================

    $input4 = @'
{{Campaignbox
|name=Campaignbox Golden Age of Piracy
|title=[[Golden Age of Piracy]]
}}
'@

    $result = Convert-WikipediaTemplates -Text $input4 -MapPath $mapPath
    # Template parameter value should be renamed
    Assert-Contains "Template param value renamed" 'صندوق حملة العصر الذهبي للقرصنة' $result
    # Link inside template should still be present for link stage
    Assert-Contains "Link inside template survives template stage" '[[Golden Age of Piracy]]' $result

    $result = Convert-WikipediaLinks -Text $result
    # Now the link should be translated
    Assert-Contains "Link inside template translated" 'العصر الذهبي للقرصنة' $result

    # ============================================
    Write-Host "`n=== Test 5: Multiple Links ===" -ForegroundColor Cyan
    # ============================================

    $input5 = '[[Golden Age of Piracy]] and [[Henry Morgan]] and [[Blackbeard]]'
    $result = Convert-WikipediaTemplates -Text $input5 -MapPath $mapPath
    $result = Convert-WikipediaLinks -Text $result
    $result = Convert-WikipediaVisibleText -Text $result

    Assert-Contains "Multi-link: first translated" 'العصر الذهبي للقرصنة' $result
    Assert-Contains "Multi-link: second translated" 'هنري مورغان' $result
    Assert-Contains "Multi-link: third translated" 'بلاكبيرد' $result

    # ============================================
    Write-Host "`n=== Test 6: Unknown Template Passthrough ===" -ForegroundColor Cyan
    # ============================================

    $input6 = '{{UnknownTemplate|param=value}} text'
    $result = Convert-WikipediaTemplates -Text $input6 -MapPath $mapPath
    Assert-Contains "Unknown template preserved" '{{UnknownTemplate|param=value}}' $result

    # ============================================
    Write-Host "`n=== Test 7: Ignored Namespace Links ===" -ForegroundColor Cyan
    # ============================================

    $input7 = '[[Category:Pirates]] [[File:Pirate.jpg|thumb|Caption]] [[Henry Morgan]]'
    $result = Convert-WikipediaTemplates -Text $input7 -MapPath $mapPath
    $result = Convert-WikipediaLinks -Text $result
    Assert-Contains "Category link preserved" '[[Category:Pirates]]' $result
    Assert-Contains "File link preserved" '[[File:Pirate.jpg|thumb|Caption]]' $result
    Assert-Contains "Regular link translated" 'هنري مورغان' $result

    # ============================================
    Write-Host "`n=== Test 8: Section Links ===" -ForegroundColor Cyan
    # ============================================

    $input8 = '[[Henry Morgan#Early life|his early life]]'
    $result = Convert-WikipediaLinks -Text $input8
    # Target should be Arabic with section preserved
    Assert-Contains "Section link: Arabic target" 'هنري مورغان' $result
    Assert-Contains "Section link: section preserved" '#Early life' $result

    # ============================================
    Write-Host "`n=== Test 9: Empty Input ===" -ForegroundColor Cyan
    # ============================================

    # Note: truly empty strings are rejected by [Parameter(Mandatory)],
    # which is expected. The main pipeline checks for empty input before
    # calling these functions. Test whitespace-only input instead.
    $result = Convert-WikipediaTemplates -Text '   ' -MapPath $mapPath
    Assert-Equal "Whitespace-only input template stage" '   ' $result
    $result = Convert-WikipediaVisibleText -Text '   '
    Assert-Equal "Whitespace-only input visible text stage" '   ' $result

    # ============================================
    Write-Host "`n=== Test 10: Multiline Template ===" -ForegroundColor Cyan
    # ============================================

    $input10 = @'
{{Campaignbox Golden Age of Piracy
|name=Campaignbox Golden Age of Piracy
|battles=
* [[Golden Age of Piracy|Overview]]
* [[Henry Morgan|Morgan's raids]]
}}
'@

    $result = Convert-WikipediaTemplates -Text $input10 -MapPath $mapPath
    Assert-Contains "Multiline: template renamed" 'صندوق حملة العصر الذهبي للقرصنة' $result

    $result = Convert-WikipediaLinks -Text $result
    Assert-Contains "Multiline: links inside translated" 'العصر الذهبي للقرصنة' $result
    Assert-Contains "Multiline: second link inside translated" 'هنري مورغان' $result

    # ============================================
    Write-Host "`n=== Test 11: Nested Templates ===" -ForegroundColor Cyan
    # ============================================

    $input11 = '{{Outer|nested={{Campaignbox Golden Age of Piracy}}}}'
    $result = Convert-WikipediaTemplates -Text $input11 -MapPath $mapPath
    Assert-Contains "Nested: inner template renamed" 'صندوق حملة العصر الذهبي للقرصنة' $result
    Assert-Contains "Nested: outer template preserved" '{{Outer' $result

    # ============================================
    Write-Host "`n=== Test 12: Tables with Links ===" -ForegroundColor Cyan
    # ============================================

    $input12 = @'
{| class="wikitable"
|-
| [[Golden Age of Piracy]]
| [[Henry Morgan]]
|}
'@

    $result = Convert-WikipediaLinks -Text $input12
    Assert-Contains "Table: first link translated" 'العصر الذهبي للقرصنة' $result
    Assert-Contains "Table: second link translated" 'هنري مورغان' $result
    Assert-Contains "Table: structure preserved" '{| class="wikitable"' $result
    Assert-Contains "Table: closing preserved" '|}' $result

    # ============================================
    Write-Host "`n=== Test 13: Lists ===" -ForegroundColor Cyan
    # ============================================

    $input13 = @'
* [[Golden Age of Piracy]]
* [[Henry Morgan]]
# [[Blackbeard]]
'@

    $result = Convert-WikipediaLinks -Text $input13
    Assert-Contains "List: first item translated" 'العصر الذهبي للقرصنة' $result
    Assert-Contains "List: second item translated" 'هنري مورغان' $result
    Assert-Contains "List: numbered item translated" 'بلاكبيرد' $result

    # ============================================
    # Summary
    # ============================================

    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "Pipeline Integration Tests: $passed passed, $failed failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
    Write-Host "============================================`n" -ForegroundColor Cyan

    if ($failed -gt 0) { exit 1 }

} finally {
    # Restore original cache
    Set-Content $cachePath -Value $originalCache -Encoding UTF8
}
