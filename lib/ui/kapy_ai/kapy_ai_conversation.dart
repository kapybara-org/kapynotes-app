import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/mobile_data.dart';
import '../../core/phone_keyboard.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../kapy_cursor_peek.dart';
import '../mobile_data_sheet.dart';
import '../settings_rows.dart' show SettingsPie;
import 'kapy_ai_markdown.dart';
import 'kapy_ai_parts.dart';

/// Kapy AI's conversation: what a new chat says, the questions and answers,
/// and the notice that holds up a question until it is dealt with.

/// A chat with nothing in it yet: Kapy, one line, three questions to start
/// from, and the promise about Hidden notes.
class KapyAiEmpty extends StatelessWidget {
  const KapyAiEmpty({
    super.key,
    required this.suggestions,
    required this.onAsk,
    this.menu,
  });

  final List<String> suggestions;
  final ValueChanged<String> onAsk;

  /// The picker's menu while it is open over this chat.
  final GlobalKey? menu;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 20).clamp(0, double.infinity),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: [
                    // The peeking Kapy, its head and paw only: the top of
                    // the 136 × 256 pose at 72 px wide.
                    _ClearOfMenu(
                      menu: menu,
                      child: SizedBox(
                        width: 72,
                        height: 76,
                        child: Image.asset(
                          KapyCursorPeek.assetPath,
                          fit: BoxFit.fitWidth,
                          alignment: Alignment.topCenter,
                          excludeFromSemantics: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Ask about anything in your notes',
                      textAlign: TextAlign.center,
                      style: kapyText(
                        14.5,
                        20,
                        palette.textPrimary,
                        weight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 18),
                    for (final suggestion in suggestions) ...[
                      if (suggestion != suggestions.first)
                        const SizedBox(height: 6),
                      _Suggestion(suggestion, onTap: () => onAsk(suggestion)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  KapyIcon(
                    KapyIcons.lockRounded,
                    size: 13,
                    color: palette.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Hidden notes are never used',
                    style: kapyText(12, 16, palette.textTertiary),
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

/// While the picker's [menu] is open, Kapy is painted only when the menu's
/// top clears the whole head, so the menu never cuts it in two; the paw below
/// the chin may go under the menu. Decided as it paints, when the menu has
/// already been laid out beside it.
class _ClearOfMenu extends SingleChildRenderObjectWidget {
  const _ClearOfMenu({required this.menu, super.child});

  final GlobalKey? menu;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderClearOfMenu()..menu = menu;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderClearOfMenu renderObject,
  ) => renderObject
    ..menu = menu
    ..markNeedsPaint();
}

class _RenderClearOfMenu extends RenderProxyBox {
  /// Ears to chin: the top 56 px of the 76.
  static const _head = 56.0;

  GlobalKey? menu;

  @override
  void paint(PaintingContext context, Offset offset) {
    final box = menu?.currentContext?.findRenderObject();
    if (box is RenderBox &&
        box.hasSize &&
        localToGlobal(const Offset(0, _head)).dy >
            box.localToGlobal(Offset.zero).dy) {
      return;
    }
    super.paint(context, offset);
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion(this.text, {required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
      side: BorderSide(color: palette.separator),
    );
    return KeepsKeyboard(
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          hoverColor: palette.kapyMenu,
          onTap: onTap,
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 12),
              child: Row(
                children: [
                  KapyIcon(
                    KapyIcons.sparklesOutlined,
                    size: 14,
                    color: palette.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kapyText(
                        13,
                        16,
                        palette.textSubheading,
                        weight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chat: each question on the right, each answer under it, and whatever
/// holds up the last question beneath it. Anchored to the bottom, the way a
/// conversation grows.
///
/// [compact] is a phone's sheet resting over the note (M10): larger type, the
/// chat from the top, and each answer without its Copy and source line, which
/// the sheet shows at full height.
class KapyAiConversation extends StatelessWidget {
  const KapyAiConversation({
    super.key,
    required this.kapyAi,
    required this.chat,
    required this.noteTitle,
    required this.onOpenNote,
    required this.onPickAnother,
    required this.onManageAccounts,
    required this.now,
    this.onSignIn,
    this.onUpgrade,
    this.compact = false,
  });

  final bool compact;

  final KapyAi kapyAi;
  final KapyChat chat;
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;
  final VoidCallback onPickAnother;
  final VoidCallback onManageAccounts;
  final VoidCallback? onSignIn;
  final VoidCallback? onUpgrade;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final pending = kapyAi.pending;
    final waiting =
        pending == null &&
        kapyAi.answering &&
        chat.messages.lastOrNull?.role == KapyRole.user;
    final children = [
      for (final message in chat.messages)
        message.role == KapyRole.user
            ? _Question(message.text, compact: compact)
            : _Answer(
                message: message,
                sources: kapyAi.linkSources(chat, message),
                noteTitle: noteTitle,
                onOpenNote: onOpenNote,
                now: now,
                compact: compact,
              ),
      if (pending != null)
        KapyAiNotice(
          kapyAi: kapyAi,
          pending: pending,
          onPickAnother: onPickAnother,
          onManageAccounts: onManageAccounts,
          onSignIn: onSignIn,
          onUpgrade: onUpgrade,
        ),
      if (waiting) const _Thinking(),
    ];
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children) ...[
          if (child != children.first) SizedBox(height: compact ? 16 : 18),
          child,
        ],
      ],
    );
    if (!compact) {
      return SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: column,
      );
    }
    const padding = EdgeInsets.fromLTRB(20, 20, 20, 12);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        reverse: true,
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (box.maxHeight - padding.vertical).clamp(
              0,
              double.infinity,
            ),
          ),
          child: Align(alignment: Alignment.topCenter, child: column),
        ),
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.text, {required this.compact});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 40),
        child: Align(
          alignment: Alignment.centerRight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.hover,
              borderRadius: BorderRadius.circular(AppRadii.surface),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(text, style: kapyText(15, 20, palette.textPrimary)),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.kapyHighlight,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.surface),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              text,
              style: kapyText(
                13.5,
                20,
                palette.textPrimary,
                weight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({
    required this.message,
    required this.sources,
    required this.noteTitle,
    required this.onOpenNote,
    required this.now,
    required this.compact,
  });

  final KapyMessage message;
  final String sources;
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;
  final DateTime now;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final source = message.model?.sourceLine(kapyDeviceWord);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KapyAiMarkdown(
          message.text,
          sources: sources,
          style: compact ? kapyText(15, 22, palette.textPrimary) : null,
        ),
        if (message.read.isNotEmpty) ...[
          const SizedBox(height: 10),
          _NotesRead(
            message: message,
            noteTitle: noteTitle,
            onOpenNote: onOpenNote,
            now: now,
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              KapyAiIconButton(
                key: const ValueKey('kapy-ai-copy'),
                icon: KapyIcons.copyRounded,
                tooltip: 'Copy',
                extent: 28,
                iconSize: 15,
                radius: AppRadii.control,
                color: palette.textTertiary,
                onPressed: () {
                  unawaited(
                    Clipboard.setData(ClipboardData(text: message.text)),
                  );
                  Toast.show(context, 'Copied', icon: KapyIcons.copyRounded);
                },
              ),
              const SizedBox(width: 6),
              if (source != null)
                Flexible(
                  child: Text(
                    source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kapyText(11.5, 16, palette.textTertiary),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Read 3 of the 7 matching notes", and the three, each opening its note.
class _NotesRead extends StatelessWidget {
  const _NotesRead({
    required this.message,
    required this.noteTitle,
    required this.onOpenNote,
    required this.now,
  });

  final KapyMessage message;
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final read = message.read.length;
    final matching = message.matching < read ? read : message.matching;
    final heading = read == matching
        ? 'Read the ${matching == 1 ? 'one matching note' : '$matching matching notes'}'
        : 'Read $read of the $matching matching notes';
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
              child: Text(
                heading,
                style: kapyText(
                  12,
                  16,
                  palette.textTertiary,
                  weight: FontWeight.w400,
                ),
              ),
            ),
            for (final note in message.read)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _NoteRow(
                  // A note deleted or hidden since, here or on the device the
                  // chat synced from, is named as gone rather than opened.
                  title: noteTitle(note.noteId),
                  day: kapyDay(note.edited, now),
                  onTap: () => onOpenNote(note.noteId),
                  noteId: note.noteId,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.title,
    required this.day,
    required this.onTap,
    required this.noteId,
  });

  final String? title;
  final String day;
  final VoidCallback onTap;
  final String noteId;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final title = this.title;
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(AppRadii.compact),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('kapy-ai-read-$noteId'),
        hoverColor: palette.kapyMenu,
        onTap: title == null ? null : onTap,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.noteOutlined,
                  size: 14,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title ?? 'Note not available',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kapyText(
                      13,
                      16,
                      title == null
                          ? palette.textTertiary
                          : palette.textSubheading,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(day, style: kapyText(12, 16, palette.textTertiary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Said while an answer is on its way and nothing of it has arrived yet.
class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Text(
    'Reading your notes…',
    key: const ValueKey('kapy-ai-thinking'),
    style: kapyText(12.5, 18, context.palette.textTertiary),
  );
}

/// What holds up the last question (kapy-ai-7/8): a title, why, and the one
/// or two actions that move it on.
class KapyAiNotice extends StatelessWidget {
  const KapyAiNotice({
    super.key,
    required this.kapyAi,
    required this.pending,
    required this.onPickAnother,
    required this.onManageAccounts,
    this.onSignIn,
    this.onUpgrade,
  });

  final KapyAi kapyAi;
  final KapyPending pending;
  final VoidCallback onPickAnother;

  /// Settings › Voice & AI, where a key or an account of the person's own is
  /// added.
  final VoidCallback onManageAccounts;

  /// Settings › Account & sync. Null in a build with nobody to sign in as.
  final VoidCallback? onSignIn;

  /// The Pro sheet. Null where there's no plan to show.
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ai = kapyAi;
    final device = ai.device.model;
    final word = kapyDeviceWord;
    final usable = switch (ai.device.status) {
      DeviceModelStatus.unavailable ||
      DeviceModelStatus.needsSystemFeature => null,
      _ => device,
    };
    KapyAiButton use(KapyModel model) => KapyAiButton(
      // "On this device" is a description that cannot follow "Use"; Apple
      // Intelligence is the name the sentence above uses, and the row the
      // person would otherwise have picked from.
      model.kind == KapyModelKind.device && model.id != 'apple'
          ? 'Use this device'
          : 'Use ${model.plainLabel}',
      onPressed: () => unawaited(ai.answerWith(model)),
    );
    // "On this device" is a description, not a name to put in a sentence.
    String named(KapyModel model, {bool first = false}) =>
        model.kind == KapyModelKind.device && model.id != 'apple'
        ? '${first ? 'This' : 'this'} $word'
        : model.plainLabel;
    final pickAnother = KapyAiButton('Pick another', onPressed: onPickAnother);
    // The first two are the likeliest to work; the rest stay reachable through
    // the picker rather than crowding the card.
    List<KapyAiButton> offersIn(
      List<KapyModel> fallbacks, {
      bool alwaysPick = false,
    }) => [
      for (final other in fallbacks.take(2)) use(other),
      if (alwaysPick || fallbacks.length > 2) pickAnother,
    ];
    final goAhead = KapyAiButton(
      'Go ahead',
      filled: true,
      onPressed: () => unawaited(ai.proceed()),
    );
    final tryAgain = KapyAiButton(
      'Try again',
      onPressed: () => unawaited(ai.proceed()),
    );
    final deviceName = device?.id == 'apple'
        ? 'Apple Intelligence'
        : 'the on-device model';
    final (icon, title, lines, actions) = switch (pending) {
      KapyCloudConsent(:final recording) => (
        KapyIcons.cloudRounded,
        'Before the first answer',
        recording
            ? [
                'Kapy AI sends your question and this transcript through Kapy '
                    'cloud, where an AI service answers it. Kapy keeps '
                    'nothing, and it is never used to train AI.',
              ]
            : [
                'Kapy AI sends your question and only the notes that match it '
                    'through Kapy cloud, where an AI service answers it. Kapy '
                    'keeps nothing, and it is never used to train AI.',
                'Hidden notes are never used, locked or unlocked.',
              ],
        [
          goAhead,
          if (usable != null)
            KapyAiButton(
              'Use this device',
              onPressed: () => unawaited(ai.answerWith(usable)),
            ),
        ],
      ),
      KapyAccountConsent(:final account) => (
        kapyAccountIcon(account),
        'Leaves this $word',
        [
          switch (account) {
            KapyAccountKind.codex =>
              'Your question and the notes it reads leave this $word through '
                  'Codex, under your ChatGPT plan. Hidden notes never do. '
                  'Turn this off in Settings › Voice & AI.',
            KapyAccountKind.claudeCode =>
              'Your question and the notes it reads leave this $word through '
                  'Claude Code. Hidden notes never do. Turn this off in '
                  'Settings › Voice & AI.',
            KapyAccountKind.openRouter =>
              'Your question and the notes it reads leave this $word through '
                  'your key. Hidden notes never do. Turn this off in '
                  'Settings › Voice & AI.',
          },
        ],
        [goAhead, pickAnother],
      ),
      KapyDownloadAsk(:final totalBytes) => (
        KapyIcons.downloadRounded,
        'Download $deviceName first',
        [
          'A one-time ${kapyGigabytes(totalBytes)} GB download. Your question '
              'is answered on this $word as soon as it’s done.',
        ],
        [
          KapyAiButton(
            'Download ${kapyGigabytes(totalBytes)} GB',
            filled: true,
            onPressed: () => unawaited(
              _download(context, ai, name: deviceName, bytes: totalBytes),
            ),
          ),
          KapyAiButton('Not now', onPressed: ai.dismissPending),
        ],
      ),
      KapyDownloading() => (
        KapyIcons.downloadRounded,
        'Getting $deviceName ready',
        [
          'A one-time download. Your question is answered on this $word as '
              'soon as it’s done.',
        ],
        [
          KapyAiButton(
            'Cancel',
            onPressed: () {
              ai.cancelDeviceDownload();
              ai.dismissPending();
            },
          ),
        ],
      ),
      KapyLimitReached(:final resetsAt, :final fallback) => (
        KapyIcons.scheduleRounded,
        'No answers left until ${resetsAt.day} '
            '${kapyMonths[resetsAt.month - 1].substring(0, 3)}',
        [
          // The allowance is the account's own (a trial gets fewer than a
          // subscription), so it is read, never assumed.
          [
            if (ai.cloudUsage case CloudUsage(:final limit))
              'Kapy AI Cloud gives $limit answers a month.'
            else
              'Kapy AI Cloud’s answers for the month are used up.',
            'Until then, ${fallback == null ? 'your accounts' : '${named(fallback)} and your accounts'} '
                'still answer.',
          ].join(' '),
        ],
        [?(fallback == null ? null : use(fallback))],
      ),
      KapyOffline(:final fallback) => (
        KapyIcons.wifiOffRounded,
        'You’re offline',
        [
          [
            '${ai.model.plainLabel} needs a connection.',
            if (fallback != null)
              '${named(fallback, first: true)} answers offline.',
          ].join(' '),
        ],
        [?(fallback == null ? null : use(fallback)), tryAgain],
      ),
      KapyAccountError(:final account, :final fallbacks) => (
        KapyIcons.warningRounded,
        account == KapyAccountKind.openRouter
            ? 'This key was rejected'
            : '${kapyAccountName(account)} is signed out',
        [
          account == KapyAccountKind.openRouter
              ? 'Check the key in Settings.'
              : 'Sign in inside ${kapyAccountName(account)}, then check '
                    'again.',
        ],
        [
          switch (account) {
            KapyAccountKind.openRouter => KapyAiButton(
              'Open Settings',
              onPressed: onManageAccounts,
            ),
            KapyAccountKind.codex => KapyAiButton(
              'Check again',
              onPressed: () => unawaited(_checkThenAnswer(ai.checkCodex)),
            ),
            KapyAccountKind.claudeCode => KapyAiButton(
              'Check again',
              onPressed: () => unawaited(_checkThenAnswer(ai.checkClaudeCode)),
            ),
          },
          ...offersIn(fallbacks, alwaysPick: true),
        ],
      ),
      final KapyCloudLocked locked => _locked(locked, [
        for (final other in locked.fallbacks.take(1)) use(other),
      ]),
      KapyFailed(:final message, :final fallbacks, :final retry) => (
        KapyIcons.warningRounded,
        'Couldn’t answer',
        [message],
        [...offersIn(fallbacks, alwaysPick: !retry), if (retry) tryAgain],
      ),
    };
    return DecoratedBox(
      key: const ValueKey('kapy-ai-notice'),
      decoration: BoxDecoration(
        color: palette.editorBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                KapyIcon(icon, size: 15, color: palette.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: kapyText(
                      13.5,
                      16,
                      palette.textPrimary,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            if (pending case KapyDownloading(:final received, :final total))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    SettingsPie(fraction: total == 0 ? null : received / total),
                    const SizedBox(width: 6),
                    Text(
                      '${kapyGigabytes(received)} of ${kapyGigabytes(total)} GB',
                      style: kapyText(12.5, 18, palette.textSecondary),
                    ),
                  ],
                ),
              ),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  line,
                  style: kapyText(12.5, 18, palette.textSecondary),
                ),
              ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 8, runSpacing: 8, children: actions),
              ),
          ],
        ),
      ),
    );
  }

  /// Kapy AI Cloud won't answer yet: what the person can do about it, and
  /// [offers] of what answers instead. Signing in and upgrading come first,
  /// then their own AI account, which works on any plan.
  (KapyIconData, String, List<String>, List<KapyAiButton>) _locked(
    KapyCloudLocked locked,
    List<KapyAiButton> offers,
  ) {
    final signIn = locked.signIn ? onSignIn : null;
    final upgrade = locked.upgrade ? onUpgrade : null;
    final (title, line) = switch ((signIn != null, upgrade != null)) {
      (true, true) => (
        'Kapy AI Cloud is part of Pro',
        'Sign in if you have Pro, or upgrade. You can also use your own AI '
            'account.',
      ),
      (false, true) => (
        'Kapy AI Cloud is part of Pro',
        'Upgrade to get answers from it. You can also use your own AI '
            'account.',
      ),
      (true, false) => (
        'Sign in to use Kapy AI Cloud',
        'You’re signed out on this $kapyDeviceWord. Sign in again, or use '
            'your own AI account.',
      ),
      (false, false) => (
        'Kapy AI Cloud is part of Pro',
        'Use your own AI account to get answers here.',
      ),
    };
    return (
      KapyIcons.cloudRounded,
      title,
      [line],
      [
        if (signIn != null)
          KapyAiButton('Sign in', filled: true, onPressed: signIn),
        if (upgrade != null)
          KapyAiButton('Upgrade', filled: signIn == null, onPressed: upgrade),
        KapyAiButton('Use your own account', onPressed: onManageAccounts),
        ...offers,
      ],
    );
  }

  /// Check again: looks for the tool once more, then answers the question
  /// it held up.
  Future<void> _checkThenAnswer(Future<void> Function() check) async {
    await check();
    await kapyAi.proceed();
  }
}

/// Downloads the device model, asking first when that would spend mobile
/// data.
Future<void> _download(
  BuildContext context,
  KapyAi ai, {
  required String name,
  required int bytes,
}) async {
  if (bytes > MobileData.askAboveBytes &&
      await ai.deviceDownloadOnMobileData()) {
    if (!context.mounted) return;
    final choice = await showMobileDataSheet(context, name: name, bytes: bytes);
    if (choice == MobileDataChoice.onWifi) ai.downloadDeviceModelOnWifi();
    if (choice != MobileDataChoice.now) return;
  }
  await ai.proceed();
}
