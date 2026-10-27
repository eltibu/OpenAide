import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/studio/listen.dart';

/// A 40 ms frame: a tone at [loud] (0 to 1), or quiet hiss.
Uint8List frame(double loud) {
  final b = ByteData(960 * 2);
  for (var i = 0; i < 960; i++) {
    final v = loud > 0
        ? math.sin(i * 2 * math.pi * 220 / micRate) * loud
        : (i.isEven ? 0.002 : -0.002);
    b.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('pieces are cut at a pause once long enough', () {
    final c = Cutter();
    final pieces = <Uint8List>[];
    void feed(double loud, int seconds) {
      for (var i = 0; i < seconds * 25; i++) {
        final p = c.add(frame(loud));
        if (p != null) pieces.add(p);
      }
    }

    feed(0.3, 2);
    feed(0, 1); // A pause, but too soon to cut.
    expect(pieces, isEmpty);
    feed(0.3, 2);
    feed(0, 1);
    expect(pieces.length, 1);
    // Five seconds and a bit of audio, in 16-bit samples.
    expect(pieces.first.length, greaterThan(micRate * 2 * 5));
  });

  test('long speech is cut at the longest, silence is dropped', () {
    final c = Cutter(longest: const Duration(seconds: 10));
    var cuts = 0;
    for (var i = 0; i < 25 * 25; i++) {
      if (c.add(frame(0.3)) != null) cuts++;
    }
    expect(cuts, 2);
    final quiet = Cutter(longest: const Duration(seconds: 5));
    for (var i = 0; i < 25 * 20; i++) {
      expect(quiet.add(frame(0)), isNull);
    }
    expect(quiet.flush(), isNull);
  });

  test('a WAV file has the right header', () {
    final wav = wavFile(List.filled(4800, 0));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final d = ByteData.sublistView(wav);
    expect(d.getUint32(24, Endian.little), micRate);
    expect(d.getUint32(40, Endian.little), 4800);
    expect(wav.length, 44 + 4800);
  });
}
