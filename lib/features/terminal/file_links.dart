/// Spots file paths and file names in replies, so a tap on one opens it in
/// the Files browser instead of doing nothing, the way the web chat's
/// loader.js add-on does on the mainframe.
library;

/// A file a reply mentions: a full [path] (absolute or from home), or just a
/// [name] to look up, maybe with the folders before it ([hint]).
class FileRef {
  const FileRef.path(String this.path) : name = null, hint = null;
  const FileRef.name(String this.name, {this.hint}) : path = null;

  final String? path;
  final String? name;

  /// Folders written before a bare name (`docs/a.md` → `docs/a.md`), used to
  /// rank the lookup's matches.
  final String? hint;

  @override
  String toString() => path ?? hint ?? name!;
}

/// File types a bare name may end in to count as a file. A full path needs
/// none; a bare word with a dot (e.g. "v1.2", "example.com") is not a file.
const fileTypes = {
  // documents and text
  'txt', 'md', 'markdown', 'rst', 'pdf', 'doc', 'docx', 'odt', 'rtf', 'xls',
  'xlsx', 'ods', 'csv', 'tsv', 'ppt', 'pptx', 'odp', 'epub', 'tex', 'log',
  'html', 'htm', 'xml', 'json', 'jsonl', 'ndjson', 'yaml', 'yml', 'toml',
  'ini', 'cfg', 'conf', 'env', 'properties', 'plist', 'srt', 'vtt', 'ics',
  'vcf', 'eml', 'msg', 'sql', 'db', 'sqlite', 'sqlite3', 'bak', 'lock',
  'pem', 'crt', 'key', 'pub', 'service', 'timer', 'socket', 'mount',
  // code
  'py', 'ipynb', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'svelte', 'vue',
  'css', 'scss', 'sass', 'less', 'dart', 'kt', 'kts', 'java', 'gradle',
  'swift', 'go', 'rs', 'rb', 'php', 'pl', 'lua', 'r', 'c', 'h', 'cc', 'cpp',
  'hpp', 'cs', 'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat', 'cmd', 'mk',
  'cmake', 'dockerfile', 'tf', 'nix', 'patch', 'diff',
  // pictures, sound, video, 3D
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico', 'heic', 'heif',
  'tif', 'tiff', 'avif', 'psd', 'xcf', 'raw', 'mp3', 'wav', 'ogg', 'oga',
  'opus', 'flac', 'm4a', 'aac', 'wma', 'mid', 'midi', 'mp4', 'mkv', 'mov',
  'webm', 'avi', 'wmv', 'm4v', 'flv', '3gp', 'vrm', 'glb', 'gltf', 'fbx',
  'obj', 'stl', 'blend', 'usdz', 'vrma', 'pmx', 'ply', 'step', 'stp',
  // fonts, archives, packages, disks, models
  'ttf', 'otf', 'woff', 'woff2', 'zip', 'gz', 'tgz', 'tar', 'xz', 'bz2',
  'zst', '7z', 'rar', 'apk', 'aab', 'deb', 'rpm', 'appimage', 'jar', 'whl',
  'exe', 'msi', 'dmg', 'iso', 'img', 'qcow2', 'vmdk', 'bin', 'gguf',
  'safetensors', 'onnx', 'pt', 'pth', 'ckpt', 'npy', 'npz', 'parquet', 'pkl',
};

/// Names with a file type's ending that are almost always the project, not
/// a file ("Node.js").
const _notFiles = {
  'node.js',
  'next.js',
  'nuxt.js',
  'vue.js',
  'react.js',
  'three.js',
  'chart.js',
  'd3.js',
  'express.js',
  'nest.js',
  'deno.js',
  'p5.js',
  'socket.io',
  'asp.net',
  'vue.ts',
};

/// Words that start a command, so `cat notes.md` is a command, not a file.
const _commands = {
  'cat',
  'ls',
  'cd',
  'cp',
  'mv',
  'rm',
  'mkdir',
  'touch',
  'chmod',
  'chown',
  'sudo',
  'nano',
  'vim',
  'vi',
  'less',
  'more',
  'head',
  'tail',
  'grep',
  'find',
  'python',
  'python3',
  'pip',
  'pip3',
  'node',
  'npm',
  'npx',
  'yarn',
  'pnpm',
  'git',
  'docker',
  'systemctl',
  'journalctl',
  'curl',
  'wget',
  'bash',
  'sh',
  'source',
  'echo',
  'tar',
  'unzip',
  'zip',
  'scp',
  'ssh',
  'rsync',
  'open',
  'code',
  'flutter',
  'dart',
  'go',
  'cargo',
  'make',
  'apt',
  'brew',
  'kill',
  'ffmpeg',
  'du',
  'df',
  'stat',
  'file',
  'xdg-open',
  'start',
  'run',
  'exec',
};

final _uuidPrefix = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_',
  caseSensitive: false,
);

/// The file [text] names, or null when it is a command, a link, code or
/// anything else.
FileRef? fileRefIn(String text) {
  var s = text.trim();
  // Quotes and closing punctuation around it.
  for (var before = ''; before != s;) {
    before = s;
    s = s
        .replaceAll(RegExp(r'''^["'“‘(<\[]+|["'”’)>\]]+$'''), '')
        .replaceAll(RegExp(r'[.,;:!?]+$'), '');
  }
  if (s.startsWith('file://')) {
    s = Uri.decodeFull(s.substring('file://'.length));
  }
  if (s.isEmpty || s.length > 512 || s.contains('\n')) return null;
  if (s.contains('://')) return null;
  // `name.py:12` or `name.py:12:4` (a line in a file).
  s = s.replaceFirst(RegExp(r':\d+(:\d+)?$'), '');
  // Shell syntax, wildcards and placeholders mean it isn't one file.
  if (RegExp(r'[|&;<>$`*?=\{\}\[\]\\"]').hasMatch(s)) return null;
  if (RegExp(r'^[\w.-]+@[\w.-]+:').hasMatch(s)) return null; // user@host:
  final words = s.split(RegExp(r'\s+'));
  if (words.length > 1) {
    // A space is fine inside a path ("My Photos/a.png"), not in a command.
    if (_commands.contains(words.first.toLowerCase())) return null;
    if (words.skip(1).any((w) => w.startsWith('-') || w.startsWith('/'))) {
      return null;
    }
  }

  final isPath = s.startsWith('/') || s.startsWith('~/');
  if (isPath) {
    if (s.length < 2 || s.contains('//')) return null;
    final parts = s.split('/').where((p) => p.isNotEmpty).toList();
    // A one-word path like "/api" or "/help" is a route or a command.
    if (parts.length < 2 && !_hasFileType(parts.lastOrNull ?? '')) {
      return null;
    }
    if (words.length > 1 && !s.contains('/', 1)) return null;
    return FileRef.path(s);
  }

  var rel = s;
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }
  if (rel.startsWith('../')) return null;
  final name = rel.split('/').last;
  if (name.isEmpty || name.startsWith('.') || rel.startsWith('/')) {
    return null;
  }
  if (!_hasFileType(name)) return null;
  if (_notFiles.contains(name.toLowerCase())) return null;
  // A name needs a letter or digit before its type ("v1.2" has none left).
  final dot = name.lastIndexOf('.');
  final stem = dot < 0 ? name : name.substring(0, dot);
  if (!RegExp(r'[A-Za-z0-9]').hasMatch(stem)) return null;
  // Version numbers and domains: "1.2.3", "3.11".
  if (RegExp(r'^[\d.]+$').hasMatch(stem)) return null;
  return FileRef.name(name, hint: rel.contains('/') ? rel : null);
}

bool _hasFileType(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) {
    return const {
      'dockerfile',
      'makefile',
      'readme',
      'license',
    }.contains(name.toLowerCase());
  }
  return fileTypes.contains(name.substring(i + 1).toLowerCase());
}

/// Whether [path] sits in a backup, retired or trash folder, or is itself a
/// backup copy. Those are skipped when a real copy exists too.
bool isSpareCopy(String path) {
  final parts = path.toLowerCase().split('/');
  final folders = parts.take(parts.length - 1);
  for (final f in folders) {
    if (f.contains('backup') ||
        f.contains('retired') ||
        f.contains('trash') ||
        f == 'bak' ||
        f == '.bak' ||
        f.endsWith('.bak') ||
        f.endsWith('.old') ||
        f == 'old' ||
        f == 'deprecated') {
      return true;
    }
  }
  final leaf = parts.last;
  return leaf.endsWith('~') ||
      leaf.endsWith('.bak') ||
      leaf.endsWith('.orig') ||
      RegExp(r'\.(bak|old|orig)[.-]?\d*$').hasMatch(leaf);
}

/// How well a file at [path] called [found] answers a lookup for [ref]:
/// 0 is the exact name, 1 the name with Open WebUI's upload id in front,
/// null when it isn't that file at all (a close match only).
int? nameMatch(FileRef ref, String found) {
  final want = ref.name!.toLowerCase();
  final got = found.toLowerCase();
  if (got == want) return 0;
  if (_uuidPrefix.hasMatch(got) && got.replaceFirst(_uuidPrefix, '') == want) {
    return 1;
  }
  return null;
}

/// The lookup's answer for [ref], best first: exact names (and Open WebUI
/// uploads with their id in front) when there are any, else the close
/// matches. Backup, retired and trash copies drop out when a real one is
/// there. [hits] are (path, name) pairs from the server's search.
({List<String> paths, bool exact}) rankMatches(
  FileRef ref,
  List<({String path, String name})> hits,
) {
  final seen = <String>{};
  final unique = [
    for (final h in hits)
      if (seen.add(h.path)) h,
  ];
  final exact = [
    for (final h in unique)
      if (nameMatch(ref, h.name) != null) h,
  ];
  final pool = exact.isNotEmpty ? exact : unique;
  final real = pool.where((h) => !isSpareCopy(h.path)).toList();
  final kept = real.isNotEmpty ? real : pool;
  final hint = ref.hint?.toLowerCase();
  int score(({String path, String name}) h) {
    var s = (nameMatch(ref, h.name) ?? 2) * 10;
    if (hint != null && h.path.toLowerCase().endsWith('/$hint')) s -= 5;
    return s;
  }

  kept.sort((a, b) {
    final d = score(a) - score(b);
    return d != 0 ? d : a.path.length - b.path.length;
  });
  // A folder hint that one match fits decides it.
  if (hint != null && exact.isNotEmpty) {
    final fits = kept
        .where((h) => h.path.toLowerCase().endsWith('/$hint'))
        .toList();
    if (fits.length == 1) return (paths: [fits.single.path], exact: true);
  }
  return (paths: [for (final h in kept) h.path], exact: exact.isNotEmpty);
}
