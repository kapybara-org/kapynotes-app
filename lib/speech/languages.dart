import 'dart:ui' show Locale;

/// A language a recording can be translated into: its BCP-47 [code], its
/// [own] name, written the way its speakers write it, and its [english] name.
class Language {
  const Language(this.code, this.own, this.english);

  final String code;
  final String own;
  final String english;

  /// The language without its script: `zh` for both kinds of Chinese.
  String get base => code.split('-').first;

  @override
  bool operator ==(Object other) => other is Language && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// About a hundred of the languages most spoken and most written, by
/// English name.
const List<Language> languages = [
  Language('af', 'Afrikaans', 'Afrikaans'),
  Language('sq', 'Shqip', 'Albanian'),
  Language('am', 'አማርኛ', 'Amharic'),
  Language('ar', 'العربية', 'Arabic'),
  Language('hy', 'Հայերեն', 'Armenian'),
  Language('as', 'অসমীয়া', 'Assamese'),
  Language('az', 'Azərbaycan', 'Azerbaijani'),
  Language('eu', 'Euskara', 'Basque'),
  Language('be', 'Беларуская', 'Belarusian'),
  Language('bn', 'বাংলা', 'Bengali'),
  Language('bho', 'भोजपुरी', 'Bhojpuri'),
  Language('bs', 'Bosanski', 'Bosnian'),
  Language('bg', 'Български', 'Bulgarian'),
  Language('my', 'မြန်မာ', 'Burmese'),
  Language('yue', '粵語', 'Cantonese'),
  Language('ca', 'Català', 'Catalan'),
  Language('ceb', 'Cebuano', 'Cebuano'),
  Language('zh-Hans', '简体中文', 'Chinese (Simplified)'),
  Language('zh-Hant', '繁體中文', 'Chinese (Traditional)'),
  Language('co', 'Corsu', 'Corsican'),
  Language('hr', 'Hrvatski', 'Croatian'),
  Language('cs', 'Čeština', 'Czech'),
  Language('da', 'Dansk', 'Danish'),
  Language('nl', 'Nederlands', 'Dutch'),
  Language('en', 'English', 'English'),
  Language('eo', 'Esperanto', 'Esperanto'),
  Language('et', 'Eesti', 'Estonian'),
  Language('fil', 'Filipino', 'Filipino'),
  Language('fi', 'Suomi', 'Finnish'),
  Language('fr', 'Français', 'French'),
  Language('gl', 'Galego', 'Galician'),
  Language('ka', 'ქართული', 'Georgian'),
  Language('de', 'Deutsch', 'German'),
  Language('el', 'Ελληνικά', 'Greek'),
  Language('gu', 'ગુજરાતી', 'Gujarati'),
  Language('ht', 'Kreyòl ayisyen', 'Haitian Creole'),
  Language('ha', 'Hausa', 'Hausa'),
  Language('haw', 'ʻŌlelo Hawaiʻi', 'Hawaiian'),
  Language('he', 'עברית', 'Hebrew'),
  Language('hi', 'हिन्दी', 'Hindi'),
  Language('hmn', 'Hmoob', 'Hmong'),
  Language('hu', 'Magyar', 'Hungarian'),
  Language('is', 'Íslenska', 'Icelandic'),
  Language('ig', 'Igbo', 'Igbo'),
  Language('id', 'Bahasa Indonesia', 'Indonesian'),
  Language('ga', 'Gaeilge', 'Irish'),
  Language('it', 'Italiano', 'Italian'),
  Language('ja', '日本語', 'Japanese'),
  Language('jv', 'Basa Jawa', 'Javanese'),
  Language('kn', 'ಕನ್ನಡ', 'Kannada'),
  Language('kk', 'Қазақ тілі', 'Kazakh'),
  Language('km', 'ខ្មែរ', 'Khmer'),
  Language('rw', 'Kinyarwanda', 'Kinyarwanda'),
  Language('kok', 'कोंकणी', 'Konkani'),
  Language('ko', '한국어', 'Korean'),
  Language('ku', 'Kurdî', 'Kurdish'),
  Language('ky', 'Кыргызча', 'Kyrgyz'),
  Language('lo', 'ລາວ', 'Lao'),
  Language('la', 'Latina', 'Latin'),
  Language('lv', 'Latviešu', 'Latvian'),
  Language('lt', 'Lietuvių', 'Lithuanian'),
  Language('lb', 'Lëtzebuergesch', 'Luxembourgish'),
  Language('mk', 'Македонски', 'Macedonian'),
  Language('mai', 'मैथिली', 'Maithili'),
  Language('mg', 'Malagasy', 'Malagasy'),
  Language('ms', 'Bahasa Melayu', 'Malay'),
  Language('ml', 'മലയാളം', 'Malayalam'),
  Language('mt', 'Malti', 'Maltese'),
  Language('mi', 'Māori', 'Māori'),
  Language('mr', 'मराठी', 'Marathi'),
  Language('mn', 'Монгол', 'Mongolian'),
  Language('ne', 'नेपाली', 'Nepali'),
  Language('nb', 'Norsk', 'Norwegian'),
  Language('ny', 'Chichewa', 'Nyanja'),
  Language('or', 'ଓଡ଼ିଆ', 'Odia'),
  Language('ps', 'پښتو', 'Pashto'),
  Language('fa', 'فارسی', 'Persian'),
  Language('pl', 'Polski', 'Polish'),
  Language('pt', 'Português', 'Portuguese'),
  Language('pa', 'ਪੰਜਾਬੀ', 'Punjabi'),
  Language('ro', 'Română', 'Romanian'),
  Language('ru', 'Русский', 'Russian'),
  Language('sm', 'Gagana Samoa', 'Samoan'),
  Language('sa', 'संस्कृतम्', 'Sanskrit'),
  Language('gd', 'Gàidhlig', 'Scottish Gaelic'),
  Language('sr', 'Српски', 'Serbian'),
  Language('st', 'Sesotho', 'Sesotho'),
  Language('sn', 'chiShona', 'Shona'),
  Language('sd', 'سنڌي', 'Sindhi'),
  Language('si', 'සිංහල', 'Sinhala'),
  Language('sk', 'Slovenčina', 'Slovak'),
  Language('sl', 'Slovenščina', 'Slovenian'),
  Language('so', 'Soomaali', 'Somali'),
  Language('es', 'Español', 'Spanish'),
  Language('su', 'Basa Sunda', 'Sundanese'),
  Language('sw', 'Kiswahili', 'Swahili'),
  Language('sv', 'Svenska', 'Swedish'),
  Language('tg', 'Тоҷикӣ', 'Tajik'),
  Language('ta', 'தமிழ்', 'Tamil'),
  Language('tt', 'Татар', 'Tatar'),
  Language('te', 'తెలుగు', 'Telugu'),
  Language('th', 'ไทย', 'Thai'),
  Language('bo', 'བོད་ཡིག', 'Tibetan'),
  Language('ti', 'ትግርኛ', 'Tigrinya'),
  Language('tr', 'Türkçe', 'Turkish'),
  Language('tk', 'Türkmen', 'Turkmen'),
  Language('uk', 'Українська', 'Ukrainian'),
  Language('ur', 'اردو', 'Urdu'),
  Language('ug', 'ئۇيغۇرچە', 'Uyghur'),
  Language('uz', 'Oʻzbek', 'Uzbek'),
  Language('vi', 'Tiếng Việt', 'Vietnamese'),
  Language('cy', 'Cymraeg', 'Welsh'),
  Language('fy', 'Frysk', 'Western Frisian'),
  Language('xh', 'isiXhosa', 'Xhosa'),
  Language('yi', 'ייִדיש', 'Yiddish'),
  Language('yo', 'Yorùbá', 'Yoruba'),
  Language('zu', 'isiZulu', 'Zulu'),
];

/// The language [tag] names: a BCP-47 tag (`hi`, `pt-BR`, `zh-TW`), the
/// older codes some systems still send (`iw`, `in`, `tl`, `no`), or the
/// English or own name a transcription service may give instead. Null when
/// it names none of [languages], as `und` and `mul` do.
Language? languageNamed(String tag) {
  final key = tag.trim().toLowerCase().replaceAll('_', '-');
  if (key.isEmpty) return null;
  for (final language in languages) {
    if (language.code.toLowerCase() == key ||
        language.english.toLowerCase() == key ||
        language.own.toLowerCase() == key) {
      return language;
    }
  }
  final subtags = key.split('-');
  final base = _older[subtags.first] ?? subtags.first;
  if (base == 'zh') {
    const traditional = {'hant', 'tw', 'hk', 'mo'};
    return _byCode(
      subtags.skip(1).any(traditional.contains) ? 'zh-Hant' : 'zh-Hans',
    );
  }
  return _byCode(base);
}

/// The language [locale] is in.
Language? languageOfLocale(Locale locale) => languageNamed(
  [locale.languageCode, ?locale.scriptCode, ?locale.countryCode].join('-'),
);

Language? _byCode(String code) {
  for (final language in languages) {
    if (language.code == code) return language;
  }
  return null;
}

const Map<String, String> _older = {
  'iw': 'he',
  'in': 'id',
  'ji': 'yi',
  'tl': 'fil',
  'no': 'nb',
  'nn': 'nb',
  'cmn': 'zh',
};
