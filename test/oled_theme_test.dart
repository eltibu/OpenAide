import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';

void main() {
  test('OLED Dark is true black; plain dark is not', () {
    expect(
      nexusTheme(Brightness.dark, oled: true).scaffoldBackgroundColor,
      Colors.black,
    );
    expect(
      nexusTheme(Brightness.dark).scaffoldBackgroundColor,
      isNot(Colors.black),
    );
  });
}
