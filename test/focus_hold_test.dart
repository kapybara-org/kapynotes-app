import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/focus_hold.dart';

void main() {
  ViewFocusEvent eventFor(WidgetTester tester, ViewFocusState state) =>
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: state,
        direction: ViewFocusDirection.undefined,
      );

  Future<FocusNode> pumpFocusedField(WidgetTester tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TextField(focusNode: node))),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    return node;
  }

  // The hold is installed on the engine's dispatcher, as main.dart does. The
  // test binding's own dispatcher answers the getter with its forwarding
  // handler rather than the callback it stores, so wrapping *that* would have
  // the wrapper call itself.
  final dispatcher = PlatformDispatcher.instance;

  testWidgets('without the hold, the framework parks focus when the view '
      'loses it', (tester) async {
    final node = await pumpFocusedField(tester);
    dispatcher.onViewFocusChange!(eventFor(tester, ViewFocusState.unfocused));
    await tester.pump();
    expect(node.hasPrimaryFocus, isFalse);
  });

  testWidgets('with the hold, the editor keeps focus through an inactive '
      'window and is untouched by the reactivation', (tester) async {
    final before = dispatcher.onViewFocusChange;
    holdFocusWhileInactive(dispatcher);
    addTearDown(() => dispatcher.onViewFocusChange = before);

    final node = await pumpFocusedField(tester);
    dispatcher.onViewFocusChange!(eventFor(tester, ViewFocusState.unfocused));
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);

    dispatcher.onViewFocusChange!(eventFor(tester, ViewFocusState.focused));
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
  });
}
