import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/notes_store.dart';
import '../export/archive.dart';
import '../export/archive_service.dart';
import '../export/importer.dart';

/// The two things a person does with an archive, and what they are told about
/// it while it happens.
///
/// The word "backup" is deliberately absent from every string here. A backup
/// is something that runs on its own; this runs when somebody asks it to, and
/// anyone who reads the other word will assume they are covered when they are
/// not.

/// Writes every note to a `.zip` the user picks.
Future<void> runExport(
  BuildContext context,
  NotesStore notes, {
  NoteArchiveService? service,
}) async {
  final messenger = _Messenger(context);
  final result = await (service ?? NoteArchiveService()).exportNotes(
    notes.notes,
  );
  if (!context.mounted) return;

  switch (result.status) {
    case ExportStatus.cancelled:
      return;
    case ExportStatus.failed:
      messenger.error(result.error ?? 'Kapy Notes could not write the export.');
    case ExportStatus.written:
      final count = result.noteCount;
      messenger.ok(
        AppPlatform.isDesktop
            ? 'Exported $count ${count == 1 ? 'note' : 'notes'}'
            // On a phone nobody chose the folder, so the message has to say
            // where it went or the file may as well not exist.
            : 'Exported to ${result.path?.split('/').last}',
      );
  }
}

/// Reads an archive the user picks, shows what it would do, and does it once
/// they agree.
Future<void> runImport(
  BuildContext context,
  NotesStore notes, {
  NoteArchiveService? service,
}) async {
  final messenger = _Messenger(context);
  final contents = await (service ?? NoteArchiveService()).openArchive();
  if (contents == null || !context.mounted) return;

  if (!contents.isReadable) {
    messenger.error(switch (contents.fault) {
      ArchiveFault.noManifest => 'That zip is not a Kapy Notes export.',
      ArchiveFault.futureSchema =>
        'That export was written by a newer version of Kapy Notes.',
      _ => 'Kapy Notes could not read that file. It may be incomplete.',
    });
    return;
  }

  final plan = await showDialog<ImportPlan>(
    context: context,
    builder: (context) => _ImportDialog(contents: contents, notes: notes),
  );
  if (plan == null || !context.mounted) return;

  final written = applyImportPlan(notes, plan);
  messenger.ok(
    written == 0
        ? 'Everything in that export is already here'
        : 'Imported $written ${written == 1 ? 'note' : 'notes'}',
  );
}

/// Holds the overlay from before the first await, so a toast still has
/// somewhere to go after a file picker has been and gone.
class _Messenger {
  _Messenger(this.context);

  final BuildContext context;

  void ok(String message) {
    if (context.mounted) Toast.show(context, message);
  }

  void error(String message) {
    if (context.mounted) {
      Toast.show(context, message, icon: Icons.error_outline, isError: true);
    }
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.contents, required this.notes});

  final ArchiveContents contents;
  final NotesStore notes;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late ImportMode _mode;

  /// Whether the choice is the user's to make. On a device with nothing on it
  /// there is only one sensible answer, and asking would be noise.
  bool get _hasNotes => widget.notes.notes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _mode = ImportMode.restore;
  }

  ImportPlan get _plan => ImportPlan.from(
    archive: widget.contents,
    existing: widget.notes.notes,
    tombstones: widget.notes.tombstones,
    mode: _mode,
    now: DateTime.now(),
  );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final plan = _plan;
    final exportedAt = widget.contents.manifest!.exportedAt;

    return AlertDialog(
      title: const Text('Import notes'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Exported ${_dateLabel(exportedAt)} · '
                '${widget.contents.manifest!.notes.length} notes',
                style: TextStyle(
                  fontSize: AppTypeScale.body,
                  color: palette.textSecondary,
                  height: 1.45,
                ),
              ),
              if (_hasNotes) ...[
                const SizedBox(height: 14),
                _ModeChoice(
                  key: const ValueKey('import-mode-restore'),
                  label: 'Restore',
                  detail:
                      'Puts notes back under their own ids. A note this '
                      'device has edited since is left alone.',
                  selected: _mode == ImportMode.restore,
                  onTap: () => setState(() => _mode = ImportMode.restore),
                ),
                const SizedBox(height: 6),
                _ModeChoice(
                  key: const ValueKey('import-mode-copies'),
                  label: 'Add as copies',
                  detail:
                      'Adds every note again as a new one. Nothing already '
                      'here is touched.',
                  selected: _mode == ImportMode.copies,
                  onTap: () => setState(() => _mode = ImportMode.copies),
                ),
              ],
              const SizedBox(height: 14),
              ..._summary(plan).map(
                (line) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontSize: AppTypeScale.body,
                      color: palette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              for (final problem in plan.problems)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    problem,
                    style: TextStyle(
                      fontSize: AppTypeScale.small,
                      color: Theme.of(context).colorScheme.error,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('import-confirm'),
          onPressed: plan.isEmpty
              ? null
              : () => Navigator.of(context).pop(plan),
          child: Text(
            plan.isEmpty
                ? 'Nothing to import'
                : 'Import ${plan.applyCount} '
                      '${plan.applyCount == 1 ? 'note' : 'notes'}',
          ),
        ),
      ],
    );
  }

  /// What this would do, in the order somebody would want to hear it.
  List<String> _summary(ImportPlan plan) {
    String count(int value, String noun) =>
        '$value ${value == 1 ? noun : '${noun}s'}';

    final lines = <String>[];
    if (plan.mode == ImportMode.copies) {
      lines.add('${count(plan.applyCount, 'note')} will be added as copies.');
    } else {
      lines.add(
        plan.applyCount == 0
            ? 'No notes need writing.'
            : '${count(plan.applyCount, 'note')} will be written.',
      );
    }

    // A re-import reports every note as unchanged. That is the happy path, not
    // a failure, and it has to read like one.
    final same = plan.countOf(ImportOutcome.alreadyHere);
    if (same > 0) lines.add('${count(same, 'note')} already up to date.');

    final newer = plan.countOf(ImportOutcome.keptNewer);
    if (newer > 0) {
      lines.add('${count(newer, 'note')} kept — this device has a newer copy.');
    }

    final deleted = plan.countOf(ImportOutcome.deletedSince);
    if (deleted > 0) {
      lines.add('${count(deleted, 'note')} deleted since this export.');
    }

    final missing = plan.countOf(ImportOutcome.missingFile);
    if (missing > 0) {
      lines.add('${count(missing, 'note')} missing from the archive.');
    }

    if (plan.handEditedCount > 0) {
      lines.add(
        '${count(plan.handEditedCount, 'file')} edited since the export; '
        'formatting will be read from the text.',
      );
    }
    return lines;
  }

  String _dateLabel(DateTime at) {
    final local = at.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _ModeChoice extends StatelessWidget {
  const _ModeChoice({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? scheme.primary : palette.controlBorder,
              width: selected ? 1.2 : 0.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: AppControlMetrics.iconControl,
                color: selected ? scheme.primary : palette.textTertiary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: AppTypeScale.body,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: AppTypeScale.caption,
                        color: palette.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
