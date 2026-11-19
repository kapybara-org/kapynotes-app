import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/platform.dart';
import '../floating_surface.dart';
import '../keycap.dart';
import 'slash_commands.dart';

enum _CommandGroup {
  write('Write'),
  blocks('Blocks'),
  insert('Insert');

  const _CommandGroup(this.label);

  final String label;
}

class _SlashCommandDefinition {
  const _SlashCommandDefinition({
    required this.type,
    required this.group,
    required this.label,
    required this.description,
    required this.icon,
    this.trigger,
    this.triggerNeedsMarkdown = false,
    this.aliases = const [],
    this.requiresMarkdown = false,
  });

  final SlashCommandType type;
  final _CommandGroup group;
  final String label;

  /// Read to assistive technology after the label; the row shows the label
  /// alone.
  final String description;
  final KapyIconData icon;

  /// What typed at the start of a line does the same, shown where the
  /// command has no key of its own.
  final String? trigger;

  /// Whether [trigger] only works with Markdown on, as a heading's "#" does.
  final bool triggerNeedsMarkdown;

  /// Everyday words for the command, found by what is typed after "/".
  final List<String> aliases;
  final bool requiresMarkdown;

  /// Whether every typed word starts a word of the name or an alias.
  bool matches(List<String> query) {
    final words = [...label.toLowerCase().split(' '), ...aliases];
    return query.every((typed) => words.any((word) => word.startsWith(typed)));
  }

  /// The alias [query] found the command by, shown beside the name when the
  /// name alone would not have matched.
  String? matchedAlias(List<String> query) {
    final named = label.toLowerCase().split(' ');
    if (query.every((typed) => named.any((word) => word.startsWith(typed)))) {
      return null;
    }
    for (final alias in aliases) {
      if (query.any(alias.startsWith)) return alias;
    }
    return null;
  }
}

/// In the order the menu lists them: Write, then Blocks, then the inserts
/// in the icon row at the bottom.
const _definitions = [
  _SlashCommandDefinition(
    type: SlashCommandType.checklist,
    group: _CommandGroup.write,
    label: 'Checklist',
    description: 'Tasks with checkboxes',
    icon: KapyIcons.checklistRounded,
    trigger: '[ ]',
    aliases: ['todo', 'task'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.bulletedList,
    group: _CommandGroup.write,
    label: 'Bulleted list',
    description: 'Start an unordered list',
    icon: KapyIcons.bulletedListRounded,
    trigger: '-',
    aliases: ['bullet', 'list'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.numberedList,
    group: _CommandGroup.write,
    label: 'Numbered list',
    description: 'Start an ordered list',
    icon: KapyIcons.numberedListRounded,
    trigger: '1.',
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.heading1,
    group: _CommandGroup.write,
    label: 'Heading 1',
    description: 'A large section heading',
    icon: KapyIcons.heading1Rounded,
    trigger: '#',
    triggerNeedsMarkdown: true,
    aliases: ['title', 'h1'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.heading2,
    group: _CommandGroup.write,
    label: 'Heading 2',
    description: 'A medium section heading',
    icon: KapyIcons.heading2Rounded,
    trigger: '##',
    triggerNeedsMarkdown: true,
    aliases: ['h2'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.heading3,
    group: _CommandGroup.write,
    label: 'Heading 3',
    description: 'A small section heading',
    icon: KapyIcons.heading3Rounded,
    trigger: '###',
    aliases: ['h3'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.quote,
    group: _CommandGroup.blocks,
    label: 'Quote',
    description: 'Set text apart as a quote',
    icon: KapyIcons.quoteRounded,
    trigger: '>',
    aliases: ['cite'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.codeBlock,
    group: _CommandGroup.blocks,
    label: 'Code block',
    description: 'A fenced block of code',
    icon: KapyIcons.codeRounded,
    trigger: '```',
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.formula,
    group: _CommandGroup.blocks,
    label: 'Formula',
    description: 'Math set apart on lines of its own',
    icon: KapyIcons.formulaRounded,
    trigger: r'$$',
    aliases: ['math', 'latex', 'equation'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.table,
    group: _CommandGroup.blocks,
    label: 'Table',
    description: 'Simple rows and columns',
    icon: KapyIcons.tableRounded,
    trigger: '|',
    aliases: ['grid'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.divider,
    group: _CommandGroup.blocks,
    label: 'Divider',
    description: 'Separate sections with a line',
    icon: KapyIcons.dividerRounded,
    trigger: '---',
    aliases: ['line', 'hr'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.image,
    group: _CommandGroup.insert,
    label: 'Image',
    description: 'Take or choose a picture',
    icon: KapyIcons.imageOutlined,
    aliases: ['photo', 'picture', 'img'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.video,
    group: _CommandGroup.insert,
    label: 'Video',
    description: 'Choose a video',
    icon: KapyIcons.videoOutlined,
    aliases: ['movie', 'clip'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.voiceNote,
    group: _CommandGroup.insert,
    label: 'Voice note',
    description: 'Record audio here',
    icon: KapyIcons.micRounded,
    aliases: ['mic', 'record', 'audio'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.file,
    group: _CommandGroup.insert,
    label: 'File',
    description: 'Attach any file to open on your other devices',
    icon: KapyIcons.attachFileRounded,
    aliases: ['attach', 'pdf'],
  ),
];

/// Owns the root-overlay menu while leaving focus in the real editor.
///
/// A controller rather than a modal route is important here: letters typed
/// after `/` still belong to the TextField, which is also what preserves IME,
/// undo, selection and accessibility behavior.
class SlashCommandMenuController extends ChangeNotifier {
  OverlayEntry? _entry;
  Rect _anchor = Rect.zero;
  String _query = '';
  Set<SlashCommandType> _available = const {};
  Map<SlashCommandType, String> _hints = const {};
  SlashCommandType? _last;
  bool _markdownEnabled = false;
  bool _choosingTable = false;
  int _selectedIndex = 0;
  int _tableRows = 2;
  int _tableColumns = 2;
  ValueChanged<SlashCommandChoice>? _onSelected;
  ValueChanged<bool>? _onDismissed;
  final _search = TextEditingController();
  late final _searchFocus = FocusNode(
    debugLabel: 'Commands search',
    onKeyEvent: (node, event) =>
        handleKeyEvent(event) ? KeyEventResult.handled : KeyEventResult.ignored,
  );
  bool _searching = false;

  bool get isVisible => _entry != null;

  /// Whether the menu has its own search field, as it does from the "+",
  /// and so holds the keyboard rather than the note.
  bool get searching => _searching;
  Rect get anchor => _anchor;
  bool get markdownEnabled => _markdownEnabled;
  bool get choosingTable => _choosingTable;
  int get selectedIndex => _selectedIndex;
  int get tableRows => _tableRows;
  int get tableColumns => _tableColumns;

  List<String> get _words => _query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);

  /// What is on offer for what is typed: the rows, in menu order, then the
  /// inserts in the icon row.
  List<_SlashCommandDefinition> get _commands {
    final words = _words;
    return [
      for (final definition in _definitions)
        if (_available.contains(definition.type) && definition.matches(words))
          definition,
    ];
  }

  List<_SlashCommandDefinition> get _rows => [
    for (final command in _commands)
      if (command.group != _CommandGroup.insert) command,
  ];

  /// Where the highlight starts: on the command whose name begins with what
  /// is typed, else the first match, and before anything is typed on the
  /// command used last, so repeating it is "/" and Enter.
  int _initialIndex() {
    final commands = _commands;
    final query = _query.trim().toLowerCase();
    final index = query.isEmpty
        ? commands.indexWhere((command) => command.type == _last)
        : commands.indexWhere(
            (command) => command.label.toLowerCase().startsWith(query),
          );
    return math.max(0, index);
  }

  void show(
    BuildContext context, {
    required Rect anchor,
    required String query,
    required Set<SlashCommandType> available,
    required bool markdownEnabled,
    Map<SlashCommandType, String> hints = const {},
    SlashCommandType? lastCommand,
    bool search = false,
    required ValueChanged<SlashCommandChoice> onSelected,
    required ValueChanged<bool> onDismissed,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    if (_entry == null) {
      _searching = search;
      _search.clear();
    }
    final queryChanged = query != _query;
    _anchor = anchor;
    _query = query;
    _available = Set.unmodifiable(available);
    _hints = hints;
    _last = lastCommand;
    _markdownEnabled = markdownEnabled;
    _onSelected = onSelected;
    _onDismissed = onDismissed;
    if (queryChanged || _entry == null) {
      _choosingTable = false;
      _selectedIndex = _initialIndex();
    }
    _clampSelection();

    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (context) => _SlashCommandOverlay(controller: this),
      );
      overlay.insert(_entry!);
      // The note keeps its focus until the field is there to take it.
      if (_searching) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_searching) _searchFocus.requestFocus();
        });
      }
    }
    notifyListeners();
  }

  void hide({bool userInitiated = false}) {
    final dismissed = _onDismissed;
    _remove();
    dismissed?.call(userInitiated);
  }

  void _searchChanged(String text) {
    _query = text;
    _choosingTable = false;
    _selectedIndex = _initialIndex();
    notifyListeners();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
    _searching = false;
    _choosingTable = false;
    _selectedIndex = 0;
    _onSelected = null;
    _onDismissed = null;
  }

  void _clampSelection() {
    final count = _commands.length;
    _selectedIndex = count == 0 ? 0 : _selectedIndex.clamp(0, count - 1);
  }

  void selectIndex(int index) {
    final count = _commands.length;
    if (count == 0) return;
    final next = index.clamp(0, count - 1);
    if (next == _selectedIndex) return;
    _selectedIndex = next;
    notifyListeners();
  }

  void activateIndex(int index) {
    final visible = _commands;
    if (index < 0 || index >= visible.length) return;
    _selectedIndex = index;
    final command = visible[index];
    if (command.type == SlashCommandType.table) {
      _choosingTable = true;
      _tableRows = 2;
      _tableColumns = 2;
      notifyListeners();
      return;
    }
    _complete(SlashCommandChoice(command.type));
  }

  void chooseTableSize(int rows, int columns) {
    _tableRows = rows.clamp(1, 6);
    _tableColumns = columns.clamp(1, 6);
    notifyListeners();
  }

  void insertTable() => _complete(
    SlashCommandChoice.table(rows: _tableRows, columns: _tableColumns),
  );

  void leaveTablePicker() {
    if (!_choosingTable) return;
    _choosingTable = false;
    notifyListeners();
  }

  void _complete(SlashCommandChoice choice) {
    final selected = _onSelected;
    _remove();
    selected?.call(choice);
  }

  /// Handles only navigation that belongs to an open menu. All printable
  /// keys pass through to the editor and update the search from its text.
  bool handleKeyEvent(KeyEvent event) {
    if (!isVisible || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_choosingTable) {
        leaveTablePicker();
      } else {
        hide(userInitiated: true);
      }
      return true;
    }

    if (_choosingTable) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        chooseTableSize(_tableRows, _tableColumns - 1);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        chooseTableSize(_tableRows, _tableColumns + 1);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        chooseTableSize(_tableRows - 1, _tableColumns);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        chooseTableSize(_tableRows + 1, _tableColumns);
        return true;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        insertTable();
        return true;
      }
      return false;
    }

    // Rows go up and down; past the last one is the icon row, which goes
    // left and right.
    final visible = _commands;
    final rows = _rows.length;
    final icons = visible.length - rows;
    final onIcons = _selectedIndex >= rows;
    if (key == LogicalKeyboardKey.arrowDown && visible.isNotEmpty) {
      selectIndex(
        onIcons || (_selectedIndex == rows - 1 && icons == 0)
            ? 0
            : _selectedIndex + 1,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp && visible.isNotEmpty) {
      selectIndex(switch (_selectedIndex) {
        _ when onIcons => rows > 0 ? rows - 1 : _selectedIndex,
        0 => icons > 0 ? rows : rows - 1,
        final index => index - 1,
      });
      return true;
    }
    if (onIcons &&
        icons > 0 &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      final step = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      selectIndex(rows + (_selectedIndex - rows + step) % icons);
      return true;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        visible.isNotEmpty) {
      activateIndex(_selectedIndex);
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _remove();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

class _SlashCommandOverlay extends StatefulWidget {
  const _SlashCommandOverlay({required this.controller});

  final SlashCommandMenuController controller;

  @override
  State<_SlashCommandOverlay> createState() => _SlashCommandOverlayState();
}

class _SlashCommandOverlayState extends State<_SlashCommandOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  )..forward();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelection());
  }

  void _revealSelection() {
    if (!mounted || !_scroll.hasClients || widget.controller.choosingTable) {
      return;
    }
    final rows = widget.controller._rows;
    final index = widget.controller.selectedIndex;
    if (index >= rows.length) return;
    final top = _CommandList.rowTop(rows, index);
    final bottom = top + _CommandList.rowHeight;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.animateTo(
        top,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
      );
    } else if (bottom > position.pixels + position.viewportDimension) {
      _scroll.animateTo(
        bottom - position.viewportDimension,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _scroll.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final curve = CurvedAnimation(
      parent: _animation,
      curve: Curves.easeOutCubic,
    );
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => widget.controller.hide(userInitiated: true),
          ),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: _SlashMenuPosition(
              anchor: widget.controller.anchor,
              safeArea: media.padding.copyWith(
                bottom: media.padding.bottom + media.viewInsets.bottom,
              ),
            ),
            child: FadeTransition(
              opacity: curve,
              child: ScaleTransition(
                scale: Tween(begin: 0.97, end: 1.0).animate(curve),
                alignment: Alignment.topLeft,
                child: ExcludeFocus(
                  excluding: !widget.controller.searching,
                  child: TextFieldTapRegion(
                    child: FloatingSurface(
                      key: const ValueKey('slash-command-menu'),
                      padding: const EdgeInsets.all(6),
                      child: widget.controller.choosingTable
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Kept so the keyboard stays with the menu.
                                if (widget.controller.searching)
                                  Offstage(
                                    child: _SearchField(
                                      controller: widget.controller,
                                    ),
                                  ),
                                _TableSizePicker(controller: widget.controller),
                              ],
                            )
                          : _CommandList(
                              controller: widget.controller,
                              scroll: _scroll,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CommandList extends StatelessWidget {
  const _CommandList({required this.controller, required this.scroll});

  final SlashCommandMenuController controller;
  final ScrollController scroll;

  static const double width = 300;
  static const double rowHeight = 32;
  static const double headerHeight = 29;

  /// Where row [index] of [rows] starts in the list, past the group headers
  /// above it.
  static double rowTop(List<_SlashCommandDefinition> rows, int index) {
    var top = 0.0;
    for (var i = 0; i <= index && i < rows.length; i++) {
      if (i == 0 || rows[i - 1].group != rows[i].group) top += headerHeight;
      if (i < index) top += rowHeight;
    }
    return top;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final commands = controller._commands;
    final rows = controller._rows;
    final words = controller._words;
    String? hint(_SlashCommandDefinition command) =>
        controller._hints[command.type] ??
        (command.triggerNeedsMarkdown && !controller.markdownEnabled
            ? null
            : command.trigger);
    String? note(_SlashCommandDefinition command) => words.isEmpty
        ? (command.type == controller._last ? 'last used' : null)
        : command.matchedAlias(words);
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.searching) _SearchField(controller: controller),
          if (commands.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              child: Text(
                'No matching commands',
                key: const ValueKey('slash-command-empty'),
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: AppTypeScale.control,
                ),
              ),
            ),
          if (rows.isNotEmpty)
            Flexible(
              child: ListView(
                key: const ValueKey('slash-command-list'),
                controller: scroll,
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final (index, command) in rows.indexed) ...[
                    if (index == 0 || rows[index - 1].group != command.group)
                      Container(
                        height: headerHeight,
                        alignment: Alignment.bottomLeft,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                        child: Semantics(
                          header: true,
                          label: command.group.label,
                          excludeSemantics: true,
                          child: Text(
                            command.group.label.toUpperCase(),
                            style: TextStyle(
                              color: palette.textTertiary,
                              fontSize: AppTypeScale.badge,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.44,
                            ),
                          ),
                        ),
                      ),
                    _CommandRow(
                      key: ValueKey('slash-command-${command.type.name}'),
                      command: command,
                      hint: hint(command),
                      note: note(command),
                      selected: index == controller.selectedIndex,
                      markdownEnabled: controller.markdownEnabled,
                      onHover: () => controller.selectIndex(index),
                      onPressed: () => controller.activateIndex(index),
                    ),
                  ],
                ],
              ),
            ),
          if (commands.length > rows.length)
            Container(
              key: const ValueKey('slash-command-inserts'),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              decoration: rows.isEmpty
                  ? null
                  : BoxDecoration(
                      border: Border(top: BorderSide(color: palette.separator)),
                    ),
              child: Row(
                spacing: 4,
                children: [
                  for (final (offset, command)
                      in commands.skip(rows.length).indexed)
                    Expanded(
                      child: _InsertButton(
                        key: ValueKey('slash-command-${command.type.name}'),
                        command: command,
                        hint: hint(command),
                        selected:
                            rows.length + offset == controller.selectedIndex,
                        onHover: () =>
                            controller.selectIndex(rows.length + offset),
                        onPressed: () =>
                            controller.activateIndex(rows.length + offset),
                      ),
                    ),
                ],
              ),
            ),
          if (AppPlatform.isDesktop)
            _KeyHints(
              alongIcons:
                  commands.isNotEmpty &&
                  controller.selectedIndex >= rows.length,
            ),
        ],
      ),
    );
  }
}

/// What the "+" opens Commands with: the caret stays in the note, so the
/// search has a field of its own.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final SlashCommandMenuController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      color: palette.textPrimary,
      fontSize: AppTypeScale.body,
      fontWeight: FontWeight.w400,
    );
    return Container(
      height: 36,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.separator)),
      ),
      child: Row(
        children: [
          KapyIcon(
            KapyIcons.searchRounded,
            size: 15,
            color: palette.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
                key: const ValueKey('slash-command-search'),
                controller: controller._search,
                focusNode: controller._searchFocus,
                style: style,
                cursorHeight: 16,
                decoration: InputDecoration(
                  hintText: 'Search commands',
                  hintStyle: style.copyWith(color: palette.textTertiary),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: controller._searchChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One command on one line: its icon and name, a quiet note such as
/// "last used", and on the right the key that does the same, or what typed
/// at the start of a line does.
class _CommandRow extends StatelessWidget {
  const _CommandRow({
    super.key,
    required this.command,
    required this.hint,
    required this.note,
    required this.selected,
    required this.markdownEnabled,
    required this.onHover,
    required this.onPressed,
  });

  final _SlashCommandDefinition command;
  final String? hint;
  final String? note;
  final bool selected;
  final bool markdownEnabled;
  final VoidCallback onHover;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final requiresMarkdown = command.requiresMarkdown && !markdownEnabled;
    final hint = this.hint;
    final note = this.note;
    final quiet = TextStyle(
      color: palette.textTertiary,
      fontSize: AppTypeScale.caption,
      fontWeight: FontWeight.w400,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: command.label,
      hint: requiresMarkdown ? 'Requires Markdown' : command.description,
      excludeSemantics: true,
      onTap: onPressed,
      child: MouseRegion(
        onEnter: (_) => onHover(),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: selected ? palette.selectedBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.control),
            onTap: onPressed,
            child: SizedBox(
              height: _CommandList.rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  spacing: 10,
                  children: [
                    KapyIcon(
                      command.icon,
                      size: 16,
                      color: selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                    ),
                    Expanded(
                      child: Row(
                        spacing: 10,
                        children: [
                          Flexible(
                            child: Text(
                              command.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: AppTypeScale.body,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          if (note != null)
                            Text(note, maxLines: 1, style: quiet),
                        ],
                      ),
                    ),
                    if (requiresMarkdown)
                      Text('Markdown', maxLines: 1, style: quiet)
                    else if (hint != null)
                      Keycap(hint),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An insert in the row at the bottom of the menu: its icon, with its name
/// and key in a tooltip that also shows when the keyboard reaches it.
class _InsertButton extends StatefulWidget {
  const _InsertButton({
    super.key,
    required this.command,
    required this.hint,
    required this.selected,
    required this.onHover,
    required this.onPressed,
  });

  final _SlashCommandDefinition command;
  final String? hint;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onPressed;

  @override
  State<_InsertButton> createState() => _InsertButtonState();
}

class _InsertButtonState extends State<_InsertButton> {
  final _tooltip = GlobalKey<TooltipState>();

  @override
  void didUpdateWidget(_InsertButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tooltip.currentState?.ensureTooltipVisible(),
      );
    } else if (!widget.selected && oldWidget.selected) {
      Tooltip.dismissAllToolTips();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final command = widget.command;
    final hint = widget.hint;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: command.label,
      hint: command.description,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: Tooltip(
        key: _tooltip,
        message: hint == null ? command.label : '${command.label}  $hint',
        child: MouseRegion(
          onEnter: (_) => widget.onHover(),
          cursor: SystemMouseCursors.click,
          child: Material(
            color: widget.selected
                ? palette.selectedBackground
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadii.control),
              onTap: widget.onPressed,
              child: SizedBox(
                height: 34,
                child: Center(
                  child: KapyIcon(
                    command.icon,
                    size: 17,
                    color: widget.selected
                        ? palette.textPrimary
                        : palette.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The keys that work the menu, under it on a desktop: up and down through
/// the rows, or left and right [alongIcons].
class _KeyHints extends StatelessWidget {
  const _KeyHints({required this.alongIcons});

  final bool alongIcons;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      color: palette.textTertiary,
      fontSize: AppTypeScale.caption,
      fontWeight: FontWeight.w400,
    );
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('slash-command-keys'),
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.separator)),
        ),
        child: Row(
          spacing: 6,
          children: [
            for (final (key, action) in [
              (alongIcons ? '←→' : '↑↓', 'move'),
              ('↵', 'insert'),
              ('esc', 'close'),
            ]) ...[
              Keycap(key),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(action, style: style),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TableSizePicker extends StatelessWidget {
  const _TableSizePicker({required this.controller});

  final SlashCommandMenuController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 252),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A compact phone can leave little room above its software keyboard.
          // Scale the picker, rather than overflowing or dismissing the
          // keyboard that the writer is still using.
          const horizontalPadding = 10.0;
          const pickerChromeHeight = 72.0;
          final gridSize = math.min(
            228.0,
            math.min(
              math.max(0.0, constraints.maxWidth - horizontalPadding),
              math.max(0.0, constraints.maxHeight - pickerChromeHeight),
            ),
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(5, 4, 5, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey('table-size-back'),
                      onPressed: controller.leaveTablePicker,
                      tooltip: 'Back to commands',
                      constraints: BoxConstraints.tight(
                        Size.square(AppControlMetrics.iconButtonExtent),
                      ),
                      padding: EdgeInsets.zero,
                      icon: KapyIcon(
                        KapyIcons.chevronLeftRounded,
                        size: AppControlMetrics.iconAction,
                        color: palette.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Table size',
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: AppTypeScale.control,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      '${controller.tableColumns} × ${controller.tableRows}',
                      key: const ValueKey('table-size-label'),
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: AppTypeScale.caption,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                SizedBox.square(
                  dimension: gridSize,
                  child: GridView.builder(
                    key: const ValueKey('table-size-grid'),
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                          mainAxisSpacing: 5,
                          crossAxisSpacing: 5,
                        ),
                    itemCount: 36,
                    itemBuilder: (context, index) {
                      final row = index ~/ 6 + 1;
                      final column = index % 6 + 1;
                      final selected =
                          row <= controller.tableRows &&
                          column <= controller.tableColumns;
                      return Semantics(
                        button: true,
                        label: '$column columns by $row rows',
                        child: MouseRegion(
                          onEnter: (_) =>
                              controller.chooseTableSize(row, column),
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              controller.chooseTableSize(row, column);
                              controller.insertTable();
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 70),
                              decoration: BoxDecoration(
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : palette.controlBackground,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.small,
                                ),
                                border: Border.all(
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : palette.controlBorder,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Columns × rows',
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: AppTypeScale.small,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SlashMenuPosition extends SingleChildLayoutDelegate {
  const _SlashMenuPosition({required this.anchor, required this.safeArea});

  final Rect anchor;
  final EdgeInsets safeArea;

  static const double _margin = 8;
  static const double _gap = 7;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.max(0.0, constraints.maxWidth - _margin * 2);
    final height = math.max(
      0.0,
      constraints.maxHeight - safeArea.top - safeArea.bottom - _margin * 2,
    );
    return BoxConstraints.loose(Size(width, height)).copyWith(
      maxWidth: math.min(348.0, width),
      maxHeight: math.min(540.0, height),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = _clamp(
      anchor.left,
      _margin,
      size.width - childSize.width - _margin,
    );
    final below = anchor.bottom + _gap;
    final bottomEdge = size.height - safeArea.bottom - _margin;
    final top = below + childSize.height <= bottomEdge
        ? below
        : _clamp(
            anchor.top - _gap - childSize.height,
            safeArea.top + _margin,
            bottomEdge - childSize.height,
          );
    return Offset(left, top);
  }

  static double _clamp(double value, double low, double high) =>
      high <= low ? low : math.min(math.max(value, low), high);

  @override
  bool shouldRelayout(_SlashMenuPosition oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.safeArea != safeArea;
}
