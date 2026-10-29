/// A password or key field with the web's eye button: hidden while typing,
/// shown with a tap ("Make password visible in the user interface").
library;

import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

class Hideable extends StatefulWidget {
  const Hideable({super.key, this.secret = true, required this.builder});

  /// False for a field that isn't secret: no eye, never hidden.
  final bool secret;

  /// Builds the field: [obscure] goes to obscureText, [eye] to suffixIcon.
  final Widget Function(bool obscure, Widget? eye) builder;

  @override
  State<Hideable> createState() => _HideableState();
}

class _HideableState extends State<Hideable> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    if (!widget.secret) return widget.builder(false, null);
    return widget.builder(
      _hidden,
      IconButton(
        tooltip: _hidden ? tr('Show') : tr('Hide'),
        icon: Icon(
          _hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
        onPressed: () => setState(() => _hidden = !_hidden),
      ),
    );
  }
}
