import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/admin_models_screen.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

void main() {
  test('admin list keeps connection models and switched-off ones', () {
    final models = mergeAdminModels(
      [
        {'id': 'b', 'name': 'B'},
        {
          'id': 'a',
          'name': 'A',
          'info': {'base_model_id': null},
        },
        // A workspace model belongs on the workspace page.
        {
          'id': 'mine',
          'name': 'Mine',
          'info': {'base_model_id': 'a'},
        },
      ],
      [
        WorkspaceModel({
          'id': 'a',
          'name': 'A',
          'meta': {'hidden': true},
        }),
        WorkspaceModel({'id': 'off', 'name': 'Off', 'is_active': false}),
      ],
    );
    expect([for (final m in models) m.id], ['b', 'a', 'off']);
    expect(models[1].hidden, isTrue);
    expect(models[2].active, isFalse);
    expect(models[2].live, isNull);
    // Nothing saved yet: the editor starts with the usual abilities.
    final draft = models[0].draft(const {});
    expect(draft.baseModelId, isNull);
    expect(draft.capabilities['vision'], isTrue);
  });
}
