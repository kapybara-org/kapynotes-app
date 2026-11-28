import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/theme.dart';
import '../editor/editor_context_menu.dart';
import '../sidebar.dart';
import '../sidebar_timestamp.dart';
import '../tag_colours.dart';
import '../tasks/task_marks.dart';
import 'kapy_ai_parts.dart';

/// Kapy AI on a phone, its own page from the bar (M04), drawn as Notes and
/// Folders are: the title with the account, the search well, and the past
/// chats a day at a time. The bar's + starts a new chat here.
///
/// It keeps no chats of its own. Opening one and asking both go through
/// [kapyAi], and then [onOpenChat] shows the conversation, so what is stored
/// and synced is exactly what the panel stores and syncs.
class KapyAiPage extends StatefulWidget {
  const KapyAiPage({
    super.key,
    required this.kapyAi,
    required this.onOpenChat,
    required this.account,
    this.now = DateTime.now,
  });

  final KapyAi kapyAi;

  /// A chat was opened, or a question asked: show the conversation.
  final VoidCallback onOpenChat;

  /// The S button at the end of the title row, the same one Home shows.
  final Widget account;
  final DateTime Function() now;

  @override
  State<KapyAiPage> createState() => _KapyAiPageState();
}

class _KapyAiPageState extends State<KapyAiPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'kapy-ai-page-search');

  KapyAi get _ai => widget.kapyAi;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(KapyChat chat) {
    _ai.openChat(chat.id);
    widget.onOpenChat();
  }

  void _ask(String question) {
    if (_ai.answering) return;
    _ai.newChat();
    unawaited(_ai.ask(question));
    widget.onOpenChat();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      key: const ValueKey('kapy-ai-page'),
      color: palette.paperColor,
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _ai,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhoneListTitle(title: 'Kapy AI', trailing: widget.account),
              SidebarSearchField(
                phone: true,
                placeholder: 'Search chats',
                query: _search.text,
                onClear: _search.clear,
                onSearch: _searchFocus.requestFocus,
                field: TextField(
                  key: const ValueKey('kapy-ai-page-search'),
                  contextMenuBuilder: kapyTextFieldMenu,
                  controller: _search,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  onTapOutside: (_) => _searchFocus.unfocus(),
                  style: TextStyle(fontSize: 16, color: palette.textPrimary),
                  decoration: InputDecoration.collapsed(
                    hintText: 'Search chats',
                    hintStyle: TextStyle(
                      fontSize: 16,
                      color: palette.textTertiary,
                    ),
                  ),
                ),
              ),
              Expanded(child: _chats(palette)),
            ],
          ),
        ),
      ),
    );
  }

  /// A day at a time, newest first, as Notes is: each chat under the day it
  /// last changed, giving its time alone.
  Widget _chats(CalcPalette palette) {
    final now = widget.now();
    final today = DateTime(now.year, now.month, now.day);
    final chats = kapyChatsMatching(_ai.chats, _search.text);
    if (chats.isEmpty) return _empty();
    final days = <DateTime, List<KapyChat>>{};
    for (final chat in chats) {
      final at = chat.updatedAt;
      final day = DateTime(at.year, at.month, at.day);
      (days[day.isAfter(today) ? today : day] ??= []).add(chat);
    }
    return ListView(
      key: const ValueKey('kapy-ai-page-chats'),
      physics: const AlwaysScrollableScrollPhysics(),
      // Clears the floating bar and its +.
      padding: const EdgeInsets.only(top: 4, bottom: 120),
      children: [
        for (final (i, MapEntry(key: day, value: rows)) in days.entries.indexed)
          if (SidebarTimestamp.phoneDay(day, now: today) case (
            :final lead,
            :final date,
          )) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(20, i == 0 ? 12 : 22, 20, 0),
              child: PhoneDayHeading(lead: lead, date: date),
            ),
            for (final chat in rows) _row(palette, chat),
          ],
      ],
    );
  }

  /// Notes' row: the title, its time at the end, and under them in a quieter
  /// line how the last answer starts.
  Widget _row(CalcPalette palette, KapyChat chat) {
    final answer = _answerStart(chat);
    return InkWell(
      key: ValueKey('kapy-ai-page-chat-${chat.id}'),
      onTap: () => _open(chat),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: uiStyle(
                      17,
                      24,
                      FontWeight.w400,
                      palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  SidebarTimestamp.clock(chat.updatedAt),
                  maxLines: 1,
                  style: metaStyle(13, 16, palette.textTertiary, tabular: true),
                ),
                // Where a note's tag dots go, so times line up with Notes'.
                SizedBox(width: 8 + TagDots.widthFor(TagDots.most)),
              ],
            ),
            if (answer != null) ...[
              const SizedBox(height: 3),
              Text(
                answer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: uiStyle(14, 20, FontWeight.w400, palette.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The first line of words in the chat's last answer, its marks dropped.
  static String? _answerStart(KapyChat chat) {
    final answer = chat.messages.reversed
        .where((message) => message.role == KapyRole.assistant)
        .firstOrNull;
    if (answer == null) return null;
    for (final line in answer.text.split('\n')) {
      final words = line
          .replaceFirst(RegExp(r'^\s*(#+|>|[-*+]|\d+[.)])\s+'), '')
          .replaceAllMapped(
            RegExp(r'\[([^\]]*)\]\([^)]*\)'),
            (link) => link[1]!,
          )
          .replaceAll(RegExp(r'[*_`]'), '')
          .trim();
      if (words.isNotEmpty) return words;
    }
    return null;
  }

  /// Notes' empty list, and with no chats yet, questions to start from.
  Widget _empty() {
    final searching = _search.text.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        key: const ValueKey('kapy-ai-page-chats'),
        padding: const EdgeInsets.only(bottom: 120),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, box.maxHeight - 120),
          ),
          child: SidebarEmpty(
            key: const ValueKey('kapy-ai-page-empty'),
            message: searching ? 'No chats match' : 'No chats yet',
            detail: !searching && _ai.chatsSync
                ? 'Chats sync across your devices'
                : null,
            action: searching
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      for (final (i, question) in kapyAiExamples.indexed)
                        _Example(
                          key: ValueKey('kapy-ai-page-example-$i'),
                          question: question,
                          onTap: () => _ask(question),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A question to start from: a tap asks it in a new chat.
class _Example extends StatelessWidget {
  const _Example({super.key, required this.question, required this.onTap});

  final String question;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shape = BorderRadius.circular(AppRadii.control);
    return Semantics(
      button: true,
      label: question,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: palette.fillRest,
        borderRadius: shape,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                question,
                textAlign: TextAlign.center,
                style: uiStyle(15, 20, FontWeight.w400, palette.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
