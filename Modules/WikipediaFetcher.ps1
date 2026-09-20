# ============================================
# WikipediaFetcher.ps1
# جلب Wikitext من Wikipedia
# ============================================

function Get-WikipediaLanguageFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    try { $uri=[System.Uri]$Url } catch { throw "رابط Wikipedia غير صالح: $Url" }
    if(-not [string]::Equals($uri.Host,'en.wikipedia.org',[StringComparison]::OrdinalIgnoreCase)){ throw 'الرابط يجب أن يكون من Wikipedia الإنجليزية (en.wikipedia.org).' }
    return 'en'
}

function Get-WikipediaTitleFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    try { $uri=[System.Uri]$Url } catch { throw "رابط Wikipedia غير صالح: $Url" }
    if(-not [string]::Equals($uri.Host,'en.wikipedia.org',[StringComparison]::OrdinalIgnoreCase)){ throw 'الرابط يجب أن يكون من Wikipedia الإنجليزية (en.wikipedia.org).' }
    $segments=$uri.AbsolutePath.Trim('/').Split('/')
    if($segments.Count -lt 2 -or $segments[0] -ne 'wiki'){ throw "لم أتمكن من استخراج عنوان المقالة من الرابط: $Url" }
    return [System.Uri]::UnescapeDataString(($segments[1..($segments.Count-1)] -join '/')).Replace('_',' ')
}

function Get-WikipediaWikitext {
    param([Parameter(Mandatory)][string]$Title,[string]$Language='en')
    if([string]::IsNullOrWhiteSpace($Language)){$Language='en'}
    $apiHost="$Language.wikipedia.org"
    $encoded=[System.Uri]::EscapeDataString($Title)
    $url="https://$apiHost/w/api.php?action=query&prop=revisions&rvprop=content&rvslots=main&titles=$encoded&format=json&formatversion=2&maxlag=5"
    try {
        $versionFile=Join-Path $PSScriptRoot '..\VERSION.txt'
        $version=if(Test-Path -LiteralPath $versionFile){(Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()}else{'unknown'}
        $userAgent="WikiArabicTools/$version (Wikitext converter; https://github.com/waso99/WikiArabicTools)"
        $response=Invoke-RestMethod -Uri $url -Method Get -Headers @{'User-Agent'=$userAgent} -ErrorAction Stop
    } catch { throw "فشل جلب المقالة من Wikipedia: $($_.Exception.Message)" }
    $page=@($response.query.pages)[0]
    if($null -eq $page -or $page.missing){throw "لم يتم العثور على المقالة: $Title"}
    $content=$null
    if($null -ne $page.revisions -and $page.revisions.Count -gt 0){$content=[string]$page.revisions[0].slots.main.content}
    if([string]::IsNullOrWhiteSpace($content)){throw "المقالة موجودة ولكن لم يتم العثور على Wikitext: $($page.title)"}
    [PSCustomObject]@{Title=[string]$page.title;PageId=[string]$page.pageid;Wikitext=$content;Language=$Language}
}
