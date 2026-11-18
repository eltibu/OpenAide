/// Open WebUI version checks, for behaviour the server doesn't announce in
/// its features (`/api/config` carries `version`).
library;

/// Whether [version] (such as "0.13.4") is at least [major].[minor].[patch].
/// An unknown or unreadable version counts as new enough, as the app is
/// made for the newest server.
bool serverAtLeast(String? version, int major, int minor, int patch) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(version?.trim() ?? '');
  if (m == null) return true;
  final have = [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  final want = [major, minor, patch];
  for (var i = 0; i < 3; i++) {
    if (have[i] != want[i]) return have[i] > want[i];
  }
  return true;
}

/// Open WebUI 0.13.4 and later: coding agent replies can be regenerated and
/// earlier messages edited, chats keep their terminal, and so on.
bool isOwui0134(Map<String, dynamic>? config) =>
    serverAtLeast('${config?['version'] ?? ''}', 0, 13, 4);
