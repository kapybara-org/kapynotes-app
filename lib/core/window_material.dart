import 'package:flutter/services.dart';

/// The blur behind the window, which the runners own and this switches.
///
/// Transparency mode is two halves. Flutter thins its surfaces to tints; the
/// window puts the desktop, blurred, behind them. This is the second half:
/// macOS swaps the visual effect material under the Flutter view for a thin
/// one, and Windows asks the DWM for acrylic. Neither is a package, because
/// the macOS view is created by the runner itself and the Windows attribute
/// is a single call.
///
/// The answer matters. A Windows 10 build without the composition attribute,
/// or a runner from before this channel existed, cannot blur anything, and
/// tints painted over nothing show the black behind the window. The caller
/// keeps its opaque paint until this says the glass is really there.
class WindowMaterial {
  const WindowMaterial._();

  static const MethodChannel _channel = MethodChannel(
    'kapynotes/window_material',
  );

  /// Asks the window to put a blurred desktop behind the Flutter view, or to
  /// take it away. Returns whether the glass is on afterwards.
  ///
  /// [amount] is the settings slider, 0 to 1. The window needs it because the
  /// material has a body of its own: thinning only the tints Flutter paints
  /// leaves that body in place, and the window stops getting any clearer
  /// however far the slider goes.
  static Future<bool> setGlass(bool enabled, {double amount = 0.5}) async {
    try {
      final on = await _channel.invokeMethod<bool>('setGlass', {
        'enabled': enabled,
        'amount': amount.clamp(0.0, 1.0),
      });
      return on ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
