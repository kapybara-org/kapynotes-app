import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../sync/presence.dart';
import '../sync/spaces.dart';
import 'collaborator_colors.dart';
import 'profile_avatar.dart';

/// One face in an [AvatarStack].
class StackedAvatar {
  const StackedAvatar({
    required this.id,
    required this.seed,
    required this.name,
    this.image,
    this.tooltip,
    this.highlight,
    this.pending = false,
  });

  /// Stable across rebuilds; the circle's key is built from it.
  final String id;

  /// What a default avatar is drawn from.
  final String seed;

  /// What an initial is taken from when there is no picture.
  final String name;
  final String? image;
  final String? tooltip;

  /// A ring in this colour says the person is in the note right now — the
  /// colour of their caret, so the two can be matched at a glance.
  final Color? highlight;

  /// An invitation nobody has accepted yet, drawn faded: somebody the note is
  /// on its way to rather than somebody who has it.
  final bool pending;
}

/// Faces that overlap into one group, the tail collapsing into "+n".
///
/// As many circles as the width allows and never more than [maxAvatars]; when
/// there are more people than circles, the last circle is the count of the
/// rest rather than one more face.
class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.avatars,
    required this.extent,
    this.maxAvatars = 4,
    this.keyPrefix = 'avatar',
    this.reserve = 0,
    this.fitWidth = false,
  });

  final List<StackedAvatar> avatars;
  final double extent;
  final int maxAvatars;

  /// Gives up circles to fit a width it is handed, as a crowded title bar
  /// needs to. Off everywhere else: it measures with a [LayoutBuilder], which
  /// a dialog sizing itself to its content cannot ask for a width.
  final bool fitWidth;

  /// Each circle is keyed `$keyPrefix-$id`.
  final String keyPrefix;

  /// Width the caller spends around the stack, so it is not counted as room
  /// for another circle.
  final double reserve;

  /// How much of the previous circle each one covers. Enough to read as one
  /// group, not so much that an initial is hidden.
  static const double overlap = 0.28;

  @override
  Widget build(BuildContext context) {
    if (avatars.isEmpty) return const SizedBox.shrink();
    if (!fitWidth) return _build(context, double.infinity);
    return LayoutBuilder(
      builder: (context, constraints) => _build(
        context,
        constraints.maxWidth.isFinite ? constraints.maxWidth : double.infinity,
      ),
    );
  }

  Widget _build(BuildContext context, double available) {
    final palette = context.palette;
    final step = extent * (1 - overlap);
    final usable = available - reserve;

    // A bar this narrow is a phone in portrait beside a centred wordmark, and
    // a cluster that overflows there is worse than a shorter one.
    final affordable = usable.isFinite
        ? ((usable - extent) / step).floor() + 1
        : maxAvatars;
    final circles = affordable.clamp(0, maxAvatars);
    if (circles <= 0) return const SizedBox.shrink();

    // The chip stands in for everyone it hides, so it only earns a slot when
    // there is somebody left to hide.
    final shown = circles >= avatars.length
        ? avatars
        : avatars.take(circles - 1).toList();
    final hidden = avatars.length - shown.length;
    final drawn = shown.length + (hidden > 0 ? 1 : 0);

    return SizedBox(
      width: extent + (drawn - 1) * step,
      height: extent,
      child: Stack(
        children: [
          // Painted back to front so the leftmost circle sits on top, which
          // is the direction the eye reads the group in.
          if (hidden > 0)
            Positioned(
              left: shown.length * step,
              child: _AvatarCircle(
                key: ValueKey('$keyPrefix-more'),
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
              child: _Face(
                key: ValueKey('$keyPrefix-${shown[i].id}'),
                avatar: shown[i],
                extent: extent,
                ring: palette.surfaceBackground,
              ),
            ),
        ],
      ),
    );
  }
}

/// Who a shared note is open to, as an avatar-only row in the title bar.
class MemberAvatars extends StatelessWidget {
  const MemberAvatars({
    super.key,
    required this.members,
    required this.currentUserId,
    this.present = const [],
    this.onPressed,
    this.maxAvatars = 3,
  });

  final List<SpaceMember> members;

  /// Whose account this is, so one avatar can read "You" rather than repeating
  /// the address the user already knows.
  final String currentUserId;

  /// Everyone else in the note right now. They move up beside this account
  /// and wear their caret's colour, so the row answers "who is here" as well
  /// as "who has it".
  final List<Collaborator> present;

  /// Opens the full roster. Names stay in tooltips and semantics so the top
  /// bar itself remains compact.
  final VoidCallback? onPressed;

  /// Beyond this the rest collapse into a `+n` chip. Three is what a phone's
  /// title bar can seat without crowding the lockup.
  final int maxAvatars;

  static const double _tapPadding = 4;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    final brightness = context.palette.brightness;
    final here = {for (final person in present) person.userId: person};
    final ordered = _ordered(here);
    final pressed = onPressed;

    final stack = AvatarStack(
      keyPrefix: 'member-avatar',
      extent: AppControlMetrics.avatarExtent,
      maxAvatars: maxAvatars,
      fitWidth: true,
      reserve: pressed == null ? 0 : _tapPadding * 2,
      avatars: [
        for (final member in ordered)
          StackedAvatar(
            id: member.userId,
            seed: member.userId.isEmpty ? member.email : member.userId,
            name: member.displayName,
            image: member.image,
            highlight: here.containsKey(member.userId)
                ? collaboratorColor(member.userId, on: brightness)
                : null,
            tooltip: [
              member.userId == currentUserId
                  ? '${member.displayName} (you)'
                  : member.displayName,
              [
                member.role.accessLabel,
                if (here[member.userId] case final person?)
                  person.typing ? 'Typing' : 'Here now',
              ].join(' · '),
            ].join('\n'),
          ),
      ],
    );

    final names = ordered
        .map((member) => memberName(member, currentUserId: currentUserId))
        .join(', ');
    final hereNames = [
      for (final member in ordered)
        if (here.containsKey(member.userId))
          memberName(member, currentUserId: currentUserId),
    ];

    // One node for the whole cluster. Left to themselves the circles announce
    // three tooltips and the label repeats every name a second time.
    return Semantics(
      container: true,
      button: pressed != null,
      label: [
        'Shared with $names',
        if (hereNames.isNotEmpty) '${hereNames.join(', ')} here now',
      ].join('. '),
      onTap: pressed,
      child: ExcludeSemantics(
        child: pressed == null
            ? stack
            : InkWell(
                key: const ValueKey('toolbar-members'),
                onTap: pressed,
                borderRadius: BorderRadius.circular(
                  AppControlMetrics.avatarExtent,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _tapPadding),
                  child: stack,
                ),
              ),
      ),
    );
  }

  /// This account leads, so its avatar stays put as the roster changes around
  /// it; whoever is in the note comes next, and the rest keep the order the
  /// space reports them in.
  List<SpaceMember> _ordered(Map<String, Collaborator> here) => [
    ...members.where((member) => member.userId == currentUserId),
    ...members.where(
      (member) =>
          member.userId != currentUserId && here.containsKey(member.userId),
    ),
    ...members.where(
      (member) =>
          member.userId != currentUserId && !here.containsKey(member.userId),
    ),
  ];
}

/// The people a space is shared with, beside its heading: everyone but this
/// account, with anyone still invited drawn faded.
class SpacePeopleAvatars extends StatelessWidget {
  const SpacePeopleAvatars({
    super.key,
    required this.space,
    required this.currentUserId,
    this.present = const {},
    this.extent,
    this.maxAvatars = 4,
  });

  final Space space;
  final String currentUserId;

  /// Everyone in one of the space's notes right now, by account.
  final Set<String> present;

  /// Defaults to a size that sits against a section heading.
  final double? extent;
  final int maxAvatars;

  /// Small enough to sit inside a list heading without making it taller.
  static double get headingExtent => AppControlMetrics.iconAdornment + 3;

  @override
  Widget build(BuildContext context) {
    final brightness = context.palette.brightness;
    final people = space.peopleExcept(currentUserId);
    if (people.isEmpty) return const SizedBox.shrink();
    return AvatarStack(
      keyPrefix: 'space-avatar-${space.id}',
      extent: extent ?? headingExtent,
      maxAvatars: maxAvatars,
      avatars: [
        for (final person in people)
          StackedAvatar(
            id: person.id,
            seed: person.seed,
            name: person.fullName,
            image: person.image,
            pending: person.isInvited,
            highlight: present.contains(person.id)
                ? collaboratorColor(person.id, on: brightness)
                : null,
            tooltip: person.isInvited
                ? '${person.fullName}\nInvited'
                : '${person.fullName}\n${person.member!.role.accessLabel}',
          ),
      ],
    );
  }
}

/// What to call a member in one word.
///
String memberName(SpaceMember member, {required String currentUserId}) {
  if (member.userId == currentUserId) return 'You';
  return member.displayName;
}

class _Face extends StatelessWidget {
  const _Face({
    super.key,
    required this.avatar,
    required this.extent,
    required this.ring,
  });

  final StackedAvatar avatar;
  final double extent;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    final highlight = avatar.highlight;
    Widget face = ProfileAvatar(
      extent: extent,
      seed: avatar.seed,
      name: avatar.name,
      image: avatar.image,
      // The ring is the surface behind the bar, which is what separates one
      // overlapping circle from the next — or, for somebody in the note, the
      // colour of their caret.
      ring: highlight ?? ring,
      ringWidth: highlight == null ? 1.5 : 2,
    );
    if (avatar.pending) face = Opacity(opacity: 0.55, child: face);
    final tooltip = avatar.tooltip;
    return tooltip == null ? face : Tooltip(message: tooltip, child: face);
  }
}

class _AvatarCircle extends StatelessWidget {
  const _AvatarCircle({
    super.key,
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
          fontWeight: FontWeight.w400,
          color: foreground,
          height: 1,
        ),
        textScaler: TextScaler.noScaling,
      ),
    );
  }
}
