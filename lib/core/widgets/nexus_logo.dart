import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';

/// The Nexus badge: the app's logo, drawn wherever the app shows itself.
class NexusLogo extends StatelessWidget {
  const NexusLogo({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/nexus_logo.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: tr('OpenAide'),
  );
}
