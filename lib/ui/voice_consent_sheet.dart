import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../speech/speech_api.dart';

/// Asks, once, before anything is sent anywhere.
///
/// Voice notes are the first thing this app sends off the device in plaintext:
/// everything else — the note body, its formats, its attachments — is sealed
/// before it leaves. So this is opt-in, it names who hears the audio, and
/// declining leaves a perfectly good voice memo behind rather than a broken
/// feature.
///
/// Not dismissible by tapping past it, for the same reason the sharing rules
/// are not: agreeing is a decision, and a stray tap is not one.
Future<bool> showSpeechConsentSheet(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _SpeechConsentSheet(),
  );
  return accepted ?? false;
}

class _SpeechConsentSheet extends StatelessWidget {
  const _SpeechConsentSheet();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: const Text('Turn on transcription?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To turn a recording into text, Kapy Notes sends the audio to '
              'our server, which passes it to Cloudflare Workers AI. It is '
              'transcribed, summarised, and kept by nobody: not by Cloudflare, '
              'and not by us.',
              style: TextStyle(color: palette.textPrimary, height: 1.45),
            ),
            const SizedBox(height: 12),
            _Point(
              text:
                  'Recordings you made before turning this on stay as voice '
                  'memos until you ask for them.',
            ),
            _Point(
              text:
                  'Everything else in your notes stays end-to-end encrypted. '
                  'This is the one thing that leaves readable.',
            ),
            _Point(
              text:
                  'You can turn it off again in Settings › Voice notes at '
                  'any time.',
            ),
            const SizedBox(height: 12),
            Text(
              'Version $speechConsentVersion',
              style: TextStyle(fontSize: 11, color: palette.textTertiary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: TextStyle(color: palette.textSecondary)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
