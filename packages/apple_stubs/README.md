# Apple stubs

Empty stand-ins for the iOS and macOS halves of `sherpa_onnx`, wired in
through `dependency_overrides` in the app's `pubspec.yaml`.

The real packages vendor ONNX Runtime and the sherpa-onnx C API as a
26 MB framework on iOS and a 56 MB dylib on macOS, linked at load time. Kapy
Notes does not run Parakeet on Apple's platforms — every Mac and iPhone it
supports has an on-device recogniser of its own, which `AppleTranscriber` uses
— so on those two the binaries bought nothing but download size and launch
time. `sherpa_onnx` stays a dependency for Windows, Android and Linux, where
there is no platform recogniser, and its Dart code is never asked to load a
library on a platform where these stubs stand in for it.

Each stub is a Dart-only plugin (`dartPluginClass`, no native code) rather than
a plain package, so Flutter's tooling sees a real implementation for the
platform and prints no warning about the missing default.
