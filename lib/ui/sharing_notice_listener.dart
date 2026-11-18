import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/toast.dart';
import '../sync/account.dart';
import '../sync/sharing.dart';
import '../sync/sync_api.dart';

/// Says each [SharingNotice] as a toast, wherever the person is. A share
/// that was accepted on its own offers to leave again from the toast.
class SharingNoticeListener extends StatefulWidget {
  const SharingNoticeListener({
    super.key,
    required this.account,
    required this.child,
  });

  final Account? account;
  final Widget child;

  @override
  State<SharingNoticeListener> createState() => _SharingNoticeListenerState();
}

class _SharingNoticeListenerState extends State<SharingNoticeListener> {
  Sharing? _sharing;
  StreamSubscription<SharingNotice>? _notices;

  @override
  void initState() {
    super.initState();
    widget.account?.addListener(_follow);
    _follow();
  }

  @override
  void didUpdateWidget(SharingNoticeListener old) {
    super.didUpdateWidget(old);
    if (old.account == widget.account) return;
    old.account?.removeListener(_follow);
    widget.account?.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.account?.removeListener(_follow);
    unawaited(_notices?.cancel());
    super.dispose();
  }

  void _follow() {
    final sharing = widget.account?.sharing;
    if (identical(sharing, _sharing)) return;
    unawaited(_notices?.cancel());
    _sharing = sharing;
    _notices = sharing?.notices.listen(_show);
  }

  void _show(SharingNotice notice) {
    final sharing = _sharing;
    final spaceId = notice.leaveSpaceId;
    if (!mounted || sharing == null) return;
    Toast.show(
      context,
      notice.message,
      action: spaceId == null ? null : 'Leave',
      onAction: spaceId == null
          ? null
          : () => unawaited(_leave(sharing, spaceId)),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;

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
}
