import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/groups_screen.dart';

void main() {
  final groups = [
    {'id': 'c', 'name': 'Child', 'parent_group_id': 'a'},
    {'id': 'a', 'name': 'Alpha', 'parent_group_id': null},
    {'id': 'g', 'name': 'Grandchild', 'parent_group_id': 'c'},
    {'id': 'b', 'name': 'beta', 'parent_group_id': 'gone'},
  ];

  test('groups in tree order, folded where asked', () {
    String show(List<(Map<String, dynamic>, int)> t) =>
        [for (final (g, d) in t) '${'-' * d}${g['id']}'].join(' ');
    expect(show(groupTree(groups)), 'a -c --g b');
    expect(show(groupTree(groups, collapsed: {'c'})), 'a -c b');
    expect(show(groupTree(groups, collapsed: {'a'})), 'a b');
  });

  test('a group and everything under it', () {
    expect(groupAndBelow(groups, 'a'), {'a', 'c', 'g'});
    expect(groupAndBelow(groups, 'b'), {'b'});
  });

  test('emails from a Name,Email file', () {
    final (emails, bad) = parseGroupCsv(
      'Name,Email\r\nAna,ANA@x.io\nbroken\n\nBo, bo@x.io\nAna,ana@x.io\n',
    );
    expect(emails, ['ana@x.io', 'bo@x.io']);
    expect(bad, [2]);
  });
}
