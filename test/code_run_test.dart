import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/code_run.dart';

void main() {
  test('Run is offered for Python', () {
    expect(isPythonBlock('python', 'x = 1'), isTrue);
    expect(isPythonBlock('py', ''), isTrue);
    expect(isPythonBlock('js', 'print(1)'), isFalse);
    expect(isPythonBlock('', 'import os\nprint(os.name)'), isTrue);
    expect(isPythonBlock('', 'echo hi'), isFalse);
  });

  test('pictures in the output are shown as pictures', () {
    final out = RunOutput.from({
      'stdout': 'a\ndata:image/png;base64,AAA\nb',
      'result': 'data:image/png;base64,BBB',
      'stderr': 'oops',
    });
    expect(out.stdout, 'a\nb');
    expect(out.result, '');
    expect(out.stderr, 'oops');
    expect(out.images, [
      'data:image/png;base64,AAA',
      'data:image/png;base64,BBB',
    ]);
  });

  test('the Pyodide page carries the code safely', () {
    final page = pyodidePage('print("a")\n</script>');
    expect(page, contains(r'print(\"a\")'));
    expect(page, contains(r'<\/script>'));
    expect('</script>'.allMatches(page).length, 2);
  });
}
