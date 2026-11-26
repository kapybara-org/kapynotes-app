import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ai/kapy_ai.dart';
import '../ai/recording_context.dart';
import '../core/phone_keyboard.dart';
import '../core/theme.dart';
import '../data/note_attachment.dart';
import '../speech/moments.dart';
import 'kapy_ai/kapy_ai_conversation.dart' show KapyAiNotice;
import 'kapy_ai/kapy_ai_markdown.dart';
import 'kapy_ai/kapy_ai_parts.dart';
import 'kapy_ai/kapy_ai_picker.dart';

/// Kapy AI, for asking about one recording, and what its cards open.
class VoiceAskActions {
  const VoiceAskActions({
    required this.kapyAi,
    required this.noteId,
    required this.onManageAccounts,
    this.hidden = false,
    this.onSignIn,
    this.onUpgrade,
  });

  final KapyAi kapyAi;

  /// The note the recording is in, which its chats link to.
  final String noteId;

  /// The note is hidden, so Kapy AI won't read it and questions are off.
  final bool hidden;

  /// Settings › Voice & AI, where an account of the person's own is added.
  final VoidCallback onManageAccounts;

  /// Settings › Account & sync. Null in a build with nobody to sign in as.
  final VoidCallback? onSignIn;

  /// The Pro sheet. Null where there's no plan to show.
  final VoidCallback? onUpgrade;
}

/// Asking about a recording (KAP-396 b1–b6): the starters and the ask bar
/// under [page], and the drawer an answer rises in over it.
///
/// Questions become a Kapy AI chat linked to the recording, so they are in
/// Kapy AI's history too. The chat the panel had open comes back when the
/// window closes.
class VoiceAsk extends StatefulWidget {
  const VoiceAsk({
    super.key,
    required this.actions,
    required this.ref,
    required this.page,
    this.unavailable,
    this.compact = false,
    this.onPlay,
    this.onCited,
    this.onInsert,
    this.onCopy,
  });

  final VoiceAskActions actions;
  final NoteVoiceRef ref;

  /// The summary or the transcript, which the drawer rises over.
  final Widget page;

  /// Why questions are off, said in the bar in place of its placeholder:
  /// "Ask once the transcript is ready". Null while they are on.
  final String? unavailable;

  /// The window is a sheet, on a phone or a tablet: Earlier is its clock.
  final bool compact;

  final ValueChanged<Duration>? onPlay;

  /// The moments the answer in the drawer draws on, and none once it goes.
  final ValueChanged<List<Duration>>? onCited;

  final ValueChanged<String>? onInsert;
  final ValueChanged<String>? onCopy;

  @override
  State<VoiceAsk> createState() => _VoiceAskState();
}

class _VoiceAskState extends State<VoiceAsk> {
  late final KapyAi _ai = widget.actions.kapyAi;
  late final String? _panelChat;
  late final KapyRecordingRef _recording = KapyRecordingRef(
    noteId: widget.actions.noteId,
    hash: widget.ref.hash,
  );
  final TextEditingController _field = TextEditingController();

  /// The chat the drawer shows, while it shows one.
  String? _shown;
  bool _open = false;
  bool _earlier = false;
  bool _picking = false;

  /// The answer [VoiceAsk.onCited] was last told about.
  String? _citedFrom;
  final Map<String, List<Duration>> _moments = {};

  @override
  void initState() {
    super.initState();
    _panelChat = _ai.current?.id;
    _ai.addListener(_changed);
    _field.addListener(_changed);
  }

  @override
  void dispose() {
    _ai.removeListener(_changed);
    _field.dispose();
    final ai = _ai;
    final back = _panelChat;
    // After the tree is torn down, since the panel listens too.
    if (ai.current?.id != back) {
      scheduleMicrotask(() {
        if (back != null && ai.chats.any((chat) => chat.id == back)) {
          ai.openChat(back);
        } else {
          ai.newChat();
        }
      });
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _asking => widget.unavailable == null;

  /// This recording's chats, newest first.
  List<KapyChat> get _history => [
    for (final chat in _ai.chats)
      if (chat.recording == _recording) chat,
  ];

  KapyChat? get _chat {
    for (final chat in _ai.chats) {
      if (chat.id == _shown) return chat;
    }
    return null;
  }

  void _ask(String text) {
    final question = text.trim();
    if (question.isEmpty || !_asking || _ai.answering) return;
    final chat = _open && !_earlier ? _chat : null;
    if (chat == null) {
      _ai.newChat();
    } else if (_ai.current?.id != chat.id) {
      _ai.openChat(chat.id);
    }
    unawaited(_ai.ask(question, recording: _recording));
    _field.clear();
    setState(() {
      _shown = _ai.current?.id;
      _open = true;
      _earlier = false;
      _picking = false;
    });
  }

  void _show(String chatId) {
    _ai.openChat(chatId);
    setState(() {
      _shown = chatId;
      _open = true;
      _earlier = false;
      _picking = false;
    });
  }

  void _close() => setState(() {
    _open = false;
    _earlier = false;
    _picking = false;
  });

  void _showEarlier() => setState(() {
    _open = true;
    _earlier = true;
    _picking = false;
  });

  /// Tells the window which moments the answer in view draws on, once each
  /// time that answer changes.
  void _cite(KapyMessage? answer) {
    final id = answer?.id;
    if (id == _citedFrom) return;
    _citedFrom = id;
    final moments = answer == null ? const <Duration>[] : _momentsOf(answer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onCited?.call(moments);
    });
  }

  List<Duration> _momentsOf(KapyMessage answer) =>
      _moments[answer.id] ??= momentsIn(
        answer.text,
        groupTranscriptParagraphs(widget.ref.transcript?.segments ?? const []),
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chat = _chat;
    final showing = _open && (_earlier || chat != null);
    final messages = chat?.messages ?? const <KapyMessage>[];
    final answer =
        showing &&
            !_earlier &&
            messages.isNotEmpty &&
            messages.last.role == KapyRole.assistant
        ? messages.last
        : null;
    _cite(answer);
    final history = _history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Positioned.fill(child: widget.page),
                if (showing)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 8,
                    child: _Drawer(
                      key: const ValueKey('voice-ask-drawer'),
                      maxHeight: constraints.maxHeight - 16,
                      child: _earlier
                          ? _earlierList(palette, history)
                          : _conversation(palette, chat!, answer),
                    ),
                  ),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            border: showing
                ? null
                : Border(top: BorderSide(color: palette.separator)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!showing && (_asking || history.isNotEmpty)) ...[
                  _starters(palette, history),
                  const SizedBox(height: 10),
                ],
                _bar(palette, following: showing && !_earlier),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _starters(CalcPalette palette, List<KapyChat> history) {
    final questions = _asking
        ? recordingQuestions(widget.ref.transcript)
        : const <String>[];
    return SizedBox(
      height: widget.compact ? 44 : 34,
      child: ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 1 - 28 / bounds.width, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView(
          key: const ValueKey('voice-ask-starters'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(right: 28),
          children: [
            if (history.isNotEmpty) ...[
              _EarlierButton(compact: widget.compact, onPressed: _showEarlier),
              if (questions.isNotEmpty)
                Container(
                  width: 1,
                  margin: const EdgeInsets.fromLTRB(4, 9, 8, 9),
                  color: palette.separator,
                ),
            ],
            for (final question in questions)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: _Starter(
                    label: question,
                    onPressed: _ai.answering ? null : () => _ask(question),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bar(CalcPalette palette, {required bool following}) {
    final canSend = _asking && !_ai.answering && _field.text.trim().isNotEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.separator),
      ),
      child: Row(
        children: [
          KapyIcon(
            KapyIcons.sparklesOutlined,
            size: 16,
            color: _asking ? palette.accentText : palette.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('voice-ask-field'),
              controller: _field,
              enabled: _asking,
              textInputAction: TextInputAction.send,
              onSubmitted: _ask,
              cursorColor: palette.selectedBorder,
              style: kapyText(13.5, 20, palette.textPrimary),
              decoration: InputDecoration.collapsed(
                hintText:
                    widget.unavailable ??
                    (following
                        ? 'Ask a follow-up…'
                        : 'Ask about this recording'),
                hintStyle: kapyText(13.5, 20, palette.textTertiary),
              ),
            ),
          ),
          KeepsKeyboard(
            child: Tooltip(
              message: 'Ask',
              child: Material(
                color: canSend
                    ? palette.totalPillBackground
                    : palette.surfaceBackground,
                shape: CircleBorder(side: BorderSide(color: palette.separator)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const ValueKey('voice-ask-send'),
                  onTap: canSend ? () => _ask(_field.text) : null,
                  child: SizedBox.square(
                    dimension: 32,
                    child: Center(
                      child: KapyIcon(
                        KapyIcons.sendRounded,
                        size: 16,
                        color: canSend
                            ? palette.totalPillText
                            : palette.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The drawer's top line: [title], then Earlier when [earlier], and the
  /// chevron that folds the drawer away, set apart from it.
  Widget _header(
    CalcPalette palette, {
    required Widget title,
    bool earlier = true,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 6, 4, 2),
    child: Row(
      children: [
        Expanded(child: title),
        if (earlier) ...[
          _EarlierButton(compact: widget.compact, onPressed: _showEarlier),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: palette.separator,
          ),
        ],
        KapyAiIconButton(
          key: const ValueKey('voice-ask-fold'),
          icon: KapyIcons.chevronDownRounded,
          tooltip: 'Hide',
          extent: widget.compact ? 44 : 30,
          iconSize: 16,
          radius: AppRadii.control,
          color: palette.textTertiary,
          onPressed: _close,
        ),
      ],
    ),
  );

  Widget _conversation(
    CalcPalette palette,
    KapyChat chat,
    KapyMessage? answer,
  ) {
    final question = chat.messages.lastWhere(
      (message) => message.role == KapyRole.user,
      orElse: () => chat.messages.first,
    );
    final current = _ai.current?.id == chat.id;
    final pending = current ? _ai.pending : null;
    final Widget body;
    if (_picking) {
      body = KapyAiPicker(
        kapyAi: _ai,
        onPick: (model) {
          setState(() => _picking = false);
          unawaited(_ai.answerWith(model));
        },
        onManageAccounts: widget.actions.onManageAccounts,
      );
    } else if (pending != null) {
      body = KapyAiNotice(
        kapyAi: _ai,
        pending: pending,
        onPickAnother: () => setState(() => _picking = true),
        onManageAccounts: widget.actions.onManageAccounts,
        onSignIn: widget.actions.onSignIn,
        onUpgrade: widget.actions.onUpgrade,
      );
    } else if (answer == null || (current && _ai.answering)) {
      body = Text(
        'Reading the transcript…',
        key: const ValueKey('voice-ask-thinking'),
        style: kapyText(13, 19, palette.textTertiary),
      );
    } else {
      body = _answer(palette, chat, answer);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          palette,
          title: Text(
            question.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: kapyText(
              13.5,
              19,
              palette.textSecondary,
              weight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _answer(CalcPalette palette, KapyChat chat, KapyMessage answer) {
    final moments = _momentsOf(answer);
    final source = answer.model?.sourceLine(kapyDeviceWord);
    final readTo = answer.readTo;
    final minutes = (widget.ref.duration.inSeconds / 60).ceil();
    final read = readTo == null
        ? 'Read the whole transcript'
        : 'Read the first ${_minutes(readTo)} of $minutes';
    final insert = widget.onInsert;
    final copy = widget.onCopy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KapyAiMarkdown(
          answer.text,
          sources: _ai.linkSources(chat, answer),
          style: kapyText(14, 21, palette.textPrimary),
        ),
        if (moments.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final at in moments)
                _Moment(at: at, onPlay: () => widget.onPlay?.call(at)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (insert != null)
              TextButton.icon(
                key: const ValueKey('voice-ask-insert'),
                onPressed: () => insert(answer.text),
                icon: KapyIcon(
                  KapyIcons.noteAddRounded,
                  size: 15,
                  color: palette.accentText,
                ),
                label: Text(
                  'Insert into note',
                  style: kapyText(
                    13,
                    16,
                    palette.accentText,
                    weight: FontWeight.w500,
                  ),
                ),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            if (copy != null)
              KapyAiIconButton(
                key: const ValueKey('voice-ask-copy'),
                icon: KapyIcons.copyRounded,
                tooltip: 'Copy',
                extent: 28,
                iconSize: 15,
                radius: AppRadii.control,
                color: palette.textTertiary,
                onPressed: () => copy(answer.text),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [?source, read].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: kapyText(11.5, 16, palette.textTertiary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _earlierList(CalcPalette palette, List<KapyChat> history) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _header(
        palette,
        earlier: false,
        title: Row(
          children: [
            KapyIcon(
              KapyIcons.scheduleRounded,
              size: 15,
              color: palette.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              'Earlier',
              style: kapyText(
                13.5,
                19,
                palette.textSecondary,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      Flexible(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
          children: [
            for (final chat in history)
              _EarlierRow(
                key: ValueKey('voice-ask-earlier-${chat.id}'),
                icon: KapyIcons.messageQuestionRounded,
                title: chat.title,
                preview: chat.messages
                    .lastWhere(
                      (message) => message.role == KapyRole.assistant,
                      orElse: () => chat.messages.last,
                    )
                    .text,
                at: chat.updatedAt,
                onPressed: () => _show(chat.id),
              ),
          ],
        ),
      ),
    ],
  );
}

/// "12 minutes", or "1 minute".
String _minutes(Duration duration) {
  final minutes = duration.inMinutes;
  return minutes == 1 ? '1 minute' : '$minutes minutes';
}

/// The card an answer, a hold or Earlier rises in above the bar.
class _Drawer extends StatelessWidget {
  const _Drawer({super.key, required this.maxHeight, required this.child});

  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.cardBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.separator),
          boxShadow: [
            BoxShadow(
              color: palette.shadow,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// ◷ Earlier: a label beside a pointer, and the clock alone on a sheet, with
/// a 44 pt target there however small the glyph.
class _EarlierButton extends StatelessWidget {
  const _EarlierButton({required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final clock = KapyIcon(
      KapyIcons.scheduleRounded,
      size: 16,
      color: palette.textSecondary,
    );
    final button = InkWell(
      key: const ValueKey('voice-ask-earlier'),
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: compact
          ? SizedBox.square(dimension: 44, child: Center(child: clock))
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  clock,
                  const SizedBox(width: 6),
                  Text(
                    'Earlier',
                    style: kapyText(13, 18, palette.textSecondary),
                  ),
                ],
              ),
            ),
    );
    return compact
        ? Tooltip(
            message: 'Earlier',
            child: Semantics(button: true, label: 'Earlier', child: button),
          )
        : Center(child: button);
  }
}

/// A question to ask with one tap.
class _Starter extends StatelessWidget {
  const _Starter({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return KeepsKeyboard(
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: palette.textSecondary,
          side: BorderSide(color: palette.separator),
          shape: const StadiumBorder(),
        ),
        child: Text(label, style: kapyText(13, 18, palette.textSecondary)),
      ),
    );
  }
}

/// ▷ 0:08: a moment an answer draws on, which plays from there.
class _Moment extends StatelessWidget {
  const _Moment({required this.at, required this.onPlay});

  final Duration at;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final time = formatVoiceDuration(at);
    return Tooltip(
      message: 'Play from $time',
      child: Material(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: InkWell(
          key: ValueKey('voice-ask-moment-${at.inMilliseconds}'),
          onTap: onPlay,
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KapyIcon(
                  KapyIcons.playRounded,
                  size: 12,
                  color: palette.accentText,
                ),
                const SizedBox(width: 6),
                Text(
                  time,
                  style:
                      kapyText(
                        13,
                        18,
                        palette.accentText,
                        weight: FontWeight.w600,
                      ).copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of Earlier: what was asked, the start of its answer, and when.
class _EarlierRow extends StatelessWidget {
  const _EarlierRow({
    super.key,
    required this.icon,
    required this.title,
    required this.preview,
    required this.at,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String title;
  final String preview;
  final DateTime at;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final line = preview.trim().replaceAll(RegExp(r'\s+'), ' ');
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: KapyIcon(icon, size: 16, color: palette.textTertiary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kapyText(14, 20, palette.textPrimary),
                  ),
                  if (line.isNotEmpty)
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kapyText(12.5, 18, palette.textTertiary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _when(at, DateTime.now()),
              style: kapyText(12.5, 20, palette.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// "10:42" today, "Thu 20 Nov" this year, with the year before that.
String _when(DateTime at, DateTime now) {
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  }
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final day =
      '${weekdays[at.weekday - 1]} ${at.day} ${kapyMonths[at.month - 1].substring(0, 3)}';
  return at.year == now.year ? day : '$day ${at.year}';
}
