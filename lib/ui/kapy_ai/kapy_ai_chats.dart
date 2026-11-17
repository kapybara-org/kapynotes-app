import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import 'kapy_ai_parts.dart';

/// The chats (kapy-ai-3/4): a search, then every chat newest first under
/// Today, Yesterday, Previous 7 days and each month before that.
///
/// Rename edits the row in place, ↵ keeping the new name and Esc the old.
/// Delete asks once, in the row. Neither needs a menu, so a row stays a line
/// of text until the pointer is on it.
class KapyAiChats extends StatefulWidget {
  const KapyAiChats({
    super.key,
    required this.kapyAi,
    required this.now,
    required this.onOpened,
  });

  final KapyAi kapyAi;
  final DateTime now;

  /// After a chat is opened, so the panel can go back to the conversation.
  final VoidCallback onOpened;

  @override
  State<KapyAiChats> createState() => _KapyAiChatsState();
}

class _KapyAiChatsState extends State<KapyAiChats> {
  final _search = TextEditingController();
  final _rename = TextEditingController();

  /// The chat under the pointer, or the one a long press singled out where
  /// there is no pointer to hover with.
  String? _active;
  String? _renaming;
  String? _deleting;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _rename.dispose();
    super.dispose();
  }

  /// Today, Yesterday, Previous 7 days, then the month, with its year when it
  /// is not this one.
  String _groupOf(DateTime when) {
    final now = widget.now;
    final today = DateTime(now.year, now.month, now.day);
    final days = today
        .difference(DateTime(when.year, when.month, when.day))
        .inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days <= 7) return 'Previous 7 days';
    final month = kapyMonths[when.month - 1];
    return when.year == now.year ? month : '$month ${when.year}';
  }

  void _startRename(KapyChat chat) {
    _rename.text = chat.title;
    _rename.selection = TextSelection(
      baseOffset: 0,
      extentOffset: chat.title.length,
    );
    setState(() {
      _renaming = chat.id;
      _deleting = null;
    });
  }

  void _saveRename(KapyChat chat) {
    final title = _rename.text.trim();
    if (title.isNotEmpty && title != chat.title) {
      widget.kapyAi.renameChat(chat.id, title);
    }
    setState(() => _renaming = null);
  }

  void _open(KapyChat chat) {
    widget.kapyAi.openChat(chat.id);
    widget.onOpened();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final query = _search.text.trim().toLowerCase();
    final chats =
        widget.kapyAi.chats
            .where((chat) => chat.title.toLowerCase().contains(query))
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final groups = <String, List<KapyChat>>{};
    for (final chat in chats) {
      (groups[_groupOf(chat.updatedAt)] ??= []).add(chat);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: _SearchField(controller: _search),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              for (final MapEntry(key: label, value: rows) in groups.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                        child: Text(
                          label.toUpperCase(),
                          style: kapyText(
                            11,
                            14,
                            palette.textTertiary,
                            weight: FontWeight.w600,
                          ).copyWith(letterSpacing: 0.44),
                        ),
                      ),
                      for (final chat in rows)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: _row(chat),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 14),
          child: Text(
            widget.kapyAi.isPro
                ? 'Chats sync across your devices'
                : 'Kept on this $kapyDeviceWord. Pro syncs them',
            textAlign: TextAlign.center,
            style: kapyText(11.5, 16, palette.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _row(KapyChat chat) {
    if (chat.id == _renaming) return _renameRow(chat);
    if (chat.id == _deleting) return _deleteRow(chat);
    final palette = context.palette;
    final open = widget.kapyAi.current?.id == chat.id;
    final active = chat.id == _active;
    return MouseRegion(
      onEnter: (_) => setState(() => _active = chat.id),
      onExit: (_) {
        if (_active == chat.id) setState(() => _active = null);
      },
      child: Material(
        color: open
            ? palette.kapyHighlight
            : active
            ? palette.kapyMenu
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('kapy-ai-chat-${chat.id}'),
          hoverColor: Colors.transparent,
          onTap: () => _open(chat),
          onLongPress: AppPlatform.hasPointer
              ? null
              : () => setState(() => _active = chat.id),
          child: SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kapyText(
                        13,
                        16,
                        open ? palette.textPrimary : palette.textSubheading,
                        weight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (active) ...[
                    KapyAiIconButton(
                      key: ValueKey('kapy-ai-rename-${chat.id}'),
                      icon: KapyIcons.chatEditOutlined,
                      tooltip: 'Rename',
                      extent: 26,
                      iconSize: 14,
                      radius: 7,
                      onPressed: () => _startRename(chat),
                    ),
                    KapyAiIconButton(
                      key: ValueKey('kapy-ai-delete-${chat.id}'),
                      icon: KapyIcons.deleteOutlined,
                      tooltip: 'Delete',
                      extent: 26,
                      iconSize: 14,
                      radius: 7,
                      onPressed: () => setState(() {
                        _deleting = chat.id;
                        _renaming = null;
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _renameRow(KapyChat chat) {
    final palette = context.palette;
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 9, right: 4),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.selectedBorder, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Focus(
              // Esc keeps the old name and stops there: the panel would
              // otherwise take the same key as "close".
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() => _renaming = null);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                key: const ValueKey('kapy-ai-rename-field'),
                controller: _rename,
                autofocus: true,
                maxLines: 1,
                cursorColor: palette.selectedBorder,
                style: kapyText(
                  13,
                  16,
                  palette.textPrimary,
                  weight: FontWeight.w500,
                ),
                decoration: const InputDecoration.collapsed(hintText: null),
                onSubmitted: (_) => _saveRename(chat),
              ),
            ),
          ),
          KapyAiIconButton(
            icon: KapyIcons.checkRounded,
            tooltip: 'Save',
            extent: 26,
            iconSize: 14,
            radius: 7,
            color: palette.accentText,
            onPressed: () => _saveRename(chat),
          ),
        ],
      ),
    );
  }

  Widget _deleteRow(KapyChat chat) {
    final palette = context.palette;
    return Container(
      key: ValueKey('kapy-ai-delete-confirm-${chat.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Delete “${chat.title}”? This can’t be undone.',
            style: kapyText(12.5, 18, palette.textSubheading),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              KapyAiButton(
                'Delete',
                destructive: true,
                onPressed: () {
                  widget.kapyAi.deleteChat(chat.id);
                  setState(() => _deleting = null);
                },
              ),
              const SizedBox(width: 8),
              KapyAiButton(
                'Cancel',
                onPressed: () => setState(() => _deleting = null),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          KapyIcon(
            KapyIcons.searchRounded,
            size: 14,
            strokeWidth: 1.8,
            color: palette.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('kapy-ai-chat-search'),
              controller: controller,
              maxLines: 1,
              style: kapyText(13, 16, palette.textPrimary),
              decoration: InputDecoration.collapsed(
                hintText: 'Search chats',
                hintStyle: kapyText(13, 16, palette.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
