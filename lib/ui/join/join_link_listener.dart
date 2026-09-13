import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/deep_links.dart';
import '../../core/toast.dart';
import '../../sync/account.dart';
import '../../sync/joining.dart';
import '../../sync/sharing.dart';
import '../share_dialog.dart';
import 'join_link_sheet.dart';

/// Acts on links that opened the app, and tells an owner when somebody asks
/// to join one of their spaces.
///
/// Sits just under the Navigator — around the home screen — so it can show a
/// dialog. A link that arrives before there is an account to act with is kept
/// until there is one: at launch while the account restores, or while signed
/// out, when the person is told once to sign in.
///
/// Requests are noticed through the account's own notifications: the server
/// announces a new one to the owner's devices, which refresh their spaces, and
/// that refresh is what prompts a look at who is waiting. Looked at no more
/// than once every fifteen seconds, because a busy sync notifies far more
/// often than anybody asks to join anything.
class JoinLinkListener extends StatefulWidget {
  const JoinLinkListener({
    super.key,
    required this.links,
    required this.account,
    required this.child,
  });

  /// Null in tests, and anywhere links cannot arrive.
  final DeepLinks? links;
  final Account? account;
  final Widget child;

  @override
  State<JoinLinkListener> createState() => _JoinLinkListenerState();
}

class _JoinLinkListenerState extends State<JoinLinkListener> {
  static const _lookEvery = Duration(seconds: 15);

  bool _showing = false;
  bool _toldToSignIn = false;
  Sharing? _sharing;

  Timer? _waitingTimer;
  DateTime? _lastLook;
  Set<String> _knownWaiting = const {};
  bool _primed = false;

  @override
  void initState() {
    super.initState();
    widget.links?.addListener(_linkArrived);
    widget.account?.addListener(_accountChanged);
    _followSharing();
    // A link can be waiting from before this was built: the one the app was
    // launched with.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_act()));
  }

  @override
  void didUpdateWidget(JoinLinkListener old) {
    super.didUpdateWidget(old);
    if (old.links != widget.links) {
      old.links?.removeListener(_linkArrived);
      widget.links?.addListener(_linkArrived);
    }
    if (old.account != widget.account) {
      old.account?.removeListener(_accountChanged);
      widget.account?.addListener(_accountChanged);
      _followSharing();
    }
  }

  @override
  void dispose() {
    widget.links?.removeListener(_linkArrived);
    widget.account?.removeListener(_accountChanged);
    _sharing?.removeListener(_sharingChanged);
    _waitingTimer?.cancel();
    super.dispose();
  }

  void _linkArrived() => unawaited(_act());

  void _accountChanged() {
    _followSharing();
    unawaited(_act());
  }

  /// Signing in makes a new [Sharing]; signing out drops it. Whoever was
  /// waiting belongs to the account that saw them.
  void _followSharing() {
    final sharing = widget.account?.sharing;
    if (identical(sharing, _sharing)) return;
    _sharing?.removeListener(_sharingChanged);
    _sharing = sharing;
    _knownWaiting = const {};
    _primed = false;
    if (sharing != null) {
      sharing.addListener(_sharingChanged);
      _scheduleLook();
    }
  }

  void _sharingChanged() => _scheduleLook();

  // --- links ---------------------------------------------------------------

  Future<void> _act() async {
    if (_showing || !mounted) return;
    final links = widget.links;
    if (links?.pending == null) return;

    final account = widget.account;
    final sharing = account?.sharing;
    final joining = account?.joining;
    if (account == null ||
        account.state != AccountState.ready ||
        sharing == null ||
        joining == null) {
      final signedOut =
          account == null || account.state == AccountState.signedOut;
      if (signedOut && !_toldToSignIn) {
        _toldToSignIn = true;
        Toast.show(context, 'Sign in to open that link.');
      }
      return;
    }

    final target = links!.take();
    if (target == null) return;
    _toldToSignIn = false;
    _showing = true;
    try {
      switch (target) {
        case SpaceLinkTarget(:final token):
          await showJoinLinkSheet(
            context,
            token: token,
            joining: joining,
            sharing: sharing,
          );
        case InviteTarget(:final token):
          await showInvitationSheet(context, token: token, sharing: sharing);
      }
    } finally {
      _showing = false;
    }
    // Another may have arrived while that one was open.
    if (mounted) unawaited(_act());
  }

  // --- who is waiting --------------------------------------------------------

  void _scheduleLook() {
    if (_waitingTimer != null) return;
    final last = _lastLook;
    final wait = last == null
        ? Duration.zero
        : _lookEvery - DateTime.now().difference(last);
    _waitingTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _waitingTimer = null;
      unawaited(_look());
    });
  }

  Future<void> _look() async {
    final account = widget.account;
    final sharing = account?.sharing;
    final joining = account?.joining;
    if (account == null ||
        account.state != AccountState.ready ||
        sharing == null ||
        joining == null) {
      return;
    }
    _lastLook = DateTime.now();

    final waiting = <String, JoinRequest>{};
    final spaceNames = <String, String>{};
    for (final space in sharing.teams) {
      if (!space.isOwner) continue;
      try {
        for (final r in await joining.loadRequests(space.id)) {
          final key = '${space.id}/${r.userId}';
          waiting[key] = r;
          spaceNames[key] = space.displayName;
        }
      } on Object {
        return; // Offline: look again on the next change.
      }
    }
    if (!mounted || !identical(sharing, _sharing)) return;

    final firstLook = !_primed;
    final fresh = [
      for (final key in waiting.keys)
        if (!_knownWaiting.contains(key)) key,
    ];
    _knownWaiting = waiting.keys.toSet();
    _primed = true;
    if (fresh.isEmpty) return;

    final key = fresh.first;
    final person = waiting[key]!;
    final who = person.name ?? person.email;
    final space = spaceNames[key]!;
    final String message;
    if (fresh.length == 1) {
      message = firstLook
          ? '$who is waiting to join “$space”.'
          : '$who asked to join “$space”.';
    } else {
      message = firstLook
          ? '${fresh.length} people are waiting to join your spaces.'
          : '${fresh.length} people asked to join your spaces.';
    }
    final spaceId = key.substring(0, key.indexOf('/'));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const ValueKey('join-request-snackbar'),
        content: Text(message),
        action: SnackBarAction(
          label: 'Review',
          onPressed: () => unawaited(
            showSpaceDialog(context, spaceId: spaceId, sharing: sharing),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
