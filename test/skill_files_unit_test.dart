import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/skill_files.dart';

void main() {
  test('text goes as text, anything else as base64', () {
    expect(putFile('a.md', [104, 105]), {
      'op': 'put',
      'path': 'a.md',
      'content': 'hi',
    });
    final bin = putFile('b.bin', [0, 255]);
    expect(bin['encoding'], 'base64');
    expect(bin['content'], 'AP8=');
  });

  test('paths must be relative and plain', () {
    expect(skillPathProblem('scripts/run.py'), isNull);
    expect(skillPathProblem(''), isNotNull);
    expect(skillPathProblem('/etc/x'), isNotNull);
    expect(skillPathProblem('a/../b'), isNotNull);
    expect(skillPathProblem('a//b'), isNotNull);
    expect(skillPathProblem('c:x'), isNotNull);
  });
}
