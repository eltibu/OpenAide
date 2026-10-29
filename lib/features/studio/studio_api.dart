import 'package:markdown/markdown.dart' as md;

import '../../core/api/openwebui_client.dart';
import '../notes/notes_api.dart' show fromServerTime;
import 'studio_doc.dart';

/// A Studio document as the server keeps it: an Open WebUI note, so it is
/// also in Notes on the web, with its versions stored beside its text.
class StudioDocument {
  const StudioDocument({
    required this.id,
    required this.title,
    required this.markdown,
    required this.updated,
    this.versions = const [],
  });

  factory StudioDocument.fromJson(Map j) {
    final data = (j['data'] as Map?) ?? const {};
    final content = (data['content'] as Map?) ?? const {};
    return StudioDocument(
      id: '${j['id']}',
      title: '${j['title'] ?? ''}',
      markdown: '${content['md'] ?? ''}',
      updated: fromServerTime((j['updated_at'] as num?) ?? 0),
      versions: [
        for (final v
            in (data[StudioApi.versionsKey] as List? ?? const [])
                .whereType<Map>())
          Version.fromJson(v),
      ],
    );
  }

  final String id;
  final String title;

  /// In lists, only the start of the text.
  final String markdown;
  final DateTime updated;

  /// Oldest first.
  final List<Version> versions;
}

class StudioApi {
  StudioApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/notes';
  static const versionsKey = 'nexus_versions';

  /// How many saved states a document keeps.
  static const keepVersions = 40;

  String _id(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<List<StudioDocument>> list() async => [
    for (final n
        in (await client.send('GET', '$_base/') as List? ?? const [])
            .whereType<Map>())
      StudioDocument.fromJson(n),
  ]..sort((a, b) => b.updated.compareTo(a.updated));

  Future<StudioDocument> get(String id) async =>
      StudioDocument.fromJson(await client.send('GET', _id(id)) as Map);

  /// The text as the web's note editor reads it (it prefers its rich form,
  /// so that is dropped and rebuilt from the Markdown).
  static Map<String, dynamic> content(String markdown) => {
    'json': null,
    'html': md.markdownToHtml(
      markdown,
      extensionSet: md.ExtensionSet.gitHubWeb,
    ),
    'md': markdown,
  };

  Future<StudioDocument> create(String title, String markdown) async =>
      StudioDocument.fromJson(
        await client.send(
          'POST',
          '$_base/create',
          body: {
            'title': title,
            'data': {
              'content': content(markdown),
              versionsKey: [
                Version(
                  markdown: markdown,
                  title: title,
                  at: DateTime.now(),
                  label: 'Created',
                ).toJson(),
              ],
            },
          },
        ) as Map,
      );

  /// Saves the text; [versions] (all of them, oldest first) when one was
  /// added.
  Future<void> save(
    String id, {
    required String title,
    required String markdown,
    List<Version>? versions,
  }) => client.send(
    'POST',
    '${_id(id)}/update',
    body: {
      'title': title,
      'data': {
        'content': content(markdown),
        if (versions != null)
          versionsKey: [
            for (final v in versions.skip(
              versions.length > keepVersions
                  ? versions.length - keepVersions
                  : 0,
            ))
              v.toJson(),
          ],
      },
    },
  );

  Future<void> delete(String id) => client.send('DELETE', '${_id(id)}/delete');
}
