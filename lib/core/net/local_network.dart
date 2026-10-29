/// Telling the phone and the home network apart from the internet: the
/// assistant's web reading stays off the home network, and plain http is
/// accepted only there.
library;

import 'dart:io';

import 'package:http/http.dart' as http;

/// Whether [a] is on this phone or the home network: loopback, private
/// ranges (10/8, 172.16/12, 192.168/16, fc00::/7), link-local and CGNAT.
bool isLocalAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 0 ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] < 128);
  }
  // ::, fc00::/7, and IPv4 written as ::ffff:a.b.c.d.
  if (b.every((x) => x == 0) || (b[0] & 0xfe) == 0xfc) return true;
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  return mapped &&
      isLocalAddress(InternetAddress.fromRawAddress(b.sublist(12)));
}

/// Whether [host] names this phone or a machine on the home network: a
/// local address, localhost, a name with no dots (like `nas`), or a
/// home-network suffix such as `.local` or `.lan`.
bool isLocalHost(String host) {
  var h = host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final ip = InternetAddress.tryParse(h);
  if (ip != null) return isLocalAddress(ip);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty || !h.contains('.')) return true;
  const suffixes = [
    '.localhost',
    '.local',
    '.lan',
    '.home',
    '.home.arpa',
    '.internal',
    '.intranet',
    '.localdomain',
  ];
  return h == 'localhost' || suffixes.any(h.endsWith);
}

/// Plain http to somewhere on the internet: anyone on the way could read
/// what is sent, passwords included.
bool isInsecureRemote(Uri u) => u.scheme == 'http' && !isLocalHost(u.host);

/// Whether [u] stays on this phone: loopback only, so nothing crosses a
/// network.
bool isOnPhone(Uri u) {
  var h = u.host.toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  return InternetAddress.tryParse(h)?.isLoopback ?? false;
}

/// Whether what is sent to [u] is encrypted on the way: https, or an
/// address on this phone itself.
bool isEncrypted(Uri u) =>
    u.scheme == 'https' || u.scheme == 'wss' || isOnPhone(u);

/// Plain http refused: anyone on the network could read what is sent.
class UnencryptedAddress implements Exception {
  const UnencryptedAddress(this.url);
  final Uri url;

  @override
  String toString() =>
      'OpenAide only connects to ${url.host} over https, so nobody on the '
      'network can read what is sent. Use its https:// address.';
}

/// For terminals, tool servers and MCP servers: commands, files and keys
/// go only over https (or to this phone itself), on any network. With
/// [homeNetworkOk] (your own server's connection), plain http is also
/// allowed on the home network, never across the internet.
class EncryptedOnlyClient extends http.BaseClient {
  EncryptedOnlyClient([http.Client? inner, this.homeNetworkOk = false])
    : _inner = inner ?? http.Client();
  final http.Client _inner;
  final bool homeNetworkOk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final ok = homeNetworkOk
        ? !isInsecureRemote(request.url)
        : isEncrypted(request.url);
    if (!ok) {
      return Future.error(UnencryptedAddress(request.url));
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
