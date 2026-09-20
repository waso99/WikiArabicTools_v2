# WikiArabicTools 1.3.9

أداة PowerShell لمعالجة Wikitext في ويكيبيديا، وتحويل روابط ويكيبيديا الإنجليزية إلى العربية اعتمادًا على Wikipedia وWikidata، مع ترجمة عناوين القوائم والنصوص الظاهرة الآمنة بواسطة Gemini عند الحاجة فقط، بينما تتم معالجة نصوص عرض الروابط حتميًا دون استدعاء Gemini من LinkTranslator، ودعم إعادة تسمية القوالب من خلال `Templates\TemplateMap.json`.

## المزايا

- استخراج الروابط الداخلية من Wikitext مع الحفاظ على النص الأصلي قدر الإمكان.
- حل العناوين الإنجليزية إلى QID واسم المقالة العربية باستخدام Wikipedia وWikidata.
- Cache محلي لتقليل الطلبات المتكررة.
- إنشاء `{{Ill-WD2}}` عندما لا توجد مقالة عربية لكن تتوفر تسمية عربية في Wikidata وتتوفر بقية الشروط.
- ترجمة نص العرض حتميًا من العنوان العربي أو من `Templates\DisplayTranslationMap.json` دون استدعاء Gemini من `LinkTranslator`.
- إنشاء `{{Ill-WD2}}` عند توفر QID وتسمية عربية في Wikidata دون ترجمة نص العرض الأصلي.
- Cache مستقل لترجمات Gemini.
- دعم روابط الأقسام `#Section`.
- إعادة تسمية القوالب دون Regex للقوالب المتداخلة.
- دعم قواعد `RenameParameterValue` لمعالجة قيم محددة داخل القوالب.
- الحفاظ على التعليقات والكتل المحمية مثل `<ref>` و`<math>` و`<code>` و`<nowiki>`.
- تقليل طلبات API عبر المعالجة الدفعية وCache.
- تقارير واضحة عن الروابط التي تعذر تحويلها.

## المتطلبات

- Windows PowerShell 5.1 أو PowerShell 7+.
- اتصال بالإنترنت عند جلب Wikipedia/Wikidata أو استخدام Gemini.
- مفتاح Gemini اختياري.
- لا يحتاج المشروع إلى Python أو Node.js أو مكتبات PowerShell خارجية.

## التشغيل

### من `input.wiki`

ضع Wikitext الإنجليزي في `input.wiki` ثم:

```powershell
.\WikiArabicTools.ps1
```

### من عنوان ويكيبيديا

```powershell
.\WikiArabicTools.ps1 -Title "Dutch Revolt"
```

### من رابط ويكيبيديا

```powershell
.\WikiArabicTools.ps1 -Url "https://en.wikipedia.org/wiki/Dutch_Revolt"
```

يتطلب `-Url` رابط Wikipedia الإنجليزية من النطاق `en.wikipedia.org`، لأن حل الروابط في المرحلة الحالية يعتمد على عناوين ويكيبيديا الإنجليزية.

## القوالب

تعريفات إعادة تسمية القوالب وقيمها موجودة في:

`Templates\TemplateMap.json`

مثال:

```json
[
  {
    "Action": "RenameTemplate",
    "Source": "Campaignbox Golden Age of Piracy",
    "Target": "صندوق حملة العصر الذهبي للقرصنة"
  },
  {
    "Action": "RenameParameterValue",
    "Template": "Campaignbox",
    "Parameter": "name",
    "SourceValue": "Campaignbox Golden Age of Piracy",
    "TargetValue": "صندوق حملة العصر الذهبي للقرصنة"
  }
]
```

المعالجة تتم قبل تحويل الروابط، ولذلك يمكن أيضًا تعريب الروابط الموجودة داخل معاملات القوالب.

## Gemini

لا تخزن مفتاح Gemini داخل المشروع. استخدم متغير البيئة:

```powershell
[Environment]::SetEnvironmentVariable('GEMINI_API_KEY','YOUR_KEY','User')
```

الإعدادات الاختيارية:

```powershell
$env:GEMINI_MODEL = 'gemini-3.5-flash'
$env:GEMINI_FALLBACK_MODEL = 'gemini-3.5-flash-lite'
$env:GEMINI_BATCH_SIZE = '10'
```

النموذج `gemini-3.5-flash` والنموذج الاحتياطي `gemini-3.5-flash-lite` من نماذج Gemini المتاحة حاليًا في Gemini API. وتوصي Google بالانتقال من `gemini-3.1-flash-lite` إلى `gemini-3.5-flash-lite` عند استخدام البديل الأحدث.  

## النتائج

ينتج البرنامج:

- `output.wiki`
- `untranslated-links.txt`
- `source-info.txt`

## Cache

- `Cache\WikidataCache.json`
- `Cache\ArabicLabelCache.json`
- `Cache\GeminiDisplayCache.json`

يمكن حذف Cache لإعادة بناء البيانات المحلية من الخدمات.

## الاختبارات

تشمل الاختبارات الحالية:

- `Tests\Test-Syntax.ps1` للتحقق من بناء ملفات PowerShell دون تنفيذها.
- `Tests\Test-TemplateTranslator.ps1` لاختبارات القوالب وإعادة التسمية والقيم وحفظ التعليقات.
- `Tests\Test-TextTranslator.ps1` لاختبارات ترجمة النصوص الظاهرة الآمنة.
- `Tests\Test-LinkDisplayTranslator.ps1` لاختبارات نصوص عرض الروابط و`Ill-WD2`.
- `Tests\Test-ArabicLabelCache.ps1` لاختبار التعامل مع الإدخالات القديمة غير العربية في الكاش.

يمكن تشغيلها يدويًا:

```powershell
.\Tests\Test-Syntax.ps1
.\Tests\Test-TemplateTranslator.ps1
.\Tests\Test-TextTranslator.ps1
.\Tests\Test-LinkDisplayTranslator.ps1
.\Tests\Test-ArabicLabelCache.ps1
```

## GitHub Actions

المسار `.github\workflows\translate.yml` يوفر:

- تشغيلًا يدويًا من تبويب Actions باستخدام `input` أو `title` أو `url`.
- تشغيلًا تلقائيًا عند تغيير `input.wiki` أو ملفات البرنامج أو `Templates\` أو الاختبارات.
- فحوصات بناء واختبارات تلقائية قبل أي ترجمة.
- استخدام `GEMINI_API_KEY` من GitHub Actions Secrets فقط.
- حفظ النتائج كـArtifacts وتحديث ملفات النتائج في المستودع عند تغيرها.

لإعداد Gemini في GitHub، أنشئ Repository secret باسم `GEMINI_API_KEY` من:

`Settings → Secrets and variables → Actions`

ولا تضع المفتاح داخل أي ملف من ملفات المشروع.

## بنية المشروع

```text
WikiArabicTools-v1.3.9/
├── .github/
│   └── workflows/
│       └── translate.yml
├── Modules/
│   ├── LinkTranslator.ps1
│   ├── TextTranslator.ps1
│   ├── TemplateTranslator.ps1
│   ├── Wikidata.ps1
│   ├── WikipediaFetcher.ps1
│   └── WikitextParser.ps1
├── Templates/
│   └── TemplateMap.json
├── Tests/
│   ├── Test-Syntax.ps1
│   ├── Test-TemplateTranslator.ps1
│   ├── Test-TextTranslator.ps1
│   ├── Test-LinkDisplayTranslator.ps1
│   └── Test-ArabicLabelCache.ps1
├── Cache/
├── WikiArabicTools.ps1
├── SETUP.ps1
├── SETUP.cmd
├── RUN.cmd
├── VERSION.txt
├── README.md
├── README.txt
├── GEMINI_API_KEY.txt.example
└── CHANGELOG.md
```

## الإصدار

الإصدار الحالي: **1.3.9**.

رقم الإصدار محفوظ في `VERSION.txt`.

### ترجمة نص العرض في الروابط

لا يستخدم `LinkTranslator.ps1` Gemini لترجمة نصوص عرض الروابط. إذا كان نص العرض مساويًا لعنوان الرابط الإنجليزي، يُستخدم العنوان العربي تلقائيًا. وإذا كان مختلفًا، فلا يُخمن البرنامج ترجمته؛ يمكن إضافة ترجمة موثوقة إلى `Templates\DisplayTranslationMap.json`.
