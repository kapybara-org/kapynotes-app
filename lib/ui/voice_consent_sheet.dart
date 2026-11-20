import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/voice_prefs.dart';
import '../speech/speech_api.dart';
import '../speech/speech_errors.dart';

/// What leaves the device, said once, without naming who does the work.
///
/// The audio goes to Kapy cloud, is not kept, and is never used to train AI.
/// The privacy policy on kapynotes.com keeps the legal detail.
const String _audioRoute =
    'To turn a recording into text, Kapy Notes sends the audio to Kapy cloud. '
    'The audio is not kept, and it is never used to train AI.';

const List<String> _cloudPoints = [
  'A cloud summary sends the transcript too. It is not kept, and it is never '
      'used to train AI.',
  'Your other notes stay private.',
];

const String _existing =
    'Recordings you already have stay as voice memos until you choose to '
    'transcribe them.';

const String _turnOffLater = 'Turn this off anytime in Settings › Voice & AI.';

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
    builder: (context) => const _SpeechSheet(
      title: 'Turn on transcription?',
      lead: _audioRoute,
      points: [..._cloudPoints, _existing, _turnOffLater],
      decline: 'Not now',
      accept: 'Turn on',
    ),
  );
  return accepted ?? false;
}

/// Turns cloud transcription on or off for the account: the consent sheet
/// first when turning it on, then the server, with a progress toast. The
/// Settings switch comes through here.
///
/// Returns the account's new consent, or null when nothing changed because
/// the sheet was declined or the server could not be reached; [onError] is
/// told why in the second case. [turnedOff] replaces the toast that confirms
/// turning it off.
Future<SpeechConsentStatus?> setCloudTranscription(
  BuildContext context, {
  required SpeechApi speech,
  required VoicePrefs? prefs,
  required bool on,
  void Function(String message)? onError,
  String turnedOff = 'Cloud transcription turned off',
}) async {
  if (on) {
    if (!await showSpeechConsentSheet(context)) {
      prefs?.transcriptionDeclinedVersion = speechConsentVersion;
      return null;
    }
    if (!context.mounted) return null;
  }
  final progress = Toast.showProgress(
    context,
    on ? 'Turning on cloud transcription…' : 'Turning off cloud transcription…',
  );
  try {
    // Version 0 withdraws.
    final status = await speech.acceptConsent(on ? speechConsentVersion : 0);
    if (on) prefs?.consentGiven();
    if (context.mounted) {
      progress.success(on ? 'Cloud transcription turned on' : turnedOff);
    } else {
      progress.dismiss();
    }
    return status;
  } catch (error) {
    final message = describeSpeechError(error);
    if (context.mounted) {
      onError?.call(message);
      progress.error(message);
    } else {
      progress.dismiss();
    }
    return null;
  }
}

class _SpeechSheet extends StatelessWidget {
  const _SpeechSheet({
    required this.title,
    required this.lead,
    required this.points,
    required this.decline,
    required this.accept,
  });

  final String title;
  final String lead;
  final List<String> points;
  final String decline;
  final String accept;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lead,
                style: TextStyle(color: palette.textPrimary, height: 1.45),
              ),
              const SizedBox(height: 12),
              for (final point in points) _Point(text: point),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(decline),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(accept),
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
