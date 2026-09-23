import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/blob_store.dart';
import '../../data/note_attachment.dart';
import '../../files/file_ingest.dart';
import '../../files/file_opener.dart';
import '../../images/note_image_provider.dart';
import '../context_menu.dart';
import 'note_image_layout.dart';

/// How tall a file sits in the text. Fixed, like a recording's chip, so a
/// state change never reflows the note under the reader.
const double noteFileChipHeight = 48;

typedef FileHandoff =
    Future<FileHandoffOutcome> Function(
      NoteFileRef ref, {
      required BlobStore store,
      NoteImageFetcher? fetch,
    });

/// A file, sitting in the body of a note.
///
/// One row: what it is, what it is called, how big it is, and where it is up
/// to. A click opens it on a desktop and offers to save it on a phone, where
/// there is no "open with the default app" for an arbitrary file.
class NoteFileChip extends StatefulWidget {
  const NoteFileChip({
    super.key,
    required this.ref,
    required this.store,
    this.fetch,
    this.uploadProgress,
    this.onRemove,
    this.open = _defaultOpen,
    this.save = saveAttachmentFile,
    this.canOpen,
  });

  final NoteFileRef ref;
  final BlobStore store;

  /// Null while signed out: the file is then only ever on this device.
  final NoteImageFetcher? fetch;

  /// Non-null while this file has not reached the server and an account
  /// exists to send it to: null inside means waiting, a fraction means going.
  final ValueListenable<double?>? uploadProgress;

  final VoidCallback? onRemove;
  final FileHandoff open;
  final FileHandoff save;

  /// Overrides the platform answer, for tests.
  final bool? canOpen;

  static Future<FileHandoffOutcome> _defaultOpen(
    NoteFileRef ref, {
    required BlobStore store,
    NoteImageFetcher? fetch,
  }) => openAttachmentFile(ref, store: store, fetch: fetch);

  @override
  State<NoteFileChip> createState() => _NoteFileChipState();
}

class _NoteFileChipState extends State<NoteFileChip> {
  bool _busy = false;
  bool _downloadFailed = false;

  bool get _canOpen =>
      (widget.canOpen ?? canOpenAttachmentFiles) &&
      !isExecutableFile(widget.ref);

  Future<void> _run(FileHandoff action, {required bool saving}) async {
    // A second press while the first is still fetching would start a second
    // download of the same bytes; the first will finish for both.
    if (_busy) return;
    setState(() {
      _busy = true;
      _downloadFailed = false;
    });
    final outcome = await action(
      widget.ref,
      store: widget.store,
      fetch: widget.fetch,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _downloadFailed = outcome == FileHandoffOutcome.notDownloaded;
    });
    switch (outcome) {
      case FileHandoffOutcome.done:
      case FileHandoffOutcome.cancelled:
        break;
      case FileHandoffOutcome.notDownloaded:
        Toast.show(
          context,
          widget.fetch == null
              ? 'This file is on another device. Sign in to get it here'
              : "Couldn't download ${widget.ref.name}. Try again when online",
          icon: KapyIcons.cloudOffRounded,
          isError: true,
        );
      case FileHandoffOutcome.blocked:
        Toast.show(
          context,
          "Kapy Notes doesn't open programs. Save a copy to run it",
          icon: KapyIcons.warningRounded,
          isError: true,
        );
      case FileHandoffOutcome.failed:
        Toast.show(
          context,
          "Couldn't ${saving ? 'save' : 'open'} ${widget.ref.name}",
          isError: true,
        );
    }
  }

  void _primary() => _canOpen
      ? _run(widget.open, saving: false)
      : _run(widget.save, saving: true);

  Future<void> _showMenu(Offset position) async {
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        if (_canOpen)
          const PopupMenuItem(value: 'open', height: 36, child: Text('Open')),
        const PopupMenuItem(
          value: 'save',
          height: 36,
          child: Text('Save a copy…'),
        ),
        if (widget.onRemove != null)
          const PopupMenuItem(
            value: 'remove',
            height: 36,
            child: Text('Remove'),
          ),
      ],
    );
    if (!mounted) return;
    if (choice == 'open') await _run(widget.open, saving: false);
    if (choice == 'save') await _run(widget.save, saving: true);
    if (choice == 'remove') widget.onRemove?.call();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ref = widget.ref;
    final hint = _canOpen ? 'Open ${ref.name}' : 'Save a copy of ${ref.name}';
    return Semantics(
      label: '${ref.name}, ${formatFileSize(ref.bytes)}',
      hint: hint,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: noteImageGap),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Tooltip(
            message: hint,
            triggerMode: TooltipTriggerMode.manual,
            child: GestureDetector(
              key: ValueKey('note-file-body-${ref.hash}'),
              behavior: HitTestBehavior.opaque,
              onTap: _primary,
              onSecondaryTapDown: (details) =>
                  _showMenu(details.globalPosition),
              onLongPressStart: (details) => _showMenu(details.globalPosition),
              child: Stack(
                children: [
                  Container(
                    height: noteFileChipHeight,
                    decoration: BoxDecoration(
                      color: palette.controlBackground,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.controlBorder),
                    ),
                    padding: EdgeInsets.only(
                      left: 12,
                      right: widget.onRemove == null ? 12 : 38,
                    ),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 20,
                          child: _busy
                              ? Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: CircularProgressIndicator(
                                    key: const ValueKey('note-file-busy'),
                                    strokeWidth: 1.75,
                                    color: palette.textSecondary,
                                  ),
                                )
                              : KapyIcon(
                                  _downloadFailed
                                      ? KapyIcons.cloudOffRounded
                                      : KapyIcons.fileOutlined,
                                  size: 20,
                                  color: palette.textSecondary,
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ref.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTypeScale.small,
                                  color: palette.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              _Status(
                                bytes: ref.bytes,
                                uploaded: ref.isUploaded,
                                progress: widget.uploadProgress,
                                downloadFailed: _downloadFailed,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onRemove != null)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 6,
                      child: Center(
                        child: Tooltip(
                          message: 'Remove file',
                          child: IconButton(
                            key: const ValueKey('remove-note-file'),
                            onPressed: widget.onRemove,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 28,
                              height: 28,
                            ),
                            icon: KapyIcon(
                              KapyIcons.closeRounded,
                              size: 16,
                              color: palette.textSecondary,
                            ),
                          ),
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

/// "2.4 MB", then where the file is up to when that is worth saying.
class _Status extends StatelessWidget {
  const _Status({
    required this.bytes,
    required this.uploaded,
    required this.progress,
    required this.downloadFailed,
  });

  final int bytes;
  final bool uploaded;
  final ValueListenable<double?>? progress;
  final bool downloadFailed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      fontSize: AppTypeScale.caption,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: palette.textSecondary,
    );
    final size = formatFileSize(bytes);
    if (downloadFailed) {
      return Text(
        "$size · Couldn't download",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final listenable = progress;
    if (uploaded || listenable == null) {
      return Text(size, maxLines: 1, style: style);
    }
    return ValueListenableBuilder<double?>(
      valueListenable: listenable,
      builder: (context, value, _) => Text(
        value == null
            ? '$size · Waiting to sync'
            : value >= 1
            ? size
            : '$size · Uploading ${(value * 100).floor()}%',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
