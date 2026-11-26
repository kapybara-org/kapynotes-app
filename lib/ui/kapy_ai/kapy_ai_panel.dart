import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/phone_keyboard.dart';
import '../../core/popup_keyboard.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'kapy_ai_chats.dart';
import 'kapy_ai_conversation.dart';
import 'kapy_ai_parts.dart';
import 'kapy_ai_picker.dart';

/// Whether the panel is open, and the note its "This note" chip carries.
///
/// Kept apart from [KapyAi] because it is about this window rather than the
/// chats: closing the panel keeps the chat, and opening it from a note only
/// changes which note the next question starts from.
class KapyAiPanelController extends ChangeNotifier {
  bool _open = false;
  String? _noteId;
  String? _draft;

  bool get isOpen => _open;

  /// The note the next question searches first, or null for all notes.
  String? get noteId => _noteId;

  /// Opens from [noteId]'s page, or from nowhere in particular. A [draft]
  /// waits in the composer, for a question asked while Kapy AI was still
  /// answering.
  void open({String? noteId, String? draft}) {
    _open = true;
    _noteId = noteId;
    _draft = draft ?? _draft;
    notifyListeners();
  }

  /// Keeps what was left typed in the composer as it goes, so the question
  /// is still there when it opens again.
  void keep(String typed) {
    if (typed.trim().isNotEmpty) _draft = typed;
  }

  /// The draft for the composer, once. It goes after anything already typed
  /// there, on a line of its own.
  String? takeDraft() {
    final draft = _draft;
    _draft = null;
    return draft;
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void toggle({String? noteId}) => _open ? close() : open(noteId: noteId);

  /// The chip's ✕: the next question searches all notes.
  void detachNote() {
    if (_noteId == null) return;
    _noteId = null;
    notifyListeners();
  }
}

/// The panel's width beside the page.
const double kapyAiPanelWidth = 360;

/// Below this window width the panel no longer fits beside a page of a
/// readable width, and lays over the page instead.
const double kapyAiOverlayBelow = 1180;

/// Kapy AI: the header, a chat or the chats, and the composer. The same in
/// the panel beside the page, over it in a narrow window, and on a phone's
/// sheet pulled up to full height.
///
/// [compact] is the phone's sheet resting over the note it was opened from
/// (M10): Kapy AI and Close, what it is about, the chat, and one field that
/// asks about the note. It keeps this state, so a question asked or typed
/// there is still there when the sheet is pulled up.
class KapyAiPanel extends StatefulWidget {
  const KapyAiPanel({
    super.key,
    required this.kapyAi,
    required this.controller,
    required this.noteTitle,
    required this.onOpenNote,
    required this.onManageAccounts,
    required this.onClose,
    this.onSignIn,
    this.onUpgrade,
    this.now = DateTime.now,
    this.compact = false,
    this.inSheet = false,
    this.onExpand,
  });

  final bool compact;

  /// On a phone's sheet, pulled up to full height or resting. Docked beside
  /// or over the page, on a desktop or a tablet, it is D10's panel.
  final bool inSheet;

  /// Pulls the compact sheet up to full height, for what only it shows: the
  /// model picker a notice offers.
  final VoidCallback? onExpand;

  final KapyAi kapyAi;
  final KapyAiPanelController controller;

  /// A note's title, or null for a note this device cannot open: deleted,
  /// hidden, or never here.
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;

  /// Settings › Voice & AI at Your accounts.
  final VoidCallback onManageAccounts;

  /// Kapy AI Cloud's card: sign in, and see Pro.
  final VoidCallback? onSignIn;
  final VoidCallback? onUpgrade;
  final VoidCallback onClose;
  final DateTime Function() now;

  @override
  State<KapyAiPanel> createState() => _KapyAiPanelState();
}

class _KapyAiPanelState extends State<KapyAiPanel> {
  final _field = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'kapy-ai-composer');
  final _menu = GlobalKey();
  bool _chats = false;
  bool _picking = false;

  KapyAi get _ai => widget.kapyAi;

  @override
  void initState() {
    super.initState();
    _takeDraft();
    _field.addListener(() => setState(() {}));
    widget.controller.addListener(_takeDraft);
    // Asked for rather than autofocused, which yields to whatever already
    // holds focus, and beside a note that is its editor. Esc and typing both
    // need the field. The sheet resting over a note waits for a tap
    // instead, so the keyboard does not cover the note before anyone asks.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.compact) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_takeDraft);
    widget.controller.keep(_field.text);
    _field.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _takeDraft() {
    final draft = widget.controller.takeDraft();
    if (draft == null) return;
    final typed = _field.text.trimRight();
    final text = typed.trim().isEmpty ? draft : '$typed\n$draft';
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _ask(String text) {
    final question = text.trim();
    if (question.isEmpty || _ai.answering) return;
    _field.clear();
    setState(() {
      _chats = false;
      _picking = false;
    });
    unawaited(_ai.ask(question, noteId: widget.controller.noteId));
  }

  /// A pick with a question held up answers it with the new model; without
  /// one it only changes what the chat answers with next.
  void _pick(KapyModel model) {
    setState(() => _picking = false);
    if (_ai.pending != null) {
      unawaited(_ai.answerWith(model));
    } else {
      _ai.pickModel(model);
    }
  }

  void _newChat() {
    _ai.newChat();
    setState(() {
      _chats = false;
      _picking = false;
    });
    _fieldFocus.requestFocus();
  }

  /// Esc closes what is on top first: the picker, then the panel.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_picking) {
      setState(() => _picking = false);
    } else {
      widget.onClose();
    }
    return KeyEventResult.handled;
  }

  /// ↵ asks, ⇧↵ starts a new line. On an empty field with the Cloud notice
  /// up, ↵ is its Go ahead.
  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (_field.text.trim().isEmpty && _ai.pending is KapyCloudConsent) {
      unawaited(_ai.proceed());
    } else {
      _ask(_field.text);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: _onKey,
    child: Material(
      key: const ValueKey('kapy-ai-panel'),
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: Listenable.merge([_ai, widget.controller]),
        builder: (context, _) {
          final noteId = _noteId;
          if (widget.compact && noteId != null) return _compact(noteId);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _chats
                        ? KapyAiChats(
                            kapyAi: _ai,
                            now: widget.now(),
                            onOpened: () => setState(() => _chats = false),
                          )
                        : _body(),
                    if (_picking) ...[
                      // Closes the picker and leaves the keyboard up.
                      KeepsKeyboard(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _picking = false),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: KapyAiPicker(
                            key: _menu,
                            kapyAi: _ai,
                            onPick: _pick,
                            onManageAccounts: () {
                              setState(() => _picking = false);
                              widget.onManageAccounts();
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!_chats) _composer(),
            ],
          );
        },
      ),
    ),
  );

  /// The sheet resting over the note (M10).
  Widget _compact(String noteId) {
    final palette = context.palette;
    final chat = _ai.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.only(left: 20, right: 8),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.sparklesOutlined,
                  size: 18,
                  color: palette.textPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Kapy AI',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kapyText(
                      17,
                      22,
                      palette.textPrimary,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  key: const ValueKey('kapy-ai-close'),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                  onTap: widget.onClose,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          'Close',
                          style: kapyText(
                            15,
                            20,
                            palette.textSecondary,
                            weight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'About ${widget.noteTitle(noteId)}',
            key: const ValueKey('kapy-ai-about'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kapyText(13, 16, palette.textTertiary),
          ),
        ),
        Expanded(
          child: chat == null || chat.messages.isEmpty
              ? const SizedBox.shrink()
              : KapyAiConversation(
                  kapyAi: _ai,
                  chat: chat,
                  noteTitle: widget.noteTitle,
                  onOpenNote: widget.onOpenNote,
                  onPickAnother: () {
                    setState(() => _picking = true);
                    widget.onExpand?.call();
                  },
                  onManageAccounts: widget.onManageAccounts,
                  onSignIn: widget.onSignIn,
                  onUpgrade: widget.onUpgrade,
                  now: widget.now(),
                  compact: true,
                ),
        ),
        _compactComposer(),
      ],
    );
  }

  /// One field that asks about the note, 36 above the screen's edge, or just
  /// above the keyboard while it is up.
  Widget _compactComposer() {
    final palette = context.palette;
    final canSend = _field.text.trim().isNotEmpty && !_ai.answering;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, keyboard ? 8 : 36),
      child: KeepsKeyboard(
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(
            color: palette.controlBackground,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Focus(
                    onKeyEvent: _onFieldKey,
                    child: TextField(
                      key: const ValueKey('kapy-ai-field'),
                      controller: _field,
                      focusNode: _fieldFocus,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      cursorColor: palette.selectedBorder,
                      style: kapyText(15, 20, palette.textPrimary),
                      decoration: InputDecoration.collapsed(
                        hintText: 'Ask about this note',
                        hintStyle: kapyText(15, 20, palette.textTertiary),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Ask',
                child: Material(
                  color: palette.hover,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('kapy-ai-send'),
                    onTap: canSend ? () => _ask(_field.text) : null,
                    child: SizedBox.square(
                      dimension: 28,
                      child: Center(
                        child: KapyIcon(
                          KapyIcons.sendRounded,
                          size: 16,
                          color: canSend
                              ? palette.textPrimary
                              : palette.textTertiary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// D10's header where the panel is docked. A phone's full-height sheet has
  /// no board of its own, so it keeps the hand-lettered title and the clock.
  Widget _header() {
    final palette = context.palette;
    final docked = !widget.inSheet;
    return SizedBox(
      height: docked ? 52 : 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: docked
              ? Border(bottom: BorderSide(color: palette.separator))
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.only(left: 16, right: docked ? 10 : 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _chats ? 'Chats' : 'Kapy AI',
                  maxLines: 1,
                  style: docked
                      ? kapyText(
                          13,
                          18,
                          palette.textPrimary,
                          weight: FontWeight.w500,
                        )
                      : TextStyle(
                          fontFamily: 'Shantell Sans',
                          fontSize: 17,
                          height: 22 / 17,
                          fontWeight: AppWeight.font(AppWeight.section),
                          fontVariations: AppWeight.wght(AppWeight.section),
                          color: palette.textPrimary,
                        ),
                ),
              ),
              KapyAiIconButton(
                key: const ValueKey('kapy-ai-chats'),
                icon: docked
                    ? KapyIcons.chatHistoryOutlined
                    : KapyIcons.scheduleRounded,
                tooltip: 'Chats',
                selected: _chats,
                onPressed: () => setState(() {
                  _chats = !_chats;
                  _picking = false;
                }),
              ),
              const SizedBox(width: 2),
              // It puts the caret straight back in the field.
              KeepsKeyboard(
                child: KapyAiIconButton(
                  key: const ValueKey('kapy-ai-new-chat'),
                  icon: KapyIcons.chatAddOutlined,
                  tooltip: 'New chat',
                  onPressed: _newChat,
                ),
              ),
              const SizedBox(width: 2),
              KapyAiIconButton(
                key: const ValueKey('kapy-ai-close'),
                icon: KapyIcons.closeRounded,
                tooltip: 'Close',
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final chat = _ai.current;
    if (chat == null || chat.messages.isEmpty) {
      final noteId = _noteId;
      return KapyAiEmpty(
        menu: _picking ? _menu : null,
        suggestions: noteId == null
            ? kapyAiExamples
            : [
                'Summarise this note',
                'What’s still open here?',
                ?_ai.suggestionFor(noteId),
              ],
        onAsk: _ask,
      );
    }
    return KapyAiConversation(
      kapyAi: _ai,
      chat: chat,
      noteTitle: widget.noteTitle,
      onOpenNote: widget.onOpenNote,
      onPickAnother: () => setState(() => _picking = true),
      onManageAccounts: widget.onManageAccounts,
      onSignIn: widget.onSignIn,
      onUpgrade: widget.onUpgrade,
      now: widget.now(),
    );
  }

  /// The chip's note, while this device can still open it.
  String? get _noteId {
    final id = widget.controller.noteId;
    return id != null && widget.noteTitle(id) != null ? id : null;
  }

  Widget _composer() {
    final palette = context.palette;
    final noteId = _noteId;
    final typed = _field.text.trim().isNotEmpty;
    final canSend = typed && !_ai.answering;
    final line = typed && _ai.answering ? 'Kapy AI is still answering' : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeepsKeyboard(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.editorBackground,
                border: Border.all(color: palette.separator, width: 1.5),
                borderRadius: BorderRadius.circular(AppRadii.dialog),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (noteId != null) ...[
                      _NoteChip(
                        title: widget.noteTitle(noteId)!,
                        onRemove: widget.controller.detachNote,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Focus(
                      onKeyEvent: _onFieldKey,
                      child: TextField(
                        key: const ValueKey('kapy-ai-field'),
                        controller: _field,
                        focusNode: _fieldFocus,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        cursorColor: palette.selectedBorder,
                        style: kapyText(13.5, 20, palette.textPrimary),
                        decoration: InputDecoration.collapsed(
                          hintText: 'Ask Kapy AI…',
                          hintStyle: kapyText(13.5, 20, palette.textTertiary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: KapyAiModelButton(
                              kapyAi: _ai,
                              open: _picking,
                              onPressed: () =>
                                  setState(() => _picking = !_picking),
                            ),
                          ),
                        ),
                        Tooltip(
                          message: 'Ask',
                          child: Material(
                            color: canSend
                                ? palette.totalPillBackground
                                : palette.kapyHighlight,
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: const ValueKey('kapy-ai-send'),
                              onTap: canSend ? () => _ask(_field.text) : null,
                              child: SizedBox.square(
                                dimension: 28,
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
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (line != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                line,
                textAlign: TextAlign.center,
                style: kapyText(11.5, 16, palette.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

/// "This note · Trip budget", and its ✕.
class _NoteChip extends StatelessWidget {
  const _NoteChip({required this.title, required this.onRemove});

  final String title;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('kapy-ai-chip'),
      height: 24,
      padding: const EdgeInsets.only(left: 7, right: 3),
      decoration: BoxDecoration(
        color: palette.kapyHighlight,
        borderRadius: BorderRadius.circular(AppRadii.compact),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KapyIcon(
            KapyIcons.noteOutlined,
            size: 13,
            color: palette.textSecondary,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              'This note · $title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kapyText(
                12,
                16,
                palette.textSubheading,
                weight: FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 3),
          Tooltip(
            message: 'Search all notes',
            child: InkWell(
              key: const ValueKey('kapy-ai-chip-remove'),
              borderRadius: BorderRadius.circular(AppRadii.small),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: KapyIcon(
                  KapyIcons.closeRounded,
                  size: 12,
                  color: palette.textTertiary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Places [panel] beside [child], the page, while it is open: in a column of
/// its own on a wide window, over the page's right edge on a narrow one.
class KapyAiDock extends StatelessWidget {
  const KapyAiDock({
    super.key,
    required this.kapyAi,
    required this.controller,
    required this.panel,
    required this.child,
  });

  /// Turned off in Settings while open, the panel goes too.
  final KapyAi kapyAi;
  final KapyAiPanelController controller;
  final Widget panel;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, kapyAi]),
    builder: (context, _) {
      if (!controller.isOpen || !kapyAi.enabled) return child;
      final palette = context.palette;
      if (MediaQuery.sizeOf(context).width >= kapyAiOverlayBelow) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: child),
            ToastClearance.beside(
              child: Container(
                width: kapyAiPanelWidth,
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: palette.separator)),
                ),
                child: panel,
              ),
            ),
          ],
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: 12,
            right: 12,
            bottom: 12,
            width: kapyAiPanelWidth,
            child: ToastClearance.beside(
              child: DecoratedBox(
                key: const ValueKey('kapy-ai-overlay'),
                decoration: BoxDecoration(
                  color: palette.wellBackground,
                  border: Border.all(color: palette.separator),
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                  boxShadow: [
                    BoxShadow(
                      color: palette.shadowAt(0x99),
                      offset: const Offset(0, 24),
                      blurRadius: 48,
                      spreadRadius: -16,
                    ),
                    BoxShadow(
                      color: palette.shadowAt(0x59),
                      offset: const Offset(0, 2),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                  child: panel,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The Sparkles button beside the pin: toggles the panel, and stays tonal
/// while it is open. Draws nothing while Kapy AI is off in Settings.
class KapyAiToolbarButton extends StatelessWidget {
  const KapyAiToolbarButton({
    super.key,
    required this.kapyAi,
    required this.controller,
    required this.onPressed,
    this.shortcut,
    this.extent = 32,
    this.radius = 10,
    this.iconSize = 17,
    this.trailingGap = 6,
    this.divided = false,
    this.showsOpen = true,
  });

  final KapyAi kapyAi;
  final KapyAiPanelController controller;
  final VoidCallback onPressed;
  final String? shortcut;
  final double extent;
  final double radius;
  final double iconSize;

  /// The space before the next action, kept inside so a hidden button takes
  /// its gap with it.
  final double trailingGap;

  /// Whether a hairline sets it apart from the actions before it, as at the
  /// end of the page's bar. The hairline hides with the button.
  final bool divided;

  /// Whether it turns tonal while the panel is open. A phone's sheet covers
  /// the note instead, and its button stays a bare icon (M10).
  final bool showsOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([kapyAi, controller]),
    builder: (context, _) {
      if (!kapyAi.enabled) return const SizedBox.shrink();
      final palette = context.palette;
      final open = showsOpen && controller.isOpen;
      final button = KapyAiIconButton(
        key: const ValueKey('page-kapy-ai'),
        icon: KapyIcons.sparklesOutlined,
        tooltip: [open ? 'Close Kapy AI' : 'Ask Kapy AI', ?shortcut].join('  '),
        extent: extent,
        radius: radius,
        iconSize: iconSize,
        selected: open,
        selectedBackground: palette.tonalBackground,
        color: open ? palette.tonalForeground : null,
        onPressed: onPressed,
      );
      return Padding(
        padding: EdgeInsets.only(right: trailingGap),
        child: divided
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 1,
                    height: 16,
                    child: ColoredBox(color: palette.controlBorder),
                  ),
                  const SizedBox(width: 8),
                  button,
                ],
              )
            : button,
      );
    },
  );
}

/// Where a phone's sheet rests over the note it was opened from, as a share
/// of the screen above the keyboard: with the keyboard down its top is at
/// 42.3%, so the note's header and title stay in view (M10).
const double kapyAiSheetRest = 0.577;

/// From this share of the screen up, the sheet is the full panel.
const double _kapyAiSheetFull = 0.8;

/// Kapy AI on a phone: a sheet over the page. From a note ([rest]) it rests
/// at [kapyAiSheetRest] in its compact layout, and otherwise opens at full
/// height. Pulled up it is the full panel, and pulled down past its rest, a
/// tap on the scrim, or Close puts it away. [panel] is built for the sheet's
/// layout of the moment, with what puts the sheet away and what pulls it up.
/// [typing] lets its field keep the keyboard it asks for as it opens.
Future<void> showKapyAiSheet(
  BuildContext context, {
  required bool rest,
  bool typing = false,
  required Widget Function(
    VoidCallback close,
    VoidCallback expand,
    bool compact,
  )
  panel,
}) {
  final palette = context.palette;
  final statusBar = MediaQuery.paddingOf(context).top;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    routeSettings: typing ? const TypingPopupSettings() : null,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: palette.brightness == Brightness.dark
        ? const Color(0xA30C0B09)
        : palette.scrim,
    builder: (_) =>
        _KapyAiSheet(rest: rest, statusBar: statusBar, panel: panel),
  );
}

class _KapyAiSheet extends StatefulWidget {
  const _KapyAiSheet({
    required this.rest,
    required this.statusBar,
    required this.panel,
  });

  final bool rest;
  final double statusBar;
  final Widget Function(VoidCallback close, VoidCallback expand, bool compact)
  panel;

  @override
  State<_KapyAiSheet> createState() => _KapyAiSheetState();
}

class _KapyAiSheetState extends State<_KapyAiSheet> {
  final _sheet = DraggableScrollableController();

  /// Where the person has the sheet, as a share of the space above the
  /// keyboard. Only a drag, a snap or Pick another moves it; the keyboard
  /// moves the space it is measured in instead.
  late double _size = widget.rest ? kapyAiSheetRest : 1;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_resized);
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  void _resized() {
    final wasCompact = _size < _kapyAiSheetFull;
    _size = _sheet.size;
    if (wasCompact != _size < _kapyAiSheetFull) setState(() {});
  }

  void _expand() {
    if (!_sheet.isAttached) return;
    unawaited(
      _sheet.animateTo(
        1,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final above = media.size.height - keyboard;
    final compact = _size < _kapyAiSheetFull;
    // The sheet lives in the space above the keyboard, so its rest and full
    // height are shares of that space and the field always sits just above
    // the keyboard; with the keyboard down, that is the whole screen.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: DraggableScrollableSheet(
        controller: _sheet,
        expand: false,
        snap: true,
        snapSizes: const [kapyAiSheetRest],
        minChildSize: 0,
        initialChildSize: _size,
        builder: (context, scroll) => LayoutBuilder(
          builder: (context, box) {
            final palette = context.palette;
            final height = math.max(box.maxHeight, above * kapyAiSheetRest);
            final under = math.max(
              0.0,
              widget.statusBar - (above - box.maxHeight),
            );
            return ClipRRect(
              key: const ValueKey('kapy-ai-sheet'),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadii.surface),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.sidebarBackground,
                  border: Border(
                    top: BorderSide(color: palette.textPrimary.withAlpha(0x14)),
                  ),
                ),
                child: CustomScrollView(
                  controller: scroll,
                  slivers: [
                    SliverFillRemaining(
                      // Pulled below its rest on the way out, the sheet
                      // keeps its rest layout and slides away clipped.
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: height,
                        maxHeight: height,
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: under,
                            bottom: compact || keyboard > 0
                                ? 0
                                : media.padding.bottom,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Center(
                                  child: Container(
                                    key: const ValueKey('kapy-ai-grabber'),
                                    width: 36,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: palette.textPrimary.withAlpha(
                                        0x33,
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: widget.panel(
                                  () => Navigator.of(context).pop(),
                                  _expand,
                                  compact,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
