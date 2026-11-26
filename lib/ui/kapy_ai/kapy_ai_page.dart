import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/phone_keyboard.dart';
import '../../core/theme.dart';
import '../back_entry.dart';
import '../sidebar_timestamp.dart';
import 'kapy_ai_parts.dart';
import 'kapy_ai_picker.dart';

/// Kapy AI on a phone, its own page from the bar (M04): New chat, Search
/// chats, the past chats grouped as the panel groups them, and Ask Kapy AI.
///
/// It keeps no chats of its own. Opening one, starting one and asking all go
/// through [kapyAi], and then [onOpenChat] shows the conversation, so what is
/// stored and synced is exactly what the panel stores and syncs.
class KapyAiPage extends StatefulWidget {
  const KapyAiPage({
    super.key,
    required this.kapyAi,
    required this.onOpenChat,
    required this.onManageAccounts,
    required this.account,
    this.now = DateTime.now,
  });

  final KapyAi kapyAi;

  /// A chat was opened or started, or a question asked: show the
  /// conversation.
  final VoidCallback onOpenChat;

  /// Settings › Voice & AI at Your accounts, from the picker.
  final VoidCallback onManageAccounts;

  /// The S button at the end of the title row, the same one Home shows.
  final Widget account;
  final DateTime Function() now;

  @override
  State<KapyAiPage> createState() => _KapyAiPageState();
}

/// Text that names, describes or waits: #968E7F in the crisp pass, which the
/// palette has no colour for yet.
const _quiet = Color(0xFF968E7F);

class _KapyAiPageState extends State<KapyAiPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'kapy-ai-page-search');
  final _field = TextEditingController();
  bool _picking = false;

  /// Back closes the picker before the page goes.
  late final _back = BackEntry(() {
    if (mounted) _setPicking(false);
  });

  KapyAi get _ai => widget.kapyAi;

  void _setPicking(bool picking) {
    setState(() => _picking = picking);
    picking ? _back.open(context) : _back.close();
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _field.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _back.close();
    _search.dispose();
    _searchFocus.dispose();
    _field.dispose();
    super.dispose();
  }

  /// The page's field always starts a chat, so the chat it starts is made
  /// before a model is picked for it: the pick then sticks to the new chat
  /// rather than to whichever chat was open last.
  void _freshChat() {
    if (_ai.current != null) _ai.newChat();
  }

  void _newChat() {
    _ai.newChat();
    _setPicking(false);
    widget.onOpenChat();
  }

  void _open(KapyChat chat) {
    _ai.openChat(chat.id);
    _setPicking(false);
    widget.onOpenChat();
  }

  void _ask() {
    final question = _field.text.trim();
    if (question.isEmpty || _ai.answering) return;
    _freshChat();
    _field.clear();
    _setPicking(false);
    unawaited(_ai.ask(question));
    widget.onOpenChat();
  }

  void _togglePicker() {
    if (!_picking) _freshChat();
    _setPicking(!_picking);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      key: const ValueKey('kapy-ai-page'),
      color: palette.sidebarBackground,
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _ai,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(palette),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: _searchField(palette),
              ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _chats(palette),
                    if (_picking) ...[
                      // Closes the picker and leaves the keyboard up.
                      KeepsKeyboard(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _setPicking(false),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: KapyAiPicker(
                            kapyAi: _ai,
                            onPick: (model) {
                              _ai.pickModel(model);
                              _setPicking(false);
                            },
                            onManageAccounts: () {
                              _setPicking(false);
                              widget.onManageAccounts();
                            },
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _composer(palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(CalcPalette palette) {
    final scaler = MediaQuery.textScalerOf(context);
    // The 26 px name is already large: past 1.3 it would push New chat off a
    // phone's row, so it stops growing there.
    final title = Text(
      'Kapy AI',
      maxLines: 1,
      textScaler: scaler.clamp(maxScaleFactor: 1.3),
      style: TextStyle(
        fontFamily: 'Shantell Sans',
        fontSize: 26,
        height: 32 / 26,
        fontWeight: AppWeight.font(AppWeight.regular),
        fontVariations: AppWeight.wght(AppWeight.regular),
        color: palette.textPrimary,
      ),
    );
    final label = kapyText(
      15,
      20,
      palette.textPrimary,
      weight: FontWeight.w500,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final words = (TextPainter(
              text: TextSpan(text: 'New chat', style: label),
              textScaler: scaler,
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout()).width;
            final named = (TextPainter(
              text: TextSpan(text: 'Kapy AI', style: title.style),
              textScaler: scaler.clamp(maxScaleFactor: 1.3),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout()).width;
            // Sparkles and gap, the name, two gaps, the button's padding,
            // icon and gap, and S.
            final full =
                26 + 8 + named + 12 + 12 + 18 + 6 + words + 12 + 12 + 32;
            final roomy = full <= constraints.maxWidth;
            return Row(
              children: [
                KapyIcon(
                  KapyIcons.sparklesOutlined,
                  size: 22,
                  color: palette.textPrimary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: title),
                ),
                const SizedBox(width: 12),
                _Target(
                  key: const ValueKey('kapy-ai-page-new-chat'),
                  label: 'New chat',
                  onTap: _newChat,
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: 36,
                      minWidth: 36,
                    ),
                    padding: EdgeInsets.symmetric(horizontal: roomy ? 12 : 9),
                    decoration: BoxDecoration(
                      color: palette.textPrimary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KapyIcon(
                          KapyIcons.chatAddOutlined,
                          size: 18,
                          color: palette.textPrimary,
                        ),
                        if (roomy) ...[
                          const SizedBox(width: 6),
                          Text('New chat', maxLines: 1, style: label),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                widget.account,
              ],
            );
          },
        ),
      ),
    );
  }

  /// The whole pill takes a tap, not only its line of text, and is the
  /// field's own, so a tap on it never puts the keyboard away.
  Widget _searchField(CalcPalette palette) => KeepsKeyboard(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _searchFocus.requestFocus,
      child: _searchPill(palette),
    ),
  );

  Widget _searchPill(CalcPalette palette) => Container(
    constraints: const BoxConstraints(minHeight: 36),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: palette.textPrimary.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      children: [
        const KapyIcon(KapyIcons.searchRounded, size: 16, color: _quiet),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: const ValueKey('kapy-ai-page-search'),
            controller: _search,
            focusNode: _searchFocus,
            maxLines: 1,
            textInputAction: TextInputAction.search,
            cursorColor: palette.selectedBorder,
            style: kapyText(15, 20, palette.textPrimary),
            decoration: InputDecoration.collapsed(
              hintText: 'Search chats',
              hintStyle: kapyText(15, 20, _quiet),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _chats(CalcPalette palette) {
    final now = widget.now();
    final groups = kapyChatGroups(_ai.chats, query: _search.text, now: now);
    final searching = _search.text.trim().isNotEmpty;
    final meta = kapyText(13, 16, _quiet);
    return ListView(
      key: const ValueKey('kapy-ai-page-chats'),
      padding: EdgeInsets.zero,
      children: [
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Text(
              searching ? 'No chats match' : 'No chats yet',
              style: kapyText(13, 18, _quiet),
            ),
          ),
        for (final (i, MapEntry(key: label, value: rows))
            in groups.entries.indexed) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(20, i == 0 ? 18 : 14, 20, 6),
            child: Text(
              label,
              style: kapyText(13, 18, _quiet, weight: FontWeight.w600),
            ),
          ),
          for (final chat in rows)
            InkWell(
              key: ValueKey('kapy-ai-page-chat-${chat.id}'),
              onTap: () => _open(chat),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  // Room between rows once larger text fills the 44.
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kapyText(16, 22, palette.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _when(chat.updatedAt, label, now),
                        style: meta.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Text(
            _ai.chatsSync
                ? 'Chats sync across your devices'
                : _ai.isPro
                ? 'Kept on this $kapyDeviceWord. Sign in to sync them'
                : 'Kept on this $kapyDeviceWord. Pro syncs them',
            style: kapyText(12, 16, _quiet),
          ),
        ),
      ],
    );
  }

  /// The time within the last two days, the weekday and date within the
  /// week, and the date before that.
  static String _when(DateTime at, String group, DateTime now) =>
      switch (group) {
        'Today' || 'Yesterday' => SidebarTimestamp.clock(at),
        'Previous 7 days' => '${_weekdays[at.weekday - 1]} ${at.day}',
        _ => kapyDay(at, now),
      };

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  Widget _composer(CalcPalette palette) {
    final typed = _field.text.trim().isNotEmpty;
    final canSend = typed && !_ai.answering;
    return Padding(
      // The bar's Scaffold pads the page by the bar's room, and drops it while
      // the keyboard covers the bar.
      padding: EdgeInsets.fromLTRB(
        16,
        4,
        16,
        MediaQuery.paddingOf(context).bottom + 12,
      ),
      child: KeepsKeyboard(
        child: Container(
          // The row's targets are 44 tall around 28 of button, so the spacing
          // around the row gives back the 8 they add on each side.
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 2),
          decoration: BoxDecoration(
            color: palette.textPrimary.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('kapy-ai-page-field'),
                controller: _field,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onTap: () => _setPicking(false),
                onSubmitted: (_) => _ask(),
                cursorColor: palette.selectedBorder,
                style: kapyText(15, 20, palette.textPrimary),
                decoration: InputDecoration.collapsed(
                  hintText: 'Ask Kapy AI',
                  hintStyle: kapyText(15, 20, _quiet),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _Target(
                        label: 'Answers with ${_ai.model.plainLabel}',
                        onTap: _togglePicker,
                        child: IgnorePointer(
                          child: KapyAiModelButton(
                            kapyAi: _ai,
                            open: _picking,
                            fontSize: 13,
                            weight: FontWeight.w400,
                            onPressed: _togglePicker,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (typed && _ai.answering)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        'Still answering',
                        style: kapyText(12, 16, _quiet),
                      ),
                    ),
                  _Target(
                    key: const ValueKey('kapy-ai-page-send'),
                    label: 'Ask',
                    onTap: canSend ? _ask : null,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: canSend
                            ? palette.totalPillBackground
                            : palette.textPrimary.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: KapyIcon(
                          KapyIcons.sendRounded,
                          size: 16,
                          color: canSend ? palette.totalPillText : _quiet,
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
    );
  }
}

/// A button drawn at its design size inside a 44 × 44 target, the least a
/// finger should have to hit on a phone.
class _Target extends StatelessWidget {
  const _Target({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        child: Align(widthFactor: 1, heightFactor: 1, child: child),
      ),
    ),
  );
}
