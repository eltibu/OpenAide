import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/models/model_info.dart';
import 'package:nexus_assistant/features/chat/request_options.dart';

ModelInfo model(Map<String, dynamic> meta) => ModelInfo.fromJson({
  'id': 'nexus',
  'name': 'nexus',
  'info': {'meta': meta},
});

void main() {
  test("sends the model's tools, filters and terminal like the web UI", () {
    final o = requestOptions(
      model({
        'toolIds': ['house'],
        'defaultFilterIds': ['guard'],
        'terminalId': 'mainframe',
      }),
      null,
      null,
    );
    expect(o['tool_ids'], ['house']);
    expect(o['filter_ids'], ['guard']);
    expect(o['terminal_id'], 'mainframe');
    expect(o['features'], {'memory': true});
  });

  test('memory follows the person, then the site', () {
    final m = model({});
    expect(
      requestOptions(m, {
        'ui': {'memory': false},
      }, null)['features'],
      isEmpty,
    );
    expect(
      requestOptions(m, null, {
        'features': {'enable_memories': false},
      })['features'],
      isEmpty,
    );
  });

  test('a default feature needs the capability and the admin switch', () {
    final m = model({
      'defaultFeatureIds': ['web_search', 'image_generation'],
      'capabilities': {'web_search': true, 'image_generation': false},
    });
    final features =
        requestOptions(m, null, {
              'features': {
                'enable_web_search': true,
                'enable_image_generation': true,
              },
            })['features']
            as Map;
    expect(features['web_search'], isTrue);
    expect(features.containsKey('image_generation'), isFalse);
  });

  test("passes the person's chat params", () {
    final o = requestOptions(model({}), {
      'ui': {
        'params': {'function_calling': 'native'},
      },
    }, null);
    expect(o['params'], {'function_calling': 'native'});
  });
}
