import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../sync/joining.dart';

/// Links that open the app, turned into somewhere to go.
///
/// `kapynotes://join/<token>` and `kapynotes://space/<token>` on every
/// platform, and on Android the https links it has verified against
/// kapynotes.com. Anything else is ignored.
///
/// The latest one is held until something takes it, because a link can arrive
/// before there is anyone to act on it: at launch, while the account is still
/// restoring, or while signed out. Taking it clears it, so it is acted on once.
///
/// Built in `main()` and handed to the app, never inside a widget. With no
/// native side — which is every widget test — cancelling a subscription to the
/// platform's stream never completes, and a suite that met one would hang.
class DeepLinks extends ChangeNotifier {
  DeepLinks(Stream<Uri> links) {
    _subscription = links.listen(offer, onError: (Object _) {});
  }

  /// The platform's links. `uriLinkStream` carries the one the app was
  /// launched with as well as every one after it, so nothing else is asked:
  /// asking `getInitialLink` too would deliver a cold start's link twice.
  factory DeepLinks.platform() => DeepLinks(AppLinks().uriLinkStream);

  late final StreamSubscription<Uri> _subscription;
  JoinTarget? _pending;
  JoinTarget? _last;
  DateTime? _lastAt;

  /// The link waiting to be acted on, if any.
  JoinTarget? get pending => _pending;

  /// Offers a link. The same one again within a few seconds is the same
  /// link: a platform can hand over a launch link twice.
  void offer(Uri uri) {
    final target = parseJoinTarget(uri.toString());
    if (target == null) return;
    final now = DateTime.now();
    final at = _lastAt;
    if (target == _last &&
        at != null &&
        now.difference(at) < const Duration(seconds: 5)) {
      return;
    }
    _last = target;
    _lastAt = now;
    _pending = target;
    notifyListeners();
  }

  /// Takes the waiting link, so that it is acted on exactly once.
  JoinTarget? take() {
    final target = _pending;
    _pending = null;
    return target;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
