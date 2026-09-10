/// The macOS half of `sherpa_onnx`, with the native library left out.
///
/// See `packages/apple_stubs/README.md` for why. Nothing here is ever called
/// with any effect: Flutter registers the class, and the app never asks
/// `sherpa_onnx` to load a library on macOS.
class SherpaOnnxMacosStub {
  static void registerWith() {}
}
