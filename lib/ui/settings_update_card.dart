import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/update_checker.dart';
import 'control_surface.dart';

final Uri _changelogPage = Uri.parse('https://kapynotes.com/changelog');

/// Opens the changelog page itself.
Future<void> openChangelogPage(BuildContext context) async {
  var opened = false;
  try {
    opened = await launchUrl(
      _changelogPage,
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (opened || !context.mounted) return;
  Toast.show(
    context,
    'Could not open ${_changelogPage.host}',
    icon: KapyIcons.errorOutlined,
    isError: true,
  );
}

/// One quiet line at the top of the phone's Settings: what the running
/// version brought, with the changelog behind it. A phone updates through its
/// store, so there is no card and nothing to restart.
class SettingsWhatsNewRow extends StatelessWidget {
  const SettingsWhatsNewRow({super.key, required this.updates});

  final UpdateChecker updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final version = updates.currentVersion;
      if (version.isEmpty) return const SizedBox.shrink();
      final palette = context.palette;
      return InkWell(
        key: const ValueKey('settings-whats-new-row'),
        onTap: () => unawaited(openChangelogPage(context)),
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "What's new in $version",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: palette.textDescription,
                    ),
                  ),
                ),
                KapyIcon(
                  KapyIcons.openExternalRounded,
                  size: 15,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The one card at the foot of the Settings rail.
///
/// When an update is downloaded and checked it says so and restarts into it.
/// Otherwise it says what the running version brought, in the first few lines
/// of its changelog entry, and links to the rest. Phones update through their
/// store, so there it only ever says what is new.
class SettingsUpdateCard extends StatefulWidget {
  const SettingsUpdateCard({super.key, required this.updates});

  final UpdateChecker updates;

  @override
  State<SettingsUpdateCard> createState() => _SettingsUpdateCardState();
}

class _SettingsUpdateCardState extends State<SettingsUpdateCard> {
  /// How many lines of the entry the card shows.
  static const int _lines = 3;

  late final Listenable _listenable = Listenable.merge([
    widget.updates,
    widget.updates.history,
  ]);

  @override
  void initState() {
    super.initState();
    _listenable.addListener(_changed);
    // After the first build: the changelog pane below starts the same load
    // while it builds, and its notification must not land mid-build here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.updates.history.load().then((_) => _changed()));
    });
  }

  @override
  void dispose() {
    _listenable.removeListener(_changed);
    super.dispose();
  }

  /// Notified while another widget is building, which a rebuild cannot wait
  /// out, so it waits for the frame to end instead.
  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    {
      final updates = widget.updates;
      final palette = context.palette;
      final staged = AppPlatform.isMobile ? null : updates.staged;
      final version = updates.currentVersion;
      if (staged == null && version.isEmpty) return const SizedBox.shrink();

      final title = TextStyle(
        fontSize: 13,
        height: 18 / 13,
        fontWeight: FontWeight.w400,
        color: palette.textPrimary,
      );
      final body = TextStyle(
        fontSize: 12.5,
        height: 17 / 12.5,
        fontWeight: FontWeight.w400,
        color: palette.textDescription,
      );

      final Widget content;
      if (staged != null) {
        final error = updates.downloadError;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Restart to update to ${staged.version}', style: title),
            if (error != null) ...[
              const SizedBox(height: 4),
              Text(error, style: body),
            ],
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('settings-update-restart'),
              onPressed: updates.isInstalling
                  ? null
                  : () => unawaited(updates.installAndRestart()),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                backgroundColor: palette.selectedBackground,
                foregroundColor: palette.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              child: Text(
                updates.isInstalling ? 'Restarting…' : 'Restart',
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        );
      } else {
        final notes = [
          for (final release in updates.history.releases)
            if (release.version == version) ...release.updateHighlights,
        ].take(_lines);
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("What's new in $version", style: title),
            for (final line in notes) ...[
              const SizedBox(height: 6),
              Text(
                line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: body,
              ),
            ],
            const SizedBox(height: 8),
            InkWell(
              key: const ValueKey('settings-update-changelog'),
              onTap: () => unawaited(openChangelogPage(context)),
              borderRadius: BorderRadius.circular(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'Full changelog',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  KapyIcon(
                    KapyIcons.openExternalRounded,
                    size: 13,
                    color: palette.textTertiary,
                  ),
                ],
              ),
            ),
          ],
        );
      }

      return KapyControlSurface(
        key: const ValueKey('settings-update-card'),
        radius: AppRadii.surface,
        padding: const EdgeInsets.all(13),
        color: palette.cardBackground,
        borderColor: palette.controlBorder,
        child: content,
      );
    }
  }
}
