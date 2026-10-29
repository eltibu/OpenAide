import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';

/// The chat's right-hand panel on a wide screen (an unfolded Fold, a
/// tablet), as in the Claude app: artifacts and pictures open beside the
/// conversation, the chat list steps aside while it is open, and comes back
/// when it closes. On a phone-sized screen they open full screen instead.
const wideLayout = 720.0;

/// What the panel shows.
class SidePanelContent {
  const SidePanelContent(this.id, this.builder);

  /// Opening the same thing again keeps it; something else replaces it.
  final Object id;
  final WidgetBuilder builder;
}

/// Lets anything in the chat open the panel.
class SidePanelHost extends InheritedWidget {
  const SidePanelHost({
    super.key,
    required this.current,
    required this.open,
    required this.close,
    required super.child,
  });

  final SidePanelContent? current;
  final void Function(SidePanelContent content) open;
  final VoidCallback close;

  static SidePanelHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SidePanelHost>();

  @override
  bool updateShouldNotify(SidePanelHost old) => current != old.current;
}

/// Marks what is inside the panel, so its top bar shows a close button
/// instead of a back arrow.
class InSidePanel extends InheritedWidget {
  const InSidePanel({super.key, required this.close, required super.child});
  final VoidCallback close;

  static InSidePanel? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InSidePanel>();

  @override
  bool updateShouldNotify(InSidePanel old) => false;
}

/// Opens [builder]'s page in the side panel when there is one, else as a
/// full-screen page.
void showBeside(BuildContext context, Object id, WidgetBuilder builder) {
  final host = SidePanelHost.maybeOf(context);
  if (host != null) {
    host.open(SidePanelContent(id, builder));
  } else {
    Navigator.push(context, MaterialPageRoute<void>(builder: builder));
  }
}

/// The close button for a page shown in the panel (null elsewhere, so the
/// usual back arrow shows).
Widget? panelLeading(BuildContext context) {
  final panel = InSidePanel.maybeOf(context);
  if (panel == null) return null;
  return IconButton(
    tooltip: tr('Close'),
    icon: const Icon(Icons.close),
    onPressed: panel.close,
  );
}

/// The panel itself.
class SidePanelView extends StatelessWidget {
  const SidePanelView({super.key, required this.content, required this.close});
  final SidePanelContent content;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => InSidePanel(
    close: close,
    child: KeyedSubtree(
      key: ValueKey(content.id),
      child: Builder(builder: content.builder),
    ),
  );
}
