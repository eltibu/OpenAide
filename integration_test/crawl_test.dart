// Opens every page of the real app and taps every button it can safely tap,
// then writes what broke. Two runs: signed in to an Open WebUI server, and
// with no server (AI providers only).
//
//   tool/e2e/start_server.sh            # the test server, prints the env
//   flutter test integration_test/crawl_test.dart -d linux
//
// Writes the report to $E2E_REPORT (default build/e2e/crawl.json). A
// problem is an exception, a layout overflow, or an error message that
// appeared on screen after a tap. Buttons that delete, sign out, send, or
// need the phone's hardware (microphone, camera, file picker) are left
// alone; switches are not flipped, since admin switches change the server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/auth/session.dart';
import 'package:nexus_assistant/features/standalone/local_chats.dart';
import 'package:nexus_assistant/main.dart';

class _Session extends SessionNotifier {
  _Session(this.session);
  final Session? session;
  @override
  Future<Session?> build() async => session;
}

class _Standalone extends StandaloneMode {
  @override
  Future<bool> build() async => true;
}

/// Follows the pages, dialogs and sheets the app opens.
class _Routes extends NavigatorObserver {
  final stack = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      stack[i] = newRoute;
    } else if (newRoute != null) {
      stack.add(newRoute);
    }
  }

  Route<dynamic>? get top => stack.lastOrNull;
}

/// Buttons the crawl never taps: they lose data, leave the app, or need
/// hardware a desktop test doesn't have.
final _skip = RegExp(
  r'^(back|close|cancel|dismiss|navigate up|done)$|'
  r'delete|remove|sign ?out|log ?out|clear|reset|revoke|uninstall|wipe|'
  r'\bleave\b|\bban\b|deactivate|disconnect|forget|erase|archive all|'
  r'\bsend\b|voice|\bcall\b|record|dictat|microphone|\bmic\b|camera|photo|'
  r'scan|\bshare\b|browser|website|github|learn more|privacy policy|'
  r'attach|upload|import|choose file|pick|download|export|install|'
  r'update now|restart|shut ?down|\bkill\b|\bstop\b|lock|biometric|'
  r'set as default|default assistant|exit|quit|copy|paste|cut|'
  r'emoji|regenerate|terminal|connect server|sign in|log ?in|'
  r'switch account|add account|change password|replace|overwrite|'
  r'run|execute|pull|rebuild|reindex|sync|play|speak|read aloud|listen',
  caseSensitive: false,
);

/// Text that means something failed.
final _errorText = RegExp(
  r"\berror\b|exception|failed|couldn.?t|could not|went wrong|not found|"
  r'unauthori[sz]ed|forbidden|\b(4\d\d|5\d\d)\b|null check|'
  r"isn't a subtype|type '.*' is not",
  caseSensitive: false,
);

final _iconGlyphs = RegExp(
  r'[\u{E000}-\u{F8FF}\u{F0000}-\u{FFFFD}]',
  unicode: true,
);

class _Problem {
  _Problem(this.kind, this.where, this.control, this.message);
  final String kind, where, control, message;
  Map<String, String> toJson() => {
    'kind': kind,
    'where': where,
    'control': control,
    'message': message,
  };
}

class _Crawler {
  _Crawler(this.tester, this.routes, {required this.maxDepth});
  final WidgetTester tester;
  final _Routes routes;
  final int maxDepth;
  final problems = <_Problem>[];
  final pages = <String>{};
  final tapped = <String>{};
  final skipped = <String>{};
  var taps = 0;
  final _caught = <String>[];

  /// Rows of a list that open the same kind of page (files, chats, notes):
  /// a couple are opened, the rest are the same page with other data.
  final _rowPages = <String, int>{};

  String _shape(Element e) {
    final types = <String>[];
    void visit(Element c) {
      if (types.length > 40) return;
      if (c.widget is! Text && c.widget is! RichText) {
        types.add(c.widget.runtimeType.toString());
      }
      c.visitChildElements(visit);
    }

    visit(e);
    final list = Scrollable.maybeOf(e);
    return '${identityHashCode(list)}|${types.join(',')}';
  }

  FlutterExceptionHandler? previousOnError;

  /// Hands error reporting back to the test, which checks it at the end.
  Future<void> finish() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    FlutterError.onError = previousOnError;
    _sink = null;
  }

  final _deadline = DateTime.now().add(
    Duration(
      minutes: int.tryParse(Platform.environment['E2E_MINUTES'] ?? '') ?? 40,
    ),
  );

  void caught(String what) {
    log('ERROR ${what.split('\n').first}');
    _caught.add(what);
  }

  static final _verbose = Platform.environment['E2E_VERBOSE'] == '1';
  var _shot = 0;

  void log(String what) {
    if (_verbose) debugPrint('[crawl] $what');
  }

  /// A picture of the app, when E2E_SHOTS names a folder.
  Future<void> shot(String name) async {
    final dir = Platform.environment['E2E_SHOTS'];
    if (dir == null) return;
    try {
      Directory(dir).createSync(recursive: true);
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final image = await layer.toImage(Offset.zero & view.size);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file =
          '$dir/${(_shot++).toString().padLeft(4, '0')}-'
          '${name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.png';
      File(file).writeAsBytesSync(png!.buffer.asUint8List());
    } catch (e) {
      log('no picture: $e');
    }
  }

  /// Runs [f] so errors from what it starts (taps, loads) are noted here
  /// instead of ending the test.
  Future<void> guarded(Future<void> Function() f) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await f();
      } catch (e, s) {
        caught('$e\n$s');
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }, (e, s) => caught('$e\n$s'));
    return done.future;
  }

  Future<void> settle([int ms = 900]) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Wait a little longer while something is still loading.
    for (var i = 0; i < 30; i++) {
      if (find
              .byType(CircularProgressIndicator)
              .hitTestable()
              .evaluate()
              .isEmpty &&
          find
              .byType(LinearProgressIndicator)
              .hitTestable()
              .evaluate()
              .isEmpty) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String _title() {
    final route = routes.top;
    for (final e in find.byType(AppBar).hitTestable().evaluate()) {
      if (route != null && ModalRoute.of(e) != route) continue;
      final t = (e.widget as AppBar).title;
      if (t is Text && t.data != null) return t.data!;
      final texts = find
          .descendant(of: find.byWidget(e.widget), matching: find.byType(Text))
          .evaluate()
          .map((t) => (t.widget as Text).data)
          .whereType<String>();
      if (texts.isNotEmpty) return texts.first;
    }
    return route?.settings.name ?? route.runtimeType.toString();
  }

  /// A readable name for a control: its text, else its tooltip or icon.
  String _label(Element e) {
    final words = <String>[];
    void visit(Element c) {
      final w = c.widget;
      if (w is Text) {
        // Its own RichText below says the same.
        if (w.data != null) words.add(w.data!);
        return;
      }
      if (w is RichText) words.add(w.text.toPlainText());
      if (words.length < 3) c.visitChildElements(visit);
    }

    visit(e);
    // Icons draw as text in a private-use font; leave those out.
    final clean = [
      for (final w in words)
        if (w.replaceAll(_iconGlyphs, '').trim() case final t when t.isNotEmpty)
          t,
    ];
    if (clean.isNotEmpty) return clean.take(2).join(' / ');
    String? tip;
    e.visitAncestorElements((a) {
      if (a.widget is Tooltip) {
        tip = (a.widget as Tooltip).message;
        return false;
      }
      return a.widget is! InkWell;
    });
    if (tip != null) return tip!;
    String? icon;
    void findIcon(Element c) {
      if (icon != null) return;
      final w = c.widget;
      if (w is Icon && w.icon != null) {
        icon = 'icon ${w.icon!.codePoint.toRadixString(16)}';
      }
      c.visitChildElements(findIcon);
    }

    findIcon(e);
    return icon ?? '?';
  }

  bool _isToggle(Element e) {
    var toggle = false;
    void visit(Element c) {
      final w = c.widget;
      if (w is Switch || w is Checkbox || w is Radio || w is Slider) {
        toggle = true;
      }
      if (!toggle) c.visitChildElements(visit);
    }

    visit(e);
    return toggle;
  }

  /// Visible, tappable controls on the top page.
  List<(Element, String)> _controls() {
    final route = routes.top;
    final out = <(Element, String)>[];
    final seen = <String>{};
    for (final e in find.byType(InkWell).hitTestable().evaluate()) {
      final w = e.widget as InkWell;
      if (w.onTap == null) continue;
      if (route != null && ModalRoute.of(e) != route) continue;
      final r = e.renderObject;
      if (r is! RenderBox || !r.hasSize || r.size.isEmpty) continue;
      final label = _label(e);
      if (!seen.add(label)) continue;
      if (_isToggle(e)) {
        skipped.add('$label (switch)');
        continue;
      }
      out.add((e, label));
    }
    return out;
  }

  Set<String> _texts() => {
    for (final e in find.byType(Text).hitTestable().evaluate())
      ?(e.widget as Text).data,
    for (final e in find.byType(RichText).hitTestable().evaluate())
      (e.widget as RichText).text.toPlainText(),
  };

  void _note(String where, String control, Set<String> before) {
    for (final c in _caught) {
      final kind = c.contains('MissingPluginException')
          ? 'needs the phone'
          : c.contains('overflowed')
          ? 'layout overflow'
          : 'exception';
      problems.add(_Problem(kind, where, control, _short(c)));
    }
    _caught.clear();
    for (final t in _texts().difference(before)) {
      if (t.length < 400 && _errorText.hasMatch(t)) {
        problems.add(_Problem('error on screen', where, control, t));
      }
    }
  }

  String _short(String s) {
    final lines = s.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.take(6).join('\n');
  }

  Future<void> _closeTo(Route<dynamic> page) async {
    for (var i = 0; i < 6 && routes.top != page && routes.top != null; i++) {
      final top = routes.top!;
      if (!(top.navigator?.canPop() ?? false)) break;
      top.navigator!.pop();
      await settle(400);
    }
    // Menus and drop-downs that aren't routes: the account menu closes
    // from its own row, others on Escape.
    if (find.byType(MenuItemButton).hitTestable().evaluate().isNotEmpty) {
      final account = find.byIcon(Icons.expand_more).hitTestable();
      if (account.evaluate().isNotEmpty) {
        await tester.tap(account.first, warnIfMissed: false);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await settle(300);
    }
  }

  /// Taps each control on the top page; follows new pages [maxDepth] deep.
  Future<void> crawl(String path, {int depth = 0, int maxTaps = 60}) async {
    final page = routes.top;
    if (page == null) return;
    final title = _title();
    final where = path.isEmpty ? title : '$path > $title';
    pages.add(where);
    final done = <String>{};
    var scrolls = 0;
    var count = 0;
    while (count < maxTaps && DateTime.now().isBefore(_deadline)) {
      if (routes.top != page) await _closeTo(page);
      if (routes.top != page) break;
      final next = _controls().where((c) => !done.contains(c.$2)).firstOrNull;
      if (next == null) {
        // Reveal more of the page, a few times.
        if (scrolls++ >= 4 || !await _scroll()) break;
        continue;
      }
      final (element, label) = next;
      done.add(label);
      if (_skip.hasMatch(label)) {
        skipped.add('$where: $label');
        continue;
      }
      final shape = _shape(element);
      if ((_rowPages[shape] ?? 0) >= 2) {
        skipped.add('$where: $label (same as rows above)');
        continue;
      }
      count++;
      taps++;
      tapped.add('$where: $label');
      log('tap $where: $label');
      final before = _texts();
      await guarded(() async {
        await tester.tap(
          find.byElementPredicate((e) => e == element),
          warnIfMissed: false,
        );
        await settle();
      });
      _note(where, label, before);
      final now = routes.top;
      if (now != page) {
        log('  opened ${now.runtimeType} ${_title()}');
        await shot('$where $label');
      }
      // A back or close button: this page is done.
      if (!routes.stack.contains(page)) return;
      if (now != null && now != page) {
        if (now is PageRoute) _rowPages[shape] = (_rowPages[shape] ?? 0) + 1;
        if (now is PageRoute && depth < maxDepth) {
          await crawl(where, depth: depth + 1, maxTaps: maxTaps ~/ 2 + 10);
        } else {
          pages.add('$where > ${_title()}');
        }
        final b = _texts();
        await _closeTo(page);
        _note(where, '$label (closing)', b);
      }
    }
  }

  Future<bool> _scroll() async {
    final route = routes.top;
    final lists = find
        .byType(Scrollable)
        .hitTestable()
        .evaluate()
        .where(
          (e) =>
              (route == null || ModalRoute.of(e) == route) &&
              (e.widget as Scrollable).axisDirection == AxisDirection.down,
        );
    if (lists.isEmpty) return false;
    final state = (lists.first as StatefulElement).state as ScrollableState;
    final pos = state.position;
    if (pos.pixels >= pos.maxScrollExtent) return false;
    pos.jumpTo(
      (pos.pixels + pos.viewportDimension * 0.8).clamp(0, pos.maxScrollExtent),
    );
    await settle(400);
    return true;
  }

  Map<String, Object> report(String mode) => {
    'mode': mode,
    'pages': pages.toList(),
    'taps': taps,
    'tapped': tapped.toList(),
    'skipped': skipped.toList(),
    'problems': [for (final p in problems) p.toJson()],
  };
}

Future<_Crawler> _start(
  WidgetTester tester,
  List<Override> overrides, {
  required int maxDepth,
}) async {
  final routes = _Routes();
  tester.view
    ..physicalSize = const Size(412, 915)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final crawler = _Crawler(tester, routes, maxDepth: maxDepth);
  _sink = crawler.caught;
  _early.forEach(crawler.caught);
  _early.clear();
  crawler.previousOnError = FlutterError.onError;
  FlutterError.onError = (d) => crawler.caught(d.toString());
  final platform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (e, s) {
    crawler.caught('$e\n$s');
    return true;
  };
  addTearDown(() => PlatformDispatcher.instance.onError = platform);
  await crawler.guarded(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: NexusApp(navigatorObservers: [routes]),
      ),
    );
    await crawler.settle(3000);
  });
  return crawler;
}

Future<void> _openDrawer(_Crawler c) async {
  final states = c.tester
      .stateList<ScaffoldState>(find.byType(Scaffold))
      .where((s) => s.hasDrawer);
  if (states.isEmpty) {
    c.log('no side menu here');
    return;
  }
  states.first.openDrawer();
  await c.settle(600);
}

/// Closes what the app shows over the first page when it starts (What's
/// New, a question from the server), noting each one.
Future<void> _closeStartupPopups(_Crawler c) async {
  for (var i = 0; i < 4; i++) {
    final top = c.routes.top;
    if (top == null || top is PageRoute || c.routes.stack.length < 2) return;
    c.pages.add('On start: ${c._title()}');
    c.log('closing start-up popup ${c._title()}');
    top.navigator?.pop();
    await c.settle(500);
  }
}

Future<void> _write(String name, Map<String, Object> report) async {
  final dir = Directory(Platform.environment['E2E_REPORT_DIR'] ?? 'build/e2e')
    ..createSync(recursive: true);
  File('${dir.path}/$name.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
}

/// Every place the side menu and the account menu open, by name.
Future<void> _crawlMenus(_Crawler c, {required bool account}) async {
  final home = c.routes.top!;
  await _openDrawer(c);
  bool isAccount(Element e) {
    var found = false;
    void visit(Element x) {
      final w = x.widget;
      if (w is Icon &&
          (w.icon == Icons.expand_less || w.icon == Icons.expand_more)) {
        found = true;
      }
      if (!found) x.visitChildElements(visit);
    }

    visit(e);
    return found;
  }

  // The account row opens the account menu, visited below.
  final rows = [
    for (final e in find.byType(InkWell).hitTestable().evaluate())
      if ((e.widget as InkWell).onTap != null && !isAccount(e)) c._label(e),
  ];
  // Section headings fold their section away; their rows are visited.
  const headings = {'Channels', 'Folders', 'Chats', 'Models', 'Pinned'};
  final names = <String>[];
  for (final r in rows) {
    final name = r.split(' / ').first;
    if (!names.contains(name) && !headings.contains(name)) names.add(name);
  }
  await c._closeTo(home);
  Navigator.of(c.tester.element(find.byType(Scaffold).first)).maybePop();
  await c.settle(400);

  Future<void> visit(String name, Future<void> Function() open) async {
    if (_skip.hasMatch(name)) {
      c.skipped.add('Menu: $name');
      return;
    }
    final before = c._texts();
    c.log('menu $name');
    await c.guarded(() async {
      await open();
      await c.settle();
    });
    c._note('Menu', name, before);
    c.taps++;
    c.tapped.add('Menu: $name');
    await c.shot('menu $name');
    if (c.routes.top != home) {
      await c.crawl('Menu');
      await c._closeTo(home);
    }
    if (find.byType(Drawer).hitTestable().evaluate().isNotEmpty) {
      Navigator.of(c.tester.element(find.byType(Drawer))).maybePop();
      await c.settle(400);
    }
  }

  for (final name in names) {
    await visit(name, () async {
      await _openDrawer(c);
      var hit = find.text(name).hitTestable();
      if (hit.evaluate().isEmpty) hit = find.byTooltip(name).hitTestable();
      if (hit.evaluate().isEmpty) {
        c.log('"$name" not found');
        return;
      }
      await c.tester.tap(hit.first, warnIfMissed: false);
    });
  }
  if (!account) return;
  await _openDrawer(c);
  if (find.byType(MenuItemButton).hitTestable().evaluate().isEmpty) {
    final accountTile = find.byIcon(Icons.expand_less).hitTestable();
    if (accountTile.evaluate().isEmpty) {
      c.log('account menu not found');
      return;
    }
    await c.tester.tap(accountTile.first, warnIfMissed: false);
    await c.settle(600);
  }
  final items = [
    for (final e in find.byType(MenuItemButton).hitTestable().evaluate())
      if ((e.widget as MenuItemButton).onPressed != null) c._label(e),
  ];
  await c._closeTo(home);
  for (final name in items.map((i) => i.split(' / ').first)) {
    await visit(name, () async {
      await _openDrawer(c);
      if (find.byType(MenuItemButton).hitTestable().evaluate().isEmpty) {
        final tile = find.byIcon(Icons.expand_less).hitTestable();
        if (tile.evaluate().isEmpty) {
          c.log('account menu not found');
          return;
        }
        await c.tester.tap(tile.first, warnIfMissed: false);
        await c.settle(600);
      }
      var hit = find.text(name).hitTestable();
      if (hit.evaluate().isEmpty) hit = find.byTooltip(name).hitTestable();
      if (hit.evaluate().isEmpty) {
        c.log('"$name" not found');
        return;
      }
      await c.tester.tap(hit.first, warnIfMissed: false);
    });
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final depth = int.tryParse(Platform.environment['E2E_DEPTH'] ?? '') ?? 2;

  testWidgets(
    'signed in: every page and button',
    (tester) async {
      await _guardAll(() => _signedIn(tester, url, email, password, depth));
    },
    skip: url == null,
    timeout: const Timeout(Duration(minutes: 60)),
  );

  testWidgets('no server: every page and button', (tester) async {
    await _guardAll(() => _noServer(tester, depth));
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<void> _signedIn(
  WidgetTester tester,
  String? url,
  String? email,
  String? password,
  int depth,
) async {
  final client = OpenWebUiClient(baseUrl: url!);
  await client.signIn(email!, password!);
  final c = await _start(tester, [
    sessionProvider.overrideWith(
      () => _Session(Session(serverUrl: url, token: client.token!)),
    ),
  ], maxDepth: depth);
  await _closeStartupPopups(c);
  await c.shot('start');
  // The chat page itself: composer, model picker, its menus.
  await c.crawl('', maxTaps: 40);
  await _crawlMenus(c, account: true);
  await _write('crawl-server', c.report('server'));
  await c.finish();
}

Future<void> _noServer(WidgetTester tester, int depth) async {
  final c = await _start(tester, [
    sessionProvider.overrideWith(() => _Session(null)),
    standaloneModeProvider.overrideWith(_Standalone.new),
  ], maxDepth: depth);
  await _closeStartupPopups(c);
  await c.shot('start');
  await c.crawl('', maxTaps: 40);
  await _crawlMenus(c, account: false);
  await _write('crawl-standalone', c.report('standalone'));
  await c.finish();
}

/// Where errors go while a crawl runs; see [_guardAll].
void Function(String)? _sink;
final _early = <String>[];

/// Runs the whole crawl in a zone of its own, so an error from anything the
/// app starts is noted in the report instead of ending the test.
Future<void> _guardAll(Future<void> Function() body) {
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body();
    } catch (e, s) {
      (_sink ?? _early.add)('$e\n$s');
      rethrowLater = '$e\n$s';
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }, (e, s) => (_sink ?? _early.add)('$e\n$s'));
  return done.future.then((_) {
    final r = rethrowLater;
    rethrowLater = null;
    if (r != null) fail('The crawl itself broke: $r');
  });
}

String? rethrowLater;
