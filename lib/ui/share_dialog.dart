import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/note.dart';
import '../sync/share_link.dart';
import '../sync/share_service.dart';
import '../sync/sync_api.dart' show SyncAuthException, SyncException;

/// The share sheet for one note.
///
/// Opens straight into a link rather than asking first. Somebody who tapped
/// share wants a link; making them tap "create link" as well is a step that
/// only ever has one answer. The controls underneath then adjust what they
/// already have, which is also why nothing here has a save button.
Future<void> showShareDialog(
  BuildContext context, {
  required Note note,
  required ShareService shares,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ShareDialog(note: note, shares: shares),
  );
}

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.note, required this.shares});

  final Note note;
  final ShareService shares;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  NoteShare _share = const NoteShare();
  bool _busy = true;
  bool _copied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  /// Publishes on open when the note has no link yet, and otherwise just shows
  /// the one it has.
  Future<void> _open() async {
    final existing = widget.shares.forNote(widget.note.id);
    if (existing.isShared) {
      setState(() {
        _share = existing;
        _busy = false;
      });
      return;
    }
    await _run(() => widget.shares.publish(widget.note));
  }

  /// One place for the three things every action here has to do: show it is
  /// working, keep the result, and turn a failure into a sentence instead of
  /// an exception nobody sees.
  Future<void> _run(Future<NoteShare> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _share = result;
        _busy = false;
      });
    } on SyncAuthException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Sign in to share notes.';
      });
    } on SyncException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error) {
          _ when '$error'.contains('too long') =>
            'This note is too long to share.',
          _ => 'Could not reach the server. Try again in a moment.',
        };
      });
    }
  }

  Future<void> _copy() async {
    final link = _share.link;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (!mounted) return;
    setState(() => _copied = true);
    Toast.show(context, 'Link copied');
  }

  Future<void> _stopSharing() async {
    setState(() => _busy = true);
    try {
      await widget.shares.revoke(widget.note.id);
      if (mounted) Navigator.of(context).pop();
    } on SyncException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach the server. Try again in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = _share.state;
    final live = state?.isLive ?? false;

    return AlertDialog(
      title: const Text('Share note'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              // The one sentence that explains why this is safe to send, and
              // the one thing a reader has to understand about the URL: the
              // part after the # is the key, so a trimmed link is a dead one.
              'Anyone with the link can read this note. It is encrypted in the '
              'link itself — we cannot read what we are storing, so copy the '
              'whole thing, including the part after the #.',
              style: TextStyle(
                fontSize: AppTypeScale.body,
                color: palette.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),

            if (_error case final message?) ...[
              _Banner(message: message, isError: true),
              const SizedBox(height: 12),
            ],

            if (_share.isOrphaned) ...[
              const _Banner(
                message:
                    'This note was shared from another device, which still '
                    'holds the only copy of its key. Replacing the link makes '
                    'a new one and stops the old one working.',
                isError: false,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.shares.replaceLink(widget.note)),
                child: const Text('Replace link'),
              ),
            ] else
              _LinkField(
                link: _share.link,
                busy: _busy,
                copied: _copied,
                dimmed: !live,
                onCopy: _copy,
              ),

            if (state != null) ...[
              const SizedBox(height: 18),
              _ToggleRow(
                title: 'Anyone with the link',
                subtitle: live
                    ? 'The link is live.'
                    : state.hasExpired
                    ? 'The link has expired.'
                    : 'Paused. The link stays yours; nobody can open it.',
                value: state.visibility.isPublic,
                onChanged: _busy
                    ? null
                    : (value) => _run(
                        () => widget.shares.setVisibility(
                          widget.note.id,
                          value
                              ? ShareVisibility.public
                              : ShareVisibility.private,
                        ),
                      ),
              ),
              const SizedBox(height: 14),
              _ExpiryRow(
                value: _expiryOf(state),
                enabled: !_busy,
                onChanged: (value) => _run(
                  () => widget.shares.setExpiry(widget.note.id, value),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _stopSharing,
                  icon: Icon(
                    Icons.link_off_rounded,
                    size: AppControlMetrics.iconControl,
                  ),
                  label: const Text('Stop sharing'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// The server sends a date; the dropdown speaks in durations. Only the
  /// no-expiry case round-trips exactly, so anything with a date shows as the
  /// nearest option rather than pretending to know which one was picked.
  static ShareExpiry _expiryOf(ShareState state) {
    final expiresAt = state.expiresAt;
    if (expiresAt == null) return ShareExpiry.forever;
    final left = expiresAt.difference(DateTime.now());
    return switch (left.inHours) {
      <= 1 => ShareExpiry.hour,
      <= 24 => ShareExpiry.day,
      <= 24 * 7 => ShareExpiry.week,
      _ => ShareExpiry.month,
    };
  }
}

/// The link, in a box that reads as copyable and selectable.
class _LinkField extends StatelessWidget {
  const _LinkField({
    required this.link,
    required this.busy,
    required this.copied,
    required this.dimmed,
    required this.onCopy,
  });

  final Uri? link;
  final bool busy;
  final bool copied;
  final bool dimmed;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: busy && link == null
                ? Text(
                    'Creating link…',
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      color: palette.textTertiary,
                    ),
                  )
                : SelectableText(
                    link?.toString() ?? '',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      color: dimmed ? palette.textTertiary : palette.textPrimary,
                      decoration: dimmed ? TextDecoration.lineThrough : null,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: link == null ? null : onCopy,
            icon: Icon(
              copied ? Icons.check_rounded : Icons.copy_rounded,
              size: AppControlMetrics.iconControl,
            ),
            label: Text(copied ? 'Copied' : 'Copy'),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  fontWeight: FontWeight.w500,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch.adaptive(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _ExpiryRow extends StatelessWidget {
  const _ExpiryRow({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ShareExpiry value;
  final bool enabled;
  final ValueChanged<ShareExpiry> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Text(
            'Link expires',
            style: TextStyle(
              fontSize: AppTypeScale.control,
              fontWeight: FontWeight.w500,
              color: palette.textPrimary,
            ),
          ),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<ShareExpiry>(
            key: const ValueKey('share-expiry'),
            value: value,
            isDense: true,
            borderRadius: BorderRadius.circular(9),
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textPrimary,
            ),
            onChanged: enabled
                ? (next) {
                    if (next != null && next != value) onChanged(next);
                  }
                : null,
            items: [
              for (final expiry in ShareExpiry.values)
                DropdownMenuItem(value: expiry, child: Text(expiry.label)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = isError
        ? Theme.of(context).colorScheme.error
        : palette.textSecondary;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: AppTypeScale.caption,
          color: isError ? color : palette.textSecondary,
          height: 1.4,
        ),
      ),
    );
  }
}
