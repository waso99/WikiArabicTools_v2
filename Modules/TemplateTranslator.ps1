# ============================================
# TemplateTranslator.ps1
# Safe template-name and parameter-value translation
# PowerShell 5.1 compatible
# ============================================

$script:TemplateStats = [ordered]@{
    TemplatesFound = 0
    TemplatesChanged = 0
    TemplateNamesChanged = 0
    ParameterValuesChanged = 0
}

function Get-NormalizedTemplateName {
    param([AllowNull()][string]$Name)
    if ($null -eq $Name) { return '' }
    $n = $Name.Trim().Replace('_',' ')
    $n = [regex]::Replace($n, '\s+', ' ')
    if ($n.StartsWith('Template:', [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring(9).Trim() }
    return $n
}

function Get-NormalizedTemplateValue {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return [regex]::Replace($Value.Trim().Replace('_',' '), '\s+', ' ')
}

function Get-TemplateMap {
    param([string]$MapPath)
    if (-not (Test-Path -LiteralPath $MapPath)) { return @() }
    $raw = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $parsed = $raw | ConvertFrom-Json
        foreach ($item in @($parsed)) {
            Write-Output $item
        }
    }
    catch { throw "تعذر قراءة TemplateMap.json: $($_.Exception.Message)" }
}

function Get-LeadingWhitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $i=0
    while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
    if ($i -eq 0) { return '' }
    return $Text.Substring(0,$i)
}

function Get-TrailingWhitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $i=$Text.Length-1
    while ($i -ge 0 -and [char]::IsWhiteSpace($Text[$i])) { $i-- }
    if ($i -eq $Text.Length-1) { return '' }
    return $Text.Substring($i+1)
}

function Find-TemplateEnd {

    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Start
    )

    # Stack entries:
    #   T = normal template {{ ... }}
    #   P = triple-brace parameter {{{ ... }}}
    #
    # The stack is deliberately used instead of separate counters.
    # This is important when a normal template occurs inside a
    # triple-brace parameter:
    #
    #   {{{parameter|{{Default}}}}}
    #
    # In that case the }} belonging to {{Default}} must close only
    # the nested template, while }}} closes the parameter.

    $stack = [System.Collections.Generic.Stack[string]]::new()
    $i = $Start

    while ($i -lt $Text.Length - 1) {

        # ------------------------------------------------------------
        # HTML comments are opaque.
        # ------------------------------------------------------------
        if (
            $i + 3 -lt $Text.Length -and
            $Text[$i] -eq '<' -and
            $Text[$i + 1] -eq '!' -and
            $Text[$i + 2] -eq '-' -and
            $Text[$i + 3] -eq '-'
        ) {
            $endComment = $Text.IndexOf(
                '-->',
                $i + 4,
                [System.StringComparison]::Ordinal
            )

            if ($endComment -ge 0) {
                $i = $endComment + 3
                continue
            }
        }

        # ------------------------------------------------------------
        # Protected Wikitext blocks are opaque.
        # ------------------------------------------------------------
        if ($Text[$i] -eq '<') {

            $protected = [regex]::Match(
                $Text.Substring($i),
                '^<\s*(nowiki|pre|code|syntaxhighlight|math|chem|score|timeline|gallery|ref)\b[^>]*>',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($protected.Success) {

                $open = $protected.Value
                $openEnd = $i + $protected.Length

                # Self-closing protected tag.
                if ($open -match '/\s*>$') {
                    $i = $openEnd
                    continue
                }

                $tagName = (
                    [regex]::Match(
                        $open,
                        '<\s*([A-Za-z0-9]+)'
                    )
                ).Groups[1].Value

                $closePattern = (
                    '</\s*' +
                    [regex]::Escape($tagName) +
                    '\s*>'
                )

                $close = [regex]::Match(
                    $Text.Substring($openEnd),
                    $closePattern,
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )

                if ($close.Success) {
                    $i = $openEnd + $close.Index + $close.Length
                    continue
                }
            }
        }

        # ------------------------------------------------------------
        # Open triple-brace parameter.
        #
        # Check this BEFORE normal {{ so {{{ is never interpreted
        # as a normal template followed by another construct.
        # ------------------------------------------------------------
        if (
            $i + 2 -lt $Text.Length -and
            $Text.Substring($i, 3) -eq '{{{'
        ) {
            $stack.Push('P')
            $i += 3
            continue
        }

        # ------------------------------------------------------------
        # Open normal template.
        # ------------------------------------------------------------
        if (
            $i + 1 -lt $Text.Length -and
            $Text.Substring($i, 2) -eq '{{'
        ) {
            $stack.Push('T')
            $i += 2
            continue
        }

        # ------------------------------------------------------------
        # Close triple-brace parameter.
        #
        # A }}} is valid only when P is currently on top of the stack.
        # This prevents a parameter from closing while a nested template
        # inside that parameter is still open.
        # ------------------------------------------------------------
        if (
            $i + 2 -lt $Text.Length -and
            $Text.Substring($i, 3) -eq '}}}'
        ) {
            if ($stack.Count -gt 0 -and $stack.Peek() -eq 'P') {
                [void]$stack.Pop()
                $i += 3

                if ($stack.Count -eq 0) {
                    return $i
                }

                continue
            }
        }

        # ------------------------------------------------------------
        # Close normal template.
        #
        # A }} is valid only when T is currently on top of the stack.
        # ------------------------------------------------------------
        if (
            $i + 1 -lt $Text.Length -and
            $Text.Substring($i, 2) -eq '}}'
        ) {
            if ($stack.Count -gt 0 -and $stack.Peek() -eq 'T') {
                [void]$stack.Pop()
                $i += 2

                if ($stack.Count -eq 0) {
                    return $i
                }

                continue
            }
        }

        $i++
    }

    # -1 means that the Wikitext started at $Start but never reached
    # a balanced closing construct.
    return -1
}

function Convert-OneTemplateParameterSegment {
    param(
        [Parameter(Mandatory)][string]$Segment,
        [Parameter(Mandatory)][object[]]$Rules
    )

    $eq = $Segment.IndexOf('=')
    if ($eq -lt 0) { return $Segment }

    $left = $Segment.Substring(0, $eq)
    $value = $Segment.Substring($eq + 1)
    $parameterName = $left.Trim()
    if ([string]::IsNullOrWhiteSpace($parameterName)) { return $Segment }

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        $wantedParameter = ([string]$rule.Parameter).Trim()
        if (-not [string]::Equals($parameterName, $wantedParameter, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $sourceValue = Get-NormalizedTemplateValue ([string]$rule.SourceValue)
        $currentValue = Get-NormalizedTemplateValue $value
        if (-not [string]::Equals($currentValue, $sourceValue, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $leading = Get-LeadingWhitespace $value
        $trailing = Get-TrailingWhitespace $value
        $target = ([string]$rule.TargetValue).Trim()
        $script:TemplateStats.ParameterValuesChanged++
        $script:TemplateStats.TemplatesChanged++
        return $left + '=' + $leading + $target + $trailing
    }

    return $Segment
}

function Convert-TopLevelParameterValues {
    param(
        [Parameter(Mandatory)][string]$TemplateText,
        [Parameter(Mandatory)][object[]]$Rules
    )

    $rulesArray = @($Rules)
    if ($rulesArray.Count -eq 0 -or [string]::IsNullOrEmpty($TemplateText)) { return $TemplateText }
    if ($TemplateText.Length -lt 4 -or -not $TemplateText.StartsWith('{{') -or -not $TemplateText.EndsWith('}}')) { return $TemplateText }

    $segments = [System.Collections.Generic.List[object]]::new()
    $templateDepth = 1
    $linkDepth = 0
    $segmentStart = 2
    $i = 2
    $n = $TemplateText.Length - 2

    while ($i -lt $n) {
        # Ignore HTML comments inside the template while finding top-level pipes.
        if ($i + 3 -lt $TemplateText.Length -and $TemplateText.Substring($i,4) -eq '<!--') {
            $commentEnd = $TemplateText.IndexOf('-->', $i + 4, [StringComparison]::Ordinal)
            if ($commentEnd -ge 0) { $i = $commentEnd + 3; continue }
        }

        # Ignore protected Wikitext blocks while finding top-level pipes.
        $tagMatch = [regex]::Match(
            $TemplateText.Substring($i),
            '^<\s*(nowiki|pre|code|syntaxhighlight|math|chem|score|timeline|gallery|ref)\b[^>]*>',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($tagMatch.Success) {
            $open = $tagMatch.Value
            $openEnd = $i + $tagMatch.Length
            if ($open -match '/\s*>$') { $i = $openEnd; continue }
            $tagName = ([regex]::Match($open,'<\s*([A-Za-z0-9]+)')).Groups[1].Value
            $closePattern = "</\s*$([regex]::Escape($tagName))\s*>"
            $close = [regex]::Match($TemplateText.Substring($openEnd), $closePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($close.Success) { $i = $openEnd + $close.Index + $close.Length; continue }
            $i = $TemplateText.Length - 2
            continue
        }

        # Ignore {{{parameter}}} placeholders as opaque values.
        if ($i + 2 -lt $TemplateText.Length - 2 + 3 -and $TemplateText.Substring($i,3) -eq '{{{') {
            $j = $i + 3
            while ($j -lt $n) {
                if ($j + 2 -lt $TemplateText.Length -and $TemplateText.Substring($j,3) -eq '}}}') {
                    $i = $j + 3
                    break
                }
                $j++
            }
            if ($j -ge $n) { break }
            continue
        }

        if ($i + 1 -lt $TemplateText.Length - 2 + 2 -and $TemplateText.Substring($i,2) -eq '[[') {
            $linkDepth++
            $i += 2
            continue
        }
        if ($linkDepth -gt 0 -and $i + 1 -lt $TemplateText.Length - 2 + 2 -and $TemplateText.Substring($i,2) -eq ']]') {
            $linkDepth--
            $i += 2
            continue
        }

        if ($i + 1 -lt $TemplateText.Length - 2 + 2 -and $TemplateText.Substring($i,2) -eq '{{') {
            $templateDepth++
            $i += 2
            continue
        }
        if ($i + 1 -lt $TemplateText.Length - 2 + 2 -and $TemplateText.Substring($i,2) -eq '}}') {
            if ($templateDepth -gt 1) { $templateDepth-- }
            $i += 2
            continue
        }

        if ($templateDepth -eq 1 -and $linkDepth -eq 0 -and $TemplateText[$i] -eq '|') {
            $segments.Add([PSCustomObject]@{ Start=$segmentStart; End=$i })
            $segmentStart = $i + 1
        }
        $i++
    }

    $segments.Add([PSCustomObject]@{ Start=$segmentStart; End=$TemplateText.Length - 2 })

    $sb = [System.Text.StringBuilder]::new()
    $pos = 0
    $changed = $false

    foreach ($segment in $segments) {
        if ($segment.Start -lt 2 -or $segment.End -lt $segment.Start) { continue }
        $original = $TemplateText.Substring($segment.Start, $segment.End - $segment.Start)
        $converted = Convert-OneTemplateParameterSegment -Segment $original -Rules $rulesArray
        [void]$sb.Append($TemplateText.Substring($pos, $segment.Start - $pos))
        [void]$sb.Append($converted)
        if ($converted -ne $original) { $changed = $true }
        $pos = $segment.End
    }

    [void]$sb.Append($TemplateText.Substring($pos))
    if (-not $changed) { return $TemplateText }
    return $sb.ToString()
}

function Convert-TemplateText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$RenameMap,
        [Parameter(Mandatory)][hashtable]$ParameterValueRules
    )

    $out = [System.Text.StringBuilder]::new()
    $i = 0
    $n = $Text.Length

    while ($i -lt $n) {
        # Skip HTML comments as opaque text.
        if ($i + 3 -lt $n -and
            $Text[$i] -eq '<' -and $Text[$i+1] -eq '!' -and
            $Text[$i+2] -eq '-' -and $Text[$i+3] -eq '-') {
            $ce = $Text.IndexOf('-->', $i + 4, [StringComparison]::Ordinal)
            if ($ce -ge 0) {
                [void]$out.Append($Text.Substring($i, $ce + 3 - $i))
                $i = $ce + 3
                continue
            }
        }

        # Keep Wikitext protected blocks opaque so template rules never change
        # content inside nowiki/pre/code/math/ref and similar tags.
        if ($i -lt $n -and $Text[$i] -eq '<') {
            $protected = [regex]::Match(
                $Text.Substring($i),
                '^<\s*(nowiki|pre|code|syntaxhighlight|math|chem|score|timeline|gallery|ref)\b[^>]*>',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if ($protected.Success) {
                $open = $protected.Value
                $openEnd = $i + $protected.Length
                if ($open -match '/\s*>$') {
                    [void]$out.Append($open)
                    $i = $openEnd
                    continue
                }
                $tagName = ([regex]::Match($open,'<\s*([A-Za-z0-9]+)')).Groups[1].Value
                $closePattern = "</\s*$([regex]::Escape($tagName))\s*>"
                $close = [regex]::Match($Text.Substring($openEnd), $closePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($close.Success) {
                    $endProtected = $openEnd + $close.Index + $close.Length
                    [void]$out.Append($Text.Substring($i, $endProtected - $i))
                    $i = $endProtected
                    continue
                }
                [void]$out.Append($Text.Substring($i))
                break
            }
        }

        # Detect a template start by characters, not by a boolean expression
        # containing nested Substring calls. This is PowerShell 5.1 safe.
        $isTemplate = $false
        if ($i + 1 -lt $n -and $Text[$i] -eq '{' -and $Text[$i+1] -eq '{') {
            if (-not ($i + 2 -lt $n -and $Text[$i+2] -eq '{')) {
                $isTemplate = $true
            }
        }

        if ($isTemplate) {
            $nameStart = $i + 2
            $j = $nameStart

            while ($j -lt $n) {
                if ($Text[$j] -eq '|') { break }
                if ($j + 1 -lt $n -and $Text[$j] -eq '}' -and $Text[$j+1] -eq '}') { break }
                $j++
            }

            if ($j -gt $nameStart) {
                $rawName = $Text.Substring($nameStart, $j - $nameStart)
                $normalized = Get-NormalizedTemplateName $rawName
                $end = Find-TemplateEnd -Text $Text -Start $i

                if ($end -gt $i) {
                    $script:TemplateStats.TemplatesFound++
                    $templateText = $Text.Substring($i, $end - $i)
                    $originalNormalized = $normalized

                    if ($RenameMap.ContainsKey($normalized)) {
                        $replacement = ([string]$RenameMap[$normalized]).Trim()
                        $leading = Get-LeadingWhitespace $rawName
                        $trailing = Get-TrailingWhitespace $rawName
                        $suffix = $templateText.Substring($j - $i)
                        $templateText = '{{' + $leading + $replacement + $trailing + $suffix
                        $normalized = Get-NormalizedTemplateName $replacement
                        $script:TemplateStats.TemplateNamesChanged++
                        $script:TemplateStats.TemplatesChanged++
                    }

                    # Apply parameter-value rules attached either to the original
                    # template name or to the renamed target name. This makes a
                    # RenameTemplate rule composable with typed parameter rules.
                    $rulesForTemplate = @()
                    if ($ParameterValueRules.ContainsKey($originalNormalized)) {
                        $rulesForTemplate += @($ParameterValueRules[$originalNormalized])
                    }
                    if ($normalized -ne $originalNormalized -and $ParameterValueRules.ContainsKey($normalized)) {
                        $rulesForTemplate += @($ParameterValueRules[$normalized])
                    }
                    if ($rulesForTemplate.Count -gt 0) {
                        $templateText = Convert-TopLevelParameterValues `
                            -TemplateText $templateText `
                            -Rules $rulesForTemplate
                    }

                    # Recursively process nested templates inside this template,
                    # but never recurse over the current outer {{...}} itself.
                    if ($templateText.Length -gt 4) {
                        $inner = $templateText.Substring(2, $templateText.Length - 4)
                        $innerConverted = Convert-TemplateText `
                            -Text $inner `
                            -RenameMap $RenameMap `
                            -ParameterValueRules $ParameterValueRules
                        if ($innerConverted -ne $inner) {
                            $templateText = '{{' + $innerConverted + '}}'
                        }
                    }

                    [void]$out.Append($templateText)
                    $i = $end
                    continue
                }
            }
        }

        [void]$out.Append($Text[$i])
        $i++
    }

    return $out.ToString()
}

function Convert-WikipediaTemplates {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$MapPath=$(Join-Path $PSScriptRoot '..\Templates\TemplateMap.json')
    )
    $script:TemplateStats=[ordered]@{
        TemplatesFound=0
        TemplatesChanged=0
        TemplateNamesChanged=0
        ParameterValuesChanged=0
    }
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $rules=@(Get-TemplateMap -MapPath $MapPath)
    $renameMap=@{}
    $parameterValueRules=@{}

    foreach ($rule in $rules) {
        if ($null -eq $rule) { continue }
        $action=[string]$rule.Action
        if ($action -eq 'RenameTemplate') {
            $source=Get-NormalizedTemplateName ([string]$rule.Source)
            if ($source) { $renameMap[$source]=([string]$rule.Target).Trim() }
        }
        elseif ($action -eq 'RenameParameterValue') {
            $template=Get-NormalizedTemplateName ([string]$rule.Template)
            if (-not $template) { continue }
            if (-not $parameterValueRules.ContainsKey($template)) {
                $parameterValueRules[$template] = @()
            }
            $parameterValueRules[$template] = @($parameterValueRules[$template]) + @($rule)
        }
    }

    if ($renameMap.Count -eq 0 -and $parameterValueRules.Count -eq 0) { return $Text }
    return Convert-TemplateText -Text $Text -RenameMap $renameMap -ParameterValueRules $parameterValueRules
}
