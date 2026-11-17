import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../floating_surface.dart';
import 'slash_commands.dart';

enum _CommandGroup {
  insert('Insert'),
  write('Write'),
  blocks('Blocks');

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
  final List<String> aliases;
  final bool requiresMarkdown;

  String get searchText =>
      '$label ${group.label} ${aliases.join(' ')}'.toLowerCase();
}

/// In the order the menu lists them, a group at a time.
const _definitions = [
  _SlashCommandDefinition(
    type: SlashCommandType.image,
    group: _CommandGroup.insert,
    label: 'Image',
    description: 'Take or choose a picture',
    icon: KapyIcons.imageOutlined,
    aliases: ['photo', 'picture', 'camera'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.video,
    group: _CommandGroup.insert,
    label: 'Video',
    description: 'Choose a video',
    icon: KapyIcons.videoOutlined,
    aliases: ['movie'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.voiceNote,
    group: _CommandGroup.insert,
    label: 'Voice note',
    description: 'Record audio here',
    icon: KapyIcons.micRounded,
    aliases: ['voice', 'audio', 'record'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.drawing,
    group: _CommandGroup.insert,
    label: 'Drawing',
    description: 'Start a new drawing',
    icon: KapyIcons.penRounded,
    aliases: ['sketch', 'draw', 'pen'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.file,
    group: _CommandGroup.insert,
    label: 'File',
    description: 'Attach any file to open on your other devices',
    icon: KapyIcons.attachFileRounded,
    aliases: ['attach', 'attachment', 'upload', 'document', 'pdf'],
  ),
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
    aliases: ['bullet', 'unordered'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.numberedList,
    group: _CommandGroup.write,
    label: 'Numbered list',
    description: 'Start an ordered list',
    icon: KapyIcons.numberedListRounded,
    trigger: '1.',
    aliases: ['number', 'ordered'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.quote,
    group: _CommandGroup.write,
    label: 'Quote',
    description: 'Set text apart as a quote',
    icon: KapyIcons.quoteRounded,
    trigger: '>',
    aliases: ['blockquote'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.table,
    group: _CommandGroup.blocks,
    label: 'Table',
    description: 'Simple rows and columns',
    icon: KapyIcons.tableRounded,
    aliases: ['grid', 'rows', 'columns'],
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.divider,
    group: _CommandGroup.blocks,
    label: 'Divider',
    description: 'Separate sections with a line',
    icon: KapyIcons.dividerRounded,
    trigger: '---',
    aliases: ['rule', 'separator', 'line'],
    requiresMarkdown: true,
  ),
  _SlashCommandDefinition(
    type: SlashCommandType.codeBlock,
    group: _CommandGroup.blocks,
    label: 'Code block',
    description: 'A fenced block of code',
    icon: KapyIcons.codeRounded,
    trigger: '```',
    aliases: ['code', 'snippet'],
    requiresMarkdown: true,
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
  bool _markdownEnabled = false;
  bool _choosingTable = false;
  int _selectedIndex = 0;
  int _tableRows = 2;
  int _tableColumns = 2;
  ValueChanged<SlashCommandChoice>? _onSelected;
  ValueChanged<bool>? _onDismissed;

  bool get isVisible => _entry != null;
  Rect get anchor => _anchor;
  bool get markdownEnabled => _markdownEnabled;
  bool get choosingTable => _choosingTable;
  int get selectedIndex => _selectedIndex;
  int get tableRows => _tableRows;
  int get tableColumns => _tableColumns;

  List<_SlashCommandDefinition> get _commands {
    final available = _definitions.where(
      (definition) => _available.contains(definition.type),
    );
    final words = _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    if (words.isEmpty) return available.toList(growable: false);
    return available
        .where((definition) => words.every(definition.searchText.contains))
        .toList(growable: false);
  }

  void show(
    BuildContext context, {
    required Rect anchor,
    required String query,
    required Set<SlashCommandType> available,
    required bool markdownEnabled,
    Map<SlashCommandType, String> hints = const {},
    required ValueChanged<SlashCommandChoice> onSelected,
    required ValueChanged<bool> onDismissed,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final queryChanged = query != _query;
    _anchor = anchor;
    _query = query;
    _available = Set.unmodifiable(available);
    _hints = hints;
    _markdownEnabled = markdownEnabled;
    _onSelected = onSelected;
    _onDismissed = onDismissed;
    if (queryChanged) {
      _choosingTable = false;
      _selectedIndex = 0;
    }
    _clampSelection();

    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (context) => _SlashCommandOverlay(controller: this),
      );
      overlay.insert(_entry!);
    }
    notifyListeners();
  }

  void hide({bool userInitiated = false}) {
    final dismissed = _onDismissed;
    _remove();
    dismissed?.call(userInitiated);
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
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

    final visible = _commands;
    if (key == LogicalKeyboardKey.arrowUp && visible.isNotEmpty) {
      selectIndex((_selectedIndex - 1) % visible.length);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown && visible.isNotEmpty) {
      selectIndex((_selectedIndex + 1) % visible.length);
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
    final top = _CommandList.rowTop(
      widget.controller._commands,
      widget.controller.selectedIndex,
    );
    final bottom = top + _CommandList.rowHeight;
    final position = _scroll.position;
    if (top < position.pixels) {
      _scroll.animateTo(
        top,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (bottom > position.pixels + position.viewportDimension) {
      _scroll.animateTo(
        bottom - position.viewportDimension,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
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
    final curve = CurvedAnimation(parent: _animation, curve: Curves.easeOut);
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
                  child: FloatingSurface(
                    key: const ValueKey('slash-command-menu'),
                    padding: const EdgeInsets.all(6),
                    child: widget.controller.choosingTable
                        ? _TableSizePicker(controller: widget.controller)
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
      ],
    );
  }
}

class _CommandList extends StatelessWidget {
  const _CommandList({required this.controller, required this.scroll});

  final SlashCommandMenuController controller;
  final ScrollController scroll;

  static const double rowHeight = 32;
  static const double headerHeight = 26;

  /// Where row [index] of [commands] starts in the list, past the group
  /// headers above it.
  static double rowTop(List<_SlashCommandDefinition> commands, int index) {
    var top = 0.0;
    for (var i = 0; i <= index && i < commands.length; i++) {
      if (i == 0 || commands[i - 1].group != commands[i].group) {
        top += headerHeight;
      }
      if (i < index) top += rowHeight;
    }
    return top;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final commands = controller._commands;
    final heading = TextStyle(
      color: palette.textTertiary,
      fontSize: AppTypeScale.small,
      fontWeight: FontWeight.w600,
    );
    if (commands.isEmpty) {
      return SizedBox(
        width: 260,
        child: Padding(
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
      );
    }
    return SizedBox(
      width: 260,
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.min(400.0, constraints.maxHeight),
          ),
          child: ListView(
            key: const ValueKey('slash-command-list'),
            controller: scroll,
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              for (final (index, command) in commands.indexed) ...[
                if (index == 0 || commands[index - 1].group != command.group)
                  Container(
                    height: headerHeight,
                    alignment: Alignment.bottomLeft,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                    child: Semantics(
                      header: true,
                      child: Text(command.group.label, style: heading),
                    ),
                  ),
                _CommandRow(
                  key: ValueKey('slash-command-${command.type.name}'),
                  command: command,
                  hint: controller._hints[command.type] ?? command.trigger,
                  selected: index == controller.selectedIndex,
                  markdownEnabled: controller.markdownEnabled,
                  onHover: () => controller.selectIndex(index),
                  onPressed: () => controller.activateIndex(index),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One command on one line: its icon and name, and on the right the key
/// that does the same, or what typed at the start of a line does.
class _CommandRow extends StatelessWidget {
  const _CommandRow({
    super.key,
    required this.command,
    required this.hint,
    required this.selected,
    required this.markdownEnabled,
    required this.onHover,
    required this.onPressed,
  });

  final _SlashCommandDefinition command;
  final String? hint;
  final bool selected;
  final bool markdownEnabled;
  final VoidCallback onHover;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final requiresMarkdown = command.requiresMarkdown && !markdownEnabled;
    final hint = requiresMarkdown ? 'Markdown' : this.hint;
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
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: SizedBox(
              height: _CommandList.rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    KapyIcon(
                      command.icon,
                      size: 16,
                      color: selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        command.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: AppTypeScale.control,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (hint != null)
                      Text(
                        hint,
                        maxLines: 1,
                        style: TextStyle(
                          color: palette.textTertiary,
                          fontFamily: requiresMarkdown ? null : AppFonts.mono,
                          fontFamilyFallback: requiresMarkdown
                              ? null
                              : AppFonts.monoFallback,
                          fontSize: AppTypeScale.small,
                        ),
                      ),
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
                          fontWeight: FontWeight.w600,
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
                                borderRadius: BorderRadius.circular(4),
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
      maxHeight: math.min(440.0, height),
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
