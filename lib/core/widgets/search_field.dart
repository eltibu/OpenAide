/// The one search box every screen uses: a soft, rounded field with a
/// magnifier and a clear button, as in the Claude app.
library;

import 'package:flutter/material.dart';

class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.controller,
    this.autofocus = false,
  });

  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  final bool autofocus;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final _text = widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _text,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      onChanged: (v) {
        setState(() {});
        widget.onChanged?.call(v);
      },
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: _text.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () {
                  _text.clear();
                  setState(() {});
                  widget.onChanged?.call('');
                  widget.onSubmitted?.call('');
                },
              ),
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.outline),
        ),
      ),
    );
  }
}
