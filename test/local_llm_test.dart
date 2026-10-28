import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/ai/ai_providers.dart';
import 'package:nexus_assistant/core/ai/local_llm.dart';

const _gb = 1024 * 1024 * 1024;

/// Feeds [pieces] through a splitter: (text, thinking).
(String, String) _split(List<String> pieces) {
  final s = ThinkSplitter();
  final text = StringBuffer();
  final thought = StringBuffer();
  for (final p in [...pieces.map(s.add), s.close()]) {
    text.write(p?.text ?? '');
    thought.write(p?.thinking ?? '');
  }
  return ('$text', '$thought');
}

void main() {
  test('local models have picker ids like other providers', () {
    final id = providerModelId(AiProvider.local, 'Qwen3-1.7B-Q4_K_M.gguf');
    expect(id, 'direct:local:Qwen3-1.7B-Q4_K_M.gguf');
    final parsed = parseProviderModel(id)!;
    expect(parsed.provider, AiProvider.local);
    expect(parsed.model, 'Qwen3-1.7B-Q4_K_M.gguf');
  });

  group('ThinkSplitter', () {
    test('plain replies are all text', () {
      expect(_split(['Hello', ' there', '!']), ('Hello there!', ''));
    });

    test('thinking is split out, even with tags cut across pieces', () {
      expect(
        _split(['<thi', 'nk>\nLet me see', '.</th', 'ink>\n\nIt is ', '4.']),
        ('It is 4.', '\nLet me see.'),
      );
    });

    test('a lone < in text is kept', () {
      expect(_split(['a <', ' b']), ('a < b', ''));
      expect(_split(['x <']), ('x <', ''));
    });

    test('empty thinking (thinking off) leaves only the answer', () {
      expect(_split(['<think>\n\n</think>\n\n', 'Hi']), ('Hi', '\n\n'));
    });
  });

  test('fitHistory keeps the newest messages and the system prompt', () {
    final chat = [
      const AiMessage('system', 'Be brief.'),
      const AiMessage('user', 'aaaaaaaaaa'),
      const AiMessage('assistant', 'bbbbbbbbbb'),
      const AiMessage('user', 'cccccccccc'),
    ];
    final kept = fitHistory(chat, maxChars: 25);
    expect([for (final m in kept) m.role], ['system', 'user']);
    expect(kept.last.text, 'cccccccccc');
    expect(fitHistory(chat, maxChars: 1000), hasLength(4));
  });

  test('fit check against phone memory', () {
    expect(fitFor(1 * _gb, 12 * _gb), Fit.good);
    expect(fitFor((2.5 * _gb).round(), 12 * _gb), Fit.good);
    expect(fitFor((2.5 * _gb).round(), 6 * _gb), Fit.tight);
    expect(fitFor(5 * _gb, 6 * _gb), Fit.tooBig);
  });

  test('Hugging Face files: single GGUF files, smallest first', () {
    final files = ggufFiles('me/model-GGUF', [
      {'rfilename': 'README.md', 'size': 10},
      {'rfilename': 'model-Q8_0.gguf', 'size': 900},
      {'rfilename': 'model-Q4_K_M.gguf', 'size': 500},
      {'rfilename': 'mmproj-model-f16.gguf', 'size': 300},
      {'rfilename': 'big/model-Q8-00001-of-00002.gguf', 'size': 9000},
    ]);
    expect([for (final f in files) f.name], ['model-Q4_K_M', 'model-Q8_0']);
    expect(
      files.first.url,
      'https://huggingface.co/me/model-GGUF/resolve/main/model-Q4_K_M.gguf?download=true',
    );
  });

  test('links to models', () {
    final hf = modelFromLink(
      'https://huggingface.co/unsloth/Qwen3-4B-GGUF/blob/main/Qwen3-4B-Q4_K_M.gguf',
    )!;
    expect(hf.repo, 'unsloth/Qwen3-4B-GGUF');
    expect(hf.name, 'Qwen3-4B-Q4_K_M');
    expect(
      hf.url,
      'https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf',
    );
    expect(
      modelFromLink('https://example.com/m/tiny.gguf')!.repo,
      'example.com',
    );
    expect(
      modelFromLink('https://huggingface.co/unsloth/Qwen3-4B-GGUF'),
      isNull,
    );
    expect(modelFromLink('not a link'), isNull);
  });
}
