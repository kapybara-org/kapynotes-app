import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/joining.dart';
import '../../sync/spaces.dart';
import '../control_surface.dart';
import 'joining_ui.dart';

/// Runs a sharing action the way the share dialog runs all of them: progress
/// shown, errors described, and the sharing rules offered if the server asks.
typedef SharingRun =
    Future<void> Function(
      Future<void> Function() action, {
      String waiting,
      String? done,
    });

/// The owner's link to a space: make it, copy it, replace it, turn it off.
///
/// A link lets whoever holds it ask to join and nothing more, which is why
/// it can go into a group chat when an invitation, addressed to one person,
/// cannot. The panel says so where the button is, because that is the moment
/// the owner decides whether to trust it.
class SpaceLinkPanel extends StatefulWidget {
  const SpaceLinkPanel({
    super.key,
    required this.spaceId,
    required this.joining,
    required this.run,
    required this.role,
    this.enabled = true,
  });

  final String spaceId;
  final Joining joining;
  final SharingRun run;

  /// What people let in through a new link will be able to do.
  final SpaceRole role;
  final bool enabled;

  @override
  State<SpaceLinkPanel> createState() => _SpaceLinkPanelState();
}

class _SpaceLinkPanelState extends State<SpaceLinkPanel> {
  @override
  void initState() {
    super.initState();
    widget.joining.addListener(_changed);
    if (!widget.joining.knowsLinkOf(widget.spaceId)) unawaited(_loadQuietly());
  }

  @override
  void dispose() {
    widget.joining.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadQuietly() async {
    try {
      await widget.joining.loadLink(widget.spaceId);
    } on Object {
      // Offline, or not the owner after all: the button still offers one.
    }
  }

  String _access(SpaceRole role) =>
      role == SpaceRole.viewer ? 'read its notes' : 'read and edit its notes';

  Future<void> _create() => widget.run(
    () => widget.joining.makeLink(widget.spaceId, role: widget.role),
    waiting: 'Making a link…',
    done: 'Link ready. Anyone who opens it can ask to join.',
  );

  Future<void> _replace() => widget.run(
    () => widget.joining.makeLink(widget.spaceId, role: widget.role),
    waiting: 'Making a new link…',
    done: 'New link ready. The old one no longer works.',
  );

  Future<void> _turnOff() => widget.run(
    () => widget.joining.turnOffLink(widget.spaceId),
    waiting: 'Turning the link off…',
    done: 'The link is off. Anyone already waiting is still on the list.',
  );

  Future<void> _copy(JoinLink link) async {
    await Clipboard.setData(ClipboardData(text: link.url.toString()));
    if (mounted) Toast.show(context, 'Link copied');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final link = widget.joining.linkOf(widget.spaceId);
    final enabled = widget.enabled;

    if (link == null) {
      return Column(
        key: const ValueKey('space-link-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const JoinLabel('Share a link'),
          KapyControlSurface(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const JoinMessage(
                  'Anyone with the link can ask to join. Nobody gets in '
                  'until you let them.',
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const ValueKey('space-link-create'),
                  onPressed: enabled ? _create : null,
                  icon: KapyIcon(
                    KapyIcons.linkRounded,
                    size: AppControlMetrics.iconControl,
                  ),
                  label: const Text('Create a link'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final until = MaterialLocalizations.of(
      context,
    ).formatMediumDate(link.expiresAt);
    return Column(
      key: const ValueKey('space-link-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const JoinLabel('Link to ask to join'),
        KapyControlSurface(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(11, 4, 4, 4),
                decoration: BoxDecoration(
                  color: palette.surfaceBackground,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  border: Border.all(color: palette.controlBorder),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        link.url.toString(),
                        key: const ValueKey('space-link-url'),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: AppTypeScale.small,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('space-link-copy'),
                      tooltip: 'Copy link',
                      onPressed: () => _copy(link),
                      icon: KapyIcon(
                        KapyIcons.copyRounded,
                        size: AppControlMetrics.iconControl,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              JoinMessage(
                'Works until $until. People you let in can '
                '${_access(link.role)}.',
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  TextButton(
                    key: const ValueKey('space-link-new'),
                    onPressed: enabled ? _replace : null,
                    child: const Text('New link'),
                  ),
                  TextButton(
                    key: const ValueKey('space-link-off'),
                    onPressed: enabled ? _turnOff : null,
                    child: const Text('Turn off'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
