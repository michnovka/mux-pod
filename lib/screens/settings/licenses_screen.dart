import 'package:flutter/material.dart';

import '../../services/version_info.dart';

/// License list screen
class LicensesScreen extends StatelessWidget {
  const LicensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context),
      child: LicensePage(
        applicationName: 'MuxPod',
        applicationVersion: VersionInfo.version,
        applicationLegalese: '© 2025 mox',
      ),
    );
  }
}
