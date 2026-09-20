# ============================================
# Test-ArabicSitelinkCache.ps1
# Regression test: legacy empty arwiki cache entries are refreshed.
# ============================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Modules\Wikidata.ps1')

$script:WikidataCache = [PSCustomObject]@{
    'qid:Test article' = 'QTEST'
    'arwiki:QTEST' = ''
}
$script:LastWikipediaTitleSuccess = @{ 'Test article' = $true }
$script:LastArabicSitelinkSuccess = @{}
$script:ApiSettings = [ordered]@{ BatchSize = 50 }

function Invoke-WikiApiRequest {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string]$ApiName)
    if ($Uri -like '*sitefilter=arwiki*') {
        return [PSCustomObject]@{
            entities = @([PSCustomObject]@{
                id = 'QTEST'
                sitelinks = [PSCustomObject]@{
                    arwiki = [PSCustomObject]@{ title = 'مقالة اختبارية' }
                }
            })
        }
    }
    throw 'Unexpected API request in test.'
}

$result = Resolve-WikipediaLinksBatch -EnglishTitles @('Test article')
if ([string]$result['Test article'].ArabicTitle -ne 'مقالة اختبارية') {
    throw 'Expected stale empty arwiki cache entry to be refreshed.'
}
if ([string]$script:WikidataCache.'arwiki:QTEST' -ne 'مقالة اختبارية') {
    throw 'Expected refreshed Arabic sitelink to be cached.'
}

Write-Host 'Arabic-sitelink cache regression tests passed.' -ForegroundColor Green
