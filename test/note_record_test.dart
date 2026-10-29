import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/notes/notes_screen.dart';

void main() {
  test('recorded words go in at the cursor, with a space if needed', () {
    var v = insertSaid(
      const TextEditingValue(
        text: 'Hello world',
        selection: TextSelection.collapsed(offset: 5),
      ),
      'there',
    );
    expect(v.text, 'Hello there world');
    expect(v.selection.baseOffset, 11);

    v = insertSaid(const TextEditingValue(text: 'Line\n'), 'next');
    expect(v.text, 'Line\nnext');

    v = insertSaid(
      const TextEditingValue(
        text: 'swap this out',
        selection: TextSelection(baseOffset: 5, extentOffset: 9),
      ),
      'that',
    );
    expect(v.text, 'swap that out');
  });
}
