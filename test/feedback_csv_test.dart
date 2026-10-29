import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/evaluations_screen.dart';

void main() {
  test('ratings export as the web\'s CSV', () {
    final csv = feedbacksCsv([
      {
        'id': 'f1',
        'user_id': 'u1',
        'meta': {'chat_id': 'c1'},
        'data': {
          'model_id': 'm',
          'sibling_model_ids': ['a', 'b'],
          'rating': 1,
          'reason': 'Accurate',
          'comment': 'Said "hi", then left',
        },
        'created_at': 1,
        'updated_at': 2,
      },
    ]).split('\n');
    expect(
      csv.first,
      'id,user_id,chat_id,model_id,sibling_model_ids,rating,reason,comment,'
      'created_at,updated_at',
    );
    expect(csv.last, 'f1,u1,c1,m,a;b,1,Accurate,"Said ""hi"", then left",1,2');
    expect(feedbacksCsv([]), '');
  });
}
