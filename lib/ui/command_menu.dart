import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/phone_keyboard.dart';
import '../core/platform.dart';
import '../core/popup_keyboard.dart';
import '../core/theme.dart';
import '../data/folders.dart' show Folder, FolderTree;
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/shortcut_prefs.dart';
import '../data/tags.dart';
import '../data/task_board.dart';
import 'compact_icon_button.dart';
import 'keycap.dart';
import 'notes_list.dart' show NotesShow;
import 'settings_dialog.dart' show SettingsIndex, SettingsSection;
import 'settings_search.dart';
import 'sidebar.dart' show archiveIcon, hiddenIcon;
import 'sidebar_timestamp.dart';
import 'spaces_rail.dart';
import 'tag_colours.dart';
import 'tag_ui.dart';
import 'tasks/task_marks.dart';

/// What a row of the ⌘K menu asks for. [showCommandMenu] returns it and the
/// home page carries it out.
sealed class CommandChoice {
  const CommandChoice();
}

/// Open a note or a drawing where it lives.
class OpenNoteChoice extends CommandChoice {
  const OpenNoteChoice(this.note);
  final Note note;
}

/// Show a folder in the tab in front.
class OpenFolderChoice extends CommandChoice {
  const OpenFolderChoice(this.folderId);
  final String folderId;
}

/// File [note] where the folder list, opened in the menu's place, picks.
class MoveToFolderChoice extends CommandChoice {
  const MoveToFolderChoice(this.note);
  final Note note;
}

/// How far down the window the ⌘K menu sits, and a list that follows it,
/// such as Move to folder…'s.
double commandMenuTop(Size window) => (window.height * 0.1).clamp(16.0, 88.0);

/// Show a task in Tasks, among its note's.
class OpenTaskChoice extends CommandChoice {
  const OpenTaskChoice(this.task);
  final TaskItem task;
}

/// Start a note, holding [text] when it came from the field.
class NewNoteChoice extends CommandChoice {
  const NewNoteChoice([this.text = '']);
  final String text;
}

/// Add a task: [text] straight onto the list, or else an empty add row.
class NewTaskChoice extends CommandChoice {
  const NewTaskChoice([this.text = '']);
  final String text;
}

class NewDrawingChoice extends CommandChoice {
  const NewDrawingChoice();
}

class GoToChoice extends CommandChoice {
  const GoToChoice(this.space);
  final LibrarySpace space;
}

/// My notes with the filter on Hidden or Archive.
class ShowNotesChoice extends CommandChoice {
  const ShowNotesChoice(this.show);
  final NotesShow show;
}

/// Narrow the Notes filter to a tag, as ticking it does.
class FilterTagChoice extends CommandChoice {
  const FilterTagChoice(this.tagId);
  final String tagId;
}

class OpenSettingsChoice extends CommandChoice {
  const OpenSettingsChoice();
}

/// Makes the widget that hands [CommandMenu] the settings search index.
typedef SettingsHost = Widget Function(ValueChanged<SettingsIndex> lend);

/// Open Settings on a setting a search found.
class RevealSettingChoice extends CommandChoice {
  const RevealSettingChoice(this.section, this.reveal);

  final SettingsSection section;

  /// The row to scroll to and light, or null for a whole category.
  final String? reveal;
}

/// Open Archive with the search kept.
class SearchArchiveChoice extends CommandChoice {
  const SearchArchiveChoice(this.query);
  final String query;
}

/// Ask Kapy AI [text] as a new chat's first question.
class AskKapyAiChoice extends CommandChoice {
  const AskKapyAiChoice(this.text);
  final String text;
}

/// Opens the ⌘K menu over the window: search, create and go to.
///
/// [space] is where it was opened from, which decides what New note's key
/// says: in Tasks and Drawings that key makes a task or a drawing instead.
/// [destinations] are the sections Go to lists, in order, before Hidden,
/// listed only with [showHidden], and Archive. Hidden notes are searched
/// only while [hiddenUnlocked], and [tasks] is null where there is no task
/// list to search or add to. [folders] are found by name where a folder can
/// open, and are null elsewhere. With [tags], # lists the tags to filter by, and
/// [tagNote], the open note, can be tagged from the menu. A result shows the
/// dot of the first of [marksOf]'s tags for its note: the dialog is a route
/// of its own, so the page's own marks don't reach it. [askKapyAi] is whether
/// Kapy AI is there to be asked: it adds the Ask row and Tab, and "Ask Kapy
/// AI" to the field, while the menu searches everything. With [drawings] it
/// opens on the Drawings scope, as Drawings' own search field does.
Future<CommandChoice?> showCommandMenu(
  BuildContext context, {
  required NotesStore notes,
  required ShortcutPrefs shortcuts,
  required LibrarySpace space,
  required List<LibrarySpace> destinations,
  required List<String> recentIds,
  required DateTime Function(DateTime) displayTime,
  required String Function(Note) taskLabel,
  TaskBoard? tasks,
  FolderTree? folders,
  bool showHidden = false,
  bool hiddenUnlocked = false,
  bool askKapyAi = false,
  SettingsHost? settingsIndex,
  TagShelf? tags,
  Note? tagNote,
  Note? fileNote,
  List<TagMark> Function(String noteId)? marksOf,
  bool phone = false,
  bool drawings = false,
  TextEditingController? field,
  Future<void> Function(TaskItem item, {required bool done})? onSetTaskDone,
}) {
  final palette = context.palette;
  Widget build(BuildContext context) {
    final menu = CommandMenu(
      notes: notes,
      shortcuts: shortcuts,
      space: space,
      destinations: destinations,
      recentIds: recentIds,
      displayTime: displayTime,
      taskLabel: taskLabel,
      tasks: tasks,
      folders: folders,
      showHidden: showHidden,
      hiddenUnlocked: hiddenUnlocked,
      askKapyAi: askKapyAi,
      settingsIndex: settingsIndex,
      tags: tags,
      tagNote: tagNote,
      fileNote: fileNote,
      phone: phone,
      drawings: drawings,
      field: field,
      onSetTaskDone: onSetTaskDone,
      onChosen: (choice) => Navigator.of(context).pop(choice),
    );
    return marksOf == null ? menu : TagMarks(marksOf: marksOf, child: menu);
  }

  if (phone && AppPlatform.isAndroid) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<CommandChoice>(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          backgroundColor: palette.paperColor,
          body: SafeArea(child: build(context)),
        ),
      ),
    );
  }
  if (phone) {
    return showModalBottomSheet<CommandChoice>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      routeSettings: const TypingPopupSettings(),
      backgroundColor: palette.paperColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (context) =>
          FractionallySizedBox(heightFactor: 1, child: build(context)),
    );
  }
  return showDialog<CommandChoice>(
    context: context,
    barrierColor: context.palette.scrim,
    routeSettings: const TypingPopupSettings(),
    builder: build,
  );
}

class CommandMenu extends StatefulWidget {
  const CommandMenu({
    super.key,
    required this.notes,
    required this.shortcuts,
    required this.space,
    required this.destinations,
    required this.recentIds,
    required this.displayTime,
    required this.taskLabel,
    required this.onChosen,
    this.tasks,
    this.folders,
    this.showHidden = false,
    this.hiddenUnlocked = false,
    this.askKapyAi = false,
    this.settingsIndex,
    this.tags,
    this.tagNote,
    this.fileNote,
    this.phone = false,
    this.drawings = false,
    this.field,
    this.onSetTaskDone,
  });

  /// A phone's Quick find: full height, with Cancel (or Android's back
  /// arrow), scope pills, and tasks that check off in place.
  final bool phone;

  /// Opens on the Drawings scope rather than All.
  final bool drawings;

  /// The field's words, kept by the caller so Quick find can open again
  /// with them, as a phone's does on the way back from a note it opened.
  final TextEditingController? field;

  /// Checks a task off, or back on, without leaving Quick find.
  final Future<void> Function(TaskItem item, {required bool done})?
  onSetTaskDone;

  final NotesStore notes;
  final ShortcutPrefs shortcuts;
  final LibrarySpace space;
  final List<LibrarySpace> destinations;
  final List<String> recentIds;
  final DateTime Function(DateTime) displayTime;
  final String Function(Note) taskLabel;
  final ValueChanged<CommandChoice> onChosen;
  final TaskBoard? tasks;

  /// The person's folders, which typing finds by name. Null where a folder
  /// can't open.
  final FolderTree? folders;
  final bool showHidden;
  final bool hiddenUnlocked;
  final bool askKapyAi;

  /// Builds the invisible settings that lend their search index, so Settings
  /// results come from the same index as settings search. Null leaves them
  /// out.
  final SettingsHost? settingsIndex;

  /// The person's tags, null where there are none to offer.
  final TagShelf? tags;

  /// The note Tag note... tags: the one open, or null for none.
  final Note? tagNote;

  /// The note Move to folder… files: the one open, where folders can hold
  /// it, or null.
  final Note? fileNote;

  /// How many of each kind the menu shows.
  static const int perKind = 3;

  @override
  State<CommandMenu> createState() => _CommandMenuState();
}

/// One line of the menu: a section's heading, or a row that does something.
class _Line {
  const _Line.heading(String this.heading)
    : icon = null,
      leading = null,
      title = '',
      choice = null,
      action = null,
      detail = null,
      task = null,
      item = null,
      trailing = null,
      keycap = null,
      noteId = null,
      muted = false;

  const _Line.row({
    this.icon,
    this.leading,
    required this.title,
    this.choice,
    this.action,
    this.detail,
    this.task,
    this.item,
    this.trailing,
    this.keycap,
    this.noteId,
    this.muted = false,
  }) : heading = null;

  final String? heading;
  final KapyIconData? icon;

  /// What stands before the title in place of [icon], as a tag's dot does.
  final Widget? leading;
  final String title;
  final CommandChoice? choice;

  /// What a row does that stays in the menu instead of choosing.
  final VoidCallback? action;

  /// The line under a note's title that explains why it matched.
  final String? detail;

  /// The note a task is in, named after the task's words.
  final Note? task;

  /// The task a phone row checks off in place.
  final TaskItem? item;
  final String? trailing;
  final String? keycap;

  /// The note a result opens, whose first tag's dot sits before its date.
  final String? noteId;

  /// In the quieter ink, as the row pointing into Archive is.
  final bool muted;
}

class _CommandMenuState extends State<CommandMenu> {
  late final TextEditingController _field =
      widget.field ?? TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};
  late List<_Line> _lines = _build(_field.text);
  late int _highlight = _rows.firstOrNull ?? 0;

  SettingsIndex? _settings;

  /// What the results are narrowed to: a phone's pills change it.
  late _Scope _scope = widget.drawings ? _Scope.drawings : _Scope.all;

  /// Tasks checked off here, which keep their rows until Quick find closes.
  final Set<String> _done = {};

  bool _shows(_Scope scope) => _scope == _Scope.all || _scope == scope;

  /// Kapy AI is offered only while the menu searches everything.
  bool get _asks => widget.askKapyAi && _scope == _Scope.all;

  /// The tag list for the open note, once Tag note... is chosen: it takes
  /// the place of the menu's results and of its field.
  TagPickerController? _picker;

  @override
  void dispose() {
    _picker?.dispose();
    if (widget.field == null) _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<int> get _rows => [
    for (var index = 0; index < _lines.length; index++)
      if (_lines[index].heading == null) index,
  ];

  String? _keycap(ShortcutAction action) =>
      widget.shortcuts.hintFor(action)?.keycapLabel;

  /// New note's key makes whatever the section on screen makes, so the row
  /// shows it only where that is a note.
  String? get _newNoteKey =>
      widget.space == LibrarySpace.tasks ||
          widget.space == LibrarySpace.drawings
      ? null
      : _keycap(ShortcutAction.newNote);

  String _date(Note note) => SidebarTimestamp.glance(
    note.updatedAt,
    now: widget.notes.now(),
    displayTime: widget.displayTime,
    today: true,
  ).replaceFirst(' · ', ', ');

  _Line _noteRow(Note note, {String? detail}) => _Line.row(
    icon: note.isHidden
        ? KapyIcons.lockRounded
        : note.isDrawing
        ? KapyIcons.penRounded
        : KapyIcons.noteOutlined,
    title: note.title,
    detail: detail,
    trailing: _date(note),
    noteId: note.id,
    choice: OpenNoteChoice(note),
  );

  _Line _taskRow(TaskItem task) => _Line.row(
    icon: KapyIcons.tasksOutlined,
    title: task.words,
    task: task.note,
    item: widget.phone && widget.onSetTaskDone != null ? task : null,
    choice: OpenTaskChoice(task),
  );

  /// A setting as settings search shows it: its category and heading under
  /// the name, and what it is set to at the end, as a key for a shortcut.
  _Line _settingRow(SettingsSearchEntry<SettingsSection> entry) {
    final heading = entry.group;
    final target = entry.target;
    final action = target != null && target.startsWith('shortcut-row-')
        ? ShortcutAction.values.asNameMap()[target.substring(13)]
        : null;
    return _Line.row(
      icon: entry.icon,
      title: entry.title,
      detail: entry.target == null
          ? entry.description
          : heading == null ||
                heading.toLowerCase() == entry.title.toLowerCase()
          ? entry.sectionLabel
          : '${entry.sectionLabel} › $heading',
      trailing: action == null ? entry.value : null,
      keycap: action == null ? null : _keycap(action),
      choice: RevealSettingChoice(entry.section, entry.target),
    );
  }

  List<_Line> _build(String query) {
    final text = query.trim();
    return text.isEmpty ? _beforeTyping() : _whileTyping(text);
  }

  List<_Line> _beforeTyping() {
    final notes = widget.notes;
    final recent = [
      for (final id in widget.recentIds)
        if (notes.byId(id) case final note?
            when !note.isArchived &&
                !note.isTrashed &&
                (!note.isHidden || widget.hiddenUnlocked) &&
                switch (_scope) {
                  _Scope.all => true,
                  _Scope.notes => !note.isDrawing,
                  _Scope.drawings => note.isDrawing,
                  _Scope.tasks => false,
                })
          note,
    ].take(CommandMenu.perKind);
    if (_scope == _Scope.tasks) {
      return [
        const _Line.heading('Tasks'),
        for (final task in (widget.tasks?.open ?? const <TaskItem>[]).take(
          CommandMenu.perKind * 2,
        ))
          _taskRow(task),
      ];
    }
    if (_scope != _Scope.all) {
      return [
        if (recent.isNotEmpty) ...[
          const _Line.heading('Recent'),
          for (final note in recent) _noteRow(note),
        ],
      ];
    }
    return [
      if (recent.isNotEmpty) ...[
        const _Line.heading('Recent'),
        for (final note in recent) _noteRow(note),
      ],
      const _Line.heading('Create'),
      _Line.row(
        icon: KapyIcons.noteOutlined,
        title: 'New note',
        keycap: _newNoteKey,
        choice: const NewNoteChoice(),
      ),
      if (widget.tasks != null)
        _Line.row(
          icon: KapyIcons.tasksOutlined,
          title: 'New task',
          keycap: _keycap(ShortcutAction.newTask),
          choice: const NewTaskChoice(),
        ),
      _Line.row(
        icon: KapyIcons.penRounded,
        title: 'New drawing',
        keycap: _keycap(ShortcutAction.newDrawing),
        choice: const NewDrawingChoice(),
      ),
      const _Line.heading('Go to'),
      for (final space in widget.destinations)
        _Line.row(
          icon: switch (space) {
            LibrarySpace.notes => KapyIcons.noteOutlined,
            LibrarySpace.tasks => KapyIcons.tasksOutlined,
            LibrarySpace.drawings => KapyIcons.penRounded,
            LibrarySpace.shared => KapyIcons.groupOutlined,
          },
          title: space == LibrarySpace.notes ? 'Notes' : space.title,
          keycap: switch (space) {
            LibrarySpace.notes => _keycap(ShortcutAction.showNotes),
            LibrarySpace.tasks => _keycap(ShortcutAction.showTasks),
            LibrarySpace.drawings => _keycap(ShortcutAction.showDrawings),
            LibrarySpace.shared => _keycap(ShortcutAction.showShared),
          },
          choice: GoToChoice(space),
        ),
      if (widget.showHidden)
        const _Line.row(
          icon: hiddenIcon,
          title: 'Hidden',
          choice: ShowNotesChoice(NotesShow.hidden),
        ),
      _Line.row(
        icon: archiveIcon,
        title: 'Archive',
        keycap: _keycap(ShortcutAction.showArchive),
        choice: const ShowNotesChoice(NotesShow.archive),
      ),
      _Line.row(
        icon: KapyIcons.settingsGearOutlined,
        title: 'Settings',
        keycap: _keycap(ShortcutAction.openSettings),
        choice: const OpenSettingsChoice(),
      ),
    ];
  }

  /// The notes list's search as it always matched: every word, in any order,
  /// quoted phrases kept together, across My notes and Shared, and Hidden
  /// while it is unlocked. Up to [CommandMenu.perKind] of each kind, then what
  /// the words can become, then how many more Archive holds.
  List<_Line> _whileTyping(String text) {
    final tags = widget.tags;
    if (tags != null && text.startsWith('#')) return _tagLines(tags, text);
    final notes = widget.notes;
    final found = [
      ...notes.search(text),
      if (widget.hiddenUnlocked) ...notes.searchHidden(text),
    ];
    final written = found.where((note) => !note.isDrawing);
    final drawings = found.where((note) => note.isDrawing);
    final terms = noteSearchTerms(text);
    final tasks = [
      for (final task in widget.tasks?.open ?? const <TaskItem>[])
        if (terms.every(task.words.toLowerCase().contains)) task,
    ].take(CommandMenu.perKind);
    final tree = widget.folders;
    final folders = [
      for (final folder in tree?.folders ?? const <Folder>[])
        if (terms.every(folder.name.toLowerCase().contains)) folder,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final archived = notes.searchArchived(text).length;
    final settings = [
      for (final entry in searchSettings<SettingsSection>(
        _settings?.call() ?? const [],
        text,
      ))
        if (entry.elsewhere == null) entry,
    ].take(CommandMenu.perKind);
    final lowered = text.toLowerCase();
    final tagNote = widget.tagNote;
    final fileNote = widget.fileNote;
    final named = lowered.length >= 2;
    final actions = [
      if (tags != null &&
          tagNote != null &&
          named &&
          'tag note'.startsWith(lowered))
        _Line.row(
          icon: KapyIcons.tagRounded,
          title: 'Tag note…',
          trailing: tagNote.title,
          action: () => setState(
            () => _picker = TagPickerController(
              shelf: tags,
              noteIds: [tagNote.id],
            ),
          ),
        ),
      if (fileNote != null && named && 'move to folder'.startsWith(lowered))
        _Line.row(
          icon: KapyIcons.folderMoveOutlined,
          title: 'Move to folder…',
          trailing: fileNote.title,
          choice: MoveToFolderChoice(fileNote),
        ),
    ];
    final settingsFirst =
        settings.isNotEmpty &&
        settings.first.title.toLowerCase().contains(lowered);
    final settingsLines = [
      if (settings.isNotEmpty) ...[
        const _Line.heading('Settings'),
        for (final entry in settings) _settingRow(entry),
      ],
    ];
    final all = _scope == _Scope.all;
    final make = widget.phone;
    return [
      if (all && actions.isNotEmpty) ...[
        const _Line.heading('Actions'),
        ...actions,
      ],
      if (all && settingsFirst) ...settingsLines,
      if (_shows(_Scope.notes) && written.isNotEmpty) ...[
        const _Line.heading('Notes'),
        for (final note in written.take(CommandMenu.perKind))
          _noteRow(note, detail: note.matchSnippet(text)),
      ],
      if (all && tree != null && folders.isNotEmpty) ...[
        const _Line.heading('Folders'),
        for (final folder in folders.take(CommandMenu.perKind))
          _Line.row(
            icon: KapyIcons.folderOutlined,
            title: folder.name,
            trailing: switch (tree.pathOf(folder.id)) {
              [...final above, _] when above.isNotEmpty => [
                for (final place in above) place.name,
              ].join(' › '),
              _ => null,
            },
            choice: OpenFolderChoice(folder.id),
          ),
      ],
      if (_shows(_Scope.tasks) && tasks.isNotEmpty) ...[
        const _Line.heading('Tasks'),
        for (final task in tasks) _taskRow(task),
      ],
      if (_shows(_Scope.drawings) && drawings.isNotEmpty) ...[
        const _Line.heading('Drawings'),
        for (final note in drawings.take(CommandMenu.perKind)) _noteRow(note),
      ],
      if (all && !settingsFirst) ...settingsLines,
      _Line.heading(make ? 'Make' : 'Use “$text”'),
      if (widget.tasks != null && (make ? _scope == _Scope.tasks : true))
        _Line.row(
          icon: KapyIcons.tasksOutlined,
          title: make ? 'New task “$text”' : 'New task: $text',
          keycap: _keycap(ShortcutAction.newTask),
          choice: NewTaskChoice(text),
        ),
      if (!make || _shows(_Scope.notes))
        _Line.row(
          icon: KapyIcons.noteOutlined,
          title: make ? 'New note “$text”' : 'New note: $text',
          keycap: _newNoteKey,
          choice: NewNoteChoice(text),
        ),
      if (make && _scope == _Scope.drawings)
        const _Line.row(
          icon: KapyIcons.penRounded,
          title: 'New drawing',
          choice: NewDrawingChoice(),
        ),
      if (_asks)
        _Line.row(
          icon: KapyIcons.sparklesOutlined,
          title: 'Ask Kapy AI: $text',
          keycap: 'tab',
          choice: AskKapyAiChoice(text),
        ),
      if (_shows(_Scope.notes) && archived > 0)
        _Line.row(
          icon: archiveIcon,
          title: '$archived more in Archive',
          muted: true,
          choice: SearchArchiveChoice(text),
        ),
    ];
  }

  /// What # lists: the tags, in the person's order with their counts, whose
  /// names hold the letters after it.
  List<_Line> _tagLines(TagShelf tags, String text) {
    final name = text.substring(1).trim();
    final matches = [
      for (final entry in tags.listed())
        if (entry.tag.name.v.toLowerCase().contains(name.toLowerCase())) entry,
    ];
    if (matches.isEmpty) {
      return [
        _Line.heading(name.isEmpty ? 'No tags yet' : 'No tag named “$name”'),
      ];
    }
    return [
      const _Line.heading('Filter by tag'),
      for (final entry in matches)
        _Line.row(
          leading: TagDot(tagColourOf(entry.tag.colour.v)),
          title: entry.tag.name.v,
          trailing: '${entry.count}',
          choice: FilterTagChoice(entry.tag.id),
        ),
    ];
  }

  void _search(String query) {
    setState(() {
      _lines = _build(query);
      _rowKeys.clear();
      _highlight = _rows.firstOrNull ?? 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int by) {
    final rows = _rows;
    if (rows.isEmpty) return;
    final next =
        rows[(rows.indexOf(_highlight) + by).clamp(0, rows.length - 1)];
    setState(() => _highlight = next);
    final row = _rowKeys[next]?.currentContext;
    if (row == null) return;
    Scrollable.ensureVisible(
      row,
      alignmentPolicy: by > 0
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  /// Whether there is a question to ask: Tab asks it from wherever the
  /// highlight is. Not while # lists the tags, or while tagging a note.
  bool get _asking {
    final text = _field.text.trim();
    return _picker == null &&
        text.isNotEmpty &&
        !(widget.tags != null && text.startsWith('#'));
  }

  void _choose(int index) {
    final line = _lines.elementAtOrNull(index);
    if (line?.action case final action?) return action();
    if (line?.choice case final choice?) widget.onChosen(choice);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final picker = _picker;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        picker == null ? _move(1) : picker.move(1);
      case LogicalKeyboardKey.arrowUp:
        picker == null ? _move(-1) : picker.move(-1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter
          when event is KeyDownEvent:
        picker == null ? _choose(_highlight) : picker.activate();
      case LogicalKeyboardKey.tab
          when _asks && _asking && event is KeyDownEvent:
        widget.onChosen(AskKapyAiChoice(_field.text.trim()));
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = palette.brightness == Brightness.dark;
    final top = commandMenuTop(MediaQuery.sizeOf(context));
    final terms = noteSearchTerms(_field.text);
    if (widget.phone) {
      final picker = _picker;
      final page = Material(
        key: const ValueKey('command-menu'),
        color: palette.paperColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _phoneField(palette),
            if (picker == null) _scopePills(palette),
            Expanded(
              child: picker != null
                  ? Column(children: [_tagList(picker, palette, dark)])
                  : ListView(
                      controller: _scroll,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                      children: [
                        for (var index = 0; index < _lines.length; index++)
                          _line(index, terms, palette, dark),
                      ],
                    ),
            ),
          ],
        ),
      );
      final host = widget.settingsIndex;
      if (host == null) return page;
      return Stack(children: [page, host((index) => _settings = index)]);
    }
    final menu = Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, top, 16, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            key: const ValueKey('command-menu'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: dark
                  ? palette.controlBackground
                  : palette.surfaceBackground,
              border: Border.all(color: palette.separator),
              borderRadius: BorderRadius.circular(AppRadii.surface),
              boxShadow: [
                BoxShadow(
                  color: palette.shadow.withValues(alpha: dark ? 0.5 : 0.2),
                  offset: const Offset(0, 24),
                  blurRadius: 64,
                ),
                BoxShadow(
                  color: palette.shadow.withValues(alpha: dark ? 0.3 : 0.12),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _searchField(palette),
                  if (_picker case final picker?)
                    _tagList(picker, palette, dark)
                  else
                    Flexible(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var index = 0; index < _lines.length; index++)
                              _line(index, terms, palette, dark),
                          ],
                        ),
                      ),
                    ),
                  if (AppPlatform.hasPointer && _picker == null)
                    _footer(palette, ask: _asks && _asking),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final host = widget.settingsIndex;
    if (host == null) return menu;
    return Stack(children: [menu, host((index) => _settings = index)]);
  }

  /// A phone's field: a well with the sage ring of focus, then Cancel, or
  /// Android's back arrow before it.
  Widget _phoneField(CalcPalette palette) {
    final picker = _picker;
    final sage = Theme.of(context).colorScheme.primary;
    final android = AppPlatform.isAndroid;
    final style = TextStyle(
      fontSize: 16,
      height: 20 / 16,
      color: palette.textPrimary,
    );
    void close() => unawaited(Navigator.of(context).maybePop());
    return Padding(
      padding: EdgeInsets.fromLTRB(android ? 4 : 16, 12, android ? 16 : 4, 4),
      child: Row(
        children: [
          if (android)
            CompactIconButton(
              key: const ValueKey('command-menu-back'),
              tooltip: 'Back',
              extent: AppControlMetrics.iconButtonExtent,
              foregroundColor: palette.textPrimary,
              onPressed: close,
              icon: const KapyIcon(KapyIcons.arrowBackRounded, size: 22),
            ),
          Expanded(
            child: KeepsKeyboard(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: palette.wellBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sage, width: 1.5),
                ),
                child: Row(
                  spacing: 8,
                  children: [
                    KapyIcon(
                      KapyIcons.searchRounded,
                      size: 16,
                      color: palette.textSecondary,
                    ),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('command-menu-field'),
                        controller: picker?.query ?? _field,
                        autofocus: true,
                        inputFormatters: picker == null
                            ? null
                            : [LengthLimitingTextInputFormatter(tagNameMax)],
                        onChanged: picker == null
                            ? _search
                            : (_) => picker.typed(),
                        onSubmitted: (_) => picker == null
                            ? _choose(_highlight)
                            : picker.activate(),
                        textInputAction: TextInputAction.go,
                        style: style,
                        cursorHeight: 20,
                        decoration: InputDecoration.collapsed(
                          hintText: picker != null
                              ? ''
                              : _scope == _Scope.drawings
                              ? 'Search drawings'
                              : widget.tasks == null
                              ? 'Search notes'
                              : 'Search notes and tasks',
                          hintStyle: style.copyWith(
                            color: palette.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!android)
            TextButton(
              key: const ValueKey('command-menu-cancel'),
              onPressed: close,
              child: Text(
                'Cancel',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
                  color: palette.accentText,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// All, Notes, Tasks, Drawings: what a phone's results are narrowed to.
  Widget _scopePills(CalcPalette palette) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      spacing: 8,
      children: [
        for (final scope in _Scope.values)
          if (scope != _Scope.tasks || widget.tasks != null)
            KeepsKeyboard(
              child: Semantics(
                button: true,
                selected: scope == _scope,
                label: scope.label,
                excludeSemantics: true,
                onTap: () => _setScope(scope),
                child: GestureDetector(
                  key: ValueKey('command-scope-${scope.name}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setScope(scope),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: AppControlMetrics.iconButtonExtent,
                    ),
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 30),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scope == _scope ? palette.textPrimary : null,
                          border: scope == _scope
                              ? null
                              : Border.all(color: palette.controlBorder),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          scope.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: AppWeight.font(AppWeight.regular),
                            fontVariations: AppWeight.wght(AppWeight.regular),
                            color: scope == _scope
                                ? palette.paperColor
                                : palette.textPrimary,
                          ),
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

  void _setScope(_Scope scope) {
    if (scope == _scope) return;
    _scope = scope;
    _search(_field.text);
  }

  /// Checks a task off in place, or back on; its row stays until Quick find
  /// closes, so a mistaken tap can be undone where it was made.
  void _tick(TaskItem item) {
    final done = !_done.contains(item.id);
    setState(() => done ? _done.add(item.id) : _done.remove(item.id));
    unawaited(widget.onSetTaskDone!(item, done: done));
  }

  Widget _searchField(CalcPalette palette) {
    final picker = _picker;
    final style = TextStyle(
      fontSize: 16,
      height: 20 / 16,
      color: palette.textPrimary,
    );
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.separator)),
      ),
      child: Row(
        spacing: 12,
        children: [
          KapyIcon(
            KapyIcons.searchRounded,
            size: AppControlMetrics.iconSearch,
            color: palette.textSecondary,
          ),
          if (picker != null)
            Container(
              key: const ValueKey('command-menu-tagging'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.separator,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              child: Text(
                'Tag note · ${widget.tagNote!.title}',
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: AppWeight.font(AppWeight.regular),
                  fontVariations: AppWeight.wght(AppWeight.regular),
                  color: palette.textPrimary,
                ),
              ),
            ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              skipTraversal: true,
              canRequestFocus: false,
              child: TextField(
                key: const ValueKey('command-menu-field'),
                controller: picker?.query ?? _field,
                autofocus: true,
                inputFormatters: picker == null
                    ? null
                    : [LengthLimitingTextInputFormatter(tagNameMax)],
                onChanged: picker == null ? _search : (_) => picker.typed(),
                textInputAction: TextInputAction.go,
                style: style,
                cursorHeight: 20,
                decoration: AppPlatform.hasPointer
                    ? InputDecoration.collapsed(
                        hintText: picker != null
                            ? ''
                            : _scope == _Scope.drawings
                            ? 'Search drawings…'
                            : _asks
                            ? 'Search or Ask Kapy AI…'
                            : 'Search…',
                        hintStyle: style.copyWith(color: palette.textTertiary),
                      )
                    : InputDecoration(
                        border: InputBorder.none,
                        hintText: picker != null
                            ? ''
                            : _scope == _Scope.drawings
                            ? 'Search drawings…'
                            : _asks
                            ? 'Search or Ask Kapy AI…'
                            : 'Search…',
                        hintStyle: style.copyWith(color: palette.textTertiary),
                        // A phone's target is the whole 44 pt row: the field
                        // carries the room rather than a box around it.
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
              ),
            ),
          ),
          if (AppPlatform.hasPointer) const Keycap('esc', plain: true),
        ],
      ),
    );
  }

  Widget _line(int index, List<String> terms, CalcPalette palette, bool dark) {
    final line = _lines[index];
    if (line.heading case final heading?) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text(
          heading,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 16 / 12,
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
            color: palette.textTertiary,
          ),
        ),
      );
    }
    final lit = index == _highlight;
    final mark = line.noteId == null
        ? null
        : TagMarks.of(context, line.noteId!).firstOrNull;
    final detail = line.detail;
    final task = line.task;
    final item = line.item;
    final done = item != null && _done.contains(item.id);
    final trailing = line.trailing;
    final keycap = line.keycap;
    final sage = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlight = index),
      child: GestureDetector(
        key: _rowKeys.putIfAbsent(index, GlobalKey.new),
        behavior: HitTestBehavior.opaque,
        onTap: () => _choose(index),
        child: Container(
          key: ValueKey('command-menu-row-${line.title}'),
          constraints: BoxConstraints(
            minHeight: widget.phone
                ? (detail == null ? 44 : 56)
                : (detail == null ? 40 : 52),
          ),
          margin: EdgeInsets.only(top: line.muted ? 4 : 0),
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: detail == null ? 0 : 8,
          ),
          decoration: BoxDecoration(
            color: lit
                ? (dark ? palette.separator : palette.controlBackground)
                : null,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          child: Row(
            spacing: 12,
            children: [
              if (item != null)
                Semantics(
                  checked: done,
                  label: 'Done',
                  onTap: () => _tick(item),
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: ValueKey('command-task-check-${item.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tick(item),
                    child: SizedBox.square(
                      dimension: AppControlMetrics.iconButtonExtent,
                      child: Center(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: done ? sage : null,
                            border: Border.all(
                              color: done ? sage : palette.checkboxBorder,
                              width: 1.5,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: done
                              ? KapyIcon(
                                  KapyIcons.checkRounded,
                                  size: 14,
                                  color: palette.paperColor,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                )
              else
                line.leading ??
                    KapyIcon(
                      line.icon!,
                      size: 16,
                      color: lit ? palette.textPrimary : palette.textSecondary,
                    ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text.rich(
                            _marked(
                              line.title,
                              switch (line.choice) {
                                OpenNoteChoice() || OpenTaskChoice() => terms,
                                _ => const [],
                              },
                              TextStyle(
                                fontSize: 14,
                                height: 18 / 14,
                                fontWeight: AppWeight.font(
                                  lit ? AppWeight.regular : AppWeight.regular,
                                ),
                                fontVariations: AppWeight.wght(
                                  lit ? AppWeight.regular : AppWeight.regular,
                                ),
                                color: line.muted || done
                                    ? palette.textSecondary
                                    : palette.textPrimary,
                                decoration: done
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                              palette,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (task != null) ...[
                          const SizedBox(width: 10),
                          NoteSwatch(note: task, size: 8),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              widget.taskLabel(task),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metaStyle(12.5, 16, palette.textSecondary),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (detail != null)
                      Text.rich(
                        _marked(
                          detail,
                          line.choice is RevealSettingChoice ? const [] : terms,
                          TextStyle(
                            fontSize: 13,
                            height: 17 / 13,
                            color: palette.textSecondary,
                          ),
                          palette,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (mark != null) TagDot(mark.colour),
              if (trailing != null)
                Text(
                  trailing,
                  style: TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    color: palette.textTertiary,
                  ),
                ),
              if (keycap != null && AppPlatform.hasPointer)
                Keycap(keycap, plain: true),
            ],
          ),
        ),
      ),
    );
  }

  /// [text] with every place a search word turns up in the accent, so a
  /// result shows why it matched.
  static TextSpan _marked(
    String text,
    List<String> terms,
    TextStyle style,
    CalcPalette palette,
  ) {
    if (terms.isEmpty || text.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    final lower = text.toLowerCase();
    final marked = List<bool>.filled(text.length, false);
    for (final term in terms) {
      for (
        var at = lower.indexOf(term);
        at >= 0;
        at = lower.indexOf(term, at + 1)
      ) {
        marked.fillRange(at, math.min(at + term.length, text.length), true);
      }
    }
    final mark = TextStyle(
      color: palette.accentText,
      fontWeight: AppWeight.font(AppWeight.regular),
      fontVariations: AppWeight.wght(AppWeight.regular),
    );
    final spans = <TextSpan>[];
    var start = 0;
    for (var at = 1; at <= text.length; at++) {
      if (at < text.length && marked[at] == marked[start]) continue;
      spans.add(
        TextSpan(
          text: text.substring(start, at),
          style: marked[start] ? mark : null,
        ),
      );
      start = at;
    }
    return TextSpan(style: style, children: spans);
  }

  /// The open note's tags in the menu's own rows: ticks for the ones it
  /// carries, ↵ to tick or untick, and the same refusals as + Tag.
  Widget _tagList(TagPickerController picker, CalcPalette palette, bool dark) {
    return Flexible(
      child: ListenableBuilder(
        listenable: Listenable.merge([picker.shelf.store, picker]),
        builder: (context, _) {
          final matches = picker.matches();
          final name = picker.query.text.trim();
          final problem = picker.problem;
          Widget row({
            required Key key,
            required int index,
            required Widget leading,
            required String label,
            String? count,
            bool ticked = false,
            required VoidCallback onTap,
          }) => KeepsKeyboard(
            child: MouseRegion(
              onEnter: (_) => picker.at = index,
              child: GestureDetector(
                key: key,
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: index == picker.at
                        ? (dark ? palette.separator : palette.controlBackground)
                        : null,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Row(
                    spacing: 12,
                    children: [
                      leading,
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 18 / 14,
                            fontWeight: AppWeight.font(AppWeight.regular),
                            fontVariations: AppWeight.wght(AppWeight.regular),
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      if (count != null)
                        Text(
                          count,
                          style: TextStyle(
                            fontSize: 12,
                            height: 16 / 12,
                            color: palette.textTertiary,
                          ),
                        ),
                      SizedBox(
                        width: 16,
                        child: ticked
                            ? KapyIcon(
                                KapyIcons.checkRounded,
                                size: 14,
                                color: palette.textPrimary,
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (picker.noteIds.any(picker.shelf.isShared))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                    child: Text(
                      'Shared note: your tags and their colours show only to you.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 16 / 12,
                        color: palette.textTertiary,
                      ),
                    ),
                  ),
                for (final (index, entry) in matches.indexed)
                  row(
                    key: ValueKey('tag-row-${entry.tag.id}'),
                    index: index,
                    leading: TagDot(tagColourOf(entry.tag.colour.v)),
                    label: entry.tag.name.v,
                    count: '${entry.count}',
                    ticked: picker.isOn(entry.tag.id) == true,
                    onTap: () => picker.toggle(entry.tag.id),
                  ),
                if (matches.isEmpty && name.isNotEmpty)
                  row(
                    key: const ValueKey('tag-create'),
                    index: 0,
                    leading: KapyIcon(
                      KapyIcons.addRounded,
                      size: 14,
                      color: palette.textTertiary,
                    ),
                    label: 'Create “$name”',
                    onTap: picker.create,
                  ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                    child: Text(
                      problem,
                      key: const ValueKey('tag-picker-problem'),
                      style: TextStyle(
                        fontSize: 12,
                        height: 16 / 12,
                        fontWeight: AppWeight.font(AppWeight.regular),
                        fontVariations: AppWeight.wght(AppWeight.regular),
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _footer(CalcPalette palette, {required bool ask}) {
    Widget hint(String key, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Keycap(key, plain: true),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            height: 16 / 12,
            color: palette.textTertiary,
          ),
        ),
      ],
    );
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.separator)),
      ),
      child: Row(
        spacing: 16,
        children: [
          hint('↑↓', 'Move'),
          hint('↵', switch (_lines.elementAtOrNull(_highlight)?.choice) {
            RevealSettingChoice() => 'Open in Settings',
            FilterTagChoice() => 'Filter notes',
            _ => 'Open',
          }),
          if (ask) hint('tab', 'Ask Kapy AI'),
          const Spacer(),
          hint('esc', 'Close'),
        ],
      ),
    );
  }
}

enum _Scope {
  all('All'),
  notes('Notes'),
  tasks('Tasks'),
  drawings('Drawings');

  const _Scope(this.label);

  final String label;
}
