import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/kapy_ai.dart';
import '../ai/recording_context.dart';
import '../core/phone_keyboard.dart';
import '../core/theme.dart';
import '../data/note_attachment.dart';
import '../speech/moments.dart';
import '../speech/speech_errors.dart';
import '../speech/summarizer.dart';
import '../speech/summary_instructions.dart';
import '../sync/sync_api.dart';
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

/// Asking about a recording, and making posts from it (KAP-396 b1–b6): the
/// starters and the ask bar under [page], and the drawer an answer or a
/// post rises in over it.
///
/// Questions become a Kapy AI chat linked to the recording, so they are in
/// Kapy AI's history too, and the chat the panel had open comes back when
/// the window closes. Posts are takes on the recording, written the way they
/// always have been, so they work wherever questions don't: in a hidden
/// note, out of answers, or with Kapy AI off.
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
    this.onWrite,
    this.onRemove,
  });

  /// Kapy AI, or null when it is off and only posts are made here.
  final VoiceAskActions? actions;

  /// The recording, with the takes it keeps.
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

  /// Writes a post of [kind] from the transcript, with the person's own
  /// instruction for [VoiceTakeKind.custom], and keeps it on the recording.
  /// Throws when it can't. Null when there is nothing to write one from.
  final Future<VoiceTake> Function(VoiceTakeKind kind, String? instruction)?
  onWrite;

  final ValueChanged<VoiceTake>? onRemove;

  @override
  State<VoiceAsk> createState() => _VoiceAskState();
}

class _VoiceAskState extends State<VoiceAsk> {
  late final KapyAi? _ai = widget.actions?.kapyAi;
  late final String? _panelChat;
  late final KapyRecordingRef? _recording = switch (widget.actions) {
    final actions? => KapyRecordingRef(
      noteId: actions.noteId,
      hash: widget.ref.hash,
    ),
    null => null,
  };
  final TextEditingController _field = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// The chat the drawer shows, while it shows one.
  String? _shown;
  bool _open = false;
  bool _earlier = false;
  bool _picking = false;

  /// The post the drawer shows, by when it was written, while it shows one.
  int? _post;

  /// The post being written, or that could not be, while the drawer shows
  /// it in place of [_post].
  ({VoiceTakeKind kind, String? instruction})? _asked;
  bool _writing = false;
  String? _writeError;

  /// Your own words…: what is sent from the bar becomes a post's
  /// instruction rather than a question.
  bool _ownWords = false;

  /// The answer [VoiceAsk.onCited] was last told about.
  String? _citedFrom;
  final Map<String, List<Duration>> _moments = {};

  @override
  void initState() {
    super.initState();
    _panelChat = _ai?.current?.id;
    _ai?.addListener(_changed);
    _field.addListener(_changed);
  }

  @override
  void dispose() {
    _ai?.removeListener(_changed);
    _field.dispose();
    _focus.dispose();
    final ai = _ai;
    final back = _panelChat;
    // After the tree is torn down, since the panel listens too.
    if (ai != null && ai.current?.id != back) {
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

  bool get _asking => _ai != null && widget.unavailable == null;
  bool get _answering => _ai?.answering ?? false;

  /// What is sent from the bar becomes a post: Your own words…, or every
  /// time where questions are off.
  bool get _custom => widget.onWrite != null && (_ownWords || !_asking);

  /// This recording's chats, newest first.
  List<KapyChat> get _history => [
    for (final chat in _ai?.chats ?? const <KapyChat>[])
      if (chat.recording == _recording) chat,
  ];

  KapyChat? get _chat {
    for (final chat in _ai?.chats ?? const <KapyChat>[]) {
      if (chat.id == _shown) return chat;
    }
    return null;
  }

  VoiceTake? get _take {
    for (final take in widget.ref.takes) {
      if (take.at == _post) return take;
    }
    return null;
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    if (_custom) {
      unawaited(_write(VoiceTakeKind.custom, text.trim()));
    } else {
      _ask(text);
    }
  }

  void _ask(String text) {
    final ai = _ai;
    final question = text.trim();
    if (ai == null || question.isEmpty || !_asking || ai.answering) return;
    final chat = _open && !_earlier ? _chat : null;
    if (chat == null) {
      ai.newChat();
    } else if (ai.current?.id != chat.id) {
      ai.openChat(chat.id);
    }
    unawaited(ai.ask(question, recording: _recording));
    _field.clear();
    setState(() {
      _shown = ai.current?.id;
      _post = null;
      _asked = null;
      _open = true;
      _earlier = false;
      _picking = false;
    });
  }

  /// Writes a post, one at a time: each costs a model call, and two racing
  /// would both try to be the newest take.
  Future<void> _write(VoiceTakeKind kind, String? instruction) async {
    final write = widget.onWrite;
    if (write == null || _writing) return;
    if (kind == VoiceTakeKind.custom) _field.clear();
    setState(() {
      _shown = null;
      _post = null;
      _asked = (kind: kind, instruction: instruction);
      _writing = true;
      _writeError = null;
      _ownWords = false;
      _open = true;
      _earlier = false;
      _picking = false;
    });
    try {
      final take = await write(kind, instruction);
      if (!mounted) return;
      setState(() {
        _post = take.at;
        _asked = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _writeError = _describe(error));
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  static String _describe(Object error) => switch (error) {
    SummarizerUnavailable(:final message) => message,
    SyncException() => describeSpeechError(error),
    _ => 'That did not work. Try again in a moment.',
  };

  void _show(String chatId) {
    _ai!.openChat(chatId);
    setState(() {
      _shown = chatId;
      _post = null;
      _asked = null;
      _open = true;
      _earlier = false;
      _picking = false;
    });
  }

  void _showPost(VoiceTake take) => setState(() {
    _shown = null;
    _post = take.at;
    _asked = null;
    _open = true;
    _earlier = false;
    _picking = false;
  });

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
    final take = _take;
    final showing =
        _open && (_earlier || chat != null || take != null || _asked != null);
    final messages = chat?.messages ?? const <KapyMessage>[];
    final answer =
        showing &&
            !_earlier &&
            messages.isNotEmpty &&
            messages.last.role == KapyRole.assistant
        ? messages.last
        : null;
    _cite(answer);
    final history = _earlierEntries();

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
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 24,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                palette.surfaceBackground.withValues(alpha: 0),
                                palette.surfaceBackground,
                              ],
                            ),
                          ),
                        ),
                        ColoredBox(
                          color: palette.surfaceBackground,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            child: _Drawer(
                              key: const ValueKey('voice-ask-drawer'),
                              maxHeight: constraints.maxHeight - 32,
                              child: _earlier
                                  ? _earlierList(palette, history)
                                  : chat != null
                                  ? _conversation(palette, chat, answer)
                                  : _postView(palette, take),
                            ),
                          ),
                        ),
                      ],
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
                if (!showing) ...[
                  _starters(palette, history),
                  const SizedBox(height: 10),
                ],
                _bar(palette, following: showing && chat != null),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _starters(CalcPalette palette, List<_Earlier> history) {
    if (_ownWords) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _OwnWords(onClose: () => setState(() => _ownWords = false)),
      );
    }
    final questions = _asking
        ? recordingQuestions(widget.ref.transcript)
        : const <String>[];
    final posting = widget.onWrite != null;
    Widget question(String text) =>
        _Starter(label: text, onPressed: _answering ? null : () => _ask(text));
    Widget post(VoiceTakeKind kind) => _Starter(
      label: kind == VoiceTakeKind.custom
          ? 'Your own words…'
          : _postTitle(kind),
      icon: _postIcon(kind),
      onPressed: _writing
          ? null
          : kind == VoiceTakeKind.custom
          ? () {
              setState(() => _ownWords = true);
              _focus.requestFocus();
            }
          : () => unawaited(_write(kind, null)),
    );
    // Questions and posts in turn, so both are in view on a phone.
    final starters = [
      if (questions.isNotEmpty) question(questions[0]),
      if (posting) post(VoiceTakeKind.x),
      if (questions.length > 1) question(questions[1]),
      if (posting) post(VoiceTakeKind.linkedin),
      if (questions.length > 2) question(questions[2]),
      if (posting && _asking) post(VoiceTakeKind.custom),
    ];
    if (starters.isEmpty && history.isEmpty) return const SizedBox.shrink();
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
              if (starters.isNotEmpty)
                Container(
                  width: 1,
                  margin: const EdgeInsets.fromLTRB(4, 9, 8, 9),
                  color: palette.separator,
                ),
            ],
            for (final starter in starters)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(child: starter),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bar(CalcPalette palette, {required bool following}) {
    final custom = _custom;
    final enabled = _asking || custom;
    final canSend =
        enabled &&
        (custom ? !_writing : !_answering) &&
        _field.text.trim().isNotEmpty;
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
            color: enabled ? palette.accentText : palette.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const ValueKey('voice-ask-field'),
              controller: _field,
              focusNode: _focus,
              enabled: enabled,
              textInputAction: TextInputAction.send,
              onSubmitted: _send,
              // A question and an instruction have the same cap.
              inputFormatters: [
                LengthLimitingTextInputFormatter(instructionMaxChars),
              ],
              cursorColor: palette.selectedBorder,
              style: kapyText(13.5, 20, palette.textPrimary),
              decoration: InputDecoration.collapsed(
                hintText: custom
                    ? 'What should it create?'
                    : !_asking
                    ? widget.unavailable
                    : following
                    ? 'Ask a follow-up…'
                    : 'Ask about this recording',
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
                  onTap: canSend ? () => _send(_field.text) : null,
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
          _EarlierButton(
            compact: widget.compact,
            labelled: true,
            onPressed: _showEarlier,
          ),
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
    final ai = _ai!;
    final actions = widget.actions!;
    final current = ai.current?.id == chat.id;
    final pending = current ? ai.pending : null;
    final Widget body;
    if (_picking) {
      body = KapyAiPicker(
        kapyAi: ai,
        onPick: (model) {
          setState(() => _picking = false);
          unawaited(ai.answerWith(model));
        },
        onManageAccounts: actions.onManageAccounts,
      );
    } else if (pending != null) {
      body = KapyAiNotice(
        kapyAi: ai,
        pending: pending,
        onPickAnother: () => setState(() => _picking = true),
        onManageAccounts: actions.onManageAccounts,
        onSignIn: actions.onSignIn,
        onUpgrade: actions.onUpgrade,
      );
    } else if (answer == null || (current && ai.answering)) {
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
    final model = answer.model;
    final readTo = answer.readTo;
    final minutes = (widget.ref.duration.inSeconds / 60).ceil();
    final read = readTo != null
        ? 'Read the first ${_minutes(readTo)} of $minutes'
        : _ai!.readWhole(chat, answer)
        ? 'Read the whole transcript'
        : null;
    final insert = widget.onInsert;
    final copy = widget.onCopy;
    final meta = kapyText(11.5, 16, palette.textTertiary);
    final source = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (model != null)
          Flexible(
            child: InkWell(
              key: const ValueKey('voice-ask-model'),
              onTap: () => setState(() => _picking = true),
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: widget.compact ? 44 : 26,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      KapyIcon(
                        kapyModelIcon(model.kind),
                        size: 13,
                        color: palette.textTertiary,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          model.plainLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: meta,
                        ),
                      ),
                      const SizedBox(width: 3),
                      KapyIcon(
                        KapyIcons.chevronDownRounded,
                        size: 11,
                        color: palette.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (read != null)
          Flexible(
            child: Text(
              model == null ? read : ' · $read',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
          ),
      ],
    );
    final tools = Row(
      children: [
        if (insert != null) _insertButton(palette, answer.text),
        if (copy != null)
          KapyAiIconButton(
            key: const ValueKey('voice-ask-copy'),
            icon: KapyIcons.copyRounded,
            tooltip: 'Copy',
            extent: widget.compact ? 44 : 28,
            iconSize: 15,
            radius: AppRadii.control,
            color: palette.textTertiary,
            onPressed: () => copy(answer.text),
          ),
        if (!widget.compact) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: source),
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KapyAiMarkdown(
          answer.text,
          sources: _ai!.linkSources(chat, answer),
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
        tools,
        if (widget.compact)
          Align(alignment: Alignment.centerLeft, child: source),
      ],
    );
  }

  /// Everything asked or made from this recording, newest first: its
  /// chats, and its takes, those made before posts moved here among them.
  List<_Earlier> _earlierEntries() => [
    for (final chat in _history)
      (
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
        open: () => _show(chat.id),
      ),
    for (final take in widget.ref.takes)
      (
        key: ValueKey('voice-ask-earlier-take-${take.at}'),
        icon: _postIcon(take.kind),
        title: _postTitle(take.kind, take.instruction),
        preview: take.text,
        at: DateTime.fromMillisecondsSinceEpoch(take.at),
        open: () => _showPost(take),
      ),
  ]..sort((a, b) => b.at.compareTo(a.at));

  /// A post in the drawer, or the one being written, or why it wasn't.
  Widget _postView(CalcPalette palette, VoiceTake? take) {
    final asked = take == null
        ? _asked!
        : (kind: take.kind, instruction: take.instruction);
    final Widget body;
    if (take != null) {
      final insert = widget.onInsert;
      final copy = widget.onCopy;
      final remove = widget.onRemove;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            take.text,
            style: kapyText(14, 21, palette.textPrimary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (insert != null) _insertButton(palette, take.text),
              if (copy != null)
                KapyAiIconButton(
                  key: const ValueKey('voice-ask-copy'),
                  icon: KapyIcons.copyRounded,
                  tooltip: 'Copy',
                  extent: 28,
                  iconSize: 15,
                  radius: AppRadii.control,
                  color: palette.textTertiary,
                  onPressed: () => copy(take.text),
                ),
              KapyAiIconButton(
                key: const ValueKey('voice-ask-again'),
                icon: KapyIcons.refreshRounded,
                tooltip: 'Try again',
                extent: 28,
                iconSize: 15,
                radius: AppRadii.control,
                color: palette.textTertiary,
                onPressed: () => unawaited(_write(take.kind, take.instruction)),
              ),
              const Spacer(),
              if (remove != null)
                KapyAiIconButton(
                  key: const ValueKey('voice-ask-remove'),
                  icon: KapyIcons.deleteOutlined,
                  tooltip: 'Remove',
                  extent: 28,
                  iconSize: 15,
                  radius: AppRadii.control,
                  color: palette.textTertiary,
                  onPressed: () {
                    remove(take);
                    _close();
                  },
                ),
            ],
          ),
        ],
      );
    } else if (_writing) {
      body = Text(
        'Writing…',
        key: const ValueKey('voice-ask-writing'),
        style: kapyText(13, 19, palette.textTertiary),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _writeError ?? '',
            style: kapyText(13, 19, palette.textSecondary),
          ),
          const SizedBox(height: 10),
          KapyAiButton(
            'Try again',
            filled: true,
            onPressed: () => unawaited(_write(asked.kind, asked.instruction)),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          palette,
          earlier: _earlierEntries().isNotEmpty,
          title: Row(
            children: [
              KapyIcon(
                _postIcon(asked.kind),
                size: 15,
                color: palette.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _postTitle(asked.kind, asked.instruction),
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
            ],
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

  Widget _insertButton(CalcPalette palette, String text) => TextButton.icon(
    key: const ValueKey('voice-ask-insert'),
    onPressed: () => widget.onInsert?.call(text),
    icon: KapyIcon(
      KapyIcons.noteAddRounded,
      size: 15,
      color: palette.accentText,
    ),
    label: Text(
      'Insert into note',
      style: kapyText(13, 16, palette.accentText, weight: FontWeight.w500),
    ),
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  Widget _earlierList(CalcPalette palette, List<_Earlier> history) => Column(
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
            for (final entry in history)
              _EarlierRow(
                key: entry.key,
                icon: entry.icon,
                title: entry.title,
                preview: entry.preview,
                at: entry.at,
                onPressed: entry.open,
              ),
          ],
        ),
      ),
    ],
  );
}

/// A row of Earlier: a question asked, or a post made.
typedef _Earlier = ({
  Key key,
  KapyIconData icon,
  String title,
  String preview,
  DateTime at,
  VoidCallback open,
});

/// What a post is called on its starter, over it in the drawer and in
/// Earlier: the starter's label, or the person's own words.
String _postTitle(VoiceTakeKind kind, [String? instruction]) => switch (kind) {
  VoiceTakeKind.x => 'Create X post',
  VoiceTakeKind.linkedin => 'Create LinkedIn post',
  VoiceTakeKind.custom => instruction ?? 'Your own words',
};

KapyIconData _postIcon(VoiceTakeKind kind) => switch (kind) {
  VoiceTakeKind.x => KapyIcons.newTwitter,
  VoiceTakeKind.linkedin => KapyIcons.linkedin,
  VoiceTakeKind.custom => KapyIcons.pencilEditRounded,
};

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

/// ◷ Earlier: a label beside a pointer, and the clock alone in a sheet's
/// starters unless [labelled], with a 44 pt target on a sheet however small
/// the glyph.
class _EarlierButton extends StatelessWidget {
  const _EarlierButton({
    required this.compact,
    required this.onPressed,
    this.labelled = false,
  });

  final bool compact;
  final bool labelled;
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
      child: compact && !labelled
          ? SizedBox.square(dimension: 44, child: Center(child: clock))
          : Container(
              constraints: BoxConstraints(minHeight: compact ? 44 : 0),
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
    return compact && !labelled
        ? Tooltip(
            message: 'Earlier',
            child: Semantics(button: true, label: 'Earlier', child: button),
          )
        : Center(child: button);
  }
}

/// A question to ask with one tap.
class _Starter extends StatelessWidget {
  const _Starter({required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback? onPressed;

  /// A post's logo or pencil, in the chip's own colour.
  final KapyIconData? icon;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?) ...[
              KapyIcon(icon, size: 14, color: palette.textSecondary),
              const SizedBox(width: 6),
            ],
            Text(label, style: kapyText(13, 18, palette.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// ✎ Your own words ✕, in place of the starters while the bar takes a
/// post's instruction.
class _OwnWords extends StatelessWidget {
  const _OwnWords({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('voice-ask-own-words'),
      height: 32,
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KapyIcon(
            KapyIcons.pencilEditRounded,
            size: 14,
            color: palette.accentText,
          ),
          const SizedBox(width: 6),
          Text('Your own words', style: kapyText(13, 18, palette.accentText)),
          KeepsKeyboard(
            child: KapyAiIconButton(
              icon: KapyIcons.closeRounded,
              tooltip: 'Ask a question instead',
              extent: 32,
              iconSize: 13,
              radius: 16,
              color: palette.accentText,
              onPressed: onClose,
            ),
          ),
        ],
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
