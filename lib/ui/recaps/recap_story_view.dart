import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../recaps/recap_lines.dart';
import '../../recaps/recap_story.dart';
import 'recap_cards.dart';

/// What the viewer hands to the app: opening a note, playing a recording
/// from a moment, saving the recap as a note, sharing a card's image and
/// making the recap again.
class RecapStoryActions {
  const RecapStoryActions({
    required this.openNote,
    required this.play,
    required this.saveAsNote,
    required this.shareImage,
    required this.onRemake,
    required this.remakeCredits,
    this.onPruned,
  });

  /// Opens the note a highlight is about, once the viewer has closed.
  final void Function(String noteId) openNote;

  /// Starts the quote's recording at its moment.
  final void Function(RecapQuote quote) play;

  /// Makes one normal note of the recap.
  final void Function(RecapNote note) saveAsNote;

  /// Hands a card drawn on the device, as a PNG called [name], to the share
  /// sheet.
  final Future<void> Function(Uint8List png, String name) shareImage;

  /// Makes the recap again, once the viewer has closed. It is offered only
  /// when none of its words are left ([RecapStory.wordsGone]).
  final VoidCallback onRemake;

  /// What making it again costs, as the drawer quotes it.
  final int remakeCredits;

  /// Keeps the story's chat as it opened, once, when it left words out
  /// ([recapPruned]).
  final void Function(KapyChat chat)? onPruned;
}

/// What dims the app behind the desktop's frame.
const Color recapScrim = Color(0xBD000000);

/// Opens [story]: full screen on a phone, and on a desktop a 393 × 740
/// frame centred over the dimmed window, which keeps the keyboard's focus
/// while it is open.
Future<void> showRecapStory(
  BuildContext context, {
  required RecapStory story,
  required RecapStoryActions actions,
}) {
  final still = MediaQuery.disableAnimationsOf(context);
  final fade = still ? Duration.zero : const Duration(milliseconds: 180);
  if (AppPlatform.isDesktop) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close recap',
      barrierColor: recapScrim,
      transitionDuration: fade,
      pageBuilder: (_, _, _) =>
          RecapStoryView(story: story, actions: actions, desktop: true),
    );
  }
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: fade,
      reverseTransitionDuration: fade,
      pageBuilder: (_, _, _) =>
          RecapStoryView(story: story, actions: actions, desktop: false),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// A recap as a story, a card at a time: segmented progress at the top, the
/// recap's name, "Kapy AI" and ✕.
///
/// Each card moves on by itself after [cardTime], unless reduced motion or
/// a screen reader is on. Tapping the right of a card or → moves on, the
/// left or ← goes back, holding a card pauses it, Space pauses and plays,
/// and ✕, Esc or swiping down closes.
class RecapStoryView extends StatefulWidget {
  const RecapStoryView({
    super.key,
    required this.story,
    required this.actions,
    required this.desktop,
    this.cardTime = const Duration(seconds: 7),
  });

  final RecapStory story;
  final RecapStoryActions actions;

  /// The desktop's frame rather than the phone's full screen.
  final bool desktop;
  final Duration cardTime;

  /// The frame's size on a desktop.
  static const Size frame = Size(393, 740);

  @override
  State<RecapStoryView> createState() => _RecapStoryViewState();
}

class _RecapStoryViewState extends State<RecapStoryView>
    with SingleTickerProviderStateMixin {
  late final List<RecapCard> _cards = widget.story.cards;
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: widget.cardTime,
  )..addStatusListener(_timeUp);
  final GlobalKey _shot = GlobalKey();
  final FocusNode _focus = FocusNode(debugLabel: 'Recap story');
  int _index = 0;
  bool _held = false;
  bool _paused = false;
  bool _busy = false;
  double _pull = 0;

  bool get _moves =>
      !MediaQuery.disableAnimationsOf(context) &&
      !MediaQuery.accessibleNavigationOf(context);

  RecapCard get _card => _cards[_index];

  @override
  void initState() {
    super.initState();
    if (widget.actions.onPruned case final kept?) {
      if (recapPruned(widget.story, now: DateTime.now()) case final chat?) {
        WidgetsBinding.instance.addPostFrameCallback((_) => kept(chat));
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void dispose() {
    _clock.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _run() {
    if (_moves && !_held && !_paused && !_busy) {
      _clock.forward();
    } else {
      _clock.stop();
    }
  }

  void _timeUp(AnimationStatus status) {
    if (status == AnimationStatus.completed) _go(_index + 1);
  }

  void _go(int index) {
    if (index < 0 || index >= _cards.length) return;
    setState(() => _index = index);
    _clock.value = 0;
    _run();
  }

  void _hold(bool held) {
    setState(() => _held = held);
    _run();
  }

  void _pause() {
    setState(() => _paused = !_paused);
    _run();
  }

  void _close() => Navigator.of(context).maybePop();

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final pressing =
        FocusManager.instance.primaryFocus != _focus &&
        (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter);
    if (pressing) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(_index + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(_index - 1);
    } else if (key == LogicalKeyboardKey.space && event is KeyDownEvent) {
      _pause();
    } else if (key == LogicalKeyboardKey.escape) {
      _close();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _openNote(RecapHighlight highlight) {
    _close();
    widget.actions.openNote(highlight.noteId);
  }

  void _remake() {
    _close();
    widget.actions.onRemake();
  }

  void _play(RecapQuote quote) {
    setState(() => _paused = true);
    _run();
    widget.actions.play(quote);
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    _run();
    try {
      final boundary =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(
        pixelRatio: math.max(2, MediaQuery.devicePixelRatioOf(context)),
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await widget.actions.shareImage(
        png!.buffer.asUint8List(),
        '${widget.story.name}.png',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _run();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tones = RecapTones.of(Theme.of(context).brightness);
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _key,
        child: widget.desktop ? _desktop(tones) : _phone(tones),
      ),
    );
  }

  Widget _phone(RecapTones tones) {
    final padding = MediaQuery.paddingOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: GestureDetector(
        onVerticalDragStart: (_) => _hold(true),
        onVerticalDragUpdate: (details) =>
            setState(() => _pull = math.max(0, _pull + details.delta.dy)),
        onVerticalDragEnd: (details) {
          if (_pull > 120 || (details.primaryVelocity ?? 0) > 700) {
            _close();
          } else {
            setState(() => _pull = 0);
            _hold(false);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _pull),
          child: _story(
            tones,
            top: padding.top,
            bottom: math.max(24, padding.bottom + 10),
          ),
        ),
      ),
    );
  }

  Widget _desktop(RecapTones tones) {
    final first = _index == 0;
    final last = _index == _cards.length - 1;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 24,
                children: [
                  _Arrow(
                    shown: !first,
                    label: 'Previous card',
                    icon: KapyIcons.chevronLeftRounded,
                    onTap: () => _go(_index - 1),
                  ),
                  Container(
                    width: RecapStoryView.frame.width,
                    height: RecapStoryView.frame.height,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x80000000),
                          offset: Offset(0, 24),
                          blurRadius: 60,
                        ),
                      ],
                    ),
                    child: _story(tones, top: 10, bottom: 44),
                  ),
                  _Arrow(
                    shown: !last,
                    label: 'Next card',
                    icon: KapyIcons.chevronRightRounded,
                    onTap: () => _go(_index + 1),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '← and → to move · Space to pause · Esc to close',
                style: recapText(12.5, 16, 400, const Color(0x8CFFFFFF)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The card under its progress and header. [top] is where the phone's
  /// status bar ends, [bottom] what the card keeps clear at its foot.
  Widget _story(
    RecapTones tones, {
    required double top,
    required double bottom,
  }) {
    final card = _card;
    final still = !_moves;
    final body = AnimatedSwitcher(
      duration: still ? Duration.zero : const Duration(milliseconds: 160),
      child: ColoredBox(
        key: ValueKey(_index),
        color: tones.surface(card),
        child: Padding(
          padding: EdgeInsets.fromLTRB(28, top + 76, 28, bottom),
          child: RecapCardBody(
            story: widget.story,
            card: card,
            tones: tones,
            actions: RecapCardActions(openNote: _openNote, play: _play),
          ),
        ),
      ),
    );
    return ColoredBox(
      color: tones.surface(card),
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              container: true,
              liveRegion: true,
              label: 'Card ${_index + 1} of ${_cards.length}',
              customSemanticsActions: {
                const CustomSemanticsAction(label: 'Next card'): () =>
                    _go(_index + 1),
                const CustomSemanticsAction(label: 'Previous card'): () =>
                    _go(_index - 1),
              },
              child: LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _go(
                    details.localPosition.dx < constraints.maxWidth / 3
                        ? _index - 1
                        : _index + 1,
                  ),
                  onLongPressStart: (_) => _hold(true),
                  onLongPressEnd: (_) => _hold(false),
                  onLongPressCancel: () => _hold(false),
                  child: RepaintBoundary(key: _shot, child: body),
                ),
              ),
            ),
          ),
          Positioned(
            top: top + 4,
            left: 14,
            right: 14,
            child: ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _clock,
                builder: (context, _) => Row(
                  spacing: 4,
                  children: [
                    for (var i = 0; i < _cards.length; i++)
                      Expanded(
                        child: _Segment(
                          filled: i < _index
                              ? 1
                              : i > _index
                              ? 0
                              : still
                              ? 1
                              : _clock.value,
                          tones: tones,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: top + 16,
            left: 14,
            right: 6,
            child: _Header(
              name: widget.story.name,
              tones: tones,
              close: _close,
            ),
          ),
          if (card == RecapCard.closing)
            Positioned(
              left: 28,
              right: 28,
              bottom: bottom,
              child: _Actions(
                tones: tones,
                save: () => widget.actions.saveAsNote(widget.story.note),
                remake: widget.story.wordsGone
                    ? (
                        label: switch (widget.actions.remakeCredits) {
                          0 => 'Remake',
                          1 => 'Remake · 1 credit',
                          final n => 'Remake · $n credits',
                        },
                        onTap: _remake,
                      )
                    : null,
                share: _share,
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.filled, required this.tones});

  final double filled;
  final RecapTones tones;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: SizedBox(
      height: 3,
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: tones.track)),
          FractionallySizedBox(
            widthFactor: filled,
            heightFactor: 1,
            child: ColoredBox(color: tones.text),
          ),
        ],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.tones, required this.close});

  final String name;
  final RecapTones tones;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: tones.tint,
            shape: BoxShape.circle,
            border: Border.all(color: tones.cardEdge),
          ),
          child: Center(
            child: KapyIcon(
              KapyIcons.recapOutlined,
              size: 16,
              color: tones.accentInk,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Row(
            spacing: 9,
            children: [
              Flexible(
                child: Semantics(
                  header: true,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: recapText(14, 18, 600, tones.text, tabular: true),
                  ),
                ),
              ),
              Text('Kapy AI', style: recapText(13, 18, 400, tones.secondary)),
            ],
          ),
        ),
        RecapPress(
          label: 'Close recap',
          onTap: close,
          child: SizedBox.square(
            dimension: 40,
            child: Center(
              child: KapyIcon(
                KapyIcons.closeRounded,
                size: 22,
                color: tones.text,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Save as note and Share as image, under the closing card.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.tones,
    required this.save,
    required this.remake,
    required this.share,
  });

  final RecapTones tones;
  final VoidCallback save;

  /// In place of [save] when there are no words left to save.
  final ({String label, VoidCallback onTap})? remake;
  final VoidCallback share;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      if (remake case final remake?)
        _pill(
          remake.label,
          KapyIcons.refreshRounded,
          tones.quietButton,
          tones.onQuietButton,
          remake.onTap,
        )
      else
        _pill(
          'Save as note',
          KapyIcons.noteAddRounded,
          tones.quietButton,
          tones.onQuietButton,
          save,
        ),
      _pill(
        'Share as image',
        KapyIcons.shareRounded,
        tones.strongButton,
        tones.onStrongButton,
        share,
      ),
    ],
  );

  Widget _pill(
    String label,
    KapyIconData icon,
    Color fill,
    Color ink,
    VoidCallback onTap,
  ) => RecapPress(
    label: label,
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: recapActionsHeight),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(recapActionsHeight / 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          KapyIcon(icon, size: 18, color: ink),
          Flexible(child: Text(label, style: recapText(15, 20, 600, ink))),
        ],
      ),
    ),
  );
}

/// The desktop's side arrows, gone at either end but keeping their place.
class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.shown,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final bool shown;
  final String label;
  final KapyIconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => !shown
      ? const SizedBox.square(dimension: 40)
      : RecapPress(
          label: label,
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: Color(0x1FFFFFFF),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: KapyIcon(icon, size: 20, color: const Color(0xFFFFFFFF)),
            ),
          ),
        );
}
