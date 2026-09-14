import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../sync/joining.dart';
import '../control_surface.dart';
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
    waiting: people.length == 1 ? 'Approving request…' : 'Approving requests…',
    done: people.length == 1
        ? '${_who(people.single)} now has access.'
        : '${people.length} people now have access.',
  );

  Future<void> _decline(JoinRequest r) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decline this request?'),
        content: Text(
          '${r.email} cannot use this link again. You can still invite them '
          'by email.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('join-request-decline-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await widget.run(
      () => widget.joining.decline(widget.spaceId, r.userId),
      waiting: 'Declining request…',
      done: 'Request declined',
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final waiting = widget.joining.requestsOf(widget.spaceId);
    if (waiting.isEmpty) return const SizedBox.shrink();
    final enabled = widget.enabled;

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        key: const ValueKey('join-requests'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          JoinLabel('Waiting to join (${waiting.length})'),
          KapyControlSurface(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              children: [
                for (var index = 0; index < waiting.length; index++) ...[
                  if (index > 0) Divider(height: 1, color: palette.separator),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                waiting[index].name ?? waiting[index].email,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTypeScale.body,
                                  fontWeight: FontWeight.w500,
                                  color: palette.textPrimary,
                                ),
                              ),
                              if (waiting[index].name != null)
                                Text(
                                  waiting[index].email,
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
                          key: ValueKey(
                            'join-request-approve-${waiting[index].userId}',
                          ),
                          onPressed: enabled
                              ? () => _letIn([waiting[index]])
                              : null,
                          child: const Text('Approve'),
                        ),
                        IconButton(
                          key: ValueKey(
                            'join-request-decline-${waiting[index].userId}',
                          ),
                          tooltip: 'Decline request',
                          onPressed: enabled
                              ? () => _decline(waiting[index])
                              : null,
                          icon: KapyIcon(
                            KapyIcons.closeRounded,
                            size: AppControlMetrics.iconControl,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (waiting.length > 1) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      key: const ValueKey('join-requests-approve-all'),
                      onPressed: enabled ? () => _letIn(waiting) : null,
                      child: Text('Approve all ${waiting.length}'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
