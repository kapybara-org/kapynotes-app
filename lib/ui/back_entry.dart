import 'dart:async';

import 'package:flutter/widgets.dart';

/// Something Back closes before the page under it goes: a slash menu, a
/// link's popover, the selection bubble, Kapy AI's picker. While open it is
/// one pop entry on the route it was opened over, so Android's Back closes it
/// first and iOS's swipe waits until it has gone.
class BackEntry implements PopEntry<Object?> {
  BackEntry(this.onBack);

  /// Closes it. Called a moment after the press, once the route is done
  /// asking its entries.
  final VoidCallback onBack;

  static int _open = 0;

  /// Whether any is open, so a page's own Back leaves the press to it.
  static bool get anyOpen => _open > 0;

  ModalRoute<Object?>? _route;

  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(false);

  /// Registers it on the route around [context], once.
  void open(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route == _route) return;
    close();
    if (route == null) return;
    _route = route..registerPopEntry(this);
    _open++;
  }

  void close() {
    final route = _route;
    if (route == null) return;
    _route = null;
    _open--;
    route.unregisterPopEntry(this);
  }

  @override
  void onPopInvoked(bool didPop) {}

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) scheduleMicrotask(onBack);
  }
}
