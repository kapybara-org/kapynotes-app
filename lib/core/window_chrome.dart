import 'platform.dart';

/// Space the operating system paints its own controls into, on top of the
/// app's content.
///
/// The macOS window uses a hidden title bar so the toolbar can act as window
/// chrome. That is what a native notes app looks like, but it also means the
/// traffic lights are drawn over whatever is in the window's top-left corner
/// — nothing reserves that space for us.
class WindowChrome {
  const WindowChrome._();

  /// Width from the window's left edge to the right of the zoom button, plus
  /// breathing room. Close/minimise/zoom are 12pt wide with 8pt gaps starting
  /// at x=13, so they end at x=65.
  static const double trafficLightsWidth = 78;

  /// Height of the same region, measured to the bottom of the buttons.
  static const double trafficLightsHeight = 32;

  /// True where the OS draws window controls over the app's own content.
  static bool get overlaysContent => AppPlatform.isMacOS;

  /// Inset for a pane flush against the window's left edge that wants to keep
  /// its content beside the window controls.
  static double leadingInset({required bool atWindowLeftEdge}) =>
      overlaysContent && atWindowLeftEdge ? trafficLightsWidth : 0;

  /// Inset for a pane flush against the window's left edge that would rather
  /// keep its content below the window controls. Taller panes prefer this;
  /// a single-row toolbar has no room and uses [leadingInset] instead.
  static double topInset({required bool atWindowLeftEdge}) =>
      overlaysContent && atWindowLeftEdge ? trafficLightsHeight : 0;
}
