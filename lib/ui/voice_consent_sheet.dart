import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Asks, once, before anything is sent anywhere.
///
/// Voice notes are the first thing this app sends off the device in a form
/// that can be read: everything else is private before it leaves. So this is
/// opt-in, it says what is sent, and declining leaves a voice memo behind
/// rather than a broken feature.
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'To turn a recording into text, Kapy Notes sends the audio to '
                'Kapy cloud, where an AI service turns it into text. The audio '
                'is not kept, and it is never used to train AI.',
                style: TextStyle(color: palette.textPrimary, height: 1.45),
              ),
              const SizedBox(height: 12),
              const _Point(
                text:
                    'A cloud summary sends the transcript to an AI service too. '
                    'It is not kept, and it is never used to train AI.',
              ),
              const _Point(text: 'Your other notes stay private.'),
              const _Point(
                text:
                    'Recordings you already have stay as voice memos until you '
                    'choose to transcribe them.',
              ),
              const _Point(
                text: 'Turn this off anytime in Settings › Voice & AI.',
              ),
            ],
          ),
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
