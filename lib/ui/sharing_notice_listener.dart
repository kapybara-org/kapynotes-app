import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../sync/account.dart';
import '../sync/sharing.dart';
import '../sync/sync_api.dart';

/// Follows the account to whichever [Sharing] it has now, signed in or not,
/// and says that one's notices.
class SharingNoticeListener extends StatelessWidget {
  const SharingNoticeListener({
    super.key,
    required this.account,
    required this.child,
  });

  final Account? account;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return child;
    return ListenableBuilder(
      listenable: account,
      builder: (context, child) =>
          SharingNotices(sharing: account.sharing, child: child!),
      child: child,
    );
  }
}

/// Says each [SharingNotice] as a toast, wherever the person is. A share
/// that was accepted on its own offers to leave again from the toast.
class SharingNotices extends StatefulWidget {
  const SharingNotices({super.key, required this.sharing, required this.child});

  final Sharing? sharing;
  final Widget child;

  @override
  State<SharingNotices> createState() => _SharingNoticesState();
}

class _SharingNoticesState extends State<SharingNotices> {
  StreamSubscription<SharingNotice>? _notices;

  @override
  void initState() {
    super.initState();
    _notices = widget.sharing?.notices.listen(_show);
  }

  @override
  void didUpdateWidget(SharingNotices old) {
    super.didUpdateWidget(old);
    if (identical(old.sharing, widget.sharing)) return;
    unawaited(_notices?.cancel());
    _notices = widget.sharing?.notices.listen(_show);
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    super.dispose();
  }

  void _show(SharingNotice notice) {
    final sharing = widget.sharing;
    final spaceId = notice.leaveSpaceId;
    if (!mounted || sharing == null) return;
    Toast.show(
      context,
      notice.message,
      icon: notice.arrived && !AppPlatform.hasPointer
          ? KapyIcons.groupOutlined
          : null,
      isError: notice.isError,
      action: spaceId == null ? null : 'Leave',
      onAction: spaceId == null
          ? null
          : () => unawaited(_leave(sharing, spaceId)),
    );
  }

  Future<void> _leave(Sharing sharing, String spaceId) async {
    try {
      await sharing.leave(spaceId);
      if (mounted) Toast.show(context, 'Left. Your copy stays in your notes');
    } on SyncException {
      if (mounted) {
        Toast.show(
          context,
          "Couldn't leave. Try again from Shared",
          isError: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
