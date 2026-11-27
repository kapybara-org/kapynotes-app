import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Hands Flutter the prebuilt cleaner for the platform being built.
///
/// No build machine needs Rust: .github/workflows/denoise.yml builds the
/// library for every target below and the results are committed under
/// prebuilt/. A target the app ships on with no library there fails the build
/// rather than quietly shipping without Remove noise.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final target = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.android, Architecture.arm64) => 'android-arm64',
      (OS.android, Architecture.arm) => 'android-arm',
      (OS.android, Architecture.x64) => 'android-x64',
      (OS.iOS, Architecture.arm64) =>
        code.iOS.targetSdk == IOSSdk.iPhoneSimulator
            ? 'ios-sim-arm64'
            : 'ios-arm64',
      (OS.iOS, Architecture.x64) => 'ios-sim-x64',
      (OS.macOS, Architecture.arm64) => 'macos-arm64',
      (OS.macOS, Architecture.x64) => 'macos-x64',
      (OS.linux, Architecture.x64) => 'linux-x64',
      (OS.linux, Architecture.arm64) => 'linux-arm64',
      (OS.windows, Architecture.x64) => 'windows-x64',
      _ => null,
    };
    if (target == null) return;
    final file = input.packageRoot.resolve(
      'prebuilt/$target/${code.targetOS.dylibFileName('kapy_denoise')}',
    );
    if (!File.fromUri(file).existsSync()) {
      throw StateError(
        'No prebuilt denoise library for $target. Run the Denoise library '
        'workflow and commit its output under packages/denoise/prebuilt/.',
      );
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'denoise.dart',
        linkMode: DynamicLoadingBundled(),
        file: file,
      ),
    );
    output.dependencies.add(file);
  });
}
