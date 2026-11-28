import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/note_attachment.dart';
import 'sharing_sheet.dart';

/// Says once that something just added can't sync, because the account has
/// reached its storage limit, and that it stays in the note meanwhile. A sheet
/// on a phone and the centred alert on a computer. True when the person asked
/// to see their storage.
Future<bool> showStorageFullSheet(
  BuildContext context,
  NoteAttachmentRef refused,
) async {
  final kind = switch (refused) {
    NoteVideoRef() => 'video',
    NoteImageRef() => 'photo',
    NoteVoiceRef() => 'voice note',
    NoteFileRef() || NoteUnknownRef() => 'file',
  };
  final device = AppPlatform.isMobile ? 'phone' : 'computer';
  final title = "This $kind can't sync yet";
  final body =
      'Your account has reached its storage limit. The $kind stays in this '
      "note on this $device, and goes to your other devices once there's "
      'room.';
  final see = await showSharingSheet<bool>(
    context,
    (asSheet) => asSheet
        ? SharingSheetFrame(
            child: _StorageFullSheet(title: title, body: body),
          )
        : _StorageFullDialog(title: title, body: body),
  );
  return see ?? false;
}

class _StorageFullDialog extends StatelessWidget {
  const _StorageFullDialog({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('storage-full'),
    title: Text(title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Text(
        body,
        style: TextStyle(
          fontSize: AppTypeScale.control,
          height: 1.4,
          color: context.palette.textPrimary,
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('storage-full-ok'),
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('OK'),
      ),
      FilledButton(
        key: const ValueKey('storage-full-see'),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('See storage'),
      ),
    ],
  );
}

/// a5's sheet: the cloud crossed out beside the title, the words under it,
/// then See storage and OK side by side.
class _StorageFullSheet extends StatelessWidget {
  const _StorageFullSheet({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
    );
    TextStyle label(Color color) => chromeStyle(
      size: 15,
      line: 20,
      weight: AppWeight.regular,
      color: color,
    );
    return SingleChildScrollView(
      key: const ValueKey('storage-full'),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              KapyIcon(
                KapyIcons.cloudOffRounded,
                size: 19,
                color: palette.textPrimary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    height: 22 / 17,
                    fontWeight: AppWeight.font(AppWeight.semibold),
                    fontVariations: AppWeight.wght(AppWeight.semibold),
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('storage-full-see'),
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    backgroundColor: palette.tonalBackground,
                    foregroundColor: palette.tonalForeground,
                    textStyle: label(palette.tonalForeground),
                    shape: shape,
                  ),
                  child: const Text('See storage'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  key: const ValueKey('storage-full-ok'),
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    foregroundColor: palette.textPrimary,
                    textStyle: label(palette.textPrimary),
                    shape: shape.copyWith(
                      side: BorderSide(
                        color: palette.separator,
                        width: AppHairline.of(context),
                      ),
                    ),
                  ),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
