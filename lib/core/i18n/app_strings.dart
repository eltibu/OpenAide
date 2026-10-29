/// Settings > General > Language, as on the web: the app's words in another
/// language. The words come from Open WebUI's own translations (bundled in
/// assets/i18n, see tool/i18n/build_catalogs.py); the app's own words that
/// the web doesn't have are translated once by a model on your server and
/// kept on the phone. Like the web, the choice belongs to this device.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A language the app can show, as the web lists it.
typedef AppLanguage = ({String code, String title});

/// The app's words for the chosen language. English needs no table: the
/// app is written in it.
class AppStrings extends ChangeNotifier {
  AppStrings._();
  static final instance = AppStrings._();

  /// The chosen language: a code from [languages], 'system' for the phone's
  /// own, or null for English.
  String? choice;

  /// The language being shown (after 'system' is worked out), or null.
  String? code;
  Map<String, String> _words = const {};

  /// Where the choice and the server's translations are kept; set once at
  /// start (tests leave it unset and stay in English).
  Directory? dir;

  /// The server's own wording (Admin > UI translations), by language,
  /// which wins over everything else, as on the web.
  Map<String, Map<String, String>> _admin = const {};

  String tr(String s) => _admin[code ?? 'en-US']?[s] ?? _words[s] ?? s;

  /// Takes the server's wording from /api/config (`i18n`).
  void setAdminWords(Object? i18n) {
    final next = <String, Map<String, String>>{
      if (i18n is Map)
        for (final e in i18n.entries)
          if (e.value is Map)
            '${e.key}': {
              for (final w in (e.value as Map).entries)
                if (w.value is String && '${w.value}'.trim().isNotEmpty)
                  '${w.key}': w.value as String,
            },
    };
    if (jsonEncode(next) == jsonEncode(_admin)) return;
    _admin = next;
    notifyListeners();
  }

  /// For [MaterialApp.locale]; null keeps the phone's.
  Locale? get locale {
    final c = code;
    if (c == null) return choice == null ? const Locale('en', 'US') : null;
    final parts = c.split('-');
    return Locale(parts.first, parts.length > 1 ? parts.last : null);
  }

  File? _file(String name) => dir == null ? null : File('${dir!.path}/$name');

  /// Loads the saved choice; call once before the app shows.
  Future<void> start() async {
    try {
      final support = await getApplicationSupportDirectory();
      dir = Directory('${support.path}/i18n')..createSync(recursive: true);
      final saved = _file('choice.json');
      if (saved != null && saved.existsSync()) {
        choice =
            (jsonDecode(saved.readAsStringSync()) as Map)['language']
                as String?;
      }
    } catch (_) {
      // Stays in English.
    }
    await _load();
  }

  Future<void> choose(String? language) async {
    choice = language;
    try {
      _file('choice.json')
          ?.writeAsStringSync(jsonEncode({'language': language}));
    } catch (_) {
      // Shown now, chosen again next start.
    }
    await _load();
  }

  /// The phone's language as one of [languages], if there's a match.
  static Future<String?> phoneLanguage() async {
    final all = await languages();
    final phone = ui.PlatformDispatcher.instance.locale;
    final full = '${phone.languageCode}-${phone.countryCode ?? ''}';
    for (final l in all) {
      if (l.code == full) return l.code;
    }
    for (final l in all) {
      if (l.code.split('-').first == phone.languageCode) return l.code;
    }
    return null;
  }

  Future<void> _load() async {
    var c = choice;
    if (c == 'system') c = await phoneLanguage();
    if (c == null || c.startsWith('en-')) {
      code = c;
      _words = const {};
      notifyListeners();
      return;
    }
    final words = <String, String>{};
    try {
      final bundled = await rootBundle.loadString('assets/i18n/$c.json');
      words.addAll((jsonDecode(bundled) as Map).cast<String, String>());
    } catch (_) {
      // No web translations for it; the server's fill in.
    }
    words.addAll(await _serverWords(c));
    code = c;
    _words = words;
    notifyListeners();
  }

  Future<Map<String, String>> _serverWords(String c) async {
    try {
      final f = _file('server-$c.json');
      if (f != null && f.existsSync()) {
        return (jsonDecode(f.readAsStringSync()) as Map).cast<String, String>();
      }
    } catch (_) {
      // Start again.
    }
    return {};
  }

  /// The app's words that still show in English for [c].
  Future<List<String>> missing(String c) async {
    final all = await appWords();
    final have = {..._words};
    if (code != c) {
      try {
        have.addAll(
          (jsonDecode(
            await rootBundle.loadString('assets/i18n/$c.json'),
          ) as Map).cast<String, String>(),
        );
      } catch (_) {}
      have.addAll(await _serverWords(c));
    }
    return [
      for (final w in all)
        if (!have.containsKey(w)) w,
    ];
  }

  /// Keeps translations made by the server's model, and shows them.
  Future<void> addServerWords(String c, Map<String, String> words) async {
    final kept = {...await _serverWords(c), ...words};
    try {
      _file('server-$c.json')?.writeAsStringSync(jsonEncode(kept));
    } catch (_) {}
    if (code == c) {
      _words = {..._words, ...words};
      notifyListeners();
    }
  }

  static List<AppLanguage>? _languages;

  /// Every language the web offers.
  static Future<List<AppLanguage>> languages() async {
    return _languages ??= [
      for (final l in jsonDecode(
        await rootBundle.loadString('assets/i18n/languages.json'),
      ) as List)
        (code: '${l['code']}', title: '${l['title']}'),
    ];
  }

  static List<String>? _appWords;

  /// Every phrase the app shows, as written.
  static Future<List<String>> appWords() async => _appWords ??= [
    for (final w in jsonDecode(
      await rootBundle.loadString('assets/i18n/strings.json'),
    ) as List)
      '$w',
  ];
}

/// [s] in the chosen language.
String tr(String s) => AppStrings.instance.tr(s);

/// Puts [AppStrings] above the app, so [T] redraws when the language
/// changes without losing where you are.
class AppStringsScope extends InheritedNotifier<AppStrings> {
  AppStringsScope({super.key, required super.child})
    : super(notifier: AppStrings.instance);
}

/// A [Text] of the app's own words, in the chosen language.
class T extends StatelessWidget {
  const T(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textScaler,
    this.semanticsLabel,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextScaler? textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<AppStringsScope>();
    return Text(
      tr(data),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textScaler: textScaler,
      semanticsLabel: semanticsLabel,
    );
  }
}
