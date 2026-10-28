import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/email/email_html.dart';

void main() {
  test('internet pictures and styles are blocked until asked for', () {
    final page = emailPage('<img src="https://t.example/p.gif">');
    expect(page, contains("img-src data:;"));
    expect(page, isNot(contains('img-src *')));
    expect(emailPage('x', remote: true), contains('img-src * data:'));
    expect(page, isNot(contains('script-src')));
  });

  test('spots content that would load from the internet', () {
    expect(hasRemoteContent('<img src="https://t.example/p.gif">'), isTrue);
    expect(hasRemoteContent("<td background='http://x/y.png'>"), isTrue);
    expect(hasRemoteContent('<div style="background:url(//x/y.png)">'), isTrue);
    expect(hasRemoteContent('<img src="data:image/png;base64,AAA">'), isFalse);
    expect(
      hasRemoteContent('<a href="https://shop.example">Shop</a> hello'),
      isFalse,
    );
  });
}
