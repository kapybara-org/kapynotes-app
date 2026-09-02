import 'dart:async';
import 'dart:developer' show Timeline;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';

/// The smallest useful mobile first frame: a focused, editable note surface.
///
/// It intentionally has no storage, calculator, assets, custom fonts, routes,
/// or Material theme on its critical path. The root app replaces it after
/// saved notes finish hydrating and carries its text into a normal note.
class InstantCaptureApp extends StatefulWidget {
  const InstantCaptureApp({super.key, required this.controller});

  static const editorKey = ValueKey('instant-capture-editor');

  final TextEditingController controller;

  @override
  State<InstantCaptureApp> createState() => _InstantCaptureAppState();
}

class _InstantCaptureAppState extends State<InstantCaptureApp>
    with WidgetsBindingObserver {
  static const _retryInterval = Duration(milliseconds: 150);
  static const _maxKeyboardRetries = 10;

  final FocusNode _focusNode = FocusNode(debugLabel: 'instant-capture');
  Timer? _keyboardRetryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Timeline.instantSync('KapyNotes.readyToType');
      _focusAndShowKeyboard();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusAndShowKeyboard();
      });
    }
  }

  void _focusAndShowKeyboard() {
    _focusNode.requestFocus();
    _keyboardRetryTimer?.cancel();
    if (!AppPlatform.isMobile && !AppPlatform.isFlutterTest) return;

    _showKeyboard();
    _keyboardRetryTimer = Timer.periodic(_retryInterval, (timer) {
      if (!mounted ||
          !_focusNode.hasFocus ||
          MediaQuery.viewInsetsOf(context).bottom > 0 ||
          timer.tick >= _maxKeyboardRetries) {
        timer.cancel();
        return;
      }
      _showKeyboard();
    });
  }

  void _showKeyboard() =>
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keyboardRetryTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: const Color(0xFFFAF9F7),
      debugShowCheckedModeBanner: false,
      builder: (context, _) =>
          _CaptureSurface(controller: widget.controller, focusNode: _focusNode),
    );
  }
}

class _CaptureSurface extends StatelessWidget {
  const _CaptureSurface({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final background = dark ? const Color(0xFF242018) : const Color(0xFFF7F0DE);
    final foreground = dark ? const Color(0xFFEDE2CA) : const Color(0xFF26364A);
    final cursor = dark ? const Color(0xFFE58A65) : const Color(0xFFA94A35);

    return ColoredBox(
      color: background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Semantics(
            label: 'Quick note',
            textField: true,
            child: EditableText(
              key: InstantCaptureApp.editorKey,
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              expands: true,
              maxLines: null,
              minLines: null,
              style: TextStyle(
                color: foreground,
                fontSize: 16,
                height: 1.55,
                fontFamilyFallback: AppPlatform.monoFontFallback,
              ),
              cursorColor: cursor,
              backgroundCursorColor: background,
              selectionColor: cursor.withValues(alpha: 0.24),
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              keyboardAppearance: dark ? Brightness.dark : Brightness.light,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              scrollPadding: const EdgeInsets.all(40),
            ),
          ),
        ),
      ),
    );
  }
}
