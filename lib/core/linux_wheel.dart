import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// One notch of a mouse wheel scrolls as far as it does in a GTK app.
///
/// The Linux engine turns a notch into 53 px whatever it scrolls
/// (`fl_scrolling_manager.cc`, a number taken from Chromium). GTK scrolls a
/// pane by its height to the power of two thirds: measured in GTK 3 and
/// GTK 4 on Xvfb, a notch moves a 400 px pane 54 px, a 600 px one 71 px and
/// an 848 px one 90 px. So in a 900 px window,
/// where a note is 848 px tall, a notch moved the note 53 px where any other
/// app on the desktop moved 90.
///
/// The window's height stands in for the pane's, since an event doesn't say
/// which pane it will scroll; the note and the lists run nearly the window's
/// height, so their step comes within a few percent of GTK's.
///
/// Only the wheel's up and down. A sideways notch, from a tilting or a thumb
/// wheel, keeps its step: sideways is the swipe that opens the notes list
/// (`SidebarSwipe.threshold`), and one notch shouldn't be enough for it. A
/// touchpad's scrolling isn't a wheel's (it is a pan that follows the
/// fingers), and with Ctrl or Meta held the wheel zooms, in steps of its own.
mixin GtkWheelSteps on GestureBinding {
  /// How far the Linux engine scrolls one notch, in logical pixels.
  static const double engineNotch = 53;

  @override
  void handlePointerEvent(PointerEvent event) => super.handlePointerEvent(
    event is PointerScrollEvent ? _gtkStep(event) : event,
  );

  PointerScrollEvent _gtkStep(PointerScrollEvent event) {
    final keys = HardwareKeyboard.instance;
    final view = platformDispatcher.view(id: event.viewId);
    if (event.kind != PointerDeviceKind.mouse ||
        keys.isControlPressed ||
        keys.isMetaPressed ||
        view == null) {
      return event;
    }
    final page = view.physicalSize.height / view.devicePixelRatio;
    final step = math.pow(page, 2 / 3);
    return PointerScrollEvent(
      viewId: event.viewId,
      timeStamp: event.timeStamp,
      kind: event.kind,
      device: event.device,
      position: event.position,
      embedderId: event.embedderId,
      scrollDelta: Offset(
        event.scrollDelta.dx,
        event.scrollDelta.dy * step / engineNotch,
      ),
      onRespond: event.respond,
    );
  }
}
