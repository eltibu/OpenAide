import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/external_knowledge.dart';

void main() {
  test('a pgvector source sends its table and keeps no key', () {
    final f = ExternalSourceForm(
      provider: 'pgvector',
      name: 'Docs',
      endpoint: ' postgresql://u:p@h/db ',
      apiKey: 'ignored',
      sourceName: 'docs',
    );
    expect(f.connection()['auth_config'], {});
    expect(f.connection()['endpoint'], 'postgresql://u:p@h/db');
    final s = f.source();
    expect(s['config']['table_name'], 'document_chunk');
    expect(s['config']['vector_field'], 'vector');
    expect(f.testProblem('hi'), isNull);
    expect(f.testProblem(''), 'Type a test query');
  });

  test('qdrant needs no vector field; an edit keeps the saved key', () {
    final f = ExternalSourceForm(endpoint: 'https://q', sourceName: 'c')
      ..editing = true;
    expect(f.source()['config'].containsKey('vector_field'), isFalse);
    expect(f.connection()['auth_config'], isNull);
    f.apiKey = 'k';
    expect(f.connection()['auth_config'], {'type': 'bearer', 'api_key': 'k'});
    expect(f.connection()['name'], 'c');
    expect(f.testProblem('q'), isNull);
  });

  test('milvus asks for a vector field and sends its database', () {
    final f = ExternalSourceForm(
      provider: 'milvus',
      endpoint: 'http://m',
      sourceName: 'c',
      dbName: 'kb',
      fields: {...externalSchemaDefaults('milvus'), 'vector': ''},
    );
    expect(f.testProblem('q'), 'Fill in the vector field');
    expect(f.connection()['config'], {'timeout': 30, 'db_name': 'kb'});
  });
}
