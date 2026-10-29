import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/artifacts_view.dart';

void main() {
  test('html, css and js blocks make one page, like the web UI', () {
    const reply = '''Here you go:
```html
<button id="b">Hi</button>
```
```css
button { color: red; }
```
```js
document.getElementById('b').onclick = () => {};
```''';
    final a = artifactsOf(reply, 'm1');
    expect(a, hasLength(1));
    expect(a.single.isSvg, isFalse);
    expect(a.single.content, contains('<button id="b">Hi</button>'));
    expect(a.single.content, contains('button { color: red; }'));
    expect(a.single.content, contains("getElementById('b')"));
  });

  test('each html block is its own page; svg only without pages', () {
    expect(
      artifactsOf('```html\n<p>a</p>\n```\n```html\n<p>b</p>\n```', 'm'),
      hasLength(2),
    );
    final svg = artifactsOf('```svg\n<svg></svg>\n```', 'm');
    expect(svg.single.isSvg, isTrue);
    expect(svg.single.page, contains('<svg></svg>'));
    expect(artifactsOf('```python\nprint(1)\n```', 'm'), isEmpty);
  });

  test('code inside reasoning is ignored', () {
    expect(
      artifactsOf(
        '<details type="reasoning">```html\n<p>x</p>\n```</details>ok',
        'm',
      ),
      isEmpty,
    );
  });

  test('inline html without code blocks', () {
    final a = artifactsOf('<html><b>hi</b></html><style>b{}</style>', 'm');
    expect(a.single.content, contains('<b>hi</b>'));
    expect(a.single.content, contains('b{}'));
  });
}
