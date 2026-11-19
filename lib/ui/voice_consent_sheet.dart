import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/toast.dart';
import '../data/voice_prefs.dart';
import '../speech/speech_api.dart';
import '../speech/speech_errors.dart';

/// Where a recording goes, said once for both the consent sheet and the
/// provider notice, so the two can never name different providers.
const String _audioRoute =
    'To transcribe a recording, Kapy Notes sends its audio through our server '
    "and OpenRouter to Microsoft's MAI-Transcribe 2, or, when that model is "
    "busy or unavailable, to NVIDIA's Nemotron 3.5 Transcribe. Kapy Notes does "
    'not store the uploaded audio on its server.';

const List<String> _providerPoints = [
  'OpenRouter requests require zero-data-retention providers.',
  'Cloud summaries send the transcript text to MiniMax M3.1 Flash through '
      'OpenRouter.',
];

const String _encrypted = 'All other note content stays end-to-end encrypted.';
const String _turnOffLater =
    'Turn transcription off anytime in Settings › Voice & AI.';

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
    builder: (context) => _SpeechSheet(
      title: 'Turn on transcription?',
      lead: _audioRoute,
      points: const [
        ..._providerPoints,
        'Existing recordings stay as voice memos until you choose to '
            'transcribe them.',
        _encrypted,
        _turnOffLater,
      ],
      footer: 'Version $speechConsentVersion',
      decline: 'Not now',
      accept: 'Turn on',
    ),
  );
  return accepted ?? false;
}

/// Tells someone who agreed to cloud transcription under an earlier sheet's
/// providers who handles it now. True keeps it on, false turns it off, and
/// null is a close without an answer, which asks again on the next launch.
Future<bool?> showSpeechProviderNotice(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => const _SpeechSheet(
        title: 'Cloud transcription has new providers',
        lead: _audioRoute,
        points: [..._providerPoints, _encrypted, _turnOffLater],
        decline: 'Turn off',
        accept: 'Keep on',
      ),
    );

/// Turns cloud transcription on or off for the account: the consent sheet
/// first when turning it on, then the server, with a progress toast. The
/// Settings switch and the provider notice both come through here.
///
/// Returns the account's new consent, or null when nothing changed because
/// the sheet was declined or the server could not be reached; [onError] is
/// told why in the second case.
Future<SpeechConsentStatus?> setCloudTranscription(
  BuildContext context, {
  required SpeechApi speech,
  required VoicePrefs? prefs,
  required bool on,
  void Function(String message)? onError,
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
      progress.success(
        on ? 'Cloud transcription turned on' : 'Cloud transcription turned off',
      );
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
    this.footer,
    required this.decline,
    required this.accept,
  });

  final String title;
  final String lead;
  final List<String> points;
  final String? footer;
  final String decline;
  final String accept;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final footer = this.footer;
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
              if (footer != null) ...[
                const SizedBox(height: 12),
                Text(
                  footer,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    color: palette.textTertiary,
                  ),
                ),
              ],
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
