# ============================================
# TextTranslator.ps1
# ترجمة النصوص الظاهرة الآمنة في Wikitext
# ============================================

$script:TextStats = [ordered]@{
    Candidates = 0
    Changed = 0
    GeminiRequests = 0
    GeminiFailures = 0
    CacheHits = 0
    CacheMisses = 0
}

$script:TextTranslationCachePath = Join-Path $PSScriptRoot '..\Cache\TextTranslationCache.json'

# Deterministic translations for established historical section labels.
# These override Gemini output so terminology remains stable across runs.
$script:DeterministicTextTranslations = @{
    'Buccaneering Period' = 'فترة البوكانير'
    'Pirate Round' = 'جولة القراصنة'
    'Post-Spanish Succession' = 'ما بعد حرب الخلافة الإسبانية'
}

function Get-TextTranslationCache {
    if (-not (Test-Path -LiteralPath $script:TextTranslationCachePath)) { return @{} }
    try {
        $obj = Get-Content -LiteralPath $script:TextTranslationCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cache = @{}
        foreach ($p in $obj.PSObject.Properties) { $cache[[string]$p.Name] = [string]$p.Value }
        return $cache
    } catch {
        Write-Warning "تعذر قراءة TextTranslationCache.json: $($_.Exception.Message)"
        return @{}
    }
}

function Save-TextTranslationCache {
    param([Parameter(Mandatory)][hashtable]$Cache)
    try {
        $dir = Split-Path -Parent $script:TextTranslationCachePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:TextTranslationCachePath -Encoding UTF8
    } catch {
        Write-Warning "تعذر حفظ TextTranslationCache.json: $($_.Exception.Message)"
    }
}

function Get-TextTranslatorSetting {
    param([Parameter(Mandatory)][string]$Name,[string]$Default='')
    $value = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($Name,'User') }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($Name,'Machine') }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    if ($null -ne $value) { $value = $value.Trim().Trim('"').Trim() }
    return $value
}

function Invoke-GeminiPlainTextTranslations {
    param([Parameter(Mandatory)][string[]]$Texts)

    $apiKey = Get-TextTranslatorSetting -Name 'GEMINI_API_KEY'
    if ([string]::IsNullOrWhiteSpace($apiKey)) { return @{} }

    $model = Get-TextTranslatorSetting -Name 'GEMINI_MODEL' -Default 'gemini-3.5-flash'
    $fallback = Get-TextTranslatorSetting -Name 'GEMINI_FALLBACK_MODEL' -Default 'gemini-3.5-flash-lite'
    $batchSize = 10
    $rawBatch = Get-TextTranslatorSetting -Name 'GEMINI_BATCH_SIZE' -Default '10'
    $parsed = 0
    if ([int]::TryParse($rawBatch,[ref]$parsed) -and $parsed -ge 1 -and $parsed -le 20) { $batchSize = $parsed }

    $result = @{}
    for ($offset = 0; $offset -lt $Texts.Count; $offset += $batchSize) {
        $end = [Math]::Min($offset + $batchSize - 1, $Texts.Count - 1)
        $batch = @($Texts[$offset..$end])
        $items = for ($i = 0; $i -lt $batch.Count; $i++) { "{0}. {1}" -f ($i + 1), $batch[$i] }

        $prompt = @"
You are an English-to-Arabic translator for Arabic Wikipedia.

Translate each English visible label below into concise, natural, formal Modern Standard Arabic.
These strings are short Wikitext definition-list headings or labels.

STRICT OUTPUT:
- Return exactly one line for every numbered input.
- Format: NUMBER<TAB>ARABIC TRANSLATION
- Return only translations.
- Do not repeat English.
- Do not use Markdown or Wikitext.
- Preserve proper names and established Arabic terminology when appropriate.

$($items -join "`n")
"@

        $body = @{
            contents = @(@{ parts = @(@{ text = $prompt }) })
            generationConfig = @{ temperature = 0.1 }
        } | ConvertTo-Json -Depth 10

        $models = @($model)
        if ($fallback -and $fallback -ne $model) { $models += $fallback }
        $response = $null

        foreach ($m in $models) {
            try {
                $uri = "https://generativelanguage.googleapis.com/v1beta/models/$m`:generateContent"
                $script:TextStats.GeminiRequests++
                $response = Invoke-RestMethod -Uri $uri -Method Post `
                    -Headers @{'x-goog-api-key'=$apiKey;'Accept'='application/json'} `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body $body -ErrorAction Stop
                break
            } catch {
                if ($m -eq $models[-1]) {
                    $script:TextStats.GeminiFailures++
                    Write-Warning "فشل Gemini في ترجمة النصوص الظاهرة: $($_.Exception.Message)"
                } else {
                    Write-Warning "فشل النموذج الأساسي؛ ستتم تجربة النموذج البديل."
                }
            }
        }

        if ($null -eq $response -or $null -eq $response.candidates -or $response.candidates.Count -eq 0) { continue }
        $raw = [string]$response.candidates[0].content.parts[0].text
        foreach ($line in @($raw -split "`r?`n")) {
            if ($line -match '^\s*(\d+)\s*[\.\)\-:]?\s*[\t ]+(.+?)\s*$') {
                $num = [int]$Matches[1]
                $translation = $Matches[2].Trim()
                if ($num -ge 1 -and $num -le $batch.Count -and $translation -and $translation -notmatch '[{}\[\]]') {
                    $result[$batch[$num - 1]] = $translation
                }
            }
        }
    }
    return $result
}

function Find-WikitextParameterEnd {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Start
    )

    if ($Start + 2 -ge $Text.Length -or
        $Text[$Start] -ne '{' -or
        $Text[$Start + 1] -ne '{' -or
        $Text[$Start + 2] -ne '{') {
        return -1
    }

    $parameterDepth = 1
    $templateDepth = 0
    $i = $Start + 3

    while ($i -lt $Text.Length) {
        if ($i + 2 -lt $Text.Length -and
            $Text[$i] -eq '{' -and
            $Text[$i + 1] -eq '{' -and
            $Text[$i + 2] -eq '{') {
            $parameterDepth++
            $i += 3
            continue
        }

        if ($i + 1 -lt $Text.Length -and
            $Text[$i] -eq '{' -and
            $Text[$i + 1] -eq '{') {
            $templateDepth++
            $i += 2
            continue
        }

        if ($templateDepth -gt 0 -and
            $i + 1 -lt $Text.Length -and
            $Text[$i] -eq '}' -and
            $Text[$i + 1] -eq '}') {
            $templateDepth--
            $i += 2
            continue
        }

        if ($templateDepth -eq 0 -and
            $i + 2 -lt $Text.Length -and
            $Text[$i] -eq '}' -and
            $Text[$i + 1] -eq '}' -and
            $Text[$i + 2] -eq '}') {
            $parameterDepth--
            $i += 3
            if ($parameterDepth -eq 0) {
                return $i
            }
            continue
        }

        $i++
    }

    return -1
}

function Convert-WikipediaVisibleText {
    param([Parameter(Mandatory)][string]$Text)

    $script:TextStats = [ordered]@{
        Candidates = 0; Changed = 0; GeminiRequests = 0; GeminiFailures = 0; CacheHits = 0; CacheMisses = 0
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    # Safe scope: only definition-list labels at the beginning of a line.
    # We intentionally do not translate arbitrary prose here because Wikitext
    # can contain syntax, names, parameters, tables, and code that must remain exact.
    # Protected tags are masked with spaces first so even a line beginning with ';'
    # inside <ref>, <nowiki>, <code>, etc. can never be translated.
    $masked = $Text.ToCharArray()
    $tokens = Get-WikitextTokens -Text $Text
    foreach ($token in $tokens) {
        if ($token.Type -eq 'Protected') {
            $start = [int]$token.Start
            $end = [int]$token.End
            for ($i = $start; $i -lt $end -and $i -lt $masked.Length; $i++) { $masked[$i] = ' ' }
        }
    }
    $maskedText = -join $masked
    $pattern = '(?m)^(?<prefix>[ \t]*;)(?<value>[^\r\n]+)\r?$'
    $definitionMatches = [regex]::Matches($maskedText, $pattern)
    if ($definitionMatches.Count -eq 0) { return $Text }

    $cache = Get-TextTranslationCache
    $pending = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($m in $definitionMatches) {
        $valueStart = $m.Groups['value'].Index
        $valueLength = $m.Groups['value'].Length
        $value = $Text.Substring($valueStart, $valueLength)
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value -match '[\u0600-\u06FF]' -and $value -notmatch '[A-Za-z]') { continue }
        $script:TextStats.Candidates++

        # Use deterministic terminology before consulting the cache/Gemini.
        if ($script:DeterministicTextTranslations.ContainsKey($value)) {
            $cache[$value] = [string]$script:DeterministicTextTranslations[$value]
            $script:TextStats.CacheHits++
            continue
        }

        if ($cache.ContainsKey($value)) { $script:TextStats.CacheHits++; continue }
        $script:TextStats.CacheMisses++
        if (-not $seen.ContainsKey($value)) {
            $seen[$value] = $true
            $pending.Add($value)
        }
    }

    $translations = @{}
    if ($pending.Count -gt 0) {
        $geminiInputs = [System.Collections.Generic.List[string]]::new()
        $placeholderMaps = @{}
        $originalToPlaceholderized = @{}
        $hasFindTemplateEnd = [bool](Get-Command Find-TemplateEnd -ErrorAction SilentlyContinue)

        foreach ($orig in $pending) {
            $tokens = Get-WikitextTokens -Text $orig
            $sbPh = [System.Text.StringBuilder]::new()
            $map = [System.Collections.Generic.List[string]]::new()
            $phId = 1

            $i = 0
            while ($i -lt $orig.Length) {
                $t = $null
                foreach ($tok in $tokens) {
                    if ($tok.Start -eq $i -and $tok.Type -ne 'Text') {
                        $t = $tok
                        break
                    }
                }

                if ($t) {
                    $ph = "<WA_SAFE_$phId>"
                    [void]$sbPh.Append($ph)
                    $map.Add($orig.Substring($t.Start, $t.End - $t.Start))
                    $phId++
                    $i = $t.End
                    continue
                }

                # Triple-brace template parameters must be protected before
                # ordinary double-brace templates. Otherwise {{{parameter}}}
                # would become {<WA_SAFE_1>}, leaving one Wikitext brace exposed.
                if ($i + 2 -lt $orig.Length -and
                    $orig[$i] -eq '{' -and
                    $orig[$i + 1] -eq '{' -and
                    $orig[$i + 2] -eq '{') {
                    $end = Find-WikitextParameterEnd -Text $orig -Start $i
                    if ($end -gt $i) {
                        $ph = "<WA_SAFE_$phId>"
                        [void]$sbPh.Append($ph)
                        $map.Add($orig.Substring($i, $end - $i))
                        $phId++
                        $i = $end
                        continue
                    }
                }

                if ($hasFindTemplateEnd -and $i+1 -lt $orig.Length -and $orig[$i] -eq '{' -and $orig[$i+1] -eq '{') {
                    $end = Find-TemplateEnd -Text $orig -Start $i
                    if ($end -gt $i) {
                        $ph = "<WA_SAFE_$phId>"
                        [void]$sbPh.Append($ph)
                        $map.Add($orig.Substring($i, $end - $i))
                        $phId++
                        $i = $end
                        continue
                    }
                }

                [void]$sbPh.Append($orig[$i])
                $i++
            }

            $phStr = $sbPh.ToString()
            $placeholderMaps[$orig] = $map
            $originalToPlaceholderized[$orig] = $phStr
            if (-not $geminiInputs.Contains($phStr)) {
                $geminiInputs.Add($phStr)
            }
        }

        $rawTranslations = Invoke-GeminiPlainTextTranslations -Texts @($geminiInputs)

        foreach ($orig in $pending) {
            if (-not $originalToPlaceholderized.ContainsKey($orig)) { continue }
            $phStr = $originalToPlaceholderized[$orig]
            if (-not $rawTranslations.ContainsKey($phStr)) { continue }

            $trans = [string]$rawTranslations[$phStr]
            $map = $placeholderMaps[$orig]

            $valid = $true
            $pidMatches = [regex]::Matches($trans, "<WA_SAFE_(\d+)>")
            $foundPids = @{}
            foreach ($m in $pidMatches) {
                $foundPids[[int]$m.Groups[1].Value]++
            }

            if ($foundPids.Count -ne $map.Count) {
                $valid = $false
            } else {
                for ($k = 1; $k -le $map.Count; $k++) {
                    if (-not $foundPids.ContainsKey($k) -or $foundPids[$k] -ne 1) {
                        $valid = $false
                        break
                    }
                }
            }

            if ($valid) {
                for ($k = 1; $k -le $map.Count; $k++) {
                    $trans = $trans.Replace("<WA_SAFE_$k>", $map[$k-1])
                }
                $cache[$orig] = $trans
            } else {
                Write-Warning "Gemini translation rejected due to missing, duplicated, or unknown placeholders: $orig"
            }
        }
        Save-TextTranslationCache -Cache $cache
    }

    if ($definitionMatches.Count -eq 0) { return $Text }
    $sb = [System.Text.StringBuilder]::new()
    $pos = 0
    foreach ($m in $definitionMatches) {
        $valueStart = $m.Groups['value'].Index
        $valueEnd = $valueStart + $m.Groups['value'].Length
        [void]$sb.Append($Text.Substring($pos, $valueStart - $pos))
        $old = $Text.Substring($valueStart, $m.Groups['value'].Length)
        $new = $old
        if ($cache.ContainsKey($old) -and -not [string]::IsNullOrWhiteSpace([string]$cache[$old])) {
            $new = [string]$cache[$old]
        }
        [void]$sb.Append($new)
        if ($new -ne $old) { $script:TextStats.Changed++ }
        $pos = $valueEnd
    }
    [void]$sb.Append($Text.Substring($pos))
    return $sb.ToString()
}
