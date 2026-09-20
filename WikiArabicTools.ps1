# ============================================
# WikiArabicTools
# ============================================
param([string]$Url,[string]$Title)
$ErrorActionPreference='Stop'
$VersionFile=Join-Path $PSScriptRoot 'VERSION.txt'
$Version=if(Test-Path $VersionFile){(Get-Content $VersionFile -Raw -Encoding UTF8).Trim()}else{'unknown'}
Write-Host "WikiArabicTools v$Version" -ForegroundColor Cyan
$ProjectRoot=$PSScriptRoot
$InputFile=Join-Path $ProjectRoot 'input.wiki'
$OutputFile=Join-Path $ProjectRoot 'output.wiki'
$UntranslatedFile=Join-Path $ProjectRoot 'untranslated-links.txt'
$SourceInfoFile=Join-Path $ProjectRoot 'source-info.txt'
$modulesPath=Join-Path $PSScriptRoot 'Modules'
. (Join-Path $modulesPath 'WikitextParser.ps1')
. (Join-Path $modulesPath 'WikipediaFetcher.ps1')
. (Join-Path $modulesPath 'Wikidata.ps1')
. (Join-Path $modulesPath 'LinkTranslator.ps1')
. (Join-Path $modulesPath 'TemplateTranslator.ps1')
. (Join-Path $modulesPath 'TextTranslator.ps1')

$text=$null;$sourceTitle=$null;$sourceType=$null;$pageId=$null
if(-not [string]::IsNullOrWhiteSpace($Url)){
    Write-Host "`nSource: Wikipedia URL" -ForegroundColor Cyan
    $requestedTitle=Get-WikipediaTitleFromUrl -Url $Url
    $article=Get-WikipediaWikitext -Title $requestedTitle
    $text=$article.Wikitext;$sourceTitle=$article.Title;$pageId=$article.PageId;$sourceType='Wikipedia URL'
}elseif(-not [string]::IsNullOrWhiteSpace($Title)){
    Write-Host "`nSource: Wikipedia article title" -ForegroundColor Cyan
    $article=Get-WikipediaWikitext -Title $Title
    $text=$article.Wikitext;$sourceTitle=$article.Title;$pageId=$article.PageId;$sourceType='Wikipedia Title'
}else{
    Write-Host "`nSource: input.wiki" -ForegroundColor Cyan
    if(-not (Test-Path $InputFile)){
        Write-Host 'input.wiki was not found. A new empty file will be created.' -ForegroundColor Yellow
        Set-Content -Path $InputFile -Value '<!-- ضع هنا نص Wikitext الإنجليزي الذي تريد معالجته -->' -Encoding UTF8
        Write-Host "Created: $InputFile" -ForegroundColor Cyan
        Write-Host 'Put Wikitext into the file and run the program again.' -ForegroundColor Yellow
        exit 1
    }
    $text=Get-Content -Path $InputFile -Raw -Encoding UTF8;$sourceTitle='input.wiki';$sourceType='Local File'
}
if([string]::IsNullOrWhiteSpace($text)){Write-Host 'Error: no content was found to process.' -ForegroundColor Red;exit 1}
Write-Host "Article: $sourceTitle" -ForegroundColor Green
if($pageId){Write-Host "Page ID: $pageId"}


Write-Host "`nProcessing Wikipedia templates..." -ForegroundColor Cyan
$result=Convert-WikipediaTemplates -Text $text

Write-Host "`nProcessing Wikipedia links..." -ForegroundColor Cyan
$result=Convert-WikipediaLinks -Text $result

Write-Host "`nTranslating safe visible text..." -ForegroundColor Cyan
# $result=Convert-WikipediaVisibleText -Text $result
Set-Content -Path $OutputFile -Value $result -Encoding UTF8
$sourceInfo=[System.Collections.Generic.List[string]]::new()
$sourceInfo.Add("WikiArabicTools version: $Version")
$sourceInfo.Add("Source type: $sourceType");$sourceInfo.Add("Title: $sourceTitle")
if($pageId){$sourceInfo.Add("Page ID: $pageId")};if($Url){$sourceInfo.Add("URL: $Url")}
$sourceInfo.Add("Retrieved: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
Set-Content -Path $SourceInfoFile -Value $sourceInfo -Encoding UTF8

$untranslated=@($script:UntranslatedLinks)
if($untranslated.Count -gt 0){
    $lines=[System.Collections.Generic.List[string]]::new();$number=1
    foreach($link in $untranslated){
        $lines.Add("$number. $($link.Title)")
        if(-not [string]::IsNullOrWhiteSpace([string]$link.QID)){$lines.Add("   QID: $($link.QID)")}
        if(-not [string]::IsNullOrWhiteSpace([string]$link.Section)){$lines.Add("   Section: #$($link.Section)")}
        $lines.Add("   Reason: $($link.Reason)");$lines.Add('');$number++
    }
    Set-Content -Path $UntranslatedFile -Value $lines -Encoding UTF8
}else{Set-Content -Path $UntranslatedFile -Value 'No untranslated links.' -Encoding UTF8}

Write-Host "`n============================================" -ForegroundColor Green
Write-Host '          WikiArabicTools Report' -ForegroundColor Green
Write-Host '============================================' -ForegroundColor Green
Write-Host "`nSource:                $sourceType"
Write-Host "Article:                $sourceTitle"
Write-Host "`nTemplates found:        $($TemplateStats.TemplatesFound)"
Write-Host "Templates changed:      $($TemplateStats.TemplatesChanged)"
Write-Host "`nTotal links:            $($LinkStats.Total)"
Write-Host "Translated:             $($LinkStats.Converted)" -ForegroundColor Green
Write-Host "Ill-WD2:                $($LinkStats.IllWD2)" -ForegroundColor Cyan
Write-Host "No Wikidata:          $($LinkStats.NoWikidata)" -ForegroundColor Yellow
Write-Host "No Arabic page:        $($LinkStats.NoArabic)" -ForegroundColor Yellow
Write-Host "Ignored:             $($LinkStats.Ignored)"
Write-Host "Protected items:            $($LinkStats.Protected)"
Write-Host "Section links:          $($LinkStats.SectionLinks)"
Write-Host "Visible text changed:   $($TextStats.Changed)"
if($script:CacheStats){Write-Host "`nCache Statistics:" -ForegroundColor Cyan;Write-Host "QID cache hits:             $($CacheStats.QidHits)";Write-Host "New QIDs:                 $($CacheStats.QidMisses)";Write-Host "Arabic page cache hits:     $($CacheStats.ArabicHits)";Write-Host "New Arabic pages:        $($CacheStats.ArabicMisses)"}
if($script:ApiStats){Write-Host "`nAPI Statistics:" -ForegroundColor Cyan;Write-Host "Wikipedia requests:          $($ApiStats.WikipediaRequests)";Write-Host "Wikidata requests:           $($ApiStats.WikidataRequests)";Write-Host "Successful requests:              $($ApiStats.SuccessfulRequests)" -ForegroundColor Green;Write-Host "Failed requests:              $($ApiStats.FailedRequests)"}
Write-Host "`nOutput:`n$OutputFile" -ForegroundColor Cyan
Write-Host "`nUntranslated links:`n$UntranslatedFile" -ForegroundColor Cyan
Write-Host "`nSource information:`n$SourceInfoFile" -ForegroundColor Cyan
Write-Host "`n============================================" -ForegroundColor Green

