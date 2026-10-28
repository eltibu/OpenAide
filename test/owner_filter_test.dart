import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/owner_filter.dart';

void main() {
  test('created by you, shared with you, or all', () {
    expect(ownerMatches(OwnerView.all, 'x', 'me'), isTrue);
    expect(ownerMatches(OwnerView.created, 'me', 'me'), isTrue);
    expect(ownerMatches(OwnerView.created, 'x', 'me'), isFalse);
    expect(ownerMatches(OwnerView.shared, 'x', 'me'), isTrue);
    expect(ownerMatches(OwnerView.shared, 'me', 'me'), isFalse);
    expect(ownerMatches(OwnerView.shared, 'me', null), isTrue);
  });
}
