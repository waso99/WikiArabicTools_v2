# ============================================
# Test-ArabicSitelinkResponse.ps1
# ============================================

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'Modules\Wikidata.ps1')

$arrayMock = @([pscustomobject]@{
    id = 'Q123'
    sitelinks = [pscustomobject]@{ arwiki = [pscustomobject]@{ title = 'عنوان عربي' } }
})

$objectMock = [pscustomobject]@{
    Q123 = [pscustomobject]@{
        id = 'Q123'
        sitelinks = [pscustomobject]@{ arwiki = [pscustomobject]@{ title = 'عنوان عربي' } }
    }
    Q456 = [pscustomobject]@{ id = 'Q456'; sitelinks = [pscustomobject]@{} }
}

foreach($shape in @($arrayMock, $objectMock)) {
    $items = @(Get-WikidataEntitiesCollection -Entities $shape)
    $found = $false
    foreach($entity in $items){
        if([string]$entity.id -eq 'Q123' -and [string]$entity.sitelinks.arwiki.title -eq 'عنوان عربي'){ $found = $true }
    }
    if(-not $found){ throw 'Arabic sitelink response parsing regression test failed for one of the supported response shapes.' }
}

# BUG #7: A failed Wikidata API request must not mark QIDs as successful.
$originalInvoke = ${function:Invoke-WikiApiRequest}

try {
    function Invoke-WikiApiRequest {
        param(
            [Parameter(Mandatory)][string]$Uri,
            [Parameter(Mandatory)]
            [ValidateSet("Wikipedia","Wikidata")]
            [string]$ApiName
        )

        return $null
    }

    $script:LastArabicSitelinkSuccess = @{}

    $null = Get-ArabicWikipediaTitlesBatch -WikidataIds @(
        'Q12345'
        'Q67890'
    )

    if ($script:LastArabicSitelinkSuccess.ContainsKey('Q12345') -or
        $script:LastArabicSitelinkSuccess.ContainsKey('Q67890')) {
        throw 'BUG #7 regression: failed Wikidata API request was marked as successful.'
    }

    Write-Host 'BUG #7 regression test passed.' -ForegroundColor Green
}
finally {
    ${function:Invoke-WikiApiRequest} = $originalInvoke
}

Write-Host 'Arabic sitelink response regression tests passed.'


# Regression test for Get-ArabicWikipediaTitlesBatch with PSCustomObject
$script:ApiSettings = [pscustomobject]@{ BatchSize = 50 }
$mockEntities = [pscustomobject]@{
    Q13917 = [pscustomobject]@{
        id = 'Q13917'
        sitelinks = [pscustomobject]@{
            arwiki = [pscustomobject]@{
                title = 'إيل دو فرانس'
            }
        }
    }
    Q1607 = [pscustomobject]@{
        id = 'Q1607'
        sitelinks = [pscustomobject]@{
            arwiki = [pscustomobject]@{
                title = 'بلانكنيزا'
            }
        }
    }
    Q55 = [pscustomobject]@{
        id = 'Q55'
        sitelinks = [pscustomobject]@{
            arwiki = [pscustomobject]@{
                title = 'هولندا'
            }
        }
    }
}
function Invoke-WikiApiRequest {
    param($Uri, $ApiName)
    return [pscustomobject]@{ entities = $mockEntities }
}
$testQids = @('Q13917', 'Q1607', 'Q55')
$result = Get-ArabicWikipediaTitlesBatch -WikidataIds $testQids
if ($result['Q13917'] -ne 'إيل دو فرانس' -or $result['Q1607'] -ne 'بلانكنيزا' -or $result['Q55'] -ne 'هولندا') {
    throw 'Get-ArabicWikipediaTitlesBatch regression test failed! Did not parse PSCustomObject properties correctly.'
}
Write-Host 'Get-ArabicWikipediaTitlesBatch PSCustomObject regression test passed.' -ForegroundColor Green
