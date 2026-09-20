# ============================================
# WikitextParser.ps1
# محلل Wikitext محافظ على النص الأصلي
# ============================================

$script:ProtectedTagNames = @(
    'nowiki','pre','code','syntaxhighlight','math','chem','score','timeline','gallery','ref'
)

$script:IgnoredNamespaces = @(
    'File','Image','Media','Category','Template','Help','Special','Module','Portal','Draft','TimedText'
)

function Test-WikitextStartsWith {
    param([string]$Text,[int]$Index,[string]$Value)
    if ($null -eq $Text -or $null -eq $Value) { return $false }
    if ($Index -lt 0 -or $Index + $Value.Length -gt $Text.Length) { return $false }
    return $Text.Substring($Index,$Value.Length) -ceq $Value
}

function Find-WikitextClosingTag {
    param([string]$Text,[int]$Start,[string]$TagName)
    $pattern = "</$TagName\s*>"
    $m = [regex]::Match($Text,$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase,[TimeSpan]::FromSeconds(10))
    while ($m.Success -and $m.Index -lt $Start) {
        $nextStart = $m.Index + $m.Length
        if ($nextStart -ge $Text.Length) { return -1 }
        $m = [regex]::Match($Text.Substring($nextStart),$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase,[TimeSpan]::FromSeconds(10))
        if ($m.Success) { $m = [System.Text.RegularExpressions.Match]::new() }
    }
    return -1
}

function Get-ClosingTagIndex {
    param([string]$Text,[int]$OpenIndex,[string]$TagName)
    $pattern = "</$([regex]::Escape($TagName))\s*>"
    $match = [regex]::Match($Text,$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    while ($match.Success -and $match.Index -le $OpenIndex) {
        $offset = $match.Index + $match.Length
        if ($offset -ge $Text.Length) { return -1 }
        $next = [regex]::Match($Text.Substring($offset),$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $next.Success) { return -1 }
        $match = [regex]::Match($Text,$pattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase,$offset)
    }
    if ($match.Success) { return $match.Index }
    return -1
}

function Add-WikitextToken {
    param([System.Collections.Generic.List[object]]$Tokens,[string]$Type,[int]$Start,[int]$End,[string]$Text,[hashtable]$Data)
    $obj = [ordered]@{ Type=$Type; Start=$Start; End=$End; Text=$Text }
    if ($Data) { foreach ($k in $Data.Keys) { $obj[$k]=$Data[$k] } }
    $Tokens.Add([PSCustomObject]$obj)
}

function Parse-InternalLink {
    param([string]$Raw,[int]$Start)
    $inner = $Raw.Substring(2,$Raw.Length-4)
    $parts = $inner.Split('|',2)
    $targetPart = $parts[0].Trim()
    $display = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    $section = $null
    $target = $targetPart
    $hash = $targetPart.IndexOf('#')
    if ($hash -ge 0) {
        $target = $targetPart.Substring(0,$hash).Trim()
        $section = $targetPart.Substring($hash+1)
    }
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    $namespace = $null
    $colon = $target.IndexOf(':')
    if ($colon -gt 0) { $namespace = $target.Substring(0,$colon).Trim() }
    [PSCustomObject]@{
        Type='InternalLink'; Start=$Start; End=$Start+$Raw.Length; Text=$Raw
        Target=$target; Section=$section; Display=$display; Namespace=$namespace
    }
}

function Get-WikitextTokens {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = [System.Collections.Generic.List[object]]::new()
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        # comments
        if (Test-WikitextStartsWith $Text $i '<!--') {
            $end = $Text.IndexOf('-->',$i+4,[System.StringComparison]::Ordinal)
            if ($end -lt 0) { $end=$n-3 }
            Add-WikitextToken $tokens 'Protected' $i ($end+3) $Text.Substring($i,$end+3-$i) @{ProtectedReason='comment'}
            $i=$end+3; continue
        }

        # protected/self-closing ref and common tags
        $tagMatch = [regex]::Match($Text.Substring($i),'^<\s*(nowiki|pre|code|syntaxhighlight|math|chem|score|timeline|gallery|ref)\b[^>]*>',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($tagMatch.Success) {
            $open = $tagMatch.Value
            $openEnd = $i + $tagMatch.Length
            $selfClosing = $open -match '/\s*>$'
            if ($selfClosing) {
                Add-WikitextToken $tokens 'Protected' $i $openEnd $open @{ProtectedReason='tag'}
                $i=$openEnd; continue
            }
            $tagName = ([regex]::Match($open,'<\s*([A-Za-z0-9]+)')).Groups[1].Value
            $closePattern = "</\s*$([regex]::Escape($tagName))\s*>"
            $close = [regex]::Match($Text.Substring($openEnd),$closePattern,[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($close.Success) {
                $end = $openEnd + $close.Index + $close.Length
            } else { $end=$n }
            Add-WikitextToken $tokens 'Protected' $i $end $Text.Substring($i,$end-$i) @{ProtectedReason='tag'}
            $i=$end; continue
        }

        # self-closing protected tags such as <br>, <hr>, <wbr>, <references />
        $self = [regex]::Match($Text.Substring($i),'^<\s*(br|hr|wbr|references)\b[^>]*?/\s*>',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($self.Success) {
            Add-WikitextToken $tokens 'Protected' $i ($i+$self.Length) $self.Value @{ProtectedReason='self-closing'}
            $i += $self.Length; continue
        }

        # IMPORTANT:
        # لا نحمي القوالب {{...}} ككتلة كاملة، لأن ذلك يمنع استخراج
        # الوصلات [[...]] الموجودة داخل معاملات القوالب.
        #
        # مثال:
        # {{معلومات كتاب
        # | المؤلف = [[John Smith]]
        # }}
        #
        # يجب أن تصل [[John Smith]] إلى Get-WikitextInternalLinks().
        # Parser لا يغيّر نص القالب نفسه؛ فهو يستخرج فقط InternalLink tokens،
        # لذلك لا توجد حاجة لحماية {{...}} هنا.

        # IMPORTANT:
        # لا نحمي الجداول {| ... |} ككتلة كاملة أيضًا، لأن الجداول في
        # ويكيبيديا تحتوي كثيرًا على وصلات داخل الخلايا.
        #
        # مثال:
        # {| class="wikitable"
        # | [[Military history]]
        # |}
        #
        # يجب أن تكون الوصلة قابلة للاستخراج والتعريب.
        #
        # نترك {{...}} و {| ... |} يمران إلى محلل الوصلات العادي.
        # علامات {{ }} و {| |} نفسها ليست InternalLink، لذلك لن تدخل
        # في Rebuild-Wikitext إلا إذا وُجد رابط داخلها.
        # internal links, including nested links in display text by finding balanced [[ ]]
        if (Test-WikitextStartsWith $Text $i '[[') {
            $depth=1; $j=$i+2
            while ($j -lt $n-1 -and $depth -gt 0) {
                if (Test-WikitextStartsWith $Text $j '[[') { $depth++; $j+=2; continue }
                if (Test-WikitextStartsWith $Text $j ']]') { $depth--; $j+=2; continue }
                $j++
            }
            if ($depth -eq 0) {
                $raw=$Text.Substring($i,$j-$i)
                $link=Parse-InternalLink $raw $i
                if ($link -and ($script:IgnoredNamespaces -notcontains $link.Namespace)) {
                    $tokens.Add($link)
                } else {
                    Add-WikitextToken $tokens 'Protected' $i $j $raw @{ProtectedReason='ignored-link'}
                }
                $i=$j; continue
            }
        }

        $tokens.Add([PSCustomObject]@{Type='Text';Start=$i;End=$i+1;Text=$Text.Substring($i,1)})
        $i++
    }
    return $tokens
}

function Get-WikitextInternalLinks {
    param([Parameter(Mandatory)][array]$Tokens)
    $links = [System.Collections.Generic.List[object]]::new()
    foreach ($token in $Tokens) {
        if ($token.Type -eq 'InternalLink') { $links.Add($token) }
    }
    return @($links)
}

function Rebuild-Wikitext {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][array]$Tokens,[Parameter(Mandatory)][hashtable]$Replacements)
    if ($Replacements.Count -eq 0) { return $Text }
    $ordered = @($Replacements.GetEnumerator() | Sort-Object {[int]$_.Key})
    $sb=[System.Text.StringBuilder]::new()
    $pos=0
    foreach ($r in $ordered) {
        $start=[int]$r.Key
        if ($start -lt $pos -or $start -gt $Text.Length) { continue }
        [void]$sb.Append($Text.Substring($pos,$start-$pos))
        [void]$sb.Append([string]$r.Value)
        $token = $Tokens | Where-Object { $_.Start -eq $start } | Select-Object -First 1
        if ($token) { $pos=$token.End } else { $pos=$start }
    }
    if ($pos -lt $Text.Length) { [void]$sb.Append($Text.Substring($pos)) }
    return $sb.ToString()
}
