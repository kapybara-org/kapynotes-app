import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/voice_recording_controller.dart';
import '../billing/note_limit.dart';
import '../core/app_tray.dart';
import '../core/menu_bar_panel.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/layout_prefs.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/shortcut_prefs.dart';
import '../data/task_board.dart';
import 'back_forward.dart';
import 'keycap.dart';
import 'sidebar_timestamp.dart';
import 'tasks/task_marks.dart';
import 'tasks/tasks_controller.dart';

/// Whether the panel may check [note]'s tasks or add one to it: not while the
/// plan holds the note read-only, and not in a note shared view-only.
bool panelCanEdit(
  Note note, {
  NoteLimit? limit,
  bool Function(Note note)? canEditShared,
}) {
  if (limit?.isLocked(note) ?? false) return false;
  if (!note.isShared) return true;
  return canEditShared?.call(note) ?? false;
}

/// Draws the menu bar panel into its own view, beside the window's.
///
/// Placed as a [ViewAnchor]'s view, so it lives in the same tree, and the same
/// isolate, as the window. It has its own [MaterialApp] for what a text field
/// needs (an overlay, text editing keys), in the window's theme.
class MenuBarPanelView extends StatelessWidget {
  const MenuBarPanelView({
    super.key,
    required this.controller,
    required this.look,
    required this.lookChanges,
    required this.panel,
  });

  final MenuBarPanelController controller;

  /// The themes the panel wears now: the window's, without transparency.
  final WindowLook Function() look;

  /// Whatever changes [look].
  final Listenable lookChanges;

  /// The panel itself, built only while it is open.
  final WidgetBuilder panel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, lookChanges]),
    builder: (context, _) {
      final view = controller.view;
      if (view == null) return const ViewCollection(views: []);
      final look = this.look();
      return View(
        view: view,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: look.light,
          darkTheme: look.dark,
          themeMode: look.mode,
          home: controller.isOpen
              ? KeyedSubtree(
                  key: ValueKey(controller.openings),
                  child: Builder(builder: panel),
                )
              : const SizedBox.shrink(),
        ),
      );
    },
  );
}

enum _Tab { notes, tasks }

/// What the line under the field says once something has happened.
sealed class _Notice {
  const _Notice();
}

final class _Saved extends _Notice {
  const _Saved(this.noteId);
  final String noteId;
}

final class _Added extends _Notice {
  const _Added(this.taskId);
  final String taskId;
}

final class _AtLimit extends _Notice {
  const _AtLimit(this.limit);
  final int? limit;
}

final class _MicrophoneRefused extends _Notice {
  const _MicrophoneRefused();
}

final class _NoMicrophone extends _Notice {
  const _NoMicrophone();
}

/// Two tabs, each with its own capture field and its own list, opening on the
/// one used last. See handoffs/KAPY-14/menubar-spec.md.
class MenuBarPanel extends StatefulWidget {
  const MenuBarPanel({
    super.key,
    required this.controller,
    required this.notes,
    required this.tasks,
    required this.prefs,
    required this.shortcuts,
    required this.canEdit,
    required this.inWindow,
    required this.isTaken,
    this.noteLimit,
    this.recording,
    this.now = DateTime.now,
  });

  final MenuBarPanelController controller;
  final NotesStore notes;
  final TasksController tasks;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;

  /// Whether a note's tasks may be checked or added to: false for a note
  /// shared view-only, and for one the Free plan holds read-only.
  final bool Function(Note note) canEdit;

  /// Closes the panel, brings the window forward and has it act.
  final Future<void> Function(void Function(MenuBarWindowActions window))
  inWindow;

  /// Whether another app holds [action]'s chord, so this one never got it.
  final bool Function(ShortcutAction action) isTaken;

  final NoteLimit? noteLimit;
  final VoiceRecordingController? recording;
  final DateTime Function() now;

  /// Do now and then this many rows of the list, before "All tasks".
  static const int taskRows = 6;

  /// Pinned and then recent notes, this many in all.
  static const int noteRows = 8;
  static const int pinnedRows = 3;

  @override
  State<MenuBarPanel> createState() => _MenuBarPanelState();
}

class _MenuBarPanelState extends State<MenuBarPanel> {
  late _Tab _tab = widget.prefs.menuBarOpensTasks ? _Tab.tasks : _Tab.notes;
  late final FocusNode _field = FocusNode(
    debugLabel: 'Menu bar panel field',
    onKeyEvent: _onFieldKey,
  );
  final FocusNode _list = FocusNode(debugLabel: 'Menu bar panel list');
  final LayerLink _chipLink = LayerLink();
  final OverlayPortalController _picker = OverlayPortalController();

  /// The row the arrow keys are on, or null while the field has them.
  int? _cursor;
  int? _hovered;
  _Notice? _notice;
  Timer? _noticeTimer;

  /// The tasks as the panel opened, then each one added: a task checked in
  /// place keeps its row until the panel closes.
  List<String>? _taskOrder;
  String? _doNowId;
  String? _recordingNoteId;

  TextEditingController get _draft => _tab == _Tab.notes
      ? widget.controller.noteDraft
      : widget.controller.taskDraft;

  @override
  void initState() {
    super.initState();
    widget.notes.addListener(_changed);
    widget.tasks.addListener(_changed);
    widget.noteLimit?.addListener(_changed);
    widget.recording?.addListener(_recordingChanged);
    widget.controller.noteDraft.addListener(_changed);
    widget.controller.taskDraft.addListener(_changed);
    _field.requestFocus();
  }

  @override
  void dispose() {
    widget.notes.removeListener(_changed);
    widget.tasks.removeListener(_changed);
    widget.noteLimit?.removeListener(_changed);
    widget.recording?.removeListener(_recordingChanged);
    widget.controller.noteDraft.removeListener(_changed);
    widget.controller.taskDraft.removeListener(_changed);
    _noticeTimer?.cancel();
    _field.dispose();
    _list.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The recording bar stands where the field was, so when a recording ends,
  /// however it ends, the field gets its focus and the panel its keys back.
  void _recordingChanged() {
    if (_recordingNoteId != null && widget.recording?.session == null) {
      _recordingNoteId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _field.requestFocus();
      });
    }
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Tabs and keys

  void _show(_Tab tab) {
    if (_picker.isShowing) _picker.hide();
    setState(() {
      _tab = tab;
      _cursor = null;
      _notice = null;
    });
    widget.prefs.menuBarOpensTasks = tab == _Tab.tasks;
    _field.requestFocus();
  }

  void _escape() {
    if (_picker.isShowing) {
      _picker.hide();
      _field.requestFocus();
    } else if (_cursor != null) {
      setState(() => _cursor = null);
      _field.requestFocus();
    } else if (_isRecording) {
      unawaited(_discardRecording());
    } else {
      unawaited(widget.controller.close());
    }
  }

  KeyEventResult _onFieldKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (keyboard.isShiftPressed || _draft.value.composing.isValid) {
        return KeyEventResult.ignored;
      }
      if (_isRecording) {
        unawaited(_stopRecording());
      } else {
        unawaited(
          _submit(open: keyboard.isMetaPressed || keyboard.isControlPressed),
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && _rowCount > 0) {
      final text = _draft.text;
      final caret = _draft.selection.extentOffset;
      if (_tab == _Tab.notes &&
          text.substring(caret.clamp(0, text.length)).contains('\n')) {
        return KeyEventResult.ignored;
      }
      setState(() => _cursor = 0);
      _list.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final cursor = _cursor;
    if (cursor == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _cursor = (cursor + 1).clamp(0, _rowCount - 1));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      if (cursor == 0) {
        setState(() => _cursor = null);
        _field.requestFocus();
      } else {
        setState(() => _cursor = cursor - 1);
      }
    } else if (key == LogicalKeyboardKey.space && _tab == _Tab.tasks) {
      final item = _taskRows()[cursor];
      _check(item, done: item.line.done ? false : true);
    } else if (key == LogicalKeyboardKey.enter) {
      _openRow(cursor);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  int get _rowCount =>
      _tab == _Tab.tasks ? _taskRows().length : _noteRows().length;

  void _openRow(int index) {
    if (_tab == _Tab.tasks) {
      _openTask(_taskRows()[index]);
    } else {
      final id = _noteRows()[index].id;
      unawaited(widget.inWindow((window) => window.openNote(id)));
    }
  }

  // ---------------------------------------------------------------------------
  // Capture

  void _say(_Notice? notice) {
    _noticeTimer?.cancel();
    setState(() => _notice = notice);
    if (notice is _Saved || notice is _Added) {
      _noticeTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _notice = null);
      });
    }
  }

  bool get _canCreate => widget.noteLimit?.canCreate ?? true;

  Future<void> _submit({required bool open}) async {
    final draft = _draft;
    final words = draft.text.trim();
    if (words.isEmpty) return;
    if (_tab == _Tab.notes) {
      if (!_canCreate) return _say(_AtLimit(widget.noteLimit?.limit));
      final note = widget.notes.create(body: words);
      draft.clear();
      if (open) {
        return widget.inWindow((window) => window.openNote(note.id));
      }
      return _say(_Saved(note.id));
    }
    final noteId = _taskNote?.id;
    if (noteId == null && widget.tasks.read().home == null && !_canCreate) {
      return _say(_AtLimit(widget.noteLimit?.limit));
    }
    draft.clear();
    final id = await widget.tasks.add(words, noteId: noteId);
    if (!mounted) return;
    if (open) {
      return widget.inWindow(
        (window) =>
            noteId == null ? window.openTasks() : window.openNote(noteId),
      );
    }
    if (id != null) _taskOrder?.add(id);
    _say(id == null ? null : _Added(id));
  }

  Future<void> _undoAdd(String taskId) async {
    _say(null);
    final item = widget.tasks.read().byId(taskId);
    if (item != null) await widget.tasks.remove(item);
  }

  /// The note the Tasks field adds to, while it may still be added to.
  Note? get _taskNote {
    final note = widget.notes.byId(widget.controller.taskNoteId);
    if (note == null ||
        note.isHidden ||
        note.isArchived ||
        !widget.canEdit(note)) {
      return null;
    }
    return note;
  }

  // ---------------------------------------------------------------------------
  // Voice

  bool get _isRecording {
    final session = widget.recording?.session;
    return session != null && session.noteId == _recordingNoteId;
  }

  Future<void> _record() async {
    final recording = widget.recording;
    if (recording == null || recording.isRecording) return;
    if (!_canCreate) return _say(_AtLimit(widget.noteLimit?.limit));
    if (!await recording.hasMicrophone()) {
      if (mounted) _say(const _NoMicrophone());
      return;
    }
    final note = widget.notes.create(body: Note.blankBody, authored: false);
    setState(() => _recordingNoteId = note.id);
    if (await recording.start(noteId: note.id)) return;
    _recordingNoteId = null;
    widget.notes.delete(note.id);
    if (mounted) _say(const _MicrophoneRefused());
  }

  Future<void> _stopRecording() async {
    final id = _recordingNoteId;
    await widget.recording?.finishRecordingAndFlush();
    if (mounted && id != null) _say(_Saved(id));
  }

  Future<void> _discardRecording() async {
    final id = _recordingNoteId;
    await widget.recording?.cancel();
    if (id != null) widget.notes.delete(id);
  }

  // ---------------------------------------------------------------------------
  // Tasks

  List<TaskItem> _taskRows() {
    final board = widget.tasks.read();
    final order = _taskOrder ??= [
      for (final item in board.open)
        if (item.doNow) item.id,
      for (final item in board.open)
        if (!item.doNow) item.id,
    ];
    _doNowId ??= board.open.where((item) => item.doNow).firstOrNull?.id ?? '';
    for (final item in board.open) {
      if (!order.contains(item.id)) order.add(item.id);
    }
    final rows = <TaskItem>[];
    var others = 0;
    for (final id in order) {
      final item = board.byId(id);
      if (item == null) continue;
      if (id != _doNowId) {
        if (others == MenuBarPanel.taskRows) break;
        others++;
      }
      rows.add(item);
    }
    return rows;
  }

  void _check(TaskItem item, {required bool done}) {
    if (!widget.canEdit(item.note)) return;
    unawaited(widget.tasks.setDone(item, done: done));
  }

  void _openTask(TaskItem item) {
    widget.tasks.requestSheet(item.id);
    unawaited(widget.inWindow((window) => window.openTasks()));
  }

  // ---------------------------------------------------------------------------
  // Notes

  List<Note> _noteRows() {
    final pinned = widget.notes.pinnedNoteIds;
    final notes = widget.notes.notes;
    final first = [
      for (final note in notes)
        if (pinned.contains(note.id)) note,
    ].take(MenuBarPanel.pinnedRows).toList();
    return [
      ...first,
      ...notes
          .where((note) => !first.contains(note))
          .take(MenuBarPanel.noteRows - first.length),
    ];
  }

  String _ago(DateTime at) {
    final now = widget.now();
    final minutes = now.difference(at).inMinutes;
    if (minutes < 60) return '${minutes < 1 ? 1 : minutes}m';
    final today = DateTime(now.year, now.month, now.day);
    if (!at.isBefore(today)) return '${now.difference(at).inHours}h';
    return SidebarTimestamp.glance(at, now: now, displayTime: (time) => time);
  }

  // ---------------------------------------------------------------------------
  // Drawing

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final meta = AppPlatform.isMacOS;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          LogicalKeyboardKey.digit1,
          meta: meta,
          control: !meta,
        ): () =>
            _show(_Tab.notes),
        SingleActivator(
          LogicalKeyboardKey.digit2,
          meta: meta,
          control: !meta,
        ): () =>
            _show(_Tab.tasks),
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
      },
      child: BackForwardArea(
        onStep: _stepTab,
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: AppFonts.ui,
              fontSize: 13.5,
              height: 18 / 13.5,
              color: palette.textPrimary,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: 0,
                maxHeight: MenuBarPanelController.maxHeight,
                child: _ReportHeight(
                  onHeight: widget.controller.fitHeight,
                  child: Container(
                    key: const ValueKey('menu-bar-panel'),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: palette.editorBackground,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: dark
                            ? palette.textPrimary.withAlpha(0x17)
                            : palette.textPrimary.withAlpha(0x1A),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: _Tabs(tab: _tab, onTab: _show),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          child: _captureField(context),
                        ),
                        _hintRow(context),
                        Divider(height: 1, thickness: 1, color: palette.hover),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
                            child: Focus(
                              focusNode: _list,
                              onKeyEvent: _onListKey,
                              child: BackForwardSlide(
                                child: _tab == _Tab.tasks
                                    ? _tasksList(context)
                                    : _notesList(context),
                              ),
                            ),
                          ),
                        ),
                        Divider(height: 1, thickness: 1, color: palette.hover),
                        _footer(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A swipe or the mouse's Back and Forward over the panel: Notes is the
  /// first tab and Tasks the second.
  bool _stepTab(BackForwardStep step) {
    final tab = step == BackForwardStep.back ? _Tab.notes : _Tab.tasks;
    if (tab == _tab) return false;
    _show(tab);
    return true;
  }

  Widget _captureField(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final sage = theme.colorScheme.primary;
    final notes = _tab == _Tab.notes;
    if (_isRecording) return _recordingBar(context);
    return ListenableBuilder(
      listenable: _field,
      builder: (context, _) {
        final focused = _field.hasFocus && _cursor == null;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 37),
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
          decoration: BoxDecoration(
            color: dark ? palette.wellBackground : palette.sidebarBackground,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: focused ? sage : palette.controlBorder),
            boxShadow: [
              if (focused)
                BoxShadow(color: sage.withValues(alpha: 0.2), spreadRadius: 3),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('menu-bar-field'),
                  controller: _draft,
                  focusNode: _field,
                  onTap: () => setState(() => _cursor = null),
                  minLines: 1,
                  maxLines: notes ? 5 : 1,
                  keyboardType: notes
                      ? TextInputType.multiline
                      : TextInputType.text,
                  textInputAction: notes
                      ? TextInputAction.newline
                      : TextInputAction.done,
                  cursorColor: sage,
                  style: TextStyle(
                    fontFamily: AppFonts.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    color: palette.textPrimary,
                  ),
                  decoration: InputDecoration.collapsed(
                    hintText: notes ? 'Write a note…' : 'Add a task…',
                    hintStyle: TextStyle(
                      fontFamily: AppFonts.ui,
                      fontSize: 14,
                      height: 20 / 14,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
              ),
              if (notes && widget.recording != null)
                _IconButton(
                  key: const ValueKey('menu-bar-mic'),
                  icon: KapyIcons.micRounded,
                  tooltip: 'Record a voice note',
                  onPressed: () => unawaited(_record()),
                ),
              if (!notes) _noteChip(context),
            ],
          ),
        );
      },
    );
  }

  Widget _recordingBar(BuildContext context) {
    final palette = context.palette;
    final elapsed = widget.recording?.session?.elapsed ?? Duration.zero;
    final seconds = elapsed.inSeconds;
    return Container(
      key: const ValueKey('menu-bar-recording'),
      height: 37,
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
      decoration: BoxDecoration(
        color: palette.wellBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder),
      ),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.clay,
              shape: BoxShape.circle,
            ),
            child: const SizedBox.square(dimension: 8),
          ),
          const SizedBox(width: 10),
          Text(
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
            style: TextStyle(
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: palette.textPrimary,
            ),
          ),
          const Spacer(),
          _TextButton(
            key: const ValueKey('menu-bar-stop'),
            label: 'Stop',
            onPressed: () => unawaited(_stopRecording()),
          ),
        ],
      ),
    );
  }

  Widget _noteChip(BuildContext context) {
    final palette = context.palette;
    final note = _taskNote;
    final label = note?.title ?? 'No note';
    return CompositedTransformTarget(
      link: _chipLink,
      child: OverlayPortal(
        controller: _picker,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _chipLink,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 6),
          child: Align(
            alignment: Alignment.topLeft,
            child: _NotePicker(
              notes: _pickable(),
              chosen: note?.id,
              onPick: (id) {
                _picker.hide();
                setState(() => widget.controller.taskNoteId = id);
                _field.requestFocus();
              },
            ),
          ),
        ),
        child: Semantics(
          button: true,
          label: 'Add to note: $label',
          child: InkWell(
            key: const ValueKey('menu-bar-note-chip'),
            borderRadius: BorderRadius.circular(7),
            onTap: _picker.toggle,
            child: Container(
              height: 28,
              constraints: const BoxConstraints(maxWidth: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: note == null
                  ? null
                  : BoxDecoration(
                      color: palette.editorBackground,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: palette.controlBorder),
                    ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KapyIcon(
                    KapyIcons.noteOutlined,
                    size: 15,
                    color: palette.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  KapyIcon(
                    KapyIcons.chevronDownRounded,
                    size: 14,
                    color: palette.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The notes a task may go into: pinned, then recent, never hidden, never
  /// a drawing, and never one this person cannot change.
  List<Note> _pickable() {
    final pinned = widget.notes.pinnedNoteIds;
    final notes = [
      for (final note in widget.notes.notes)
        if (!note.isDrawing && widget.canEdit(note)) note,
    ];
    return [
      ...notes.where((note) => pinned.contains(note.id)),
      ...notes.where((note) => !pinned.contains(note.id)),
    ];
  }

  Widget _hintRow(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      fontSize: 11.5,
      height: 14 / 11.5,
      color: palette.textTertiary,
    );
    final link = style.copyWith(
      color: palette.textSecondary,
      fontWeight: AppWeight.font(AppWeight.regular),
      fontVariations: AppWeight.wght(AppWeight.regular),
    );
    final notes = _tab == _Tab.notes;
    final Widget? line = switch (_notice) {
      _Saved(:final noteId) => _Hint(
        children: [
          Text('Saved to Notes', style: style),
          Text('  ·  ', style: style),
          _Link(
            'Open',
            style: link,
            onTap: () =>
                unawaited(widget.inWindow((window) => window.openNote(noteId))),
          ),
        ],
      ),
      _Added(:final taskId) => _Hint(
        children: [
          Text('Added to Tasks', style: style),
          Text('  ·  ', style: style),
          _Link('Undo', style: link, onTap: () => unawaited(_undoAdd(taskId))),
        ],
      ),
      _AtLimit(:final limit) => _Hint(
        children: [
          Flexible(
            child: Text(
              limit == null
                  ? 'Your plan has no room for another note.'
                  : 'The Free plan keeps $limit notes.',
              style: style,
            ),
          ),
          const SizedBox(width: 6),
          _Link(
            'Upgrade',
            style: link,
            onTap: () => unawaited(
              widget.inWindow((window) => window.explainNoteLimit()),
            ),
          ),
        ],
      ),
      _MicrophoneRefused() => _Hint(
        children: [
          Text('Kapy Notes needs microphone access to record', style: style),
        ],
      ),
      _NoMicrophone() => _Hint(
        children: [Text('No microphone found', style: style)],
      ),
      null when _draft.text.trim().isNotEmpty && !_isRecording => _Hint(
        children: [
          const Keycap('↵'),
          const SizedBox(width: 6),
          Text(notes ? 'Save' : 'Add to Tasks', style: style),
          const SizedBox(width: 14),
          Keycap('${AppPlatform.isMacOS ? '⌘' : 'Ctrl+'}↵'),
          const SizedBox(width: 6),
          Text(notes ? 'Save and open' : 'Add and open', style: style),
        ],
      ),
      null => null,
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        line == null ? 13 : 8,
        12,
        line == null ? 0 : 10,
      ),
      child: line,
    );
  }

  Widget _tasksList(BuildContext context) {
    final palette = context.palette;
    final board = widget.tasks.read();
    final rows = _taskRows();
    final now = widget.now();
    final done = board.doneSince(DateTime(now.year, now.month, now.day));
    final shownOpen = rows.where((item) => !item.line.done).length;
    final more = board.open.length - shownOpen;
    final meta = TextStyle(
      fontSize: 12,
      height: 16 / 12,
      color: palette.textTertiary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              Text(
                'Today',
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
                  color: palette.textSecondary,
                ),
              ),
              const Spacer(),
              Text('$done of ${done + board.open.length} done', style: meta),
            ],
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Text(
              'No open tasks. Type one above and press Return.',
              style: TextStyle(color: palette.textTertiary),
            ),
          ),
        for (final (index, item) in rows.indexed)
          _TaskRow(
            key: ValueKey('menu-bar-task-${item.id}'),
            item: item,
            doNow: item.id == _doNowId,
            noteLabel: item.note.id == board.home?.id
                ? 'No note'
                : item.note.title,
            editable: widget.canEdit(item.note),
            highlighted: _cursor == index || _hovered == index,
            onHover: (hovering) =>
                setState(() => _hovered = hovering ? index : null),
            onCheck: (done) => _check(item, done: done),
            onOpen: () => _openTask(item),
          ),
        if (more > 0)
          _Row(
            key: const ValueKey('menu-bar-all-tasks'),
            highlighted: false,
            onTap: () =>
                unawaited(widget.inWindow((window) => window.openTasks())),
            child: Row(
              children: [
                Text(
                  'All tasks',
                  style: TextStyle(color: palette.textSecondary),
                ),
                Text(
                  ' · $more more',
                  style: TextStyle(color: palette.textTertiary),
                ),
                const Spacer(),
                KapyIcon(
                  KapyIcons.chevronRightRounded,
                  size: 15,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _notesList(BuildContext context) {
    final palette = context.palette;
    final rows = _noteRows();
    if (rows.isEmpty) return _empty(context);
    final pinned = widget.notes.pinnedNoteIds;
    final head = TextStyle(
      fontSize: 12,
      height: 16 / 12,
      fontWeight: AppWeight.font(AppWeight.regular),
      fontVariations: AppWeight.wght(AppWeight.regular),
      color: palette.textSecondary,
    );
    final children = <Widget>[];
    String? section;
    for (final (index, note) in rows.indexed) {
      final heading =
          pinned.contains(note.id) && index < MenuBarPanel.pinnedRows
          ? 'Pinned'
          : 'Recent';
      if (heading != section) {
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(8, section == null ? 0 : 12, 8, 6),
            child: Text(heading, style: head),
          ),
        );
        section = heading;
      }
      children.add(
        _Row(
          key: ValueKey('menu-bar-note-${note.id}'),
          highlighted: _cursor == index || _hovered == index,
          onHover: (hovering) =>
              setState(() => _hovered = hovering ? index : null),
          onTap: () =>
              unawaited(widget.inWindow((window) => window.openNote(note.id))),
          child: Row(
            children: [
              KapyIcon(
                heading == 'Pinned'
                    ? KapyIcons.pinOutlined
                    : note.isDrawing
                    ? KapyIcons.penRounded
                    : KapyIcons.noteOutlined,
                size: 15,
                color: palette.textTertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _ago(note.updatedAt),
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  color: palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _empty(BuildContext context) {
    final palette = context.palette;
    final quiet = TextStyle(color: palette.textTertiary);
    final soft = TextStyle(color: palette.textSecondary);
    final meta = AppPlatform.isMacOS;
    final summon = widget.isTaken(ShortcutAction.openMenuBarPanel)
        ? null
        : widget.shortcuts.bindingFor(ShortcutAction.openMenuBarPanel);
    Widget line(List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: children),
    );
    return Padding(
      key: const ValueKey('menu-bar-empty'),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No notes yet',
            style: TextStyle(
              fontSize: 14,
              fontWeight: AppWeight.font(AppWeight.regular),
              fontVariations: AppWeight.wght(AppWeight.regular),
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text('Write one above and press Return.', style: soft),
          line([
            Text('Tasks are one key away:', style: soft),
            const SizedBox(width: 6),
            Keycap(meta ? '⌘2' : 'Ctrl+2'),
          ]),
          if (summon != null) ...[
            const SizedBox(height: 14),
            line([
              Text('Open this from anywhere with', style: quiet),
              const SizedBox(width: 6),
              Keycap(summon.keycapLabel),
            ]),
            line([Text('Change it in Settings → Shortcuts.', style: quiet)]),
          ],
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final palette = context.palette;
    final open = widget.isTaken(ShortcutAction.openApp)
        ? null
        : widget.shortcuts.bindingFor(ShortcutAction.openApp);
    final find = widget.shortcuts.bindingFor(ShortcutAction.findNotes);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        children: [
          InkWell(
            key: const ValueKey('menu-bar-open-app'),
            borderRadius: BorderRadius.circular(7),
            onTap: () => unawaited(widget.inWindow((_) {})),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  Image.asset(
                    AppTray.templateIcon,
                    width: 18,
                    height: 18,
                    color: const Color(0xFFE8772E),
                    excludeFromSemantics: true,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Open Kapy Notes',
                    style: TextStyle(color: palette.textSecondary),
                  ),
                  if (open != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      open.keycapLabel,
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                        fontSize: 11,
                        height: 14 / 11,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Spacer(),
          _IconButton(
            key: const ValueKey('menu-bar-search'),
            icon: KapyIcons.searchRounded,
            tooltip: find == null
                ? 'Find notes'
                : 'Find notes ${find.keycapLabel}',
            onPressed: () =>
                unawaited(widget.inWindow((window) => window.find())),
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.tab, required this.onTab});

  final _Tab tab;
  final ValueChanged<_Tab> onTab;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final light = Theme.of(context).brightness == Brightness.light;
    final meta = AppPlatform.isMacOS;
    Widget segment(_Tab value, String label, String keys) {
      final selected = value == tab;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            key: ValueKey('menu-bar-tab-${value.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onTab(value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 28,
              decoration: BoxDecoration(
                color: selected ? palette.segmentSelected : null,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  if (selected && light)
                    BoxShadow(
                      color: palette.shadow,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      height: 16 / 13,
                      fontWeight: AppWeight.font(
                        selected ? AppWeight.regular : AppWeight.regular,
                      ),
                      fontVariations: AppWeight.wght(
                        selected ? AppWeight.regular : AppWeight.regular,
                      ),
                      color: selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 7),
                  ExcludeSemantics(
                    child: Text(
                      meta ? '⌘$keys' : 'Ctrl+$keys',
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                        fontSize: 11,
                        height: 14 / 11,
                        color: palette.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.wellBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          segment(_Tab.notes, 'Notes', '1'),
          segment(_Tab.tasks, 'Tasks', '2'),
        ],
      ),
    );
  }
}

/// A list row: 32 points high, the hover colour behind it when highlighted.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.highlighted,
    required this.onTap,
    required this.child,
    this.onHover,
    this.height = 32,
  });

  final bool highlighted;
  final VoidCallback onTap;
  final ValueChanged<bool>? onHover;
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => onHover?.call(true),
    onExit: (_) => onHover?.call(false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: highlighted ? context.palette.hover : null,
          borderRadius: BorderRadius.circular(7),
        ),
        child: child,
      ),
    ),
  );
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.item,
    required this.doNow,
    required this.noteLabel,
    required this.editable,
    required this.highlighted,
    required this.onHover,
    required this.onCheck,
    required this.onOpen,
  });

  final TaskItem item;
  final bool doNow;
  final String noteLabel;
  final bool editable;
  final bool highlighted;
  final ValueChanged<bool> onHover;
  final ValueChanged<bool> onCheck;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sage = Theme.of(context).colorScheme.primary;
    final done = item.line.done;
    final check = Semantics(
      checked: done,
      enabled: editable,
      label: item.words,
      child: GestureDetector(
        key: ValueKey('menu-bar-check-${item.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: editable ? () => onCheck(!done) : null,
        child: Opacity(
          opacity: editable ? 1 : 0.4,
          child: Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: done ? palette.accentFill : null,
              shape: BoxShape.circle,
              border: done
                  ? null
                  : Border.all(color: palette.checkboxBorder, width: 1.5),
            ),
            child: done
                ? const KapyIcon(
                    KapyIcons.checkRounded,
                    size: 11,
                    color: Colors.white,
                  )
                : null,
          ),
        ),
      ),
    );
    final row = _Row(
      highlighted: highlighted,
      onHover: onHover,
      onTap: onOpen,
      child: Row(
        children: [
          if (editable)
            check
          else
            Tooltip(message: "This note can't be changed here", child: check),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              item.words,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: done
                  ? TextStyle(
                      color: palette.textTertiary,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: palette.textTertiary,
                    )
                  : null,
            ),
          ),
          TaskDetailsIcon(item: item),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              noteLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 16 / 12,
                color: palette.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
    if (!doNow) return row;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(
                  'Do now',
                  style: TextStyle(
                    fontSize: 12,
                    height: 15 / 12,
                    fontWeight: AppWeight.font(AppWeight.regular),
                    fontVariations: AppWeight.wght(AppWeight.regular),
                    color: palette.textSecondary,
                  ),
                ),
              ),
              row,
            ],
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 2,
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: sage,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotePicker extends StatefulWidget {
  const _NotePicker({
    required this.notes,
    required this.chosen,
    required this.onPick,
  });

  final List<Note> notes;
  final String? chosen;
  final ValueChanged<String?> onPick;

  @override
  State<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends State<_NotePicker> {
  final TextEditingController _find = TextEditingController();

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final query = _find.text.trim().toLowerCase();
    final matches = [
      for (final note in widget.notes)
        if (query.isEmpty || note.title.toLowerCase().contains(query)) note,
    ].take(7).toList();
    Widget option(String? id, String label) => _Row(
      key: ValueKey('menu-bar-pick-${id ?? 'none'}'),
      height: 28,
      highlighted: id == widget.chosen,
      onTap: () => widget.onPick(id),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return Container(
      width: 240,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: TextField(
              key: const ValueKey('menu-bar-pick-find'),
              controller: _find,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => widget.onPick(matches.firstOrNull?.id),
              style: TextStyle(
                fontFamily: AppFonts.ui,
                fontSize: 13,
                color: palette.textPrimary,
              ),
              decoration: InputDecoration.collapsed(
                hintText: 'Find a note',
                hintStyle: TextStyle(
                  fontFamily: AppFonts.ui,
                  fontSize: 13,
                  color: palette.textTertiary,
                ),
              ),
            ),
          ),
          if (query.isEmpty) option(null, 'No note'),
          for (final note in matches) option(note.id, note.title),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 22, child: Row(children: children));
}

class _Link extends StatelessWidget {
  const _Link(this.label, {required this.style, required this.onTap});

  final String label;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      key: ValueKey('menu-bar-link-$label'),
      onTap: onTap,
      child: Text(label, style: style),
    ),
  );
}

class _TextButton extends StatelessWidget {
  const _TextButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onPressed,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: AppWeight.font(AppWeight.regular),
          fontVariations: AppWeight.wght(AppWeight.regular),
          color: context.palette.textPrimary,
        ),
      ),
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: KapyIcon(icon, size: 18, color: context.palette.textSecondary),
      ),
    ),
  );
}

/// Tells [onHeight] how tall the panel's content is, at layout, so that the
/// native panel can be sized to it before it is shown.
class _ReportHeight extends SingleChildRenderObjectWidget {
  const _ReportHeight({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReportHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderReportHeight extends RenderProxyBox {
  _RenderReportHeight(this.onHeight);

  ValueChanged<double> onHeight;

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
