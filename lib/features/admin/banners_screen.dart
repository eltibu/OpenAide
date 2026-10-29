/// Admin > Interface > Banners: notices shown across the top of the web
/// UI (and here) for everyone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../../core/i18n/app_strings.dart';

const bannerTypes = ['info', 'success', 'warning', 'error'];

/// A new banner as the web makes one.
Map<String, dynamic> newBanner() => {
  'id': const Uuid().v4(),
  'type': 'info',
  'title': '',
  'content': '',
  'dismissible': true,
  'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
};

class BannersScreen extends ConsumerStatefulWidget {
  const BannersScreen({super.key});

  @override
  ConsumerState<BannersScreen> createState() => _BannersScreenState();
}

class _BannersScreenState extends ConsumerState<BannersScreen> {
  List<Map<String, dynamic>>? _banners;
  Object? _error;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref
          .read(clientProvider)
          .send('GET', '/api/v1/configs/banners');
      _banners = [
        for (final b in res as List? ?? const [])
          if (b is Map) Map<String, dynamic>.of(b.cast<String, dynamic>()),
      ];
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    try {
      await ref
          .read(clientProvider)
          .send('POST', '/api/v1/configs/banners', body: {'banners': _banners});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: T('Saved')));
        setState(() => _dirty = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not saved: $e')));
      }
    }
  }

  void _changed() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final list = _banners;
    return Scaffold(
      appBar: AppBar(
        title: const T('Banners'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _dirty ? _save : null,
              child: const T('Save'),
            ),
          ),
        ],
      ),
      floatingActionButton: list == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                setState(() => list.add(newBanner()));
                _changed();
              },
              icon: const Icon(Icons.add),
              label: const T('Add banner'),
            ),
      body: list == null
          ? Center(
              child: _error != null
                  ? Text('Couldn\'t load banners.\n$_error')
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              children: [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: T(
                      'No banners. Add one to show a notice to everyone.',
                      style: TextStyle(color: context.nexus.muted),
                    ),
                  ),
                for (final b in list)
                  Card(
                    key: ValueKey(b['id']),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              DropdownButton<String>(
                                value: bannerTypes.contains(b['type'])
                                    ? '${b['type']}'
                                    : 'info',
                                items: [
                                  for (final t in bannerTypes)
                                    DropdownMenuItem(
                                      value: t,
                                      child: Text(
                                        '${t[0].toUpperCase()}${t.substring(1)}',
                                      ),
                                    ),
                                ],
                                onChanged: (t) {
                                  setState(() => b['type'] = t);
                                  _changed();
                                },
                              ),
                              const Spacer(),
                              const T('Can be closed'),
                              Switch(
                                value: b['dismissible'] != false,
                                onChanged: (on) {
                                  setState(() => b['dismissible'] = on);
                                  _changed();
                                },
                              ),
                              IconButton(
                                tooltip: tr('Remove banner'),
                                onPressed: () {
                                  setState(() => list.remove(b));
                                  _changed();
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: TextFormField(
                              initialValue: '${b['content'] ?? ''}',
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                labelText: tr('Message'),
                              ),
                              onChanged: (t) {
                                b['content'] = t;
                                _changed();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
