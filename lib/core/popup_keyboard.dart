import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// Keeps a newly opened popup from inheriting the editor's software keyboard.
///
/// The second pass wins over focus requested while the popup's first frame is
/// being mounted. A field can still open the keyboard after the user taps it.
void keepMobilePopupKeyboardClosed() {
  if (!AppPlatform.isMobile) return;

  void dismiss() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  dismiss();
  WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
}

/// Applies the mobile keyboard policy to dialogs, sheets, and popup menus.
class MobilePopupKeyboardObserver extends NavigatorObserver {
  void _guardOpeningPopup(PopupRoute<dynamic> route) {
    if (!AppPlatform.isMobile) return;
    keepMobilePopupKeyboardClosed();

    final animation = route.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return;
    }

    late AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      animation.removeStatusListener(listener);
      if (status == AnimationStatus.completed) {
        // Navigator requests route focus when the entrance transition ends.
        // Run once more after that request has had a chance to settle.
        keepMobilePopupKeyboardClosed();
      }
    };
    animation.addStatusListener(listener);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route is PopupRoute<dynamic>) _guardOpeningPopup(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (route is PopupRoute<dynamic>) keepMobilePopupKeyboardClosed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (route is PopupRoute<dynamic>) keepMobilePopupKeyboardClosed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute is PopupRoute<dynamic>) {
      _guardOpeningPopup(newRoute);
    } else if (oldRoute is PopupRoute<dynamic>) {
      keepMobilePopupKeyboardClosed();
    }
  }
}
