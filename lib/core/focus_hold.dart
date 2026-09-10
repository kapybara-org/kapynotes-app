import 'dart:ui';

/// Keeps the editor focused while the window is not the active one, so that
/// a dictation tool looking at the app from outside still finds a text field.
///
/// Wispr Flow, Spokenly and their kind decide how to deliver a transcript by
/// asking the system for the app's focused accessibility element. A text
/// field means they can type into it; anything else means the app has nowhere
/// to put words, and they copy the transcript to the clipboard instead, with
/// a notice and without an error. They ask at the moment their own recording
/// window comes up — which is the moment ours stops being the active window.
///
/// The framework's answer to a window going inactive is to park focus on the
/// root scope: nothing is focused, so nothing can receive keys the window
/// will not be sent anyway. On macOS that has a visible consequence. The
/// engine backs a focused text field with a real `NSTextField` whose field
/// editor is the input plugin, and it is that field editor the system reports
/// as focused. Parking focus closes the input connection, the field editor is
/// taken down, and the app's focused element falls back to the plain group
/// that is the Flutter view. A native text view keeps its place through a
/// deactivation, so every other app on the machine passes the test and this
/// one did not.
///
/// The unfocused event is dropped here, before the framework sees it. The
/// focused event that follows a reactivation still goes through; with the
/// editor never having let go, it changes nothing. Nothing is lost by keeping
/// the focus: an inactive window receives no key events, so there is nothing
/// for the parked focus to protect against.
///
/// Installed once, after the binding has registered its own handler, which
/// [WidgetsFlutterBinding.ensureInitialized] does. Only macOS is known to
/// need this; Windows tools reach the editor by other means (see
/// `windows/runner/synthetic_keys.cpp`) and its behaviour under this change
/// has not been exercised.
void holdFocusWhileInactive(PlatformDispatcher dispatcher) {
  final forward = dispatcher.onViewFocusChange;
  dispatcher.onViewFocusChange = (ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) return;
    forward?.call(event);
  };
}
