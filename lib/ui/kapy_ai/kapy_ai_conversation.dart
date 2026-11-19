import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/mobile_data.dart';
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
  });

  final List<String> suggestions;
  final ValueChanged<String> onAsk;

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
                    SizedBox(
                      width: 72,
                      height: 76,
                      child: Image.asset(
                        KapyCursorPeek.assetPath,
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        excludeFromSemantics: true,
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
                    strokeWidth: 1.8,
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
    return Material(
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
                  strokeWidth: 1.8,
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
    );
  }
}

/// The chat: each question on the right, each answer under it, and whatever
/// holds up the last question beneath it. Anchored to the bottom, the way a
/// conversation grows.
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
  });

  final KapyAi kapyAi;
  final KapyChat chat;
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;
  final VoidCallback onPickAnother;
  final VoidCallback onManageAccounts;
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
            ? _Question(message.text)
            : _Answer(
                message: message,
                sources: kapyAi.linkSources(chat, message),
                noteTitle: noteTitle,
                onOpenNote: onOpenNote,
                now: now,
              ),
      if (pending != null)
        KapyAiNotice(
          kapyAi: kapyAi,
          pending: pending,
          onPickAnother: onPickAnother,
          onManageAccounts: onManageAccounts,
        ),
      if (waiting) const _Thinking(),
    ];
    return SingleChildScrollView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in children) ...[
            if (child != children.first) const SizedBox(height: 18),
            child,
          ],
        ],
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
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
  });

  final KapyMessage message;
  final String sources;
  final String? Function(String noteId) noteTitle;
  final ValueChanged<String> onOpenNote;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final source = message.model?.sourceLine(kapyDeviceWord);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KapyAiMarkdown(message.text, sources: sources),
        const SizedBox(height: 10),
        if (message.read.isNotEmpty) ...[
          _NotesRead(
            message: message,
            noteTitle: noteTitle,
            onOpenNote: onOpenNote,
            now: now,
          ),
          const SizedBox(height: 10),
        ],
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
                unawaited(Clipboard.setData(ClipboardData(text: message.text)));
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
                  strokeWidth: 1.8,
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
  });

  final KapyAi kapyAi;
  final KapyPending pending;
  final VoidCallback onPickAnother;
  final VoidCallback onManageAccounts;

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
      'Use ${model.label}',
      onPressed: () => unawaited(ai.answerWith(model)),
    );
    final pickAnother = KapyAiButton('Pick another', onPressed: onPickAnother);
    final goAhead = KapyAiButton(
      'Go ahead',
      filled: true,
      onPressed: () => unawaited(ai.proceed()),
    );
    final tryAgain = KapyAiButton(
      'Try again',
      onPressed: () => unawaited(ai.proceed()),
    );
    final deviceName = device?.label ?? 'The model';
    final (icon, title, lines, actions) = switch (pending) {
      KapyCloudConsent() => (
        KapyIcons.cloudRounded,
        'Before the first answer',
        [
          'Kapy AI Cloud sends your question and only the notes that match it '
              'through Kapy’s server to the AI model that answers. Kapy keeps '
              'nothing.',
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
        'Goes to ${_provider(account)}',
        [
          switch (account) {
            KapyAccountKind.codex =>
              'Your question and the notes it reads go to OpenAI through '
                  'Codex on this $word, under your ChatGPT plan. Hidden notes '
                  'never do.',
            KapyAccountKind.claudeCode =>
              'Your question and the notes it reads go to Anthropic through '
                  'Claude Code on this $word. Hidden notes never do.',
            KapyAccountKind.openRouter =>
              'Your question and the notes it reads go to OpenRouter'
                  '${_maker(ai.model)} under your key. Hidden notes never do.',
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
            'Until then, ${fallback == null ? 'your accounts' : '${fallback.label} and your accounts'} '
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
            '${ai.model.label} needs a connection.',
            if (fallback != null) '${fallback.label} answers offline.',
          ].join(' '),
        ],
        [?(fallback == null ? null : use(fallback)), tryAgain],
      ),
      KapyAccountError(:final account) => (
        KapyIcons.warningRounded,
        account == KapyAccountKind.openRouter
            ? 'OpenRouter rejected the key'
            : '${kapyAccountName(account)} is signed out',
        [
          account == KapyAccountKind.openRouter
              ? 'Check the key in Settings, or pick another model.'
              : 'Sign in inside ${kapyAccountName(account)}, then check '
                    'again, or pick another model.',
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
          pickAnother,
        ],
      ),
      KapyFailed(:final message) => (
        KapyIcons.warningRounded,
        'Couldn’t answer',
        [message],
        [tryAgain],
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
                KapyIcon(
                  icon,
                  size: 15,
                  strokeWidth: 1.8,
                  color: palette.textSecondary,
                ),
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

  static String _provider(KapyAccountKind account) => switch (account) {
    KapyAccountKind.codex => 'OpenAI',
    KapyAccountKind.claudeCode => 'Anthropic',
    KapyAccountKind.openRouter => 'OpenRouter',
  };

  /// " and Google" for an OpenRouter model id such as
  /// google/gemini-3.8-flash: the company whose model reads the notes.
  static String _maker(KapyModel model) {
    if (model.kind != KapyModelKind.openRouter) return '';
    final slash = model.id.indexOf('/');
    if (slash <= 0) return '';
    final maker = model.id.substring(0, slash);
    return ' and ${switch (maker) {
      'openai' => 'OpenAI',
      'anthropic' => 'Anthropic',
      'google' => 'Google',
      'meta-llama' => 'Meta',
      'mistralai' => 'Mistral',
      'deepseek' => 'DeepSeek',
      'x-ai' => 'xAI',
      'qwen' => 'Qwen',
      _ => maker[0].toUpperCase() + maker.substring(1),
    }}';
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
