param([switch]$SkipApiKeyPrompt)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot

Write-Host "WikiArabicTools setup" -ForegroundColor Cyan

$required = @(
    'WikiArabicTools.ps1',
    'VERSION.txt',
    'Modules\WikitextParser.ps1',
    'Modules\WikipediaFetcher.ps1',
    'Modules\Wikidata.ps1',
    'Modules\LinkTranslator.ps1',
    'Modules\TemplateTranslator.ps1',
    'Templates\TemplateMap.json'
)

foreach($file in $required){
    if(-not (Test-Path (Join-Path $root $file))){
        throw "Missing required file: $file"
    }
}

New-Item -ItemType Directory -Path (Join-Path $root 'Cache') -Force | Out-Null

Get-ChildItem -Path $root -Recurse -Filter *.ps1 -File | Unblock-File -ErrorAction SilentlyContinue

Write-Host "Version: $((Get-Content (Join-Path $root 'VERSION.txt') -Raw).Trim())" -ForegroundColor Green

$key=[Environment]::GetEnvironmentVariable('GEMINI_API_KEY','User')
if(-not $SkipApiKeyPrompt -and [string]::IsNullOrWhiteSpace($key)){
    $secure=Read-Host 'أدخل GEMINI_API_KEY أو اضغط Enter للتخطي' -AsSecureString
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    if(-not [string]::IsNullOrWhiteSpace($value)){
        [Environment]::SetEnvironmentVariable('GEMINI_API_KEY',$value,'User')
        Write-Host 'تم حفظ مفتاح Gemini كمتغير User.' -ForegroundColor Green
    }
}

Write-Host 'Setup completed.' -ForegroundColor Green
