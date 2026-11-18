import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../speech/local_models.dart';

/// What to do about a large download asked for on mobile data.
enum MobileDataChoice { now, onWifi }

/// Asks before a download of [bytes] spends somebody's mobile data, with
/// waiting for Wi-Fi as the first answer.
///
/// Null when dismissed, which downloads nothing.
Future<MobileDataChoice?> showMobileDataSheet(
  BuildContext context, {
  required String name,
  required int bytes,
}) {
  return showDialog<MobileDataChoice>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('mobile-data-dialog'),
      title: Text('Download $name on mobile data?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          "It's ${fileSize(bytes)}. Waiting for Wi-Fi keeps it off your data "
          'plan; it starts when you join one while Kapy Notes is open.',
          style: TextStyle(fontSize: 13, color: context.palette.textSecondary),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('mobile-data-now'),
          onPressed: () => Navigator.of(context).pop(MobileDataChoice.now),
          child: const Text('Use mobile data'),
        ),
        TextButton(
          key: const ValueKey('mobile-data-wifi'),
          onPressed: () => Navigator.of(context).pop(MobileDataChoice.onWifi),
          child: const Text('Wait for Wi-Fi'),
        ),
      ],
    ),
  );
}
