import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/iconography.dart';
import '../../core/platform.dart';
import '../../recaps/recap_lines.dart';
import '../../recaps/recap_maker.dart';
import '../../recaps/recap_period.dart';
import '../../recaps/recap_story.dart';
import '../context_menu.dart';
import '../kapy_ai/kapy_ai_parts.dart';
import '../sidebar_timestamp.dart';
import 'recap_cards.dart';
import 'recap_story_view.dart';

/// What the recap drawer hands to the app: asking Kapy AI about a period,
/// the story viewer's actions, and the ways out of Kapy AI Cloud's limits
/// that Kapy AI's own card offers.
class RecapDrawerHooks {
  const RecapDrawerHooks({
    required this.onAsk,
    required this.openNote,
    required this.play,
    required this.saveAsNote,
    required this.shareImage,
    required this.onManageAccounts,
    this.onSignIn,
    this.onUpgrade,
  });

  /// Opens a Kapy AI chat that answers only from the period's notes.
  final void Function(RecapPeriod period) onAsk;
  final void Function(String noteId) openNote;
  final void Function(RecapQuote quote) play;
  final void Function(RecapNote note) saveAsNote;
  final Future<void> Function(Uint8List png, String name) shareImage;

  /// Settings › Voice & AI, where an account of the person's own is added.
  final VoidCallback onManageAccounts;

  /// Settings › Account & sync. Null in a build with nobody to sign in as.
  final VoidCallback? onSignIn;

  /// The Pro sheet. Null where there's no plan to show.
  final VoidCallback? onUpgrade;
}

/// The desktop popover's width.
const double recapPopoverWidth = 372;

/// Opens the recap drawer on [period]: a bottom sheet on a phone, and on a
/// desktop a popover beside [anchor], the tapped icon's rect in global
/// coordinates, so the list stays in view. Its period switch moves between
/// the day, week, month and year around [period].
Future<void> showRecapDrawer(
  BuildContext context,
  RecapPeriod period, {
  required RecapMaker maker,
  required RecapDrawerHooks hooks,
  Rect? anchor,
}) {
  void watch(RecapPeriod period) =>
      unawaited(watchRecap(context, period, maker: maker, hooks: hooks));
  Widget drawer(bool popover) => RecapDrawer(
    period: period,
    maker: maker,
    hooks: hooks,
    popover: popover,
    onWatch: watch,
  );
  if (AppPlatform.isDesktop && anchor != null) {
    return showKapyPopover<void>(
      context: context,
      barrierLabel: 'Close recap',
      pageBuilder: (_, _, _) => CustomSingleChildLayout(
        delegate: _BesideAnchor(anchor),
        child: drawer(true),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (_) => drawer(false),
  );
}

/// Opens [period]'s recap in the story viewer, read against its notes as
/// they are now. Making it again from the closing card spends what the
/// viewer quotes, and a recap that left words out as it opened is kept so.
Future<void> watchRecap(
  BuildContext context,
  RecapPeriod period, {
  required RecapMaker maker,
  required RecapDrawerHooks hooks,
}) async {
  final story = maker.story(period);
  if (story == null) return;
  final again = maker.quote(period);
  await showRecapStory(
    context,
    story: story,
    actions: RecapStoryActions(
      openNote: hooks.openNote,
      play: hooks.play,
      saveAsNote: hooks.saveAsNote,
      shareImage: hooks.shareImage,
      onRemake: () => unawaited(maker.make(again)),
      remakeCredits: again.credits,
      onPruned: maker.keep,
    ),
  );
}

/// Where the drawer is: what it shows for a period.
enum RecapDrawerStep {
  /// Nothing made yet: what goes in, the cost and Create recap.
  ready,
  making,
  made,

  /// Too little in the period for a recap: only Ask Kapy AI.
  tooLittle,

  /// Kapy AI Cloud can't make it: credits short, signed out or no Pro.
  noCredits,

  /// The person's own account can't answer.
  account,
  offline,
  failed,
}

/// The step [maker] puts [period] in, with [quote] what it would take.
RecapDrawerStep recapDrawerStep(
  RecapMaker maker,
  RecapPeriod period,
  RecapPrice quote,
) {
  final run = maker.runOf(period);
  if (run != null) {
    switch (run.end) {
      case null:
        return RecapDrawerStep.making;
      case RecapEnd.offline:
        return RecapDrawerStep.offline;
      case RecapEnd.failed:
        return RecapDrawerStep.failed;
      case RecapEnd.noCredits || RecapEnd.signIn || RecapEnd.upgrade:
        return RecapDrawerStep.noCredits;
    }
  }
  if (maker.hasRecap(period)) return RecapDrawerStep.made;
  if (quote.tooLittle) return RecapDrawerStep.tooLittle;
  final usage = maker.usage;
  return switch (maker.hold) {
    KapyCloudLocked() => RecapDrawerStep.noCredits,
    KapyAccountError() => RecapDrawerStep.account,
    _
        when quote.model.kind == KapyModelKind.cloud &&
            usage != null &&
            usage.remaining < quote.credits =>
      RecapDrawerStep.noCredits,
    _ => RecapDrawerStep.ready,
  };
}

/// The drawer's own surfaces, from the Drawer boards; its text and orange
/// come from [RecapTones].
class _Shades {
  const _Shades(
    this.sheet,
    this.box,
    this.chosen,
    this.rule,
    this.grab,
    this.quiet,
  );

  static const dark = _Shades(
    Color(0xFF141414),
    Color(0xFF1E1E1E),
    Color(0xFF333333),
    Color(0xFF2A2A2A),
    Color(0xFF3A3A3A),
    Color(0xFF262626),
  );
  static const light = _Shades(
    Color(0xFFFFFFFF),
    Color(0xFFF4F4F4),
    Color(0xFFFFFFFF),
    Color(0xFFE5E5E5),
    Color(0xFFD4D4D4),
    Color(0xFFEDEDED),
  );

  final Color sheet;
  final Color box;
  final Color chosen;
  final Color rule;
  final Color grab;
  final Color quiet;
}

/// The recap drawer: a period switch, what goes in, the cost before
/// anything is spent, and every step of making a recap.
class RecapDrawer extends StatefulWidget {
  const RecapDrawer({
    super.key,
    required this.period,
    required this.maker,
    required this.hooks,
    required this.popover,
    required this.onWatch,
  });

  final RecapPeriod period;
  final RecapMaker maker;
  final RecapDrawerHooks hooks;

  /// The desktop's popover rather than a phone's sheet.
  final bool popover;

  /// Opens the period's recap, once the drawer has closed.
  final void Function(RecapPeriod period) onWatch;

  @override
  State<RecapDrawer> createState() => _RecapDrawerState();
}

class _RecapDrawerState extends State<RecapDrawer> {
  late RecapPeriod _period = widget.period;

  /// The day, week, month and year around the period it opened on.
  late final List<RecapPeriod> _periods = () {
    final period = widget.period;
    final today = widget.maker.today;
    final day = period.contains(today) ? today : period.last;
    final weekday = period.kind == RecapKind.week
        ? period.first.weekday
        : widget.maker.firstWeekday;
    return [
      for (final kind in RecapKind.values)
        kind == period.kind
            ? period
            : RecapPeriod.containing(day, kind, firstWeekday: weekday),
    ];
  }();

  void _close() => Navigator.of(context).pop();

  void _then(VoidCallback action) {
    _close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final t = RecapTones.of(brightness);
    final s = brightness == Brightness.dark ? _Shades.dark : _Shades.light;
    final media = MediaQuery.of(context);
    final body = ListenableBuilder(
      listenable: widget.maker,
      builder: (context, _) => _content(t, s),
    );
    if (widget.popover) {
      return DecoratedBox(
        key: const ValueKey('recap-drawer'),
        decoration: BoxDecoration(
          color: s.sheet,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.cardEdge, width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 30,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: recapPopoverWidth,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: body,
            ),
          ),
        ),
      );
    }
    return Material(
      key: const ValueKey('recap-drawer'),
      color: s.sheet,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: t.cardEdge, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 10, 20, media.padding.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: s.grab,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              body,
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(RecapTones t, _Shades s) {
    final maker = widget.maker;
    final period = _period;
    final quote = maker.quote(period);
    final step = recapDrawerStep(maker, period, quote);
    final gap = widget.popover ? 14.0 : 16.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(t, s, period, step),
        SizedBox(height: gap),
        _switch(t, s),
        SizedBox(height: gap),
        ..._step(t, s, step, quote, gap),
      ],
    );
  }

  Widget _header(
    RecapTones t,
    _Shades s,
    RecapPeriod period,
    RecapDrawerStep step,
  ) {
    final little = step == RecapDrawerStep.tooLittle;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: little ? s.box : t.tint,
            shape: BoxShape.circle,
          ),
          child: KapyIcon(
            KapyIcons.recapOutlined,
            size: 20,
            color: little ? t.secondary : t.accentInk,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                little ? period.label : '${period.label} recap',
                style: recapText(19, 24, 600, t.text, spacing: -0.2),
              ),
              const SizedBox(height: 2),
              Text(
                recapSpan(period, today: widget.maker.today),
                style: recapText(13, 17, 400, t.tertiary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Semantics(
          button: true,
          label: 'Close',
          child: InkResponse(
            key: const ValueKey('recap-drawer-close'),
            onTap: _close,
            radius: 18,
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: s.box, shape: BoxShape.circle),
              child: KapyIcon(
                KapyIcons.closeRounded,
                size: 16,
                color: t.secondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _switch(RecapTones t, _Shades s) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: s.box,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (final period in _periods)
          Expanded(
            child: Semantics(
              button: true,
              selected: period == _period,
              child: GestureDetector(
                key: ValueKey('recap-period-${period.kind.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _period = period),
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: period == _period
                      ? BoxDecoration(
                          color: s.chosen,
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: [
                            const BoxShadow(
                              color: Color(0x1A000000),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                            BoxShadow(color: t.cardEdge, spreadRadius: 0.5),
                          ],
                        )
                      : null,
                  child: Text(
                    period.label,
                    maxLines: 1,
                    style: recapText(
                      13.5,
                      18,
                      period == _period ? 500 : 400,
                      period == _period ? t.text : t.tertiary,
                      tabular: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  List<Widget> _step(
    RecapTones t,
    _Shades s,
    RecapDrawerStep step,
    RecapPrice quote,
    double gap,
  ) {
    final maker = widget.maker;
    final period = quote.period;
    final hooks = widget.hooks;
    final cloud = quote.model.kind == KapyModelKind.cloud;
    final usage = maker.usage;
    final busy = maker.making;
    final kind = period.kind.name;
    final (about, aboutNotes) = _about(period, period.isOngoing(maker.today));
    final ask = _Button(
      widget.popover && step != RecapDrawerStep.tooLittle
          ? 'Ask Kapy AI'
          : 'Ask Kapy AI about $about',
      key: const ValueKey('recap-ask'),
      icon: KapyIcons.sparklesOutlined,
      filled: step == RecapDrawerStep.tooLittle,
      t: t,
      s: s,
      onPressed: () => _then(() => hooks.onAsk(period)),
    );
    final askCost = maker.askCosts ? ', and each answer uses 1 credit' : '';
    Widget pair(_Button first) => widget.popover
        ? Row(
            children: [
              Expanded(child: first),
              const SizedBox(width: 8),
              Expanded(child: ask),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first, const SizedBox(height: 8), ask],
          );
    String credits(int n) => _count(n, 'credit', 'credits');
    final left = usage == null
        ? null
        : '${usage.remaining} of ${usage.limit} left';
    final busyLine = busy != null && busy.period != period
        ? 'One recap is made at a time. The ${busy.period.label} recap is '
              'being made now.'
        : null;
    void make() => unawaited(maker.make(quote));
    switch (step) {
      case RecapDrawerStep.ready:
        final counts = quote.digest.counts;
        final open = quote.digest.tasksOpen;
        return [
          Text('What goes in', style: recapText(13, 16, 500, t.tertiary)),
          const SizedBox(height: 8),
          _Box(
            t: t,
            s: s,
            rows: [
              (KapyIcons.noteOutlined, 'Notes', '${counts.notes}'),
              if (counts.tasksDone > 0 || open > 0)
                (
                  KapyIcons.checkCircleRounded,
                  'Tasks',
                  '${counts.tasksDone} done · $open open',
                ),
              if (counts.voiceNotes > 0)
                (
                  KapyIcons.micRounded,
                  'Voice notes',
                  '${counts.voiceNotes} · ${counts.voiceMinutes} min',
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Line(
            [
              'Hidden notes are never used.',
              if (period.isOngoing(maker.today)) _notOver(period.kind),
            ].join(' '),
            t,
          ),
          SizedBox(height: gap),
          Row(
            children: [
              KapyIcon(KapyIcons.sparklesOutlined, size: 18, color: t.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  cloud
                      ? 'Uses ${quote.credits} Kapy AI '
                            '${quote.credits == 1 ? 'credit' : 'credits'}'
                      : 'Uses your own account',
                  key: const ValueKey('recap-cost'),
                  style: recapText(15, 20, 500, t.text),
                ),
              ),
              if (cloud && left != null)
                Text(
                  left,
                  style: recapText(13, 18, 400, t.tertiary, tabular: true),
                ),
            ],
          ),
          SizedBox(height: gap),
          _Line(_privacy(quote.model, kind), t),
          SizedBox(height: gap),
          pair(
            _Button(
              'Create recap',
              key: const ValueKey('recap-create'),
              filled: true,
              t: t,
              s: s,
              onPressed: busyLine == null ? make : null,
            ),
          ),
          const SizedBox(height: 10),
          _Line(
            busyLine ??
                'Create recap makes the story once. Ask Kapy AI is a separate '
                    'chat that answers from $aboutNotes$askCost.',
            t,
          ),
        ];
      case RecapDrawerStep.making:
        final run = maker.runOf(period)!;
        final counts = quote.digest.counts;
        final part = (run.made + 1).clamp(1, run.parts);
        return [
          Row(
            children: [
              const ExcludeSemantics(
                child: Image(
                  image: AssetImage('assets/mascot/kapy_standing.webp'),
                  width: 44,
                  height: 62,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Making your recap',
                      style: recapText(16, 21, 600, t.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Reading '
                      '${_reading(counts.notes, counts.tasksDone + quote.digest.tasksOpen, counts.voiceNotes)}',
                      style: recapText(13.5, 18, 400, t.secondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: gap),
          Semantics(
            label: 'Part $part of ${run.parts}',
            child: Row(
              key: const ValueKey('recap-parts'),
              children: [
                for (var i = 0; i < run.parts; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: i < run.made ? t.text : s.grab,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Part $part of ${run.parts}',
                  style: recapText(12.5, 16, 400, t.tertiary, tabular: true),
                ),
              ),
              Text(
                _timeLeft(maker.timeLeft(run)),
                style: recapText(12.5, 16, 400, t.tertiary),
              ),
            ],
          ),
          SizedBox(height: gap),
          _Line(
            'You can close this. It keeps going while Kapy Notes is open, and '
            'the icon on ${period.label} turns orange when it’s ready.',
            t,
          ),
          SizedBox(height: gap),
          _Button(
            run.stopping ? 'Stopping…' : 'Stop',
            key: const ValueKey('recap-stop'),
            t: t,
            s: s,
            onPressed: run.stopping ? null : () => maker.stop(period),
          ),
        ];
      case RecapDrawerStep.made:
        final record = maker.recordOf(period)!;
        final story = maker.story(period);
        final changed = maker.changesSince(period);
        final made = maker.shown(record.madeAt);
        return [
          Row(
            children: [
              if (story != null) ...[
                _Thumbnail(story, t),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ready to watch',
                      style: recapText(16, 21, 600, t.text),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Made ${_madeOn(made, maker.today)}. It opens free, as '
                      'often as you like.',
                      style: recapText(13.5, 19, 400, t.secondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: gap),
          pair(
            _Button(
              'Watch recap',
              key: const ValueKey('recap-watch'),
              icon: KapyIcons.playRounded,
              filled: true,
              t: t,
              s: s,
              onPressed: () => _then(() => widget.onWatch(period)),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: changed == 0
                    ? const SizedBox.shrink()
                    : Text(
                        '${_count(changed, 'note', 'notes')} changed since '
                        'then',
                        key: const ValueKey('recap-changed'),
                        style: recapText(12.5, 16, 400, t.tertiary),
                      ),
              ),
              TextButton(
                key: const ValueKey('recap-again'),
                onPressed: busy == null && !quote.tooLittle ? make : null,
                style: TextButton.styleFrom(
                  foregroundColor: t.text,
                  disabledForegroundColor: t.tertiary,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  cloud
                      ? 'Make it again · ${credits(quote.credits)}'
                      : 'Make it again',
                  style: recapText(
                    13,
                    16,
                    500,
                    busy == null ? t.text : t.tertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _Line(
            busyLine ??
                [
                  'Watching stays free.',
                  if (maker.askCosts)
                    'Each Kapy AI answer about $about uses 1 credit.',
                ].join(' '),
            t,
          ),
        ];
      case RecapDrawerStep.tooLittle:
        final counts = quote.digest.counts;
        return [
          _Notice(
            icon: KapyIcons.noteOutlined,
            title: 'Too little for a recap',
            line:
                'A $kind recap needs at least ${period.kind.least} notes, '
                'tasks done or voice notes together. ${period.label} has '
                '${_has(counts.notes, counts.tasksDone, counts.voiceNotes)}, so '
                'there’s no recap, but you can still ask about it.',
            t: t,
            s: s,
          ),
          SizedBox(height: gap),
          ask,
          if (maker.askCosts) ...[
            const SizedBox(height: 10),
            _Line(['Each answer uses 1 credit', ?left].join(' · '), t),
          ],
        ];
      case RecapDrawerStep.noCredits:
        final run = maker.runOf(period);
        final held = maker.hold;
        final locked = held is KapyCloudLocked ? held : null;
        final short = run?.end == RecapEnd.noCredits || locked == null;
        final signIn = run?.end == RecapEnd.signIn || (locked?.signIn ?? false)
            ? hooks.onSignIn
            : null;
        final upgrade =
            run?.end == RecapEnd.upgrade ||
                (locked?.upgrade ?? false) ||
                maker.onTrial
            ? hooks.onUpgrade
            : null;
        final costs = 'A $kind recap uses ${credits(quote.credits)}';
        final shown = run?.usage ?? usage;
        final (title, first) = short
            ? (
                'Not enough credits for this one',
                shown == null
                    ? '$costs.'
                    : '$costs, and you have ${credits(shown.remaining)} '
                          'left until '
                          '${shown.resetsAt.day} '
                          '${SidebarTimestamp.monthName(shown.resetsAt).substring(0, 3)}.',
              )
            : signIn != null && upgrade == null
            ? ('Sign in to use Kapy AI Cloud', '$costs.')
            : ('Kapy AI Cloud is part of Pro', '$costs.');
        final then = switch ((signIn != null, upgrade != null)) {
          (true, true) =>
            'Sign in if you have Pro, or upgrade. You can also use your own '
                'AI account.',
          (false, true) => 'Upgrade for more, or use your own AI account.',
          (true, false) => 'Sign in again, or use your own AI account.',
          (false, false) => 'You can use your own AI account instead.',
        };
        return [
          _Notice(
            icon: KapyIcons.scheduleRounded,
            title: title,
            line: '$first $then',
            t: t,
            s: s,
          ),
          SizedBox(height: gap),
          if (signIn != null) ...[
            _Button(
              'Sign in',
              key: const ValueKey('recap-sign-in'),
              filled: true,
              t: t,
              s: s,
              onPressed: () => _then(signIn),
            ),
            const SizedBox(height: 8),
          ],
          if (upgrade != null) ...[
            _Button(
              'Upgrade',
              key: const ValueKey('recap-upgrade'),
              filled: signIn == null,
              t: t,
              s: s,
              onPressed: () => _then(upgrade),
            ),
            const SizedBox(height: 8),
          ],
          _Button(
            'Use your own account',
            key: const ValueKey('recap-own-account'),
            plain: true,
            t: t,
            s: s,
            onPressed: () => _then(hooks.onManageAccounts),
          ),
        ];
      case RecapDrawerStep.account:
        final account = (maker.hold! as KapyAccountError).account;
        final key = account == KapyAccountKind.openRouter;
        return [
          _Notice(
            icon: KapyIcons.warningRounded,
            title: key
                ? 'This key was rejected'
                : '${kapyAccountName(account)} is signed out',
            line: key
                ? 'Check the key in Settings, then make the recap.'
                : 'Sign in inside ${kapyAccountName(account)}, then make the '
                      'recap.',
            t: t,
            s: s,
          ),
          SizedBox(height: gap),
          _Button(
            'Open Settings',
            key: const ValueKey('recap-settings'),
            t: t,
            s: s,
            onPressed: () => _then(hooks.onManageAccounts),
          ),
        ];
      case RecapDrawerStep.offline:
        return [
          _Notice(
            icon: KapyIcons.wifiOffRounded,
            title: 'You’re offline',
            line:
                'Recaps are made in Kapy cloud, so this needs a connection. '
                'Nothing was used. Recaps you’ve already made still open.',
            t: t,
            s: s,
          ),
          SizedBox(height: gap),
          _Button(
            'Try again',
            key: const ValueKey('recap-try-again'),
            t: t,
            s: s,
            onPressed: busy == null ? make : null,
          ),
        ];
      case RecapDrawerStep.failed:
        final run = maker.runOf(period)!;
        return [
          _Notice(
            icon: KapyIcons.warningRounded,
            title: 'Couldn’t finish the recap',
            line: run.failedPart <= 1
                ? 'The recap couldn’t be made, and nothing was used.'
                : 'Part ${run.failedPart} of ${run.parts} couldn’t be made. '
                      'The parts already made are kept, so Try again only '
                      'makes what’s left and you never pay twice.',
            t: t,
            s: s,
          ),
          SizedBox(height: gap),
          _Button(
            cloud ? 'Try again · ${credits(quote.credits)}' : 'Try again',
            key: const ValueKey('recap-try-again'),
            filled: true,
            t: t,
            s: s,
            onPressed: busy == null ? make : null,
          ),
          const SizedBox(height: 8),
          _Button('Close', plain: true, t: t, s: s, onPressed: _close),
        ];
    }
  }
}

/// What the header says under the title: "Today so far · Wednesday, 19
/// November", "This week so far · 17 to 23 November", "1 to 30 November".
String recapSpan(RecapPeriod period, {required DateTime today}) {
  final first = period.first;
  final last = period.last;
  String day(DateTime it) => '${it.day} ${SidebarTimestamp.monthName(it)}';
  final span = switch (period.kind) {
    RecapKind.day => SidebarTimestamp.fullDay(first),
    _ when first.month == last.month && first.year == last.year =>
      '${first.day} to ${day(last)}',
    _ => '${day(first)} to ${day(last)}',
  };
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  final lead = period.isOngoing(today)
      ? switch (period.kind) {
          RecapKind.day => 'Today so far',
          RecapKind.week => 'This week so far',
          RecapKind.month => 'This month so far',
          RecapKind.year => 'This year so far',
        }
      : period.kind == RecapKind.day && period.contains(yesterday)
      ? 'Yesterday'
      : null;
  return lead == null ? span : '$lead · $span';
}

/// How Ask Kapy AI names [period], "this week" while it lasts and its label
/// after, and the notes it answers from.
(String, String) _about(RecapPeriod period, bool ongoing) {
  if (!ongoing) return (period.label, 'the notes from ${period.label}');
  final word = switch (period.kind) {
    RecapKind.day => 'today',
    RecapKind.week => 'this week',
    RecapKind.month => 'this month',
    RecapKind.year => 'this year',
  };
  return (word, '$word’s notes');
}

String _notOver(RecapKind kind) => switch (kind) {
  RecapKind.day => 'The day isn’t over, so you can make it again tonight.',
  _ => 'The ${kind.name} isn’t over, so you can make it again later.',
};

/// Kapy AI's consent line for [model], about a recap of this [kind].
String _privacy(KapyModel model, String kind) {
  final what = 'the notes, tasks and voice notes from this $kind';
  return switch (model.kind) {
    KapyModelKind.codex =>
      'Kapy AI sends $what through Codex, under your ChatGPT plan. Hidden '
          'notes never leave.',
    KapyModelKind.claudeCode =>
      'Kapy AI sends $what through Claude Code. Hidden notes never leave.',
    KapyModelKind.openRouter =>
      'Kapy AI sends $what through your key. Hidden notes never leave.',
    KapyModelKind.cloud || KapyModelKind.device =>
      'Kapy AI sends $what through Kapy cloud, where an AI service writes '
          'the recap. Kapy keeps nothing, and it is never used to train AI.',
  };
}

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';

String _reading(int notes, int tasks, int voices) {
  final parts = [
    if (notes > 0) _count(notes, 'note', 'notes'),
    if (tasks > 0) _count(tasks, 'task', 'tasks'),
    if (voices > 0) _count(voices, 'voice note', 'voice notes'),
  ];
  return parts.length < 2
      ? parts.join()
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

String _has(int notes, int done, int voices) {
  final parts = [
    if (notes > 0) _count(notes, 'note', 'notes'),
    if (done > 0) _count(done, 'task done', 'tasks done'),
    if (voices > 0) _count(voices, 'voice note', 'voice notes'),
  ];
  return parts.isEmpty ? 'nothing yet' : parts.join(' and ');
}

String _timeLeft(Duration left) {
  final seconds = left.inSeconds;
  if (seconds < 45) return 'Less than a minute left';
  if (seconds < 90) return 'About a minute left';
  return 'About ${(seconds / 60).round()} minutes left';
}

String _madeOn(DateTime made, DateTime today) {
  final day = DateTime(made.year, made.month, made.day);
  final at = SidebarTimestamp.clock(made);
  if (day == today) return 'today at $at';
  if (day == DateTime(today.year, today.month, today.day - 1)) {
    return 'yesterday at $at';
  }
  return 'on ${SidebarTimestamp.shortDay(made, now: today)} at $at';
}

/// A drawer button: [filled] for the step's main action, quiet otherwise,
/// and [plain] with no fill at all.
class _Button extends StatelessWidget {
  const _Button(
    this.label, {
    super.key,
    required this.t,
    required this.s,
    required this.onPressed,
    this.icon,
    this.filled = false,
    this.plain = false,
  });

  final String label;
  final RecapTones t;
  final _Shades s;
  final VoidCallback? onPressed;
  final KapyIconData? icon;
  final bool filled;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    final off = onPressed == null;
    final background = plain
        ? Colors.transparent
        : filled && !off
        ? t.strongButton
        : s.quiet;
    final ink = off
        ? t.tertiary
        : filled
        ? t.onStrongButton
        : t.text;
    return SizedBox(
      height: 48,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: background,
          foregroundColor: ink,
          disabledForegroundColor: t.tertiary,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?) ...[
              KapyIcon(icon, size: 16, color: ink),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: recapText(15, 20, 600, ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small grey line under a part of the drawer.
class _Line extends StatelessWidget {
  const _Line(this.text, this.t);

  final String text;
  final RecapTones t;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: recapText(12.5, 18, 400, t.tertiary));
}

/// What goes in: a row each for notes, tasks and voice notes.
class _Box extends StatelessWidget {
  const _Box({required this.t, required this.s, required this.rows});

  final RecapTones t;
  final _Shades s;
  final List<(KapyIconData, String, String)> rows;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: s.box,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: [
        for (final (index, (icon, name, value)) in rows.indexed)
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: index == 0
                ? null
                : BoxDecoration(
                    border: Border(top: BorderSide(color: s.rule, width: 0.5)),
                  ),
            child: Row(
              children: [
                KapyIcon(icon, size: 18, color: t.secondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name, style: recapText(15, 20, 400, t.text)),
                ),
                Text(
                  value,
                  style: recapText(14, 18, 400, t.secondary, tabular: true),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// A step's icon, title and why.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.line,
    required this.t,
    required this.s,
  });

  final KapyIconData icon;
  final String title;
  final String line;
  final RecapTones t;
  final _Shades s;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: s.box, shape: BoxShape.circle),
        child: KapyIcon(icon, size: 16, color: t.secondary),
      ),
      const SizedBox(height: 12),
      Text(title, style: recapText(16, 21, 600, t.text)),
      const SizedBox(height: 6),
      Text(line, style: recapText(13.5, 19, 400, t.secondary)),
    ],
  );
}

/// The recap's cover, small, as it opens.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 58,
          height: 88,
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            child: Container(
              width: 393,
              height: 596,
              color: t.tint,
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
              child: RecapCardBody(
                story: story,
                card: RecapCard.cover,
                tones: t,
                actions: RecapCardActions(openNote: (_) {}, play: (_) {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Puts the popover beside [anchor]: to its right where it fits, else to
/// its left, and level with it as far as the window allows.
class _BesideAnchor extends SingleChildLayoutDelegate {
  _BesideAnchor(this.anchor);

  final Rect anchor;
  static const double gap = 8;
  static const double margin = 12;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: recapPopoverWidth,
        maxHeight: constraints.maxHeight - margin * 2,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = anchor.right + gap;
    final x = right + childSize.width <= size.width - margin
        ? right
        : anchor.left - gap - childSize.width;
    final lowest = size.height - margin - childSize.height;
    final y = (anchor.top - 24).clamp(
      margin,
      lowest < margin ? margin : lowest,
    );
    return Offset(
      x.clamp(margin, size.width - childSize.width).toDouble(),
      y.toDouble(),
    );
  }

  @override
  bool shouldRelayout(_BesideAnchor oldDelegate) =>
      oldDelegate.anchor != anchor;
}
