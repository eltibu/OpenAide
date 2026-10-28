import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/knowledge_api.dart';

void main() {
  test('a web page is named after its address', () {
    expect(webpageFileName('https://Ex.com/a?b=1'), 'https___ex_com_a_b_1');
    expect(webpageFileName('https://x.io/${'a' * 80}'), hasLength(50));
  });
}
