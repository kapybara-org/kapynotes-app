import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'platform.dart';

/// On a phone, a finger that lands outside a text field's tap group puts its
/// keyboard away, as a click outside one already does on the desktop.
/// Flutter keeps a touch's focus everywhere but the web, which left a field
/// whose return key sends, such as Kapy AI's, with no way to close its
/// keyboard and reach the bar under it. A scroll that starts outside the
/// field closes it the same way, since it starts with that finger.
///
/// Every other pointer, and every desktop, gets Flutter's own rule. The note
/// editor is no [EditableText] and keeps a rule of its own, so a finger under
/// a note's text still puts the caret there.
class TouchUnfocusAction extends Action<EditableTextTapOutsideIntent> {
  @override
  Object? invoke(EditableTextTapOutsideIntent intent) {
    if (AppPlatform.isMobile &&
        intent.pointerDownEvent.kind == PointerDeviceKind.touch) {
      intent.focusNode.unfocus();
      return null;
    }
    return callingAction?.invoke(intent);
  }
}

/// A control that works with the keyboard up, such as Send or the model
/// picker. On a phone it joins the text fields' tap group, so touching it
/// keeps the field focused and the keyboard up. On the desktop it stays
/// outside, so a click on it drops the field's focus as it always has.
class KeepsKeyboard extends StatelessWidget {
  const KeepsKeyboard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      TextFieldTapRegion(enabled: AppPlatform.isMobile, child: child);
}
