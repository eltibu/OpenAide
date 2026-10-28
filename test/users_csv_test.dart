import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/config_editor.dart';

void main() {
  test('users export as the web\'s CSV', () {
    final csv = utf8.decode(
      usersCsv({
        'users': [
          {'id': '1', 'name': 'Ana "A"', 'email': 'a@x.io', 'role': 'admin'},
          {'id': '2', 'name': null, 'email': 'b@x.io', 'role': 'user'},
        ],
      }),
    );
    expect(
      csv,
      'id,name,email,role\n'
      '"1","Ana ""A""","a@x.io","admin"\n'
      '"2",,"b@x.io","user"',
    );
  });
}
