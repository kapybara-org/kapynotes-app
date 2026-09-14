import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../sync/joining.dart';
import '../../sync/spaces.dart';
import '../control_surface.dart';
import '../settings_rows.dart' show SettingsSwitch;
import 'joining_ui.dart';

/// Runs a sharing action the way the share dialog runs all of them: progress
/// shown, errors described, and the sharing rules offered if the server asks.
/// [success] is what the finishing toast says, where something more useful
/// than "Sharing updated" happened, such as a link landing on the clipboard.
typedef SharingRun =
    Future<void> Function(
      Future<void> Function() action, {
      String waiting,
      String? done,
      String? success,
    });

/// Who a link lets in, as the one choice the share sheet offers: no link at
/// all, or one that lets anyone who opens it straight in, to view or to edit.
enum LinkAccess {
  invitedOnly,
  anyoneCanView,
  anyoneCanEdit;

  static LinkAccess of(JoinLink? link) => switch (link?.role) {
    null => LinkAccess.invitedOnly,
    SpaceRole.viewer => LinkAccess.anyoneCanView,
    _ => LinkAccess.anyoneCanEdit,
  };

  /// What people who come in through the link can do, or null for no link.
  SpaceRole? get role => switch (this) {
    LinkAccess.invitedOnly => null,
    LinkAccess.anyoneCanView => SpaceRole.viewer,
    LinkAccess.anyoneCanEdit => SpaceRole.member,
  };

  String get label => switch (this) {
    LinkAccess.invitedOnly => 'Only people you invite',
    LinkAccess.anyoneCanView => 'Anyone with the link can view',
    LinkAccess.anyoneCanEdit => 'Anyone with the link can edit',
  };

  KapyIconData get icon => switch (this) {
    LinkAccess.invitedOnly => KapyIcons.lockRounded,
    LinkAccess.anyoneCanView => KapyIcons.visibilityOutlined,
    LinkAccess.anyoneCanEdit => KapyIcons.editOutlined,
  };
}

/// A note's link, offered the way Craft or Google Docs offer one: who it lets
/// in, chosen from a menu, beside a button that copies it.
///
/// Choosing view or edit makes the link and copies it at once, since wanting
/// a link to hand out is why anybody opens that menu. Whoever opens it joins
/// straight away, unless the owner chooses to approve people first; either
/// way the key reaches them only from a member's device, never through the
/// link or the server. "Only people you invite" turns the link off.
///
/// With [spaceId] this is that space's link. Without one the note is not
/// shared yet, and [create] shares it by link and returns the link it made.
class SpaceLinkPanel extends StatefulWidget {
  const SpaceLinkPanel({
    super.key,
    this.spaceId,
    required this.joining,
    required this.run,
    this.create,
    this.scope,
    this.enabled = true,
  }) : assert(spaceId != null || create != null);

  final String? spaceId;
  final Joining joining;
  final SharingRun run;

  /// Shares a note that is not shared yet, by a link letting people in as
  /// the given role. Used when there is no [spaceId].
  final Future<JoinLink> Function(SpaceRole role)? create;

  /// What else the link opens, said where the choice is made, or null when
  /// it opens only what the owner is looking at.
  final String? scope;
  final bool enabled;

  @override
  State<SpaceLinkPanel> createState() => _SpaceLinkPanelState();
}

class _SpaceLinkPanelState extends State<SpaceLinkPanel> {
  final _menu = GlobalKey<PopupMenuButtonState<LinkAccess>>();

  @override
  void initState() {
    super.initState();
    widget.joining.addListener(_changed);
    _loadIfUnknown();
  }

  @override
  void didUpdateWidget(SpaceLinkPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.joining, widget.joining)) {
      old.joining.removeListener(_changed);
      widget.joining.addListener(_changed);
    }
    if (old.spaceId != widget.spaceId) _loadIfUnknown();
  }

  @override
  void dispose() {
    widget.joining.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _loadIfUnknown() {
    final spaceId = widget.spaceId;
    if (spaceId == null || widget.joining.knowsLinkOf(spaceId)) return;
    unawaited(_loadQuietly(spaceId));
  }

  Future<void> _loadQuietly(String spaceId) async {
    try {
      await widget.joining.loadLink(spaceId);
    } on Object {
      // Offline, or not the owner after all: the menu still offers a link.
    }
  }

  JoinLink? get _link => switch (widget.spaceId) {
    final spaceId? => widget.joining.linkOf(spaceId),
    null => null,
  };

  static Future<void> _toClipboard(JoinLink link) =>
      Clipboard.setData(ClipboardData(text: link.url.toString()));

  Future<void> _copy() async {
    final link = _link;
    if (link == null) {
      // Nothing to copy yet. Which link to make is the owner's to say, and
      // the menu is where they say it.
      _menu.currentState?.showButtonMenu();
      return;
    }
    await _toClipboard(link);
    if (mounted) Toast.show(context, 'Link copied');
  }

  Future<void> _choose(LinkAccess access) async {
    final current = _link;
    if (access == LinkAccess.of(current)) return;
    final spaceId = widget.spaceId;
    final role = access.role;

    if (role == null) {
      if (spaceId == null) return;
      return widget.run(
        () => widget.joining.turnOffLink(spaceId),
        waiting: 'Turning the link off…',
        done:
            'The link is off, so it lets nobody else in. Everyone already in '
            'stays.',
      );
    }

    final can = role == SpaceRole.viewer ? 'view' : 'edit';
    if (current != null && spaceId != null) {
      return widget.run(
        () => widget.joining.changeLink(spaceId, role: role),
        waiting: 'Updating the link…',
        done:
            'Anyone who opens the link can $can now. Everyone already in '
            'keeps what they had.',
      );
    }

    return widget.run(
      () async {
        final link = spaceId == null
            ? await widget.create!(role)
            : await widget.joining.makeLink(
                spaceId,
                role: role,
                approval: false,
              );
        await _toClipboard(link);
      },
      waiting: 'Creating link…',
      done: 'Link copied. Anyone who opens it can $can, in Kapy Notes.',
      success: 'Link copied',
    );
  }

  Future<void> _setApproval(bool approval) async {
    final spaceId = widget.spaceId;
    if (spaceId == null) return;
    await widget.run(
      () => widget.joining.changeLink(spaceId, approval: approval),
      waiting: 'Updating the link…',
      done: approval
          ? 'People who open the link ask now, and you let each one in.'
          : 'Anyone who opens the link joins straight away now.',
    );
  }

  Future<void> _replace() async {
    final spaceId = widget.spaceId;
    final link = _link;
    if (spaceId == null || link == null) return;
    await widget.run(
      () async {
        final fresh = await widget.joining.makeLink(
          spaceId,
          role: link.role,
          approval: link.approval,
        );
        await _toClipboard(fresh);
      },
      waiting: 'Creating a new link…',
      done: 'New link copied. The old link no longer works.',
      success: 'Link copied',
    );
  }

  String _describe(JoinLink? link) {
    if (link == null) {
      return 'Set the link to view or edit to share with anyone, no '
          'invitation needed.';
    }
    final can = link.role == SpaceRole.viewer ? 'view' : 'edit';
    final who = link.approval
        ? 'Anyone who opens the link can ask to $can, and you let each one in.'
        : 'Anyone who opens the link can $can straight away, in Kapy Notes.';
    final until = link.expiresAt;
    if (until == null) return who;
    final date = MaterialLocalizations.of(context).formatMediumDate(until);
    return '$who It works until $date.';
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    final access = LinkAccess.of(link);
    final enabled = widget.enabled;

    final picker = PopupMenuButton<LinkAccess>(
      key: _menu,
      enabled: enabled,
      tooltip: 'Who the link lets in',
      position: PopupMenuPosition.under,
      onSelected: _choose,
      itemBuilder: (context) => [
        for (final option in LinkAccess.values)
          PopupMenuItem<LinkAccess>(
            key: ValueKey('link-access-${option.name}'),
            value: option,
            child: _AccessRow(access: option, chosen: option == access),
          ),
      ],
      child: _AccessField(
        key: const ValueKey('link-access'),
        access: access,
        enabled: enabled,
      ),
    );
    final copy = FilledButton.icon(
      key: const ValueKey('link-copy'),
      onPressed: enabled ? _copy : null,
      icon: KapyIcon(
        KapyIcons.linkRounded,
        size: AppControlMetrics.iconControl,
      ),
      label: const Text('Copy link'),
    );

    return Column(
      key: const ValueKey('space-link-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const JoinLabel('Share with a link'),
        KapyControlSurface(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (MediaQuery.sizeOf(context).width < 520) ...[
                picker,
                const SizedBox(height: 8),
                copy,
              ] else
                Row(
                  children: [
                    Expanded(child: picker),
                    const SizedBox(width: 8),
                    copy,
                  ],
                ),
              const SizedBox(height: 8),
              JoinMessage(_describe(link)),
              if (widget.scope case final scope?) ...[
                const SizedBox(height: 4),
                JoinMessage(scope),
              ],
              if (link != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _ApproveFirst(
                        value: link.approval,
                        enabled: enabled,
                        onChanged: _setApproval,
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const ValueKey('link-replace'),
                      onPressed: enabled ? _replace : null,
                      child: const Text('Replace link'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The menu while it is closed: a field holding the current choice, which is
/// what it is.
class _AccessField extends StatelessWidget {
  const _AccessField({super.key, required this.access, required this.enabled});

  final LinkAccess access;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: AppControlMetrics.buttonHeight,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: palette.surfaceBackground,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.controlBorder),
      ),
      child: Row(
        children: [
          KapyIcon(
            access.icon,
            size: AppControlMetrics.iconAdornment,
            color: palette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              access.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypeScale.control,
                color: enabled ? palette.textPrimary : palette.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          KapyIcon(
            KapyIcons.chevronDownRounded,
            size: AppControlMetrics.iconControl,
            color: palette.textTertiary,
          ),
        ],
      ),
    );
  }
}

/// One choice in the open menu, with a tick beside the current one. The tick
/// keeps its room on every row, so the labels line up.
class _AccessRow extends StatelessWidget {
  const _AccessRow({required this.access, required this.chosen});

  final LinkAccess access;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        KapyIcon(
          access.icon,
          size: AppControlMetrics.iconControl,
          color: palette.textSecondary,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(access.label)),
        const SizedBox(width: 12),
        Opacity(
          opacity: chosen ? 1 : 0,
          child: KapyIcon(
            KapyIcons.checkRounded,
            size: AppControlMetrics.iconControl,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

/// Whether the owner lets each person in: one row that is one switch.
class _ApproveFirst extends StatelessWidget {
  const _ApproveFirst({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: InkWell(
        key: const ValueKey('link-approval'),
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              ExcludeSemantics(child: SettingsSwitch(value: value)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Approve people before they join',
                  style: TextStyle(
                    fontSize: AppTypeScale.small,
                    color: enabled
                        ? palette.textSecondary
                        : palette.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
