/// Web search and reading pages, for models without a server: no key
/// needed (DuckDuckGo), or Brave, Tavily or your own SearXNG if you set
/// one up.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../net/local_network.dart';

export '../net/local_network.dart' show isLocalAddress;

/// A browser's User-Agent; many sites turn plain clients away.
const browserAgent =
    'Mozilla/5.0 (Linux; Android 15; Pixel) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/138.0 Mobile Safari/537.36';

enum SearchEngine {
  duckDuckGo('duckduckgo', 'DuckDuckGo', needsKey: false),
  brave('brave', 'Brave Search'),
  tavily('tavily', 'Tavily'),
  searxng('searxng', 'SearXNG (your own)', needsKey: false, needsUrl: true);

  const SearchEngine(
    this.id,
    this.label, {
    this.needsKey = true,
    this.needsUrl = false,
  });
  final String id;
  final String label;
  final bool needsKey;
  final bool needsUrl;

  static SearchEngine byId(String? id) => SearchEngine.values.firstWhere(
    (e) => e.id == id,
    orElse: () => SearchEngine.duckDuckGo,
  );
}

class SearchResult {
  const SearchResult(this.title, this.url, this.snippet);
  final String title;
  final String url;
  final String snippet;
}

/// The results as text for the model.
String searchResultsText(String query, List<SearchResult> results) {
  if (results.isEmpty) return 'No results for "$query".';
  return [
    for (final (i, r) in results.indexed)
      '${i + 1}. ${r.title}\n   ${r.url}\n   ${r.snippet}',
  ].join('\n');
}

Future<List<SearchResult>> webSearch(
  String query, {
  SearchEngine engine = SearchEngine.duckDuckGo,
  String? key,
  String? url,
  int count = 8,
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    switch (engine) {
      case SearchEngine.brave:
        final r = await client
            .get(
              Uri.https('api.search.brave.com', '/res/v1/web/search', {
                'q': query,
                'count': '$count',
              }),
              headers: {
                'Accept': 'application/json',
                'X-Subscription-Token': key ?? '',
              },
            )
            .timeout(const Duration(seconds: 20));
        _check(r, 'Brave Search');
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        return [
          for (final w
              in ((j['web'] as Map?)?['results'] as List? ?? const [])
                  .whereType<Map>())
            SearchResult(
              htmlText('${w['title'] ?? ''}'),
              '${w['url'] ?? ''}',
              htmlText('${w['description'] ?? ''}'),
            ),
        ];
      case SearchEngine.tavily:
        final r = await client
            .post(
              Uri.parse('https://api.tavily.com/search'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${key ?? ''}',
              },
              body: jsonEncode({'query': query, 'max_results': count}),
            )
            .timeout(const Duration(seconds: 30));
        _check(r, 'Tavily');
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        return [
          for (final w in (j['results'] as List? ?? const []).whereType<Map>())
            SearchResult(
              '${w['title'] ?? ''}',
              '${w['url'] ?? ''}',
              '${w['content'] ?? ''}',
            ),
        ];
      case SearchEngine.searxng:
        final base = (url ?? '').replaceAll(RegExp(r'/+$'), '');
        if (base.isEmpty) throw Exception('Add your SearXNG address first.');
        final r = await client
            .get(
              Uri.parse('$base/search')
                  .replace(queryParameters: {'q': query, 'format': 'json'}),
              headers: {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 20));
        _check(r, 'SearXNG');
        final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        return [
          for (final w
              in (j['results'] as List? ?? const []).whereType<Map>().take(
                count,
              ))
            SearchResult(
              '${w['title'] ?? ''}',
              '${w['url'] ?? ''}',
              '${w['content'] ?? ''}',
            ),
        ];
      case SearchEngine.duckDuckGo:
        final r = await client
            .post(
              Uri.parse('https://html.duckduckgo.com/html/'),
              headers: {
                'User-Agent': browserAgent,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: {'q': query},
            )
            .timeout(const Duration(seconds: 20));
        _check(r, 'DuckDuckGo');
        final results = parseDuckDuckGo(utf8.decode(r.bodyBytes));
        if (results.isEmpty && r.body.contains('anomaly')) {
          throw Exception(
            'DuckDuckGo is asking for a check right now. Try again later, '
            'or pick another search engine in Tools and skills.',
          );
        }
        return results.take(count).toList();
    }
  } finally {
    if (httpClient == null) client.close();
  }
}

void _check(http.Response r, String who) {
  if (r.statusCode == 401 || r.statusCode == 403) {
    throw Exception('$who refused the key. Check it in Tools and skills.');
  }
  if (r.statusCode >= 400) throw Exception('$who answered ${r.statusCode}');
}

/// Results from DuckDuckGo's HTML page.
List<SearchResult> parseDuckDuckGo(String html) {
  final out = <SearchResult>[];
  final link = RegExp(
    r'<a[^>]+class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
  );
  final snippet = RegExp(
    r'class="result__snippet"[^>]*>([\s\S]*?)</(?:a|td|div)>',
  );
  final blocks = html.split(RegExp(r'class="result(?:s_links)?[ "]'));
  for (final b in blocks) {
    final l = link.firstMatch(b);
    if (l == null) continue;
    var href = _entities(l[1]!);
    final redirect = Uri.tryParse(href.startsWith('//') ? 'https:$href' : href);
    final real = redirect?.queryParameters['uddg'];
    if (real != null) href = real;
    // Ads go through DuckDuckGo's y.js.
    if (href.contains('duckduckgo.com/y.js')) continue;
    out.add(
      SearchResult(
        htmlText(l[2]!),
        href,
        htmlText(snippet.firstMatch(b)?[1] ?? ''),
      ),
    );
  }
  return out;
}

String _entities(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#x27;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m[1]!)),
    )
    .replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
    );

/// The readable text of an HTML fragment.
String htmlText(String html) =>
    _entities(html.replaceAll(RegExp(r'<[^>]+>'), ''))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// The readable text of a whole page: headings, paragraphs and lists, with
/// scripts, styles, menus and footers left out.
({String title, String text}) pageText(String html) {
  final title = htmlText(
    RegExp(
          r'<title[^>]*>([\s\S]*?)</title>',
          caseSensitive: false,
        ).firstMatch(html)?[1] ??
        '',
  );
  var body = html;
  for (final tag in const [
    'script',
    'style',
    'noscript',
    'svg',
    'nav',
    'footer',
    'header',
    'aside',
    'form',
    'template',
    'iframe',
  ]) {
    body = body.replaceAll(
      RegExp('<$tag\\b[\\s\\S]*?</$tag>', caseSensitive: false),
      ' ',
    );
  }
  body = body.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  // Keep links' addresses: models often need them to read further.
  body = body.replaceAllMapped(
    RegExp(
      r'<a\b[^>]*href="(https?://[^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    ),
    (m) {
      final t = htmlText(m[2]!);
      return t.isEmpty ? ' ' : '[$t](${_entities(m[1]!)})';
    },
  );
  body = body
      .replaceAllMapped(
        RegExp(r'<h([1-6])\b[^>]*>', caseSensitive: false),
        (m) => '\n\n${'#' * int.parse(m[1]!)} ',
      )
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(
        RegExp(
          r'</?(p|div|section|article|br|tr|table|ul|ol|h[1-6]|blockquote|pre)\b[^>]*>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');
  final text = _entities(body)
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t ]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (title: title, text: text);
}

/// Turns away addresses on the phone or the home network. A page the model
/// reads can tell it what to open next, so without this a web page could
/// make it read a router or a home server and pass the text on.
Future<void> _checkPublic(
  Uri u,
  Future<List<InternetAddress>> Function(String host) lookup,
) async {
  final host = u.host.toLowerCase();
  final literal = InternetAddress.tryParse(host);
  List<InternetAddress> addresses;
  if (literal != null) {
    addresses = [literal];
  } else if (host == 'localhost' || host.endsWith('.localhost')) {
    addresses = [InternetAddress.loopbackIPv4];
  } else {
    try {
      addresses = await lookup(host);
    } on SocketException {
      return; // The request itself says the name doesn't resolve.
    }
  }
  if (addresses.any(isLocalAddress)) {
    throw Exception(
      "$host is on this phone or your home network. For safety, the "
      "assistant only reads public web pages.",
    );
  }
}

/// A page's text for the model: HTML made readable, JSON and plain text as
/// they are. Only public addresses, and every redirect is checked too.
Future<String> fetchPage(
  String url, {
  http.Client? httpClient,
  Future<List<InternetAddress>> Function(String host)? lookup,
}) async {
  var u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) {
    u = Uri.tryParse('https://${url.trim()}');
  }
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) {
    throw Exception('That is not a web address: $url');
  }
  final resolve = lookup ?? InternetAddress.lookup;
  final client = httpClient ?? http.Client();
  var at = u;
  try {
    late http.Response r;
    for (var hops = 0; ; hops++) {
      await _checkPublic(at, resolve);
      final req = http.Request('GET', at)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': browserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/json,'
              'text/plain;q=0.9,*/*;q=0.5',
        });
      r = await http.Response.fromStream(await client.send(req))
          .timeout(const Duration(seconds: 30));
      final location = r.headers['location'];
      if (r.statusCode < 300 || r.statusCode >= 400 || location == null) {
        break;
      }
      if (hops >= 5) throw Exception('The page redirects too many times');
      at = at.resolve(location);
      if (!(at.scheme == 'http' || at.scheme == 'https')) {
        throw Exception('The page redirects to $at');
      }
    }
    if (r.statusCode >= 400) {
      throw Exception('The page answered ${r.statusCode}');
    }
    final type = r.headers['content-type'] ?? '';
    final body = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (type.contains('html') || body.trimLeft().startsWith('<')) {
      final p = pageText(body);
      return '${p.title.isEmpty ? '' : '# ${p.title}\n'}$at\n\n${p.text}';
    }
    if (type.startsWith('image/') ||
        type.startsWith('video/') ||
        type.startsWith('audio/') ||
        type.contains('octet-stream') ||
        type.contains('pdf')) {
      return "$at is a file ($type), not a page I can read.";
    }
    return body;
  } finally {
    if (httpClient == null) client.close();
  }
}
