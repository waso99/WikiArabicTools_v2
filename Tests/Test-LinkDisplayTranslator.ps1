$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Modules\WikitextParser.ps1')
. (Join-Path $root 'Modules\Wikidata.ps1')
. (Join-Path $root 'Modules\TemplateTranslator.ps1')
. (Join-Path $root 'Modules\TextTranslator.ps1')
. (Join-Path $root 'Modules\LinkTranslator.ps1')

function Resolve-WikipediaLinksBatch {
    param([Parameter(Mandatory)][string[]]$EnglishTitles)
    $result=@{}
    foreach($title in $EnglishTitles){
        $ar=''; $qid='QTEST'
        switch($title){
            "Henry Morgan's raid on Porto Bello" {$ar='غارة هنري مورغان على بورتوبيلو'}
            "Henry Morgan's raid on Lake Maracaibo" {$ar='غارة هنري مورغان على بحيرة ماراكايبو'}
            'Lake Nicaragua' {$ar='بحيرة نيكاراغوا';$qid='Q-LAKE'}
            'Panama' {$ar='بنما';$qid='Q-PANAMA'}
            'Joseph Bannister' {$qid='Q-RANGER'}
            'Charles Town' {$ar='شارلستون (توضيح)';$qid='Q-CHARLESTON'}
            'Target' {$ar='الهدف';$qid='Q-TARGET'}
            'plasma (physics)' {$ar='بلازما (فيزياء)';$qid='Q-PLASMA'}
            'Ottoman Turks' {$ar='أتراك عثمانيون';$qid='QOTTOMAN'}
            'United Provinces' {$ar='جمهورية هولندا';$qid='Q-UP'}
            'Spanish Empire' {$ar='الإمبراطورية الإسبانية';$qid='Q-SPANISHEMPIRE'}
            'Spanish Language' {$ar='اللغة الإسبانية';$qid='Q-SPANISHLANGUAGE'}
            'John of Austria' {$ar='دون خوان النمساوي';$qid='Q-JOHN'}
            'Crown of Castile' {$ar='تاج قشتالة';$qid='Q-CASTILE'}
            'Article A' {$ar='مقالة أ';$qid='Q-ARTICLEA'}
        }
        $result[$title]=[PSCustomObject]@{QID=$qid;ArabicTitle=$ar}
    }
    return $result
}
function Get-ArabicWikidataLabelsBatch { param([Parameter(Mandatory)][string[]]$WikidataIds) $r=@{}; foreach($q in $WikidataIds){if($q -eq 'Q-RANGER'){$r[$q]='جوزيف بانيستر'}}; return $r }
function Get-ArabicWikipediaDisambiguationBatch { param([Parameter(Mandatory)][string[]]$ArabicTitles) $r=@{}; foreach($t in $ArabicTitles){$r[$t]=($t -eq 'شارلستون (توضيح)')}; return $r }

function Invoke-GeminiLinkDisplayTranslations {
    param([Parameter(Mandatory)][array]$Contexts)
    $result = @{}
    foreach ($ctx in $Contexts) {
        if ($ctx.EnglishTitle -eq 'Spanish Empire' -and $ctx.EnglishDisplay -eq 'Spanish') {
            $result[$ctx.CacheKey] = 'الإسبانية'
        }
        elseif ($ctx.EnglishTitle -eq 'Spanish Language' -and $ctx.EnglishDisplay -eq 'Spanish') {
            $result[$ctx.CacheKey] = 'الإسبانية'
        }
        elseif ($ctx.EnglishTitle -eq 'Article A' -and $ctx.EnglishDisplay -eq 'short display') {
            $result[$ctx.CacheKey] = 'النص القصير'
        }
        elseif ($ctx.EnglishTitle -eq 'Article A' -and $ctx.EnglishDisplay -eq '{{lang|en|missing placeholder}}') {
            $result[$ctx.CacheKey] = 'Missing'
        }
        elseif ($ctx.EnglishTitle -eq 'Article A' -and $ctx.EnglishDisplay -eq '{{lang|en|extra placeholder}}') {
            $result[$ctx.CacheKey] = 'Extra <WA_SAFE_1> <WA_SAFE_2>'
        }
        elseif ($ctx.EnglishTitle -eq 'Article A' -and $ctx.EnglishDisplay -eq '{{lang|en|duplicate placeholder}}') {
            $result[$ctx.CacheKey] = 'Duplicate <WA_SAFE_1> <WA_SAFE_1>'
        }
        elseif ($ctx.EnglishTitle -eq 'Target' -and $ctx.EnglishDisplay -eq 'Spanish {{lang|en|Empire}}') {
            $result[$ctx.CacheKey] = 'إسباني <WA_SAFE_1>'
        }
        elseif ($ctx.EnglishTitle -eq 'United Provinces' -and $ctx.EnglishDisplay -eq 'United Provinces') {
            $result[$ctx.CacheKey] = 'المقاطعات المتحدة'
        }
        elseif ($ctx.EnglishTitle -eq 'John of Austria' -and $ctx.EnglishDisplay -eq 'Don Juan of Austria') {
            $result[$ctx.CacheKey] = 'دون خوان النمساوي'
        }
        elseif ($ctx.EnglishTitle -eq 'Crown of Castile' -and $ctx.EnglishDisplay -eq 'Castilian') {
            $result[$ctx.CacheKey] = 'القشتالية'
        }
        elseif ($ctx.EnglishTitle -eq 'Target' -and $ctx.EnglishDisplay -eq 'Untranslatable Name') {
            $result[$ctx.CacheKey] = 'Untranslatable Name'
        }
    }
    return $result
}

$input=@'
* [[Henry Morgan's raid on Porto Bello|Porto Bello]]
* [[Henry Morgan's raid on Lake Maracaibo|Lake Maracaibo]]
* [[Lake Nicaragua|Lake Nicaragua]]
* [[Panama|Panama]]
* [[Capture of John Rackham|Capture of ''William'']]
* [[Joseph Bannister|Samaná Bay]]
* [[Blackbeard#Blockade of Charles Town|Charles Town]]
* [[Target|Custom label]]
* [[Target|عربي]]
* [[Target#History|Early history]]
* [[Target|Label, with punct!]]
* [[plasma (physics)|plasma]]
* [[Target|Target]]
* [[Target|{{lang|en|X}}]]
* [[Ottoman Turks|Ottomans]]
* [[Target]]
* [[Spanish Empire|Spanish]]
* [[Spanish Language|Spanish]]
* [[Article A|short display]]
* [[Article A|{{lang|en|missing placeholder}}]]
* [[Article A|{{lang|en|extra placeholder}}]]
* [[Article A|{{lang|en|duplicate placeholder}}]]
* [[Target|12345]]
* [[Target|<ref>citation</ref>]]
* [[Target|Spanish {{lang|en|Empire}}]]
* [[United Provinces|United Provinces]]
* [[John of Austria|Don Juan of Austria]]
* [[Crown of Castile|Castilian]]
* [[Target|Untranslatable Name]]
'@
$output=Convert-WikipediaLinks -Text $input
$expected=@'
* [[غارة هنري مورغان على بورتوبيلو|بورتو بيلو]]
* [[غارة هنري مورغان على بحيرة ماراكايبو|بحيرة ماراكايبو]]
* [[بحيرة نيكاراغوا|بحيرة نيكاراغوا]]
* [[بنما|بنما]]
* [[Capture of John Rackham|Capture of ''William'']]
* {{Ill-WD2|جوزيف بانيستر|id=Q-RANGER|نص=خليج سامانا}}
* [[Blackbeard#Blockade of Charles Town|Charles Town]]
* [[الهدف|Custom label]]
* [[الهدف|عربي]]
* [[الهدف#History|Early history]]
* [[الهدف|Label, with punct!]]
* [[بلازما (فيزياء)|بلازما]]
* [[الهدف|الهدف]]
* [[الهدف|{{lang|en|X}}]]
* [[أتراك عثمانيون|عثمانيون]]
* [[الهدف]]
* [[الإمبراطورية الإسبانية|الإسبانية]]
* [[اللغة الإسبانية|الإسبانية]]
* [[مقالة أ|النص القصير]]
* [[مقالة أ|{{lang|en|missing placeholder}}]]
* [[مقالة أ|{{lang|en|extra placeholder}}]]
* [[مقالة أ|{{lang|en|duplicate placeholder}}]]
* [[الهدف|12345]]
* [[الهدف|<ref>citation</ref>]]
* [[الهدف|إسباني {{lang|en|Empire}}]]
* [[جمهورية هولندا|المقاطعات المتحدة]]
* [[دون خوان النمساوي|دون خوان النمساوي]]
* [[تاج قشتالة|القشتالية]]
* [[الهدف|Untranslatable Name]]
'@
# Normalize line endings so the regression test is platform-independent.
$expectedNormalized = $expected -replace "`r`n", "`n"
$outputNormalized   = $output   -replace "`r`n", "`n"

if($outputNormalized -ne $expectedNormalized){
    Write-Host 'Link display test FAILED.' -ForegroundColor Red
    Write-Host 'Expected:'
    Write-Host $expected
    Write-Host 'Actual:'
    Write-Host $output
    exit 1
}
$cachePath = $script:LinkDisplayTranslationCachePath
if (Test-Path -LiteralPath $cachePath) {
    try {
        $cacheObj = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rejectedKeys = @(
            'Target:::Untranslatable Name',
            'Article A:::{{lang|en|missing placeholder}}',
            'Article A:::{{lang|en|extra placeholder}}',
            'Article A:::{{lang|en|duplicate placeholder}}'
        )
        foreach ($rk in $rejectedKeys) {
            if ($null -ne $cacheObj.PSObject.Properties[$rk]) {
                Write-Host "Cache verification failed: '$rk' should have been rejected but was cached!" -ForegroundColor Red
                exit 1
            }
        }
    } catch {}
}

Write-Host 'Link display regression tests passed.' -ForegroundColor Green
