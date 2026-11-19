import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/notes_store.dart';
import '../data/onboarding.dart';
import '../data/voice_prefs.dart';
import '../sync/account.dart';
import 'voice_consent_sheet.dart';

/// Shows the provider notice, once per device, to someone who agreed to
/// cloud transcription on a build whose consent sheet named other providers.
///
/// Only on a home screen that is up, unlocked and on top: never while the
/// welcome note is all there is, never over a passphrase or PIN prompt or
/// another sheet. It asks the server whether cloud transcription is on, so
/// offline it waits for the next launch and leaves everything else alone.
class SpeechProviderNoticeListener extends StatefulWidget {
  const SpeechProviderNoticeListener({
    super.key,
    required this.account,
    required this.prefs,
    required this.notes,
    required this.child,
    this.retryAfter = const Duration(seconds: 5),
  });

  final Account? account;
  final VoicePrefs? prefs;
  final NotesStore notes;
  final Widget child;

  /// How long to wait before looking again when something else is on screen.
  final Duration retryAfter;

  @override
  State<SpeechProviderNoticeListener> createState() =>
      _SpeechProviderNoticeListenerState();
}

class _SpeechProviderNoticeListenerState
    extends State<SpeechProviderNoticeListener> {
  /// Shown, ruled out, or unanswerable for the rest of this launch.
  bool _done = false;
  bool _asking = false;
  bool? _cloudOn;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    widget.account?.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  @override
  void dispose() {
    widget.account?.removeListener(_check);
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final account = widget.account;
    final prefs = widget.prefs;
    if (_done || _asking || !mounted || account == null || prefs == null) {
      return;
    }
    if (!prefs.owesProviderNotice) return;
    final speech = account.speech;
    if (account.state != AccountState.ready || speech == null) {
      _cloudOn = null;
      return;
    }
    if (!_clear) {
      _later();
      return;
    }

    if (_cloudOn == null) {
      _asking = true;
      try {
        _cloudOn = (await speech.consent()).isAccepted;
      } catch (_) {
        _done = true;
        return;
      } finally {
        _asking = false;
      }
    }
    if (_cloudOn != true) {
      _done = true;
      return;
    }
    if (!mounted || !prefs.owesProviderNotice) return;
    if (account.state != AccountState.ready || !_clear) {
      _later();
      return;
    }

    _done = true;
    final keep = await showSpeechProviderNotice(context);
    if (keep == null || !mounted) return;
    if (keep) {
      prefs.providerNoticeSeen();
      return;
    }
    final status = await setCloudTranscription(
      context,
      speech: speech,
      prefs: prefs,
      on: false,
    );
    if (status != null && !status.isAccepted) prefs.providerNoticeSeen();
  }

  bool get _clear =>
      !Onboarding.holdsOnlyWelcome(widget.notes) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _later() {
    _retry?.cancel();
    _retry = Timer(widget.retryAfter, () => unawaited(_check()));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
