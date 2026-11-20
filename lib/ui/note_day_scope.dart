import 'package:material_ui/material_ui.dart';

import '../data/note_days.dart';

/// The account's note days, for the pages and editors under it: a note's own
/// day, where it has one. Absent in a build that has no days.
class NoteDayScope extends InheritedNotifier<NoteDayStore> {
  const NoteDayScope({
    super.key,
    required NoteDayStore days,
    required super.child,
  }) : super(notifier: days);

  /// The days on this device, or null where there are none.
  static NoteDayStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteDayScope>()?.notifier;
}

/// [child] under [days], or as it is when this build has none.
Widget withNoteDays(NoteDayStore? days, Widget child) =>
    days == null ? child : NoteDayScope(days: days, child: child);
