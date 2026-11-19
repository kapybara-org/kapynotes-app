import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the system asks for more contrast where Flutter cannot say.
///
/// Flutter's own [AccessibilityFeatures.highContrast] covers iOS (Increase
/// Contrast), Windows (High contrast) and Android's contrast level. The macOS
/// embedder never sets it, and Android's High contrast text is a switch of
/// its own, so on those two the platform answers on this channel and calls
/// back when the setting changes. Everywhere else nothing answers, and this
/// stays false.
class SystemContrast extends ValueNotifier<bool> {
  SystemContrast() : super(false);

  static const MethodChannel channel = MethodChannel('kapynotes/contrast');

  bool _disposed = false;

  /// Reads the setting once and listens for every change after that.
  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && !_disposed) {
        value = call.arguments == true;
      }
    });
    try {
      final asks = await channel.invokeMethod<bool>('increaseContrast');
      if (!_disposed) value = asks ?? false;
    } catch (_) {
      // No handler on this platform, or none behind a test: nobody asked.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
