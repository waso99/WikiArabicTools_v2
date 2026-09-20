# ============================================
# Test-ArabicLabelCache.ps1
# Regression test: non-Arabic values in ArabicLabelCache.json are treated as stale.
# ============================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Modules\Wikidata.ps1')

$cachePath = Join-Path $root 'Cache\ArabicLabelCache.json'
$original = if (Test-Path $cachePath) { Get-Content $cachePath -Raw -Encoding UTF8 } else { '{}' }

try {
    '{"QTEST":"English label"}' | Set-Content $cachePath -Encoding UTF8
    $script:WikidataLabelCache = '{"QTEST":"English label"}' | ConvertFrom-Json
    $script:WikidataLabelCacheStats = [ordered]@{ Hits = 0; Misses = 0; ApiRequests = 0 }

    function Invoke-WikiApiRequest {
        param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string]$ApiName)
        [PSCustomObject]@{
            entities = [PSCustomObject]@{
                QTEST = [PSCustomObject]@{
                    id = 'QTEST'
                    labels = [PSCustomObject]@{
                        ar = [PSCustomObject]@{ value = 'تسمية عربية اختبارية' }
                    }
                }
            }
        }
    }

    $result = Get-ArabicWikidataLabelsBatch -WikidataIds @('QTEST')

    if (-not $result.ContainsKey('QTEST')) { throw 'Expected QTEST to be returned after refreshing stale cache.' }
    if ([string]$result['QTEST'] -ne 'تسمية عربية اختبارية') { throw 'Expected Arabic label after stale-cache refresh.' }
    if ($script:WikidataLabelCacheStats.Hits -ne 0) { throw "Expected 0 cache hits, got $($script:WikidataLabelCacheStats.Hits)." }
    if ($script:WikidataLabelCacheStats.Misses -ne 1) { throw "Expected 1 cache miss, got $($script:WikidataLabelCacheStats.Misses)." }
    if ($script:WikidataLabelCacheStats.ApiRequests -ne 1) { throw "Expected 1 API request, got $($script:WikidataLabelCacheStats.ApiRequests)." }

    Write-Host 'Arabic-label cache regression tests passed.' -ForegroundColor Green
}
finally {
    Set-Content $cachePath -Value $original -Encoding UTF8
}
