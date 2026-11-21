import '../../data/task_board.dart';

/// What sits under the add row on Today.
sealed class TaskStage {
  const TaskStage();
}

/// Nothing on the list.
class EmptyStage extends TaskStage {
  const EmptyStage();
}

/// Two tasks side by side: your choice so far, or the first on the list
/// before anything is chosen, and the next task on the list.
class PairStage extends TaskStage {
  const PairStage({
    required this.left,
    required this.chosen,
    required this.right,
    required this.joined,
    required this.pairsLeft,
  });

  final TaskItem left;

  /// Whether [left] has been chosen; until then it is the first on the list.
  final bool chosen;
  final TaskItem right;

  /// Whether [right] joined the list since you chose, after a Done.
  final bool joined;

  /// How many more pairs follow this one.
  final int pairsLeft;
}

/// The one task to work on now.
class DoNowStage extends TaskStage {
  const DoNowStage(this.item);

  final TaskItem item;
}

/// After 6 pm, once a round ends with nothing chosen: the tasks left, in the
/// order they wait for tomorrow.
class EveningStage extends TaskStage {
  const EveningStage(this.left);

  final List<TaskItem> left;
}

/// Today's list read the way Tasks shows it, by main's rules (Mark
/// Forster's FVP): a picked task carries a dot, the newest dot in list order
/// is your choice so far, and the dots before it wait in Up next, newest
/// first.
///
/// Where the pair has got to is not stored. [seenUpTo] is the last task shown
/// on the right, and [since] is when the last Do now began, so after a Done
/// only tasks that joined the list later are asked about.
class TaskChoice {
  const TaskChoice._(this.stage, this.upNext, this.rest);

  factory TaskChoice.read(
    List<TaskItem> open, {
    TaskItem? seenUpTo,
    int? since,
    bool evening = false,
  }) {
    if (open.isEmpty) return const TaskChoice._(EmptyStage(), [], []);
    final doNow = open.where((item) => item.doNow).firstOrNull;
    final dots = [
      for (final item in open)
        if (item.dotted && !item.doNow) item,
    ];
    List<TaskItem> others(Set<String> shown) => [
      for (final item in open)
        if (!shown.contains(item.id) && !(item.dotted && !item.doNow)) item,
    ];
    if (doNow != null) {
      return TaskChoice._(
        DoNowStage(doNow),
        dots.reversed.toList(),
        others({doNow.id}),
      );
    }
    if (dots.isEmpty && evening) {
      return TaskChoice._(EveningStage(open), const [], const []);
    }
    final left = dots.lastOrNull ?? open.first;
    bool after(TaskItem item, TaskItem? mark) =>
        mark == null || TaskBoard.listOrder(item, mark) > 0;
    final candidates = [
      for (final item in open)
        if (!item.dotted &&
            after(item, left) &&
            after(item, seenUpTo) &&
            (since == null || item.entry.position > since))
          item,
    ];
    final upNext = [
      for (final item in dots.reversed)
        if (item.id != left.id) item,
    ];
    if (candidates.isEmpty) {
      return TaskChoice._(DoNowStage(left), upNext, others({left.id}));
    }
    final right = candidates.first;
    return TaskChoice._(
      PairStage(
        left: left,
        chosen: left.dotted,
        right: right,
        joined: since != null,
        pairsLeft: candidates.length - 1,
      ),
      upNext,
      others({left.id, right.id}),
    );
  }

  final TaskStage stage;

  /// The chosen tasks waiting, in the order they'll come.
  final List<TaskItem> upNext;

  /// The rest of today's list, in list order, without the tasks shown above.
  final List<TaskItem> rest;

  /// Whether anything is chosen, so Choose again has something to clear.
  bool get chosen => switch (stage) {
    PairStage(:final chosen) => chosen,
    DoNowStage(:final item) => item.dotted || item.doNow || upNext.isNotEmpty,
    _ => false,
  };
}
