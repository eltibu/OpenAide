import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/terminal/file_links.dart';

void main() {
  String? kind(String s) {
    final r = fileRefIn(s);
    if (r == null) return null;
    return r.path != null ? 'path:${r.path}' : 'name:${r.hint ?? r.name}';
  }

  test('full paths open directly', () {
    expect(
      kind('/home/eltibu/Pictures/cat.png'),
      'path:/home/eltibu/Pictures/cat.png',
    );
    expect(kind('~/notes/todo.md'), 'path:~/notes/todo.md');
    expect(
      kind('/home/eltibu/projects/nexus/'),
      'path:/home/eltibu/projects/nexus/',
    );
    expect(
      kind('/home/eltibu/My Photos/beach day.jpg'),
      'path:/home/eltibu/My Photos/beach day.jpg',
    );
    expect(kind('file:///home/eltibu/a%20b.txt'), 'path:/home/eltibu/a b.txt');
    expect(kind('/srv/app/main.py:42'), 'path:/srv/app/main.py');
    expect(kind('"/etc/nginx/nginx.conf".'), 'path:/etc/nginx/nginx.conf');
    expect(kind('/etc/hosts'), 'path:/etc/hosts');
  });

  test('bare names are looked up', () {
    expect(kind('nexus_avatar.vrm'), 'name:nexus_avatar.vrm');
    expect(
      kind('Meeting notes 2026-10-27.docx'),
      'name:Meeting notes 2026-10-27.docx',
    );
    expect(kind('docs/plan.md'), 'name:docs/plan.md');
    expect(kind('./run.sh'), 'name:run.sh');
    expect(kind('Dockerfile'), 'name:Dockerfile');
    expect(kind('budget.XLSX'), 'name:budget.XLSX');
  });

  test('commands, code and other things are left alone', () {
    for (final s in [
      'ls -la /home/eltibu',
      'cat notes.md',
      'python3 script.py',
      'sudo systemctl restart open-webui',
      'cd /srv && make',
      'echo \$HOME',
      '*.png',
      'KEY=value',
      'https://example.com/a.png',
      'user@host:/srv/a.txt',
      'Node.js',
      'v1.2',
      '3.11',
      'example.com',
      '/api',
      '/help',
      '.py',
      '../secret.txt',
      'foo()',
      'npm install',
      'grep -r "x" .',
      'git status',
      'C:\\Users\\a.txt',
      '',
      'nexus',
    ]) {
      expect(fileRefIn(s), isNull, reason: s);
    }
  });

  test('spare copies are spotted', () {
    expect(isSpareCopy('/home/a/backups/cat.png'), isTrue);
    expect(isSpareCopy('/home/a/.Trash/cat.png'), isTrue);
    expect(isSpareCopy('/home/a/retired-2026/cat.png'), isTrue);
    expect(isSpareCopy('/home/a/cat.png.bak'), isTrue);
    expect(isSpareCopy('/home/a/cat.png~'), isTrue);
    expect(isSpareCopy('/home/a/pictures/cat.png'), isFalse);
  });

  test('lookup prefers the real, exact file', () {
    const ref = FileRef.name('nexus_avatar.vrm');
    final r = rankMatches(ref, [
      (path: '/data/backup/nexus_avatar.vrm', name: 'nexus_avatar.vrm'),
      (
        path: '/data/uploads/0b7c1d2e-1111-2222-3333-444455556666_nexus_avatar.vrm',
        name: '0b7c1d2e-1111-2222-3333-444455556666_nexus_avatar.vrm',
      ),
      (path: '/data/old_nexus_avatar.vrm', name: 'old_nexus_avatar.vrm'),
    ]);
    expect(r.exact, isTrue);
    expect(r.paths, [
      '/data/uploads/0b7c1d2e-1111-2222-3333-444455556666_nexus_avatar.vrm',
    ]);
  });

  test('several real copies are all offered, exact name first', () {
    const ref = FileRef.name('plan.md', hint: 'docs/plan.md');
    final r = rankMatches(ref, [
      (path: '/a/plan.md', name: 'plan.md'),
      (path: '/b/docs/plan.md', name: 'plan.md'),
      (path: '/c/plan.md', name: 'plan.md'),
    ]);
    expect(r.paths, ['/b/docs/plan.md']);

    final many = rankMatches(const FileRef.name('plan.md'), [
      (path: '/long/folder/plan.md', name: 'plan.md'),
      (path: '/a/plan.md', name: 'plan.md'),
    ]);
    expect(many.exact, isTrue);
    expect(many.paths, ['/a/plan.md', '/long/folder/plan.md']);
  });

  test('no exact name gives close matches', () {
    final r = rankMatches(const FileRef.name('plan.md'), [
      (path: '/a/plan-v2.md', name: 'plan-v2.md'),
    ]);
    expect(r.exact, isFalse);
    expect(r.paths, ['/a/plan-v2.md']);
  });

  test('only backup copies still come back', () {
    final r = rankMatches(const FileRef.name('cat.png'), [
      (path: '/a/backup/cat.png', name: 'cat.png'),
    ]);
    expect(r.paths, ['/a/backup/cat.png']);
  });
}
