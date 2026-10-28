/// Telling the phone and the home network apart from the internet: the
/// assistant's web reading stays off the home network, and plain http is
/// accepted only there.
library;

import 'dart:io';

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
