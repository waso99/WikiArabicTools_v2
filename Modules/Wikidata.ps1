# ============================================
# Wikidata.ps1
# Wikipedia API (Hybrid Langlinks + Wikidata)
# ============================================

$CacheDirectory = Join-Path $PSScriptRoot "..\Cache"
$CacheFile = Join-Path $CacheDirectory "WikidataCache.json"

if (-not (Test-Path $CacheDirectory)) { New-Item -ItemType Directory -Path $CacheDirectory | Out-Null }

if (Test-Path $CacheFile) {
    try {
        $content = Get-Content -Path $CacheFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) { $script:WikidataCache = [PSCustomObject]@{} }
        else { $script:WikidataCache = $content | ConvertFrom-Json }
    }
    catch {
        $script:WikidataCache = [PSCustomObject]@{}
    }
}
else {
    $script:WikidataCache = [PSCustomObject]@{}
}

$script:ApiStats = [ordered]@{ WikipediaRequests = 0; WikidataRequests = 0; SuccessfulRequests = 0; FailedRequests = 0 }
$script:ApiSettings = @{ MaxRetries = 4; RetryDelaySeconds = 10; BatchSize = 50; MinRequestIntervalSeconds = 3 }

function Save-WikidataCache {
    $script:WikidataCache | ConvertTo-Json -Depth 10 | Set-Content -Path $CacheFile -Encoding UTF8
}

function Set-WikidataCacheValue {
    param([Parameter(Mandatory)][string]$Key, [AllowNull()][string]$Value)
    $script:WikidataCache | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

function Test-WikidataCache {
    param([Parameter(Mandatory)][string]$Key)
    return ($null -ne $script:WikidataCache.PSObject.Properties[$Key])
}

function Invoke-WikiApiRequest {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][ValidateSet("Wikipedia", "Wikidata")][string]$ApiName)
    $maxRetries = [int]$script:ApiSettings.MaxRetries
    $baseDelay = [int]$script:ApiSettings.RetryDelaySeconds

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            if ($ApiName -eq "Wikipedia") { $script:ApiStats.WikipediaRequests++ }
            else { $script:ApiStats.WikidataRequests++ }
            $script:LastApiRequestTime = Get-Date
            return Invoke-RestMethod -Uri $Uri -Method Get -Headers @{"User-Agent" = "WikiArabicTools/1.5 (Hybrid)" } -ErrorAction Stop
        }
        catch {
            $message = $_.Exception.Message
            if ($message -match "429|Too Many Requests" -and $attempt -lt $maxRetries) {
                Start-Sleep -Seconds ($baseDelay * $attempt)
                continue
            }
            $script:ApiStats.FailedRequests++
            return $null
        }
    }
    return $null
}

# الاستعلام الهجين: يجلب QID ورابط المقالة العربية المباشر (Langlink) في نفس الوقت
function Get-WikipediaPageInfoBatch {
    param([Parameter(Mandatory)][array]$EnglishTitles)
    $result = @{}
    $EnglishTitles = @($EnglishTitles)
    $batchSize = [int]$script:ApiSettings.BatchSize

    for ($i = 0; $i -lt $EnglishTitles.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $EnglishTitles.Count - 1)
        $batch = @($EnglishTitles[$i..$end])
        $titles = $batch -join "|"
        $encodedTitles = [System.Uri]::EscapeDataString($titles)

        $url = "https://en.wikipedia.org/w/api.php?action=query&prop=pageprops|langlinks&lllang=ar&lllimit=max&ppprop=wikibase_item&titles=$encodedTitles&redirects=1&format=json&formatversion=2"

        $response = Invoke-WikiApiRequest -Uri $url -ApiName "Wikipedia"
        if ($null -eq $response) { continue }
        $script:ApiStats.SuccessfulRequests++

        $redirectMap = @{}
        if ($null -ne $response.query -and $null -ne $response.query.redirects) {
            foreach ($redirect in @($response.query.redirects)) {
                if ($null -ne $redirect.from -and $null -ne $redirect.to) {
                    $redirectMap[[string]$redirect.from] = [string]$redirect.to
                }
            }
        }

        foreach ($page in @($response.query.pages)) {
            if ($null -eq $page) { continue }

            $qid = ""
            if ($null -ne $page.pageprops -and $null -ne $page.pageprops.wikibase_item) {
                $qid = [string]$page.pageprops.wikibase_item
            }

            $arTitle = ""
            if ($null -ne $page.langlinks -and $page.langlinks.Count -gt 0) {
                $arTitle = [string]$page.langlinks[0].title
            }

            $finalTitle = [string]$page.title
            $data = @{ QID = $qid; ArabicTitle = $arTitle }
            $result[$finalTitle] = $data

            foreach ($originalTitle in $redirectMap.Keys) {
                if ($redirectMap[$originalTitle] -eq $finalTitle) {
                    $result[[string]$originalTitle] = $data
                }
            }
        }
    }
    return $result
}

function Resolve-WikipediaLinksBatch {
    param([Parameter(Mandatory)][array]$EnglishTitles)
    $resolved = @{}
    $EnglishTitles = [object[]]@($EnglishTitles | Select-Object -Unique)
    if ($EnglishTitles.Count -eq 0) { return $resolved }

    $titlesToQuery = [System.Collections.Generic.List[string]]::new()
    foreach ($title in $EnglishTitles) {
        $title = [string]$title
        $qidKey = "qid:$title"
        $arTitleKey = "artitle:$title"

        if ((Test-WikidataCache -Key $qidKey) -and (Test-WikidataCache -Key $arTitleKey)) {
            $resolved[$title] = @{
                QID         = [string]$script:WikidataCache.PSObject.Properties[$qidKey].Value;
                ArabicTitle = [string]$script:WikidataCache.PSObject.Properties[$arTitleKey].Value
            }
        }
        else {
            $titlesToQuery.Add($title)
        }
    }

    if ($titlesToQuery.Count -gt 0) {
        Write-Host "جلب بيانات (QID + Langlinks) لـ $($titlesToQuery.Count) روابط دفعة واحدة..." -ForegroundColor Cyan
        $infoResults = Get-WikipediaPageInfoBatch -EnglishTitles ([object[]]$titlesToQuery.ToArray())
        $cacheChanged = $false

        foreach ($title in $titlesToQuery) {
            $qid = ""
            $arTitle = ""
            if ($infoResults.ContainsKey([string]$title)) {
                $qid = $infoResults[[string]$title].QID
                $arTitle = $infoResults[[string]$title].ArabicTitle
            }

            Set-WikidataCacheValue -Key "qid:$title" -Value $qid
            Set-WikidataCacheValue -Key "artitle:$title" -Value $arTitle
            $cacheChanged = $true

            $resolved[[string]$title] = @{ QID = $qid; ArabicTitle = $arTitle }
        }
        if ($cacheChanged) { Save-WikidataCache }
    }

    return $resolved
}

function Get-WikidataEntitiesCollection {
    param([AllowNull()]$Entities)
    $items = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Entities) { return @() }
    if ($Entities -is [System.Array] -or $Entities -is [System.Collections.IEnumerable] -and
        $Entities -isnot [string] -and $Entities.PSObject.Properties.Count -eq 0) {
        foreach ($entity in @($Entities)) { if ($null -ne $entity) { $items.Add($entity) } }
        return $items.ToArray()
    }
    $props = @($Entities.PSObject.Properties)
    if ($props.Count -gt 0) {
        foreach ($prop in $props) {
            if ($null -ne $prop.Value) { $items.Add($prop.Value) }
        }
        return $items.ToArray()
    }
    return @($Entities)
}

function Get-ArabicWikidataLabelsBatch {
    param([Parameter(Mandatory)][array]$WikidataIds)
    $result = @{}
    $ids = [object[]]@($WikidataIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return $result }

    $idsToQuery = [System.Collections.Generic.List[string]]::new()
    $cacheHits = 0
    foreach ($qid in $ids) {
        $qid = [string]$qid
        $key = "arlabel:$qid"
        if (Test-WikidataCache -Key $key) {
            $cached = [string]$script:WikidataCache.PSObject.Properties[$key].Value
            if (-not [string]::IsNullOrWhiteSpace($cached) -and $cached -match '[\u0600-\u06FF]') {
                $cacheHits++; $result[$qid] = $cached
            }
            else {
                $idsToQuery.Add($qid)
                try { $script:WikidataCache.PSObject.Properties.Remove($key) } catch {}
            }
        }
        else { $idsToQuery.Add($qid) }
    }
    if ($idsToQuery.Count -eq 0) { return $result }

    for ($i = 0; $i -lt $idsToQuery.Count; $i += 50) {
        $end = [Math]::Min($i + 49, $idsToQuery.Count - 1)
        $batch = @($idsToQuery[$i..$end])
        $encoded = [Uri]::EscapeDataString(($batch -join '|'))
        $url = "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=$encoded&props=labels&languages=ar&languagefallback=0&format=json&formatversion=2&maxlag=5"
        try {
            $response = Invoke-WikiApiRequest -Uri $url -ApiName 'Wikidata'
            if ($null -eq $response -or $null -eq $response.entities) { continue }
            foreach ($entity in (Get-WikidataEntitiesCollection -Entities $response.entities)) {
                if ($null -eq $entity) { continue }
                $qid = [string]$entity.id; $labelValue = ''
                if ($null -ne $entity.labels -and $null -ne $entity.labels.ar) { $labelValue = [string]$entity.labels.ar.value }
                if (-not [string]::IsNullOrWhiteSpace($labelValue) -and $labelValue -match '[\u0600-\u06FF]') {
                    Set-WikidataCacheValue -Key "arlabel:$qid" -Value $labelValue
                    $result[$qid] = $labelValue
                }
                else { try { $script:WikidataCache.PSObject.Properties.Remove("arlabel:$qid") } catch {} }
            }
            Save-WikidataCache
        }
        catch { Write-Warning "تعذر الحصول على التسميات من Wikidata: $($_.Exception.Message)" }
    }
    return $result
}

function Get-ArabicWikipediaDisambiguationBatch {
    param([Parameter(Mandatory)][array]$ArabicTitles)
    $result = @{}
    $items = [object[]]@($ArabicTitles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($items.Count -eq 0) { return $result }

    for ($i = 0; $i -lt $items.Count; $i += [int]$script:ApiSettings.BatchSize) {
        $end = [Math]::Min($i + [int]$script:ApiSettings.BatchSize - 1, $items.Count - 1)
        $batch = @($items[$i..$end])
        $titles = $batch -join '|'
        $encoded = [Uri]::EscapeDataString($titles)
        $url = "https://ar.wikipedia.org/w/api.php?action=query&prop=pageprops&ppprop=disambiguation&titles=$encoded&redirects=1&format=json&formatversion=2"
        try {
            $response = Invoke-WikiApiRequest -Uri $url -ApiName "Wikipedia"
            foreach ($page in @($response.query.pages)) {
                if ($null -eq $page -or [string]::IsNullOrWhiteSpace([string]$page.title)) { continue }
                $isDisambig = ($null -ne $page.pageprops -and $null -ne $page.pageprops.disambiguation)
                $result[[string]$page.title] = [bool]$isDisambig
            }
            foreach ($t in $batch) { if (-not $result.ContainsKey([string]$t)) { $result[[string]$t] = $false } }
        }
        catch { Write-Warning "فشل التحقق من صفحات التوضيح" }
    }
    return $result
}
