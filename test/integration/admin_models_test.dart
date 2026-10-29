// Runs against a real Open WebUI server as an admin; see
// server_sync_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/features/admin/admin_models_screen.dart';
import 'package:nexus_assistant/features/workspace/models_api.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  final email = Platform.environment['OWUI_EMAIL'];
  final password = Platform.environment['OWUI_PASSWORD'];
  final skip = url == null ? 'Set OWUI_URL, OWUI_EMAIL, OWUI_PASSWORD' : null;

  test('admin models: hide, switch off, defaults, order, reset', () async {
    final client = OpenWebUiClient(baseUrl: url!);
    await client.signIn(email!, password!);
    final api = ModelsApi(client);

    Future<List<AdminModel>> load() async {
      final res = await client.send('GET', '/api/models');
      final live = [
        for (final m in (res as Map)['data'] as List)
          (m as Map).cast<String, dynamic>(),
      ];
      return mergeAdminModels(live, await api.baseRecords());
    }

    var models = await load();
    expect(models, isNotEmpty);
    // One with no saved changes, so other tests' setups stay as they are.
    final m = models.lastWhere((x) => x.record == null);

    // Hiding saves a first record that stays public.
    await api.save({
      ...m.draft(const {}).json,
      'meta': {...m.draft(const {}).meta, 'hidden': true},
      'access_grants': publicModelGrants,
    }, create: true);
    models = await load();
    var now = models.firstWhere((x) => x.id == m.id);
    expect(now.hidden, isTrue);
    expect(now.live, isNotNull, reason: 'still listed for everyone');

    // Switched off, it leaves /api/models but stays on the admin page.
    await api.toggle(m.id);
    models = await load();
    now = models.firstWhere((x) => x.id == m.id);
    expect(now.active, isFalse);
    expect(now.live, isNull);
    await api.toggle(m.id);

    // Defaults, pinned and order round-trip.
    final cfg = await api.config();
    await api.saveConfig({
      ...cfg,
      'DEFAULT_MODELS': m.id,
      'DEFAULT_PINNED_MODELS': m.id,
      'MODEL_ORDER_LIST': [for (final x in models.reversed) x.id],
    });
    final saved = await api.config();
    expect(saved['DEFAULT_MODELS'], m.id);
    expect(saved['DEFAULT_PINNED_MODELS'], m.id);
    expect((saved['MODEL_ORDER_LIST'] as List).first, models.last.id);
    await api.saveConfig(cfg);

    // Export and import bring the changes back.
    final exported = [
      (await api.baseRecords()).firstWhere((r) => r.id == m.id).json,
    ];
    await api.delete(m.id);
    expect((await load()).firstWhere((x) => x.id == m.id).record, isNull);
    await api.import(exported);
    expect((await load()).firstWhere((x) => x.id == m.id).hidden, isTrue);

    // Reset to defaults.
    await api.delete(m.id);
  }, skip: skip);
}
