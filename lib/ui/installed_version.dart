import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import '../data/update_checker.dart';

/// The installed version, and whether a release is waiting to be looked at,
/// for the way into settings to show beside itself.
///
/// Read from [updates] where the app updates itself, and from the installed
/// package where an app store does.
class InstalledVersion extends StatefulWidget {
  const InstalledVersion({
    super.key,
    required this.updates,
    required this.builder,
  });

  final UpdateChecker? updates;

  /// `updateWaiting` asks the reader to go and look. While a download is
  /// running, or once it has finished and the title bar offers the restart,
  /// there is nothing to go and look at.
  final Widget Function(
    BuildContext context,
    String version,
    bool updateWaiting,
  )
  builder;

  @override
  State<InstalledVersion> createState() => _InstalledVersionState();
}

class _InstalledVersionState extends State<InstalledVersion> {
  String _standaloneVersion = '';

  @override
  void initState() {
    super.initState();
    widget.updates?.addListener(_changed);
    if (widget.updates == null && !AppPlatform.isFlutterTest) {
      unawaited(_readInstalledVersion());
    }
  }

  @override
  void didUpdateWidget(covariant InstalledVersion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates == widget.updates) return;
    oldWidget.updates?.removeListener(_changed);
    widget.updates?.addListener(_changed);
    if (widget.updates == null &&
        _standaloneVersion.isEmpty &&
        !AppPlatform.isFlutterTest) {
      unawaited(_readInstalledVersion());
    }
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _readInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _standaloneVersion = info.version);
    } catch (error) {
      debugPrint('KapyNotes: could not show the installed version: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = widget.updates;
    final updateWaiting =
        (updates?.hasUpdate ?? false) &&
        !(updates?.isReadyToInstall ?? false) &&
        !(updates?.isDownloading ?? false);
    return widget.builder(
      context,
      updates?.currentVersion ?? _standaloneVersion,
      updateWaiting,
    );
  }
}
