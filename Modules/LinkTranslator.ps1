# ============================================
# LinkTranslator.ps1
# ترجمة روابط ويكيبيديا باستخدام Wikidata
# ============================================

$script:LinkStats=[ordered]@{Total=0;Converted=0;IllWD2=0;NoWikidata=0;NoArabic=0;Ignored=0;Protected=0;SectionLinks=0;DisplayTranslated=0}
$script:UntranslatedLinks=@()

# ============================================
# LinkTranslator.ps1
# ترجمة روابط ويكيبيديا باستخدام Wikidata
# ============================================

$script:LinkStats=[ordered]@{Total=0;Converted=0;IllWD2=0;NoWikidata=0;NoArabic=0;Ignored=0;Protected=0;SectionLinks=0;DisplayTranslated=0}

$script:LinkDisplayTranslationCachePath = Join-Path $PSScriptRoot '..\Cache\LinkDisplayTranslationCache.json'

function Get-LinkDisplayTranslationCache {
    if (-not (Test-Path -LiteralPath $script:LinkDisplayTranslationCachePath)) { return @{} }
    try {
        $obj = Get-Content -LiteralPath $script:LinkDisplayTranslationCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cache = @{}
        foreach ($p in $obj.PSObject.Properties) { $cache[[string]$p.Name] = [string]$p.Value }
        return $cache
    } catch {
        return @{}
    }
}

function Save-LinkDisplayTranslationCache {
    param([Parameter(Mandatory)][hashtable]$Cache)
    try {
        $dir = Split-Path -Parent $script:LinkDisplayTranslationCachePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:LinkDisplayTranslationCachePath -Encoding UTF8
    } catch {
        Write-Warning "Could not save LinkDisplayTranslationCache.json: $($_.Exception.Message)"
    }
}

function Get-LinkTranslatorSetting {
    param([Parameter(Mandatory)][string]$Name,[string]$Default='')
    $value = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($Name,'User') }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($Name,'Machine') }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    if ($null -ne $value) { $value = $value.Trim().Trim('"').Trim() }
    return $value
}

function Invoke-GeminiLinkDisplayTranslations {
    param([Parameter(Mandatory)][array]$Contexts)

    $apiKey = Get-LinkTranslatorSetting -Name 'GEMINI_API_KEY'
    if ([string]::IsNullOrWhiteSpace($apiKey)) { return @{} }

    $model = Get-LinkTranslatorSetting -Name 'GEMINI_MODEL' 'gemini-1.5-flash-latest'

    $pendingBatches = @()
    $batchSizeText = Get-LinkTranslatorSetting -Name 'GEMINI_BATCH_SIZE' '10'
    $batchSize = 10
    if ([int]::TryParse($batchSizeText, [ref]$batchSize)) {
        if ($batchSize -lt 1) { $batchSize = 1 }
        if ($batchSize -gt 20) { $batchSize = 20 }
    } else {
        $batchSize = 10
    }

    $currentBatch = @()
    foreach ($ctx in $Contexts) {
        $currentBatch += $ctx
        if ($currentBatch.Count -ge $batchSize) {
            $pendingBatches += ,$currentBatch
            $currentBatch = @()
        }
    }
    if ($currentBatch.Count -gt 0) { $pendingBatches += ,$currentBatch }

    $result = @{}
    foreach ($batch in $pendingBatches) {
        $promptObj = @()
        foreach ($ctx in $batch) {
            $promptObj += @{
                EnglishTitle = $ctx.EnglishTitle
                ArabicTitle = $ctx.ArabicTitle
                EnglishDisplay = $ctx.EnglishDisplay
                ArabicWikidataLabel = $ctx.ArabicWikidataLabel
                SafeDisplay = $ctx.SafeDisplay
                CacheKey = $ctx.CacheKey
            }
        }
        $promptJson = $promptObj | ConvertTo-Json -Depth 5 -Compress

        $prompt = "You are a professional Wikipedia translator. Your task is to translate/arabize ONLY the 'EnglishDisplay' text. \nFollow these strict rules:\n1. EnglishTitle and ArabicTitle are provided ONLY for semantic context. DO NOT automatically replace EnglishDisplay with ArabicTitle unless they truly mean the same thing.\n2. If EnglishDisplay is a proper name, transliterate it to Arabic (e.g. 'John' -> 'جون'). Translate adjectives and nouns (e.g. 'Castilian' -> 'القشتالية').\n3. The translated string MUST contain Arabic characters. DO NOT return the English string unchanged.\n4. If SafeDisplay contains placeholders like <WA_SAFE_1>, you MUST preserve them exactly in the Arabic text, with the exact same count.\n5. Output MUST be valid JSON, where keys are exactly the CacheKey provided, and values are the translated Arabic strings. No markdown, no extra text.\nInput: $promptJson"

        $body = @{
            contents = @(
                @{
                    parts = @(
                        @{ text = $prompt }
                    )
                }
            )
            generationConfig = @{ temperature = 0.1 }
        } | ConvertTo-Json -Depth 10

        try {
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey"
            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body

            $jsonText = $response.candidates[0].content.parts[0].text
            $jsonText = $jsonText -replace '^```json\s*', '' -replace '\s*```$', ''

            $batchResult = $jsonText | ConvertFrom-Json

            foreach ($p in $batchResult.PSObject.Properties) {
                $val = [string]$p.Value
                if ($val -notmatch '[\u0600-\u06FF]') { continue }
                $result[[string]$p.Name] = $val
            }
        } catch {
            Write-Warning "Gemini API failure for link display translations: $($_.Exception.Message)"
        }
    }
    return $result
}

$script:UntranslatedLinks=@()

function New-ArabicWikipediaLink {
    param(
        [Parameter(Mandatory)][string]$ArabicTitle,
        [string]$Section,
        [string]$Display
    )

    $baseTarget = $ArabicTitle.Trim()
    $target = $baseTarget

    if (-not [string]::IsNullOrWhiteSpace($Section)) {
        $target += "#$Section"
    }

    if ([string]::IsNullOrEmpty($Display)) {
        return "[[$target]]"
    }

    $displayTrimmed = $Display.Trim()

    # إذا كان النص الظاهر مطابقًا لعنوان الصفحة العربية،
    # لا تنشئ رابطًا بصيغة [[العنوان|العنوان]].
    if ([string]::Equals(
        $displayTrimmed,
        $baseTarget,
        [StringComparison]::Ordinal
    )) {
        return "[[$target]]"
    }

    return "[[$target|$displayTrimmed]]"
}

function Add-UntranslatedLink {
    param([Parameter(Mandatory)]$Link,[string]$QID,[Parameter(Mandatory)][string]$Reason)
    $script:UntranslatedLinks += [PSCustomObject]@{Title=$Link.Target;QID=$QID;Section=$Link.Section;Display=$Link.Display;Reason=$Reason}
}
# ============================================

function Get-DisplayTranslationMap {
    if ($null -ne $script:DisplayTranslationMapCache) { return $script:DisplayTranslationMapCache }
    $path = Join-Path $PSScriptRoot '..\Templates\DisplayTranslationMap.json'
    if (-not (Test-Path -LiteralPath $path)) { $script:DisplayTranslationMapCache = @{}; return @{} }
    try {
        $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($item in @($obj)) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Source)) {
                $map[[string]$item.Source] = [string]$item.Target
            }
        }
        $script:DisplayTranslationMapCache = $map
        return $map
    } catch {
        Write-Warning "Could not read DisplayTranslationMap.json: $($_.Exception.Message)"
        $script:DisplayTranslationMapCache = @{}
        return @{}
    }
}

function New-ArabicWikipediaLink {
    param([Parameter(Mandatory)][string]$ArabicTitle,[string]$Section,[string]$Display)
    $target=$ArabicTitle.Trim()
    if(-not [string]::IsNullOrWhiteSpace($Section)){$target += "#$Section"}
    if([string]::IsNullOrEmpty($Display)){return "[[$target]]"}
    return "[[$target|$Display]]"
}
function Add-UntranslatedLink {
    param([Parameter(Mandatory)]$Link,[string]$QID,[Parameter(Mandatory)][string]$Reason)
    $script:UntranslatedLinks += [PSCustomObject]@{Title=$Link.Target;QID=$QID;Section=$Link.Section;Display=$Link.Display;Reason=$Reason}
}
# ============================================

function Get-DisplayTranslationMap {
    if ($null -ne $script:DisplayTranslationMapCache) { return $script:DisplayTranslationMapCache }
    $path = Join-Path $PSScriptRoot '..\Templates\DisplayTranslationMap.json'
    if (-not (Test-Path -LiteralPath $path)) { $script:DisplayTranslationMapCache = @{}; return @{} }
    try {
        $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($item in @($obj)) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Source)) {
                $map[[string]$item.Source] = [string]$item.Target
            }
        }
        $script:DisplayTranslationMapCache = $map
        return $map
    } catch {
        Write-Warning "Could not read DisplayTranslationMap.json: $($_.Exception.Message)"
        $script:DisplayTranslationMapCache = @{}
        return @{}
    }
}

function Get-DeterministicArabicDisplay {
    param(
        [string]$Display,
        [string]$EnglishTitle,
        [string]$ArabicTitle,
        [string]$ArabicWikidataLabel
    )

    if ([string]::IsNullOrWhiteSpace($Display)) { return $null }
    $displayTrimmed = $Display.Trim()

    $map = Get-DisplayTranslationMap
    if ($map.ContainsKey($displayTrimmed) -and -not [string]::IsNullOrWhiteSpace([string]$map[$displayTrimmed])) {
        return [string]$map[$displayTrimmed]
    }

    # If visible text exactly matches the English source title or a disambiguation base,
    # use the resolved Arabic page title or Arabic Wikidata label.
    if (-not [string]::IsNullOrWhiteSpace($EnglishTitle)) {
        $engTrim = $EnglishTitle.Trim()

        # Exact match
        if ([string]::Equals($displayTrimmed, $engTrim, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not [string]::IsNullOrWhiteSpace($ArabicTitle)) { return $ArabicTitle.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($ArabicWikidataLabel) -and $ArabicWikidataLabel -match '[\u0600-\u06FF]') {
                return $ArabicWikidataLabel.Trim()
            }
        }

        # Short-name match: when the visible text is the leading name of the
        # full English title (for example, "Alessandro Farnese" vs.
        # "Alessandro Farnese, Duke of Parma and Piacenza"), use the Arabic
        # page title/label and omit the redundant English display text.
        if ($engTrim -match '^(.+?)(?:,| - | – | — )' -and
            [string]::Equals($displayTrimmed, $Matches[1].Trim(), [StringComparison]::OrdinalIgnoreCase)) {
            if (-not [string]::IsNullOrWhiteSpace($ArabicTitle)) { return $ArabicTitle.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($ArabicWikidataLabel) -and $ArabicWikidataLabel -match '[\u0600-\u06FF]') {
                return $ArabicWikidataLabel.Trim()
            }
        }

        # Prefix + short-name match: translate titles such as "prince Alessandro Farnese"
        # while keeping the resolved Arabic person name. This is deterministic and does
        # not depend on Gemini being available.
        $shortEnglishName = $null
        if ($engTrim -match '^(.+?)(?:,| - | – | — )') {
            $shortEnglishName = $Matches[1].Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($shortEnglishName) -and
            $displayTrimmed -match '^(.*?)\s*' + [regex]::Escape($shortEnglishName) + '\s*$' -and
            -not [string]::Equals($displayTrimmed, $shortEnglishName, [StringComparison]::OrdinalIgnoreCase)) {
            $prefix = $displayTrimmed.Substring(0, $displayTrimmed.Length - $shortEnglishName.Length).Trim()
            $prefixMap = @{
                'prince'='الأمير'; 'princess'='الأميرة'; 'king'='الملك'; 'queen'='الملكة';
                'duke'='الدوق'; 'duchess'='الدوقة'; 'lord'='اللورد'; 'lady'='الليدي';
                'count'='الكونت'; 'countess'='الكونتيسة'; 'earl'='الإيرل'; 'baron'='البارون';
                'baroness'='البارونة'; 'sir'='السير'; 'saint'='القديس'; 'pope'='البابا'
            }
            $prefixKey = $prefix.Trim()
            if ($prefixMap.ContainsKey($prefixKey.ToLowerInvariant())) {
                $arName = $ArabicTitle
                if ([string]::IsNullOrWhiteSpace($arName)) { $arName = $ArabicWikidataLabel }
                if (-not [string]::IsNullOrWhiteSpace($arName) -and $arName -match '[\u0600-\u06FF]') {
                    return ($prefixMap[$prefixKey.ToLowerInvariant()] + ' ' + $arName.Trim()).Trim()
                }
            }
        }

        # Disambiguation stripping match
        $engParenIndex = $engTrim.IndexOf(' (')
        if ($engParenIndex -gt 0) {
            $engBase = $engTrim.Substring(0, $engParenIndex)
            if ([string]::Equals($displayTrimmed, $engBase, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not [string]::IsNullOrWhiteSpace($ArabicTitle)) {
                    $arParenIndex = $ArabicTitle.IndexOf(' (')
                    if ($arParenIndex -gt 0) {
                        return $ArabicTitle.Substring(0, $arParenIndex).Trim()
                    }
                    return $ArabicTitle.Trim()
                }
                if (-not [string]::IsNullOrWhiteSpace($ArabicWikidataLabel) -and $ArabicWikidataLabel -match '[\u0600-\u06FF]') {
                    $wdParenIndex = $ArabicWikidataLabel.IndexOf(' (')
                    if ($wdParenIndex -gt 0) {
                        return $ArabicWikidataLabel.Substring(0, $wdParenIndex).Trim()
                    }
                    return $ArabicWikidataLabel.Trim()
                }
            }
        }
    }

    # By default, preserve the original author's display text to avoid data loss.
    return $displayTrimmed
}

function Convert-WikipediaLinks {
    param([Parameter(Mandatory)][string]$Text)
    $script:LinkStats=[ordered]@{Total=0;Converted=0;IllWD2=0;NoWikidata=0;NoArabic=0;Ignored=0;Protected=0;SectionLinks=0;DisplayTranslated=0}
    $script:UntranslatedLinks=@()
    Write-Host "`nAnalyzing Wikitext..." -ForegroundColor Cyan
    $tokens=Get-WikitextTokens -Text $Text
    $links=@(Get-WikitextInternalLinks -Tokens $tokens)
    $script:LinkStats.Total=$links.Count
    Write-Host "Found $($links.Count) processable links." -ForegroundColor Gray
    if($links.Count -eq 0){return $Text}
    $uniqueTitles=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase); $filteredLinks = @(); foreach($link in $links){ if ($link.Target -match "[a-zA-Z]") { [void]$uniqueTitles.Add($link.Target); $filteredLinks += $link; } else { $script:LinkStats.Ignored++; } }; $links = $filteredLinks;
    Write-Host "Unique titles: $($uniqueTitles.Count)" -ForegroundColor Gray
    $resolution=Resolve-WikipediaLinksBatch -EnglishTitles @($uniqueTitles)

    # For links with no Arabic Wikipedia page, retrieve the Arabic Wikidata label
    # so they can be represented with {{Ill-WD2|...|id=Q...|نص=...}}.
    $illWdLabels=@{}
    $illWdQids=[System.Collections.Generic.List[string]]::new()
    foreach($candidate in $links){
        if(-not $resolution.ContainsKey($candidate.Target)){ continue }
        $candidateResolution=$resolution[$candidate.Target]
        $candidateQid=[string]$candidateResolution.QID
        $candidateArabicTitle=[string]$candidateResolution.ArabicTitle
        if(-not [string]::IsNullOrWhiteSpace($candidateQid)){
            if(-not $illWdQids.Contains($candidateQid)){ [void]$illWdQids.Add($candidateQid) }
        }
    }
    if($illWdQids.Count -gt 0){
        $illWdLabels=Get-ArabicWikidataLabelsBatch -WikidataIds @($illWdQids)
        if($null -ne $script:WikidataLabelCacheStats){
            Write-Host "Arabic Wikidata labels: cache hits = $($script:WikidataLabelCacheStats.Hits) | misses = $($script:WikidataLabelCacheStats.Misses) | API requests = $($script:WikidataLabelCacheStats.ApiRequests)" -ForegroundColor DarkGray
        }
    }

    # Gather missing displays for Gemini
    $geminiContexts = @()
    $geminiLinks = @()
    foreach($link in $links){
        if (-not $resolution.ContainsKey($link.Target)) { continue }
        $arabicTitle = $resolution[$link.Target].ArabicTitle
        if ([string]::IsNullOrWhiteSpace($arabicTitle)) { continue }

        $displayText = [string]$link.Display
        if ([string]::IsNullOrEmpty($displayText)) { continue }

        $deterministicDisplay = Get-DeterministicArabicDisplay -Display $displayText -EnglishTitle $link.Target -ArabicTitle $arabicTitle -ArabicWikidataLabel $null

        $isFallbackToTitle = (
            $deterministicDisplay -eq $arabicTitle -and
            [string]::Equals(
                $displayText.Trim(),
                $link.Target.Trim(),
                [StringComparison]::OrdinalIgnoreCase
            )
        )

        if (-not $isFallbackToTitle) {
            if (-not [string]::IsNullOrWhiteSpace($deterministicDisplay) -and $deterministicDisplay -ne $displayText) {
                # Handled deterministically
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($deterministicDisplay) -and $deterministicDisplay -match '[\u0600-\u06FF]') {
                continue
            }
        }

        # Protect placeholders
        $dispTokens = Get-WikitextTokens -Text $displayText
        $hasFindTemplateEnd = [bool](Get-Command Find-TemplateEnd -ErrorAction SilentlyContinue)
        $hasFindWikitextParameterEnd = [bool](Get-Command Find-WikitextParameterEnd -ErrorAction SilentlyContinue)

        $phId = 1
        $phMap = @()
        $sbPh = [System.Text.StringBuilder]::new()
        $i = 0
        while ($i -lt $displayText.Length) {
            $t = $null
            foreach ($tok in $dispTokens) {
                if ($tok.Start -eq $i -and $tok.Type -ne 'Text') {
                    $t = $tok; break
                }
            }
            if ($t) {
                $ph = "<WA_SAFE_$phId>"
                [void]$sbPh.Append($ph)
                $phMap += $displayText.Substring($t.Start, $t.End - $t.Start)
                $phId++
                $i = $t.End
                continue
            }

            if ($hasFindWikitextParameterEnd -and $i + 2 -lt $displayText.Length -and
                $displayText[$i] -eq '{' -and $displayText[$i + 1] -eq '{' -and $displayText[$i + 2] -eq '{') {
                $end = Find-WikitextParameterEnd -Text $displayText -Start $i
                if ($end -gt $i) {
                    $ph = "<WA_SAFE_$phId>"
                    [void]$sbPh.Append($ph)
                    $phMap += $displayText.Substring($i, $end - $i)
                    $phId++
                    $i = $end
                    continue
                }
            }

            if ($hasFindTemplateEnd -and $i + 1 -lt $displayText.Length -and
                $displayText[$i] -eq '{' -and $displayText[$i + 1] -eq '{') {
                $end = Find-TemplateEnd -Text $displayText -Start $i
                if ($end -gt $i) {
                    $ph = "<WA_SAFE_$phId>"
                    [void]$sbPh.Append($ph)
                    $phMap += $displayText.Substring($i, $end - $i)
                    $phId++
                    $i = $end
                    continue
                }
            }

            [void]$sbPh.Append($displayText[$i])
            $i++
        }
        $safeDisplay = $sbPh.ToString()

        $textToTranslate = $safeDisplay -replace '<WA_SAFE_\d+>', ''
        if ($textToTranslate -notmatch '[a-zA-Z]') {
            continue
        }

        $cacheKey = "$($link.Target):::$displayText"
        $geminiContexts += @{
            EnglishTitle = $link.Target
            ArabicTitle = $arabicTitle
            EnglishDisplay = $displayText
            ArabicWikidataLabel = $null
            SafeDisplay = $safeDisplay
            CacheKey = $cacheKey
            PlaceholderMap = $phMap
        }
        $geminiLinks += $link
    }

    $geminiTranslations = @{}
    if ($geminiContexts.Count -gt 0) {
        $cache = Get-LinkDisplayTranslationCache
        $needsApi = @()
        foreach ($ctx in $geminiContexts) {
            if ($cache.ContainsKey($ctx.CacheKey)) {
                $geminiTranslations[$ctx.CacheKey] = $cache[$ctx.CacheKey]
            } else {
                $needsApi += $ctx
            }
        }
        if ($needsApi.Count -gt 0) {
            Write-Host "Invoking Gemini for $($needsApi.Count) link displays..." -ForegroundColor Magenta
            $apiResults = Invoke-GeminiLinkDisplayTranslations -Contexts $needsApi
            $hasUpdates = $false
            foreach ($ctx in $needsApi) {
                $k = $ctx.CacheKey
                if (-not $apiResults.ContainsKey($k)) { continue }
                $rawTrans = [string]$apiResults[$k]
                if ([string]::IsNullOrWhiteSpace($rawTrans)) { continue }
                if ($rawTrans -notmatch '[\u0600-\u06FF]') { continue }
                if ([string]::Equals($rawTrans, $ctx.EnglishDisplay, [StringComparison]::OrdinalIgnoreCase)) { continue }

                $valid = $true
                if ($ctx.PlaceholderMap.Count -gt 0) {
                    $map = $ctx.PlaceholderMap
                    $pidMatches = [regex]::Matches($rawTrans, "<WA_SAFE_(\d+)>")
                    $foundPids = @{}
                    foreach ($m in $pidMatches) { $foundPids[[int]$m.Groups[1].Value]++ }
                    if ($foundPids.Count -ne $map.Count) {
                        $valid = $false
                    } else {
                        for ($k_ph = 1; $k_ph -le $map.Count; $k_ph++) {
                            if (-not $foundPids.ContainsKey($k_ph) -or $foundPids[$k_ph] -ne 1) { $valid = $false; break }
                        }
                    }
                }
                if ($valid) {
                    $geminiTranslations[$k] = $rawTrans
                    $cache[$k] = $rawTrans
                    $hasUpdates = $true
                }
            }
            if ($hasUpdates) { Save-LinkDisplayTranslationCache -Cache $cache }
        }
    }

    $replacements=@{}
    foreach($link in $links){
        $title=$link.Target
        if(-not $resolution.ContainsKey($title)){
            $script:LinkStats.NoWikidata++;Add-UntranslatedLink -Link $link -Reason 'لا يوجد عنصر Wikidata مرتبط بالصفحة.';continue
        }
        $qid=[string]$resolution[$title].QID
        $arabicTitle=$resolution[$title].ArabicTitle
        if([string]::IsNullOrWhiteSpace([string]$arabicTitle)){
            $script:LinkStats.NoArabic++

            # No Arabic sitelink, but an Arabic Wikidata label exists: use Ill-WD2.
            $wdLabel=$null
            if(-not [string]::IsNullOrWhiteSpace($qid) -and $illWdLabels.ContainsKey($qid)){
                $wdLabel=[string]$illWdLabels[$qid]
            }

            # Use Ill-WD2 only when Wikidata has a genuine Arabic label.
            # A non-empty label written only in Latin/other scripts is not enough.
            $hasArabicWikidataLabel = (
                -not [string]::IsNullOrWhiteSpace($wdLabel) -and
                $wdLabel -match '[\u0600-\u06FF]'
            )

            if($hasArabicWikidataLabel){
                $illTarget=$wdLabel.Trim()
                if(-not [string]::IsNullOrWhiteSpace($link.Section)){
                    $illTarget += "#$($link.Section)"
                    $script:LinkStats.SectionLinks++
                }

                $displayText=[string]$link.Display
                if(-not [string]::IsNullOrEmpty($displayText)){
                    $deterministicDisplay=Get-DeterministicArabicDisplay `
                        -Display $displayText `
                        -EnglishTitle ([string]$link.Target) `
                        -ArabicTitle $null `
                        -ArabicWikidataLabel $wdLabel
                    if(-not [string]::IsNullOrWhiteSpace([string]$deterministicDisplay)){
                        $displayText=$deterministicDisplay
                    }
                }

                if([string]::IsNullOrEmpty($displayText)){
                    $newLink="{{Ill-WD2|$illTarget|id=$qid}}"
                }
                else {
                    $newLink="{{Ill-WD2|$illTarget|id=$qid|نص=$displayText}}"
                }

                if($newLink -ne $link.Text){
                    $replacements[[int]$link.Start]=$newLink
                    $script:LinkStats.IllWD2++
                    $script:LinkStats.Converted++
                }
                continue
            }

            Add-UntranslatedLink -Link $link -QID $qid -Reason 'No Arabic Wikipedia page and no Arabic Wikidata label.'
            continue
        }
        if(-not [string]::IsNullOrWhiteSpace($link.Section)){$script:LinkStats.SectionLinks++}
        $wdLabel = $null; if (-not [string]::IsNullOrWhiteSpace($qid) -and $illWdLabels.ContainsKey($qid)) { $wdLabel = [string]$illWdLabels[$qid] }; $arabicDisplay = Get-DeterministicArabicDisplay -Display ([string]$link.Display) -EnglishTitle ([string]$link.Target) -ArabicTitle ([string]$arabicTitle) -ArabicWikidataLabel $wdLabel

        # If the original display is only the leading name of a longer English
        # target title, force the Arabic page title as the display. This prevents
        # links such as [[ألساندرو فارنيزي|Alessandro Farnese]].
        if (-not [string]::IsNullOrWhiteSpace([string]$link.Display) -and
            -not [string]::IsNullOrWhiteSpace([string]$arabicTitle)) {
            $displayTrimmed = ([string]$link.Display).Trim()
            $englishTrimmed = ([string]$link.Target).Trim()
            $englishShortName = $null

            if ($englishTrimmed -match '^(.+?)(?:,|\s+-\s+|\s+–\s+|\s+—\s+)') {
                $englishShortName = $Matches[1].Trim()
            }

            if ($null -ne $englishShortName -and
                [string]::Equals($displayTrimmed, $englishShortName, [StringComparison]::OrdinalIgnoreCase)) {
                $arabicDisplay = ([string]$arabicTitle).Trim()
            }
        }

        if (-not [string]::IsNullOrEmpty($link.Display)) {
            $cacheKey = "$($link.Target):::$($link.Display)"
            if ($geminiTranslations.ContainsKey($cacheKey)) {
                $rawTrans = $geminiTranslations[$cacheKey]

                $ctx = $null
                foreach ($c in $geminiContexts) {
                    if ($c.CacheKey -eq $cacheKey) { $ctx = $c; break }
                }

                if ($ctx -and $ctx.PlaceholderMap.Count -gt 0) {
                    for ($k = 1; $k -le $ctx.PlaceholderMap.Count; $k++) {
                        $rawTrans = $rawTrans.Replace("<WA_SAFE_$k>", $ctx.PlaceholderMap[$k-1])
                    }
                }
                $arabicDisplay = $rawTrans
                $script:LinkStats.DisplayTranslated++
            }
        }

        $newLink=New-ArabicWikipediaLink -ArabicTitle $arabicTitle -Section $link.Section -Display $arabicDisplay

        if($newLink -eq $link.Text){continue}

        $replacements[[int]$link.Start]=$newLink
        $script:LinkStats.Converted++
    }
    Write-Host "`nRebuilding Wikitext..." -ForegroundColor Cyan
    return Rebuild-Wikitext -Text $Text -Tokens $tokens -Replacements $replacements
}




