/// The web's workspace view picker: everything, what you made, or what
/// others shared with you. One choice for every workspace list, as the web
/// keeps one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_screen.dart' show meProvider;

enum OwnerView { all, created, shared }

class OwnerViewNotifier extends Notifier<OwnerView> {
  @override
  OwnerView build() => OwnerView.all;
  void set(OwnerView v) => state = v;
}

final ownerViewProvider = NotifierProvider<OwnerViewNotifier, OwnerView>(
  OwnerViewNotifier.new,
);

/// Whether an item made by [owner] shows in [view] for [me]. Until it is
/// known who you are, everything shows.
bool ownerMatches(OwnerView view, Object? owner, String? me) =>
    view == OwnerView.all ||
    me == null ||
    (view == OwnerView.created) == ('$owner' == me);

/// [items] as the current view shows them.
List<T> ownerFiltered<T>(
  WidgetRef ref,
  Iterable<T> items,
  Object? Function(T) owner,
) {
  final view = ref.watch(ownerViewProvider);
  final me = ref.watch(meProvider).value?['id']?.toString();
  return [
    for (final i in items)
      if (ownerMatches(view, owner(i), me)) i,
  ];
}

/// The app bar button that picks the view.
class OwnerFilterButton extends ConsumerWidget {
  const OwnerFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(ownerViewProvider);
    return PopupMenuButton<OwnerView>(
      tooltip: 'Show',
      icon: Icon(
        view == OwnerView.all ? Icons.filter_list : Icons.filter_list_alt,
      ),
      onSelected: ref.read(ownerViewProvider.notifier).set,
      itemBuilder: (_) => [
        for (final (v, label) in const [
          (OwnerView.all, 'All'),
          (OwnerView.created, 'Created by you'),
          (OwnerView.shared, 'Shared with you'),
        ])
          CheckedPopupMenuItem(
            value: v,
            checked: view == v,
            child: Text(label),
          ),
      ],
    );
  }
}
