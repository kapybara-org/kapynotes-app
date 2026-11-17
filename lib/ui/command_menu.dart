import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/shortcut_prefs.dart';
import '../data/task_board.dart';
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

/// Show a task in Tasks, among its note's.
class OpenTaskChoice extends CommandChoice {
  const OpenTaskChoice(this.task);
  final TaskItem task;
}

/// Narrow My notes to one tag, as ticking it in the Notes filter does.
class FilterTagChoice extends CommandChoice {
  const FilterTagChoice(this.tagId);
  final String tagId;
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

/// Opens the ⌘K menu over the window: search, create and go to.
///
/// [space] is where it was opened from, which decides what New note's key
/// says: in Tasks and Drawings that key makes a task or a drawing instead.
/// [destinations] are the sections Go to lists, in order, before Hidden,
/// listed only with [showHidden], and Archive. Hidden notes are searched
/// only while [hiddenUnlocked], and [tasks] is null where there is no task
/// list to search or add to.
Future<CommandChoice?> showCommandMenu(
  BuildContext context, {
  required NotesStore notes,
  required ShortcutPrefs shortcuts,
  required LibrarySpace space,
  required List<LibrarySpace> destinations,
  required List<String> recentIds,
  required DateTime Function(DateTime) displayTime,
  required String Function(Note) taskLabel,
  required Widget Function(Widget) withTags,
  Note? openNote,
  TaskBoard? tasks,
  bool showHidden = false,
  bool hiddenUnlocked = false,
  SettingsHost? settingsIndex,
}) {
  final dark = context.palette.brightness == Brightness.dark;
  return showDialog<CommandChoice>(
    context: context,
    barrierColor: dark ? const Color(0x990C0B09) : const Color(0x402A2620),
    builder: (context) => withTags(
      CommandMenu(
        notes: notes,
        shortcuts: shortcuts,
        space: space,
        destinations: destinations,
        recentIds: recentIds,
        displayTime: displayTime,
        taskLabel: taskLabel,
        openNote: openNote,
        tasks: tasks,
        showHidden: showHidden,
        hiddenUnlocked: hiddenUnlocked,
        settingsIndex: settingsIndex,
        onChosen: (choice) => Navigator.of(context).pop(choice),
      ),
    ),
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
    this.openNote,
    this.tasks,
    this.showHidden = false,
    this.hiddenUnlocked = false,
    this.settingsIndex,
  });

  final NotesStore notes;
  final ShortcutPrefs shortcuts;
  final LibrarySpace space;
  final List<LibrarySpace> destinations;
  final List<String> recentIds;
  final DateTime Function(DateTime) displayTime;
  final String Function(Note) taskLabel;
  final ValueChanged<CommandChoice> onChosen;

  /// The note in the editor, the one Tag note… tags.
  final Note? openNote;
  final TaskBoard? tasks;
  final bool showHidden;
  final bool hiddenUnlocked;

  /// Builds the invisible settings that lend their search index, so Settings
  /// results come from the same index as settings search. Null leaves them
  /// out.
  final SettingsHost? settingsIndex;

  /// How many of each kind the menu shows.
  static const int perKind = 3;

  @override
  State<CommandMenu> createState() => _CommandMenuState();
}

/// One line of the menu: a section's heading, or a row that does something.
class _Line {
  const _Line.heading(String this.heading)
    : icon = null,
      title = '',
      choice = null,
      detail = null,
      task = null,
      trailing = null,
      keycap = null,
      noteId = null,
      tag = null,
      ticked = false,
      run = null,
      muted = false;

  const _Line.row({
    required KapyIconData this.icon,
    required this.title,
    this.choice,
    this.detail,
    this.task,
    this.trailing,
    this.keycap,
    this.noteId,
    this.run,
    this.muted = false,
  }) : heading = null,
       tag = null,
       ticked = false;

  /// A tag in a list of tags: its dot, name and count, with a tick when the
  /// note being tagged carries it.
  _Line.tag(TagEntry this.tag, {this.choice, this.run, this.ticked = false})
    : heading = null,
      icon = null,
      title = tag.tag.name.v,
      detail = null,
      task = null,
      trailing = null,
      keycap = null,
      noteId = null,
      muted = false;

  final String? heading;
  final KapyIconData? icon;
  final String title;
  final CommandChoice? choice;

  /// The line under a note's title that explains why it matched.
  final String? detail;

  /// The note a task is in, named after the task's words.
  final Note? task;
  final String? trailing;
  final String? keycap;

  /// The note a result opens, whose first tag's dot sits before its date.
  final String? noteId;
  final TagEntry? tag;
  final bool ticked;

  /// What the row does where it stays in the menu, in place of [choice].
  final VoidCallback? run;

  /// In the quieter ink, as the row pointing into Archive is.
  final bool muted;
}

class _CommandMenuState extends State<CommandMenu> {
  final TextEditingController _field = TextEditingController();
  Note? _tagging;
  String? _problem;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};
  late List<_Line> _lines = _build('');
  late int _highlight = _rows.firstOrNull ?? 0;

  SettingsIndex? _settings;

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<int> get _rows => [
    for (var index = 0; index < _lines.length; index++)
      if (_lines[index].choice != null || _lines[index].run != null) index,
  ];

  String? _keycap(ShortcutAction action) =>
      widget.shortcuts.bindingFor(action)?.keycapLabel;

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
    final shelf = TagShelf.maybeOf(context);
    final tagging = _tagging;
    if (shelf != null && tagging != null) {
      return _tagLines(shelf, tagging, text);
    }
    if (shelf != null && text.startsWith('#')) {
      return _filterLines(shelf, text.substring(1).trim());
    }
    return text.isEmpty ? _beforeTyping() : _whileTyping(text, shelf);
  }

  /// Typing # lists the tags, and letters after it narrow them.
  List<_Line> _filterLines(TagShelf shelf, String name) {
    final lowered = name.toLowerCase();
    final found = [
      for (final entry in shelf.listed())
        if (entry.tag.name.v.toLowerCase().contains(lowered)) entry,
    ];
    return [
      if (found.isEmpty)
        _Line.heading(name.isEmpty ? 'No tags yet' : 'No tag named “$name”')
      else ...[
        const _Line.heading('Filter by tag'),
        for (final entry in found)
          _Line.tag(entry, choice: FilterTagChoice(entry.tag.id)),
      ],
    ];
  }

  /// Tag note…: the field finds or creates a tag, and a row ticks or unticks
  /// it on [note].
  List<_Line> _tagLines(TagShelf shelf, Note note, String name) {
    final tagger = NoteTagging(shelf, note.id);
    final found = tagger.matches(name);
    return [
      for (final entry in found)
        _Line.tag(
          entry,
          ticked: tagger.isOn(entry.tag.id),
          run: () => _tag(tagger.toggle(entry.tag.id)),
        ),
      if (found.isEmpty && name.isNotEmpty)
        _Line.row(
          icon: KapyIcons.addRounded,
          title: 'Create “$name”',
          run: () => _tag(tagger.create(name), created: true),
        ),
    ];
  }

  void _tag(String? problem, {bool created = false}) {
    if (created && problem == null) _field.clear();
    setState(() {
      _problem = problem;
      _lines = _build(_field.text);
      _rowKeys.clear();
      if (created) _highlight = _rows.firstOrNull ?? 0;
    });
  }

  void _startTagging(Note note) {
    _field.clear();
    _tagging = note;
    _problem = null;
    _search('');
  }

  void _stopTagging() {
    _tagging = null;
    _problem = null;
    _search('');
  }

  List<_Line> _beforeTyping() {
    final notes = widget.notes;
    final recent = [
      for (final id in widget.recentIds)
        if (notes.byId(id) case final note?
            when !note.isArchived && (!note.isHidden || widget.hiddenUnlocked))
          note,
    ].take(CommandMenu.perKind);
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
  List<_Line> _whileTyping(String text, TagShelf? shelf) {
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
    final archived = notes.searchArchived(text).length;
    final settings = [
      for (final entry in searchSettings<SettingsSection>(
        _settings?.call() ?? const [],
        text,
      ))
        if (entry.elsewhere == null) entry,
    ].take(CommandMenu.perKind);
    final lowered = text.toLowerCase();
    final settingsFirst =
        settings.isNotEmpty &&
        settings.first.title.toLowerCase().contains(lowered);
    final settingsLines = [
      if (settings.isNotEmpty) ...[
        const _Line.heading('Settings'),
        for (final entry in settings) _settingRow(entry),
      ],
    ];
    final open = widget.openNote;
    return [
      if (shelf != null &&
          open != null &&
          lowered.length >= 3 &&
          'tag note'.startsWith(lowered)) ...[
        const _Line.heading('Actions'),
        _Line.row(
          icon: KapyIcons.tagRounded,
          title: 'Tag note…',
          trailing: open.title,
          run: () => _startTagging(open),
        ),
      ],
      if (settingsFirst) ...settingsLines,
      if (written.isNotEmpty) ...[
        const _Line.heading('Notes'),
        for (final note in written.take(CommandMenu.perKind))
          _noteRow(note, detail: note.matchSnippet(text)),
      ],
      if (tasks.isNotEmpty) ...[
        const _Line.heading('Tasks'),
        for (final task in tasks)
          _Line.row(
            icon: KapyIcons.tasksOutlined,
            title: task.words,
            task: task.note,
            choice: OpenTaskChoice(task),
          ),
      ],
      if (drawings.isNotEmpty) ...[
        const _Line.heading('Drawings'),
        for (final note in drawings.take(CommandMenu.perKind)) _noteRow(note),
      ],
      if (!settingsFirst) ...settingsLines,
      // Kapy AI's Ask row joins this section when the panel ships.
      _Line.heading('Use “$text”'),
      if (widget.tasks != null)
        _Line.row(
          icon: KapyIcons.tasksOutlined,
          title: 'New task: $text',
          keycap: _keycap(ShortcutAction.newTask),
          choice: NewTaskChoice(text),
        ),
      _Line.row(
        icon: KapyIcons.noteOutlined,
        title: 'New note: $text',
        keycap: _newNoteKey,
        choice: NewNoteChoice(text),
      ),
      if (archived > 0)
        _Line.row(
          icon: archiveIcon,
          title: '$archived more in Archive',
          muted: true,
          choice: SearchArchiveChoice(text),
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

  void _choose(int index) {
    final line = _lines.elementAtOrNull(index);
    if (line == null) return;
    if (line.run case final run?) return run();
    if (line.choice case final choice?) widget.onChosen(choice);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter
          when event is KeyDownEvent:
        _choose(_highlight);
      case LogicalKeyboardKey.backspace
          when _tagging != null && _field.text.isEmpty:
        _stopTagging();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = palette.brightness == Brightness.dark;
    final top = (MediaQuery.sizeOf(context).height * 0.1).clamp(16.0, 88.0);
    final terms = noteSearchTerms(_field.text);
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
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: dark
                      ? const Color(0x80000000)
                      : const Color(0x332A2620),
                  offset: const Offset(0, 24),
                  blurRadius: 64,
                ),
                BoxShadow(
                  color: dark
                      ? const Color(0x4D000000)
                      : const Color(0x1F2A2620),
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
                  Flexible(
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var index = 0; index < _lines.length; index++)
                            _line(index, terms, palette, dark),
                          if (_problem case final problem?)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                              child: Text(
                                problem,
                                key: const ValueKey('command-menu-problem'),
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 16 / 12,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (AppPlatform.hasPointer) _footer(palette),
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

  Widget _searchField(CalcPalette palette) {
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
            size: 18,
            strokeWidth: 1.8,
            color: palette.textSecondary,
          ),
          if (_tagging case final note?)
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.separator,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Tag note · ${note.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
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
                controller: _field,
                autofocus: true,
                onChanged: _search,
                textInputAction: TextInputAction.go,
                style: style,
                cursorHeight: 20,
                decoration: InputDecoration.collapsed(
                  hintText: _tagging == null ? 'Search…' : null,
                  hintStyle: style.copyWith(color: palette.textTertiary),
                ),
              ),
            ),
          ),
          if (AppPlatform.hasPointer) const Keycap('esc'),
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
            fontWeight: FontWeight.w600,
            color: palette.textTertiary,
          ),
        ),
      );
    }
    final lit = index == _highlight;
    if (line.tag != null) return _tagRow(index, line, palette, dark);
    final mark = line.noteId == null
        ? null
        : TagMarks.of(context, line.noteId!).firstOrNull;
    final detail = line.detail;
    final task = line.task;
    final trailing = line.trailing;
    final keycap = line.keycap;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlight = index),
      child: GestureDetector(
        key: _rowKeys.putIfAbsent(index, GlobalKey.new),
        behavior: HitTestBehavior.opaque,
        onTap: () => _choose(index),
        child: Container(
          key: ValueKey('command-menu-row-${line.title}'),
          constraints: BoxConstraints(minHeight: detail == null ? 40 : 52),
          margin: EdgeInsets.only(top: line.muted ? 4 : 0),
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: detail == null ? 0 : 8,
          ),
          decoration: BoxDecoration(
            color: lit
                ? (dark ? palette.separator : palette.controlBackground)
                : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            spacing: 12,
            children: [
              KapyIcon(
                line.icon!,
                size: 16,
                strokeWidth: 1.7,
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
                                fontWeight: lit
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: line.muted
                                    ? palette.textSecondary
                                    : palette.textPrimary,
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
                              style: handStyle(
                                12,
                                16,
                                FontWeight.w400,
                                palette.textSecondary,
                              ),
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
              if (keycap != null) Keycap(keycap),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tagRow(int index, _Line line, CalcPalette palette, bool dark) {
    final entry = line.tag!;
    return MouseRegion(
      onEnter: (_) => setState(() => _highlight = index),
      child: GestureDetector(
        key: _rowKeys.putIfAbsent(index, GlobalKey.new),
        behavior: HitTestBehavior.opaque,
        onTap: () => _choose(index),
        child: Container(
          key: ValueKey('command-menu-row-${line.title}'),
          height: 30,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: index == _highlight
                ? (dark ? palette.separator : palette.controlBackground)
                : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            spacing: 9,
            children: [
              TagDot(tagColourOf(entry.tag.colour.v)),
              Expanded(
                child: Text(
                  line.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 16 / 13,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              Text(
                '${entry.count}',
                style: TextStyle(
                  fontSize: 12,
                  height: 16 / 12,
                  color: palette.textTertiary,
                ),
              ),
              SizedBox(
                width: 14,
                child: line.ticked
                    ? KapyIcon(
                        KapyIcons.checkRounded,
                        size: 14,
                        strokeWidth: 1.8,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
              ),
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
      fontWeight: FontWeight.w600,
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

  Widget _footer(CalcPalette palette) {
    Widget hint(String key, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        Keycap(key),
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
          hint('↵', switch (_lines.elementAtOrNull(_highlight)) {
            _Line(choice: RevealSettingChoice()) => 'Open in Settings',
            _Line(choice: FilterTagChoice()) => 'Filter notes',
            _ when _tagging != null => 'Add or remove',
            _ => 'Open',
          }),
          const Spacer(),
          hint('esc', 'Close'),
        ],
      ),
    );
  }
}
