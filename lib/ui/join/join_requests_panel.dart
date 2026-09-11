import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/joining.dart';
import 'joining_ui.dart';
import 'space_link_panel.dart' show SharingRun;

/// Who has asked to join through the space's link, and the buttons that let
/// them in or do not.
///
/// Letting somebody in is the moment the space key moves to them, so each
/// person is shown by the verified address that makes them accountable, with
/// the name they chose beside it rather than instead of it. Nothing is drawn
/// while nobody is waiting.
class JoinRequestsPanel extends StatefulWidget {
  const JoinRequestsPanel({
    super.key,
    required this.spaceId,
    required this.joining,
    required this.run,
    this.enabled = true,
  });

  final String spaceId;
  final Joining joining;
  final SharingRun run;
  final bool enabled;

  @override
  State<JoinRequestsPanel> createState() => _JoinRequestsPanelState();
}

class _JoinRequestsPanelState extends State<JoinRequestsPanel> {
  @override
  void initState() {
    super.initState();
    widget.joining.addListener(_changed);
    unawaited(_loadQuietly());
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
      await widget.joining.loadRequests(widget.spaceId);
    } on Object {
      // Offline: whoever was listed last time is still worth showing.
    }
  }

  String _who(JoinRequest r) => r.name ?? r.email;

  Future<void> _letIn(List<JoinRequest> people) => widget.run(
    () async {
      await widget.joining.approve(widget.spaceId, [
        for (final r in people) r.userId,
      ]);
    },
    waiting: people.length == 1 ? 'Letting them in…' : 'Letting everyone in…',
    done: people.length == 1
        ? '${_who(people.single)} is in. Their notes arrive as soon as this '
              'device hands them the key, which is now.'
        : '${people.length} people are in. Their notes arrive as soon as this '
              'device hands them the key, which is now.',
  );

  Future<void> _decline(JoinRequest r) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Do not let them in?'),
        content: Text(
          '${r.email} will not be able to ask again through this link. You '
          'can still invite them by email later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('join-request-decline-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Do not let in'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await widget.run(
      () => widget.joining.decline(widget.spaceId, r.userId),
      waiting: 'Updating…',
      done: '${r.email} was not let in.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final waiting = widget.joining.requestsOf(widget.spaceId);
    if (waiting.isEmpty) return const SizedBox.shrink();
    final enabled = widget.enabled;

    return Column(
      key: const ValueKey('join-requests'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        JoinLabel('Waiting to join (${waiting.length})'),
        for (final r in waiting)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.name ?? r.email,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.body,
                          fontWeight: FontWeight.w500,
                          color: palette.textPrimary,
                        ),
                      ),
                      if (r.name != null)
                        Text(
                          r.email,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.small,
                            color: palette.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton(
                  key: ValueKey('join-request-approve-${r.userId}'),
                  onPressed: enabled ? () => _letIn([r]) : null,
                  child: const Text('Let in'),
                ),
                IconButton(
                  key: ValueKey('join-request-decline-${r.userId}'),
                  tooltip: 'Do not let in',
                  onPressed: enabled ? () => _decline(r) : null,
                  icon: Icon(
                    Icons.close_rounded,
                    size: AppControlMetrics.iconControl,
                  ),
                ),
              ],
            ),
          ),
        if (waiting.length > 1)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const ValueKey('join-requests-approve-all'),
              onPressed: enabled ? () => _letIn(waiting) : null,
              child: Text('Let all ${waiting.length} in'),
            ),
          ),
      ],
    );
  }
}
