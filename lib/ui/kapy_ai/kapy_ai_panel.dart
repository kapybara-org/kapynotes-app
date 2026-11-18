import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/theme.dart';
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
/// full-screen sheet.
class KapyAiPanel extends StatefulWidget {
  const KapyAiPanel({
    super.key,
    required this.kapyAi,
    required this.controller,
    required this.noteTitle,
    required this.onOpenNote,
    required this.onManageAccounts,
    required this.onClose,
    this.shortcut,
    this.now = DateTime.now,
  });

  final KapyAi kapyAi;
  final KapyAiPanelController controller;

  /// A note's title, or null for a note this device cannot open: deleted,
  /// hidden, or never here.
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;

  /// Settings › Voice & AI at Your accounts.
  final VoidCallback onManageAccounts;
  final VoidCallback onClose;

  /// The keys that open and close the panel, as a keycap prints them: ⌘J.
  /// Null on a phone, and where the shortcut has been cleared.
  final String? shortcut;
  final DateTime Function() now;

  @override
  State<KapyAiPanel> createState() => _KapyAiPanelState();
}

class _KapyAiPanelState extends State<KapyAiPanel> {
  final _field = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'kapy-ai-composer');
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
    // need the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_takeDraft);
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
        builder: (context, _) => Column(
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
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _picking = false),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: KapyAiPicker(
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
        ),
      ),
    ),
  );

  Widget _header() {
    final palette = context.palette;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _chats ? 'Chats' : 'Kapy AI',
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'Shantell Sans',
                  fontSize: 17,
                  height: 22 / 17,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
            KapyAiIconButton(
              key: const ValueKey('kapy-ai-chats'),
              icon: KapyIcons.scheduleRounded,
              tooltip: 'Chats',
              selected: _chats,
              onPressed: () => setState(() {
                _chats = !_chats;
                _picking = false;
              }),
            ),
            const SizedBox(width: 2),
            KapyAiIconButton(
              key: const ValueKey('kapy-ai-new-chat'),
              icon: KapyIcons.chatAddOutlined,
              tooltip: 'New chat',
              onPressed: _newChat,
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
    );
  }

  Widget _body() {
    final chat = _ai.current;
    if (chat == null || chat.messages.isEmpty) {
      final noteId = _noteId;
      return KapyAiEmpty(
        suggestions: noteId == null
            ? const [
                'What did I plan for this week?',
                'Find my notes about Lisbon',
                'Summarise what I wrote yesterday',
              ]
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
    final empty = _ai.current?.messages.isEmpty ?? true;
    final shortcut = widget.shortcut;
    final typed = _field.text.trim().isNotEmpty;
    final canSend = typed && !_ai.answering;
    final line = typed && _ai.answering
        ? 'Kapy AI is still answering'
        : empty && shortcut != null
        ? '$shortcut opens and closes Kapy AI'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
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
                          borderRadius: BorderRadius.circular(AppRadii.control),
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
                                  strokeWidth: 1.8,
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
            strokeWidth: 1.8,
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
                  strokeWidth: 1.8,
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
            SizedBox(
              width: kapyAiPanelWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 12, right: 12, bottom: 4),
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
    this.trailingGap = 6,
  });

  final KapyAi kapyAi;
  final KapyAiPanelController controller;
  final VoidCallback onPressed;
  final String? shortcut;
  final double extent;

  /// The space before the next action, kept inside so a hidden button takes
  /// its gap with it.
  final double trailingGap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([kapyAi, controller]),
    builder: (context, _) {
      if (!kapyAi.enabled) return const SizedBox.shrink();
      final palette = context.palette;
      final open = controller.isOpen;
      return Padding(
        padding: EdgeInsets.only(right: trailingGap),
        child: KapyAiIconButton(
          key: const ValueKey('page-kapy-ai'),
          icon: KapyIcons.sparklesOutlined,
          tooltip: [
            open ? 'Close Kapy AI' : 'Ask Kapy AI',
            ?shortcut,
          ].join('  '),
          extent: extent,
          selected: open,
          selectedBackground: palette.tonalBackground,
          color: open ? palette.tonalForeground : null,
          onPressed: onPressed,
        ),
      );
    },
  );
}

/// Kapy AI on a phone: the panel as a full-screen sheet.
Future<void> showKapyAiSheet(
  BuildContext context, {
  required Widget Function(VoidCallback close) panel,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: context.palette.sidebarBackground,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
  ),
  builder: (sheetContext) => SizedBox(
    height: MediaQuery.sizeOf(sheetContext).height,
    child: panel(() => Navigator.of(sheetContext).pop()),
  ),
);
