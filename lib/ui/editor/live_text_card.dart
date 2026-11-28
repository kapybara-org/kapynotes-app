import 'package:material_ui/material_ui.dart';

import '../../audio/live_text.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/voice_prefs.dart';
import '../../speech/live_translation.dart';

/// What a recording with live translation on has heard, above the recording
/// bar: each phrase's translation first, the words as said under it (beside
/// it when [wide]). Folds to a one-line tab, remembered for next time.
class LiveTextCard extends StatelessWidget {
  const LiveTextCard({
    super.key,
    required this.text,
    required this.prefs,
    required this.paused,
    this.wide = false,
  });

  final LivePhrases text;
  final VoicePrefs prefs;
  final bool paused;
  final bool wide;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([text, prefs]),
    builder: (context, _) {
      final palette = context.palette;
      final folded = prefs.liveTextFolded;
      final body = folded
          ? _tab(context)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                wide ? _wideHeader(context) : _header(context),
                const SizedBox(height: 10),
                ...LiveTextLines.of(context, text, wide: wide),
              ],
            );
      return Container(
        key: const ValueKey('live-text-card'),
        margin: wide ? const EdgeInsets.fromLTRB(16, 0, 16, 8) : null,
        padding: EdgeInsets.fromLTRB(
          18,
          folded ? 10 : 12,
          18,
          folded ? 10 : 14,
        ),
        decoration: BoxDecoration(
          color: wide
              ? palette.cardBackground
              : palette.surfaceBackground.withMultipliedAlpha(0.98),
          borderRadius: wide
              ? BorderRadius.circular(12)
              : const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: body,
      );
    },
  );

  String get _pair => '${text.fromName} → ${text.toName}';

  Widget _tab(BuildContext context) {
    final palette = context.palette;
    return _Pressable(
      key: const ValueKey('live-text-unfold'),
      label: 'Show live text',
      onTap: () => prefs.liveTextFolded = false,
      child: Row(
        children: [
          KapyIcon(
            KapyIcons.translateRounded,
            size: 14,
            color: palette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('Live text', style: _small(palette))),
          KapyIcon(
            KapyIcons.chevronUpRounded,
            size: 14,
            color: palette.textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        KapyIcon(
          KapyIcons.translateRounded,
          size: 14,
          color: palette.textSecondary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            paused ? '$_pair · paused' : _pair,
            style: _small(palette),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _Pressable(
          key: const ValueKey('live-text-fold'),
          label: 'Hide live text',
          onTap: () => prefs.liveTextFolded = true,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: KapyIcon(
              KapyIcons.chevronDownRounded,
              size: 16,
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _wideHeader(BuildContext context) {
    final palette = context.palette;
    final style = _small(palette);
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              KapyIcon(
                KapyIcons.translateRounded,
                size: 14,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                paused ? '${text.toName} · paused' : text.toName,
                style: style,
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Row(
            children: [
              KapyIcon(
                KapyIcons.micRounded,
                size: 14,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(text.fromName, style: style)),
              _Pressable(
                key: const ValueKey('live-text-fold'),
                label: 'Hide live text',
                onTap: () => prefs.liveTextFolded = true,
                child: Text('Hide', style: style),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The phrases themselves, shared by the card and the menu bar panel.
abstract final class LiveTextLines {
  /// The newest [most] phrases, then why live text stopped, if it did.
  static List<Widget> of(
    BuildContext context,
    LivePhrases text, {
    bool wide = false,
    int most = LivePhrases.shown,
  }) {
    final palette = context.palette;
    final all = text.phrases;
    final phrases = all
        .skip(all.length > most ? all.length - most : 0)
        .toList();
    final stopped = text.stopped;
    return [
      if (phrases.isEmpty && stopped == null)
        Text(
          'Listening for ${text.fromName}…',
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            color: palette.textTertiary,
          ),
        ),
      for (final (index, phrase) in phrases.indexed)
        Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
          child: _phrase(
            palette,
            phrase,
            current: index >= phrases.length - 2,
            wide: wide,
          ),
        ),
      if (stopped != null)
        Padding(
          padding: EdgeInsets.only(top: phrases.isEmpty ? 0 : 12),
          child: Text(
            switch (stopped) {
              LiveTranslationStop.denied when AppPlatform.isIOS =>
                'Live text stopped. Allow the microphone in iPhone '
                    'Settings.',
              LiveTranslationStop.denied =>
                'Live text stopped. Allow the microphone in System '
                    'Settings.',
              _ => 'Live text stopped. The recording carries on.',
            },
            key: const ValueKey('live-text-stopped'),
            style: _small(palette),
          ),
        ),
    ];
  }

  static Widget _phrase(
    CalcPalette palette,
    LivePhrase phrase, {
    required bool current,
    required bool wide,
  }) {
    final translated = phrase.translation;
    final translation = Text(
      translated ?? '…',
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        height: 1.35,
        color: current && translated != null
            ? palette.textPrimary
            : palette.textTertiary,
      ),
    );
    final heard = Text(
      phrase.heard,
      maxLines: wide ? 3 : 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: wide ? 15 : 12.5,
        height: 1.35,
        color: translated == null
            ? palette.textTertiary
            : palette.textSecondary,
      ),
    );
    final shown = Semantics(
      liveRegion: translated != null && current,
      child: translation,
    );
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: shown),
          const SizedBox(width: 24),
          Expanded(child: heard),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [shown, const SizedBox(height: 2), heard],
    );
  }
}

TextStyle _small(CalcPalette palette) =>
    TextStyle(fontSize: 12.5, height: 1.3, color: palette.textSecondary);

class _Pressable extends StatelessWidget {
  const _Pressable({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    ),
  );
}
