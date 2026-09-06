import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../sync/safety.dart';
import '../sync/sharing.dart';
import '../sync/sync_api.dart';

/// The two screens sharing needs in order to be somewhere people can be
/// protected from each other: the rules, and the way to report a breach of
/// them.

/// The rules of a shared space, shown before somebody can take part in one.
///
/// Returns true if they accepted. A person who does not accept simply does not
/// share — there is no partial state, and nothing is held against them.
Future<bool> showSharingTermsSheet(
  BuildContext context, {
  required Sharing sharing,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    // The one dialog in the app that cannot be dismissed by tapping past it:
    // agreeing is a decision, and a stray tap is not one.
    barrierDismissible: false,
    builder: (context) => _TermsSheet(sharing: sharing),
  );
  return accepted ?? false;
}

class _TermsSheet extends StatefulWidget {
  const _TermsSheet({required this.sharing});
  final Sharing sharing;

  @override
  State<_TermsSheet> createState() => _TermsSheetState();
}

class _TermsSheetState extends State<_TermsSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sharing.acceptTerms();
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeSharingError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: const Text('Before you share'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sharingTermsSummary,
                style: TextStyle(
                  fontSize: AppTypeScale.body,
                  color: palette.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => unawaitedLaunch('https://kapynotes.com/terms'),
                  child: const Text('Read the full terms'),
                ),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  style: TextStyle(
                    fontSize: AppTypeScale.small,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const ValueKey('accept-sharing-terms'),
          onPressed: _busy ? null : _accept,
          child: const Text('I agree'),
        ),
      ],
    );
  }
}

/// Reports an invitation, a note, or a person.
///
/// The consent step is the part that matters. Everything except a note's text
/// is already visible to the server, so reporting costs nothing; a note's text
/// is not, and attaching it is a decision made once, in front of a sentence
/// that says exactly what it does.
Future<bool> showReportDialog(
  BuildContext context, {
  required Sharing sharing,
  required ReportTarget target,
}) async {
  final filed = await showDialog<bool>(
    context: context,
    builder: (context) => _ReportDialog(sharing: sharing, target: target),
  );
  return filed ?? false;
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.sharing, required this.target});
  final Sharing sharing;
  final ReportTarget target;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _details = TextEditingController();
  ReportReason _reason = ReportReason.spam;
  bool _includeContent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _file() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sharing.report(
        target: widget.target,
        reason: _reason,
        details: _details.text,
        includeContent: _includeContent,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      Toast.show(context, 'Reported. We will look at it.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeSharingError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final target = widget.target;

    return AlertDialog(
      title: Text('Report ${target.what}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'One person reads every report, usually within '
                '$reportResponseDays working days.',
                style: TextStyle(
                  fontSize: AppTypeScale.body,
                  color: palette.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              RadioGroup<ReportReason>(
                groupValue: _reason,
                // RadioGroup wants a non-null callback; disabling is done by
                // ignoring the change while a report is in flight.
                onChanged: (value) {
                  if (_busy || value == null) return;
                  setState(() => _reason = value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final reason in ReportReason.values)
                      RadioListTile<ReportReason>(
                        key: ValueKey('reason-${reason.name}'),
                        value: reason,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          reason.label,
                          style: TextStyle(
                            fontSize: AppTypeScale.body,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('report-details'),
                controller: _details,
                enabled: !_busy,
                maxLines: 3,
                maxLength: 2000,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: palette.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'Anything else we should know (optional)',
                  isDense: true,
                  filled: true,
                  fillColor: palette.controlBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: palette.controlBorder, width: 0.5),
                  ),
                ),
              ),
              if (target.canAttachContent) ...[
                const SizedBox(height: 6),
                // The whole encryption story, restated at the one moment it
                // could be given up, in the words it actually means.
                CheckboxListTile(
                  key: const ValueKey('include-note-content'),
                  value: _includeContent,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _includeContent = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Send us a copy of this note',
                    style: TextStyle(
                      fontSize: AppTypeScale.body,
                      color: palette.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    'We cannot read your notes, so we can only judge this one '
                    'if you send it. Ticking this sends its text to us, '
                    'unencrypted, for this report alone. Leave it unticked and '
                    'we will still act on who did it.',
                    style: TextStyle(
                      fontSize: AppTypeScale.small,
                      color: palette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  style: TextStyle(
                    fontSize: AppTypeScale.small,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('file-report'),
          onPressed: _busy ? null : _file,
          child: const Text('Report'),
        ),
      ],
    );
  }
}

/// Opens a URL and swallows the failure. A link that will not open is worth
/// less than a crash is expensive.
void unawaitedLaunch(String url) => unawaited(
  launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
);

/// One sentence for whatever went wrong, in place of an exception nobody sees.
///
/// It lives here rather than in the share sheet because the terms and report
/// dialogs need it too, and the share sheet imports them.
String describeSharingError(Object error) => switch (error) {
  SyncAuthException() => 'Sign in again to share notes.',
  SyncOutdatedException() => 'Update Kapy Notes to keep sharing.',
  SyncRefusedException(:final code) => switch (code) {
    termsRequiredCode => 'Agree to the sharing rules first.',
    'already a member' => 'They are already in this space.',
    'too many pending invitations' => 'Too many people are still to accept.',
    'too many invitations today' => 'That is enough invitations for today.',
    'too many reports today' => 'That is enough reports for today.',
    'the space is full' => 'This space is full.',
    'quota exceeded' => 'Not enough storage for this.',
    'the new owner does not hold the key yet' =>
      'They have to be let in before they can take over.',
    'no such invitation' =>
      'That invitation is not for this account, or has expired.',
    'owned-spaces' => 'Hand over or stop sharing your spaces first.',
    'you cannot block yourself' => 'That is your own address.',
    _ => 'The server did not allow that.',
  },
  SyncTransientException() =>
    'Could not reach the server. Try again in a moment.',
  SyncProtocolException(:final message) => message,
  _ => 'That did not work.',
};
