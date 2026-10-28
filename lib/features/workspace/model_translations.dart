/// A model's translations, as the web's Editing language: its name and
/// description in other languages, saved in meta.i18n.
library;

/// The languages a model's name and description can be translated into,
/// as the web lists them (code, name).
const editingLanguages = [
  ('en-US', 'English (US)'),
  ('en-GB', 'English (GB)'),
  ('ar', 'Arabic (العربية)'),
  ('ar-BH', 'Arabic (Bahrain)'),
  ('az-AZ', 'Azərbaycanca'),
  ('eu-ES', 'Basque (Euskara)'),
  ('bn-BD', 'Bengali (বাংলা)'),
  ('bs-BA', 'Bosanski Latinica'),
  ('bo-TB', 'Tibetan (བོད)'),
  ('bg-BG', 'Bulgarian (български)'),
  ('ca-ES', 'Catalan (català)'),
  ('ceb-PH', 'Cebuano (Filipino)'),
  ('hr-HR', 'Croatian (Hrvatski)'),
  ('cs-CZ', 'Czech (čeština)'),
  ('da-DK', 'Danish (Denmark)'),
  ('nl-NL', 'Dutch (Netherlands)'),
  ('et-EE', 'Estonian (Eesti)'),
  ('fi-FI', 'Finnish (Suomalainen)'),
  ('fo-FO', 'Faroese (Faroe Islands)'),
  ('fr-CA', 'French (Canada)'),
  ('fr-FR', 'French (France)'),
  ('gl-ES', 'Galician (Galego)'),
  ('ka-GE', 'Georgian (ქართული)'),
  ('de-DE', 'German (Deutsch)'),
  ('el-GR', 'Greek (Ἑλλάδα)'),
  ('he-IL', 'Hebrew (עברית)'),
  ('hi-IN', 'Hindi (हिंदी)'),
  ('hu-HU', 'Hungarian (Magyar)'),
  ('id-ID', 'Indonesian (Bahasa Indonesia)'),
  ('ie-GA', 'Irish (Gaeilge)'),
  ('it-IT', 'Italian (Italiano)'),
  ('ja-JP', 'Japanese (日本語)'),
  ('kab-DZ', 'Kabyle (Taqbaylit)'),
  ('ko-KR', 'Korean (한국어)'),
  ('lt-LT', 'Lithuanian (Lietuvių)'),
  ('lv-LV', 'Latvian (Latviešu)'),
  ('ms-MY', 'Malay (Bahasa Malaysia)'),
  ('nb-NO', 'Norwegian Bokmål (Norway)'),
  ('fa-IR', 'Persian (فارسی)'),
  ('pl-PL', 'Polish (Polski)'),
  ('pt-BR', 'Portuguese (Brazil)'),
  ('pt-PT', 'Portuguese (Portugal)'),
  ('pa-IN', 'Punjabi (India)'),
  ('ro-RO', 'Romanian (Romania)'),
  ('ru-RU', 'Russian (Russia)'),
  ('sr-RS', 'Serbian (Српски)'),
  ('sk-SK', 'Slovak (Slovenčina)'),
  ('sl-SI', 'Slovenian (Slovenščina)'),
  ('es-ES', 'Spanish (Español)'),
  ('sv-SE', 'Swedish (Svenska)'),
  ('fil-PH', 'Tagalog (Filipino)'),
  ('ta-IN', 'தமிழ் (இந்தியா)'),
  ('th-TH', 'Thailand (ไทย)'),
  ('tr-TR', 'Turkish (Türkçe)'),
  ('tk-TM', 'Turkmen (Türkmençe)'),
  ('uk-UA', 'Ukrainian (Українська)'),
  ('ur-PK', 'Urdu (اردو)'),
  ('ug-CN', 'Uyghur (ئۇيغۇرچە)'),
  ('uz-Cyrl-UZ', 'Uzbek (Cyrillic)'),
  ('uz-Latn-UZ', 'Uzbek (Latin)'),
  ('vi-VN', 'Vietnamese (Tiếng Việt)'),
  ('zh-CN', 'Chinese (简体中文)'),
  ('zh-TW', 'Chinese (繁體中文)'),
  ('dg-DG', 'Doge (🐶)'),
];

/// meta.i18n without empty entries, or null when nothing is left.
Map<String, dynamic>? prunedTranslations(Map? i18n) {
  final out = <String, dynamic>{};
  for (final e in (i18n ?? const {}).entries) {
    if (e.value is! Map) continue;
    final fields = {
      for (final f in (e.value as Map).entries)
        if (f.value is String
            ? (f.value as String).trim().isNotEmpty
            : f.value != null)
          '${f.key}': f.value,
    };
    if (fields.isNotEmpty) out['${e.key}'] = fields;
  }
  return out.isEmpty ? null : out;
}
