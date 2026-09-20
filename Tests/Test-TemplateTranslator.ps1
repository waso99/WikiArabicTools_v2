# ============================================
# Test-TemplateTranslator.ps1
# Deterministic regression tests for template handling.
# ============================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Modules\TemplateTranslator.ps1')

$map = Join-Path $root 'Templates\TemplateMap.json'

$input = @'
<!-- {{Campaignbox Golden Age of Piracy}} must remain untouched. -->
{{Campaignbox
|name=Campaignbox Golden Age of Piracy
|title=[[Golden Age of Piracy]]
}}
{{Campaignbox Golden Age of Piracy
|name=Campaignbox Golden Age of Piracy
}}
{{Outer
|nested={{Campaignbox Golden Age of Piracy}}
|link=[[Campaignbox Golden Age of Piracy|Campaignbox Golden Age of Piracy]]
|nestedRuleGuard={{OtherTemplate
|name=Campaignbox Golden Age of Piracy
}}
}}
<nowiki>{{Campaignbox Golden Age of Piracy}}</nowiki>
{{convert|10|kg|lb}}
{{cvt|5|ft|m}}
{{convert|10|kg|lb|abbr=on}}
{{convert|10|to|20|km|mi}}
{{convert|{{formatnum:1000}}|kg|lb}}
{{some_other|10|kg|lb}}
{{test|value=<!-- }} -->|second=value}}
{{test|value=<nowiki>}}</nowiki>|second=value}}
{{test|value=<ref>}}</ref>|second=value}}
{{test|value={{inner|x=1}}|second=value}}
{{test|value=[[A|B]]|second=value}}
'@

$expected = @'
<!-- {{Campaignbox Golden Age of Piracy}} must remain untouched. -->
{{Campaignbox
|name=صندوق حملة العصر الذهبي للقرصنة
|title=[[Golden Age of Piracy]]
}}
{{صندوق حملة العصر الذهبي للقرصنة
|name=Campaignbox Golden Age of Piracy
}}
{{Outer
|nested={{صندوق حملة العصر الذهبي للقرصنة}}
|link=[[Campaignbox Golden Age of Piracy|Campaignbox Golden Age of Piracy]]
|nestedRuleGuard={{OtherTemplate
|name=Campaignbox Golden Age of Piracy
}}
}}
<nowiki>{{Campaignbox Golden Age of Piracy}}</nowiki>
{{حول|10|kg|lb}}
{{حول مختصر|5|ft|m}}
{{حول|10|kg|lb|abbr=on}}
{{حول|10|to|20|km|mi}}
{{حول|{{formatnum:1000}}|kg|lb}}
{{some_other|10|kg|lb}}
{{test|value=<!-- }} -->|second=value}}
{{test|value=<nowiki>}}</nowiki>|second=value}}
{{test|value=<ref>}}</ref>|second=value}}
{{test|value={{inner|x=1}}|second=value}}
{{test|value=[[A|B]]|second=value}}
'@

$output = Convert-WikipediaTemplates -Text $input -MapPath $map

if ($output -ne $expected) {
    Write-Host 'Template test FAILED.' -ForegroundColor Red
    Write-Host 'Expected:'
    Write-Host $expected
    Write-Host 'Actual:'
    Write-Host $output
    exit 1
}

if ($TemplateStats.TemplatesFound -ne 18) { throw "Expected 18 templates, got $($TemplateStats.TemplatesFound)." }
if ($TemplateStats.TemplateNamesChanged -ne 7) { throw "Expected 7 renamed template names, got $($TemplateStats.TemplateNamesChanged)." }
if ($TemplateStats.ParameterValuesChanged -ne 1) { throw "Expected 1 parameter value change, got $($TemplateStats.ParameterValuesChanged)." }

Write-Host 'Template regression tests passed.' -ForegroundColor Green
Write-Host "Templates found: $($TemplateStats.TemplatesFound)"
Write-Host "Template names changed: $($TemplateStats.TemplateNamesChanged)"
Write-Host "Parameter values changed: $($TemplateStats.ParameterValuesChanged)"

# BUG #8: A triple-brace parameter may contain a nested template.
$bug8Input = '{{Template|value={{{parameter|{{Default}}}}}|second=value}}'

$bug8Start = $bug8Input.IndexOf('{{')
$bug8End = Find-TemplateEnd -Text $bug8Input -Start $bug8Start

if ($bug8End -ne $bug8Input.Length) {
    throw "BUG #8 regression: expected template end $($bug8Input.Length), got $bug8End."
}

$bug8Extracted = $bug8Input.Substring(0, $bug8End)

if ($bug8Extracted -ne $bug8Input) {
    throw "BUG #8 regression: template was truncated. Extracted: [$bug8Extracted]"
}

Write-Host 'BUG #8 regression test passed.' -ForegroundColor Green
# BUG #9: Triple-brace parameters may contain pipes, links,
# nested templates, and nested triple-brace parameters.
$bug9Cases = @(
    '{{Template|value={{{p|a=b}}}|second=value}}'
    '{{Template|value={{{p|a|b}}}|second=value}}'
    '{{Template|value={{{p|[[A|B]]}}}|second=value}}'
    '{{Template|value={{{p|{{Inner|x=y}}}}}|second=value}}'
    '{{Template|value={{{p|{{A|x={{B|y}}}}}}}|second=value}}'
    '{{Template|value={{{p|{{A|x=1}} text {{B|y=2}}}}}|second=value}}'
    '{{Template|value={{{p|{{{inner|{{A|x}}}}}}}}|second=value}}'
    '{{Template|value={{{p|{{A|x={{{q|{{B}}}}}}}}}}|second=value}}'
    '{{T|x={{{p|{{A}}}}}}}'
    '{{T|x={{{p|{{A|x=1}}}}}|y=2}}'
    '{{T|x={{{p|{{A|x={{B}}}}}}}|y=2}}'
    '{{T|x={{{p|{{A}}}}}|y={{B}}}}'
    '{{T|x={{{p|{{A|x={{{q|v}}}}}}}}|y=2}}'
)

foreach ($bug9Case in $bug9Cases) {
    $start = $bug9Case.IndexOf('{{')
    $end = Find-TemplateEnd -Text $bug9Case -Start $start

    if ($end -ne $bug9Case.Length) {
        throw "BUG #9 regression: expected template end $($bug9Case.Length), got $end. Input: [$bug9Case]"
    }
}

Write-Host "BUG #9 regression tests passed: $($bug9Cases.Count) cases." -ForegroundColor Green

# BUG #10: Protected blocks inside templates must not affect
# template boundary detection.
$bug10Cases = @(
    '{{T|x=<!-- {{Inner|a=1}} -->|y=2}}'
    '{{T|x=<!-- }} -->|y=2}}'
    '{{T|x=<nowiki>{{Inner|a=1}}</nowiki>|y=2}}'
    '{{T|x=<nowiki>}}</nowiki>|y=2}}'
    '{{T|x=<ref>{{Inner|a=1}}</ref>|y=2}}'
    '{{T|x=<ref>}}</ref>|y=2}}'
    '{{T|x=<math>{{Inner}}</math>|y=2}}'
    '{{T|x=<code>{{Inner}}</code>|y=2}}'
    '{{T|x=<pre>{{Inner}}</pre>|y=2}}'
)

foreach ($bug10Case in $bug10Cases) {
    $start = $bug10Case.IndexOf('{{')
    $end = Find-TemplateEnd -Text $bug10Case -Start $start

    if ($end -ne $bug10Case.Length) {
        throw "BUG #10 regression: expected template end $($bug10Case.Length), got $end. Input: [$bug10Case]"
    }
}

Write-Host "BUG #10 regression tests passed: $($bug10Cases.Count) cases." -ForegroundColor Green