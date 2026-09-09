import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../sync/spaces.dart';
import 'profile_avatar.dart';

/// Who a shared note is open to, as an avatar-only row.
class MemberAvatars extends StatelessWidget {
  const MemberAvatars({
    super.key,
    required this.members,
    required this.currentUserId,
    this.onPressed,
    this.maxAvatars = 3,
  });

  final List<SpaceMember> members;

  /// Whose account this is, so one avatar can read "You" rather than repeating
  /// the address the user already knows.
  final String currentUserId;

  /// Opens the full roster. Names stay in tooltips and semantics so the top
  /// bar itself remains compact.
  final VoidCallback? onPressed;

  /// Beyond this the rest collapse into a `+n` chip. Three is what a phone's
  /// title bar can seat without crowding the lockup.
  final int maxAvatars;

  static const double _tapPadding = 4;

  /// How much of the previous circle each avatar covers. Enough to read as one
  /// group, not so much that an initial is hidden.
  static const double _overlap = 0.28;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) => _build(
        context,
        constraints.maxWidth.isFinite ? constraints.maxWidth : double.infinity,
      ),
    );
  }

  Widget _build(BuildContext context, double available) {
    final palette = context.palette;
    final ordered = _ordered;
    final extent = AppControlMetrics.avatarExtent;
    final step = extent * (1 - _overlap);
    final pressed = onPressed;
    final usable = available - (pressed == null ? 0 : _tapPadding * 2);

    // As many circles as the space allows, never more than [maxAvatars]. A
    // title bar this narrow is a phone in portrait beside a centred wordmark,
    // and a cluster that overflows there is worse than a shorter one.
    final affordable = usable.isFinite
        ? ((usable - extent) / step).floor() + 1
        : maxAvatars;
    final circles = affordable.clamp(0, maxAvatars);
    if (circles <= 0) return const SizedBox.shrink();

    // The chip stands in for everyone it hides, so it only earns a slot when
    // there is somebody left to hide.
    final shown = circles >= ordered.length
        ? ordered
        : ordered.take(circles - 1).toList();
    final hidden = ordered.length - shown.length;
    final drawn = shown.length + (hidden > 0 ? 1 : 0);
    final stackWidth = extent + (drawn - 1) * step;

    final stack = SizedBox(
      width: stackWidth,
      height: extent,
      child: Stack(
        children: [
          // Painted back to front so the leftmost avatar sits on top, which is
          // the direction the eye reads the group in.
          if (hidden > 0)
            Positioned(
              left: shown.length * step,
              child: _AvatarCircle(
                extent: extent,
                ring: palette.surfaceBackground,
                background: palette.controlBackground,
                foreground: palette.textSecondary,
                label: '+$hidden',
              ),
            ),
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: i * step,
              child: _MemberAvatar(
                key: ValueKey('member-avatar-${shown[i].userId}'),
                member: shown[i],
                isSelf: shown[i].userId == currentUserId,
                extent: extent,
                ring: palette.surfaceBackground,
              ),
            ),
        ],
      ),
    );

    final names = ordered
        .map((member) => memberName(member, currentUserId: currentUserId))
        .join(', ');

    // One node for the whole cluster. Left to themselves the circles announce
    // three tooltips and the label repeats every name a second time.
    return Semantics(
      container: true,
      button: pressed != null,
      label: 'Shared with $names',
      onTap: pressed,
      child: ExcludeSemantics(
        child: pressed == null
            ? stack
            : InkWell(
                key: const ValueKey('toolbar-members'),
                onTap: pressed,
                borderRadius: BorderRadius.circular(extent),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _tapPadding),
                  child: stack,
                ),
              ),
      ),
    );
  }

  /// This account leads, so its avatar stays put as the roster changes around
  /// it, and the rest keep the order the space reports them in.
  List<SpaceMember> get _ordered => [
    ...members.where((member) => member.userId == currentUserId),
    ...members.where((member) => member.userId != currentUserId),
  ];
}

/// What to call a member in one word.
///
String memberName(SpaceMember member, {required String currentUserId}) {
  if (member.userId == currentUserId) return 'You';
  return member.displayName;
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({
    super.key,
    required this.member,
    required this.isSelf,
    required this.extent,
    required this.ring,
  });

  final SpaceMember member;
  final bool isSelf;
  final double extent;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: [
        isSelf ? '${member.displayName} (you)' : member.displayName,
        member.role.accessLabel,
      ].join('\n'),
      child: ProfileAvatar(
        extent: extent,
        seed: member.userId.isEmpty ? member.email : member.userId,
        name: member.displayName,
        image: member.image,
        ring: ring,
      ),
    );
  }
}

class _AvatarCircle extends StatelessWidget {
  const _AvatarCircle({
    required this.extent,
    required this.ring,
    required this.background,
    required this.foreground,
    required this.label,
  });

  final double extent;
  final Color ring;
  final Color background;
  final Color foreground;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: extent,
      height: extent,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        // The ring is the surface behind the bar, not a border colour: it is
        // what separates one overlapping circle from the next.
        border: Border.all(color: ring, width: 1.5),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          // Fixed against the circle rather than scaled with Dynamic Type: the
          // circle cannot grow with it, so scaling the letter only clips it.
          fontSize: extent * (label.length > 1 ? 0.36 : 0.44),
          fontWeight: FontWeight.w600,
          color: foreground,
          height: 1,
        ),
        textScaler: TextScaler.noScaling,
      ),
    );
  }
}
