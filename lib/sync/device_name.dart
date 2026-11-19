import 'package:device_info_plus/device_info_plus.dart';

import '../core/platform.dart';

/// What this device calls itself, for "changed on 18 Nov from Sanjay's
/// MacBook". Computers carry a name their owner chose; phones only report a
/// model, so they borrow the account's first name. Null when nothing useful is
/// known, which reads as "another device".
Future<String?> thisDeviceName({String? ownerName}) async {
  final info = DeviceInfoPlugin();
  try {
    final named = AppPlatform.isMacOS
        ? (await info.macOsInfo).computerName
        : AppPlatform.isWindows
        ? (await info.windowsInfo).computerName
        : null;
    if (named != null && named.trim().isNotEmpty) return named.trim();

    final model =
        (AppPlatform.isIOS
                ? (await info.iosInfo).model
                : AppPlatform.isAndroid
                ? (await info.androidInfo).model
                : '')
            .trim();
    if (model.isEmpty) return null;
    final first = ownerName?.trim().split(RegExp(r'\s+')).first ?? '';
    return first.isEmpty ? model : '$first’s $model';
  } catch (_) {
    return null;
  }
}

/// The platform as the server's device registry names it.
String get thisDevicePlatform => AppPlatform.isMacOS
    ? 'macos'
    : AppPlatform.isWindows
    ? 'windows'
    : AppPlatform.isIOS
    ? 'ios'
    : AppPlatform.isAndroid
    ? 'android'
    : 'linux';

/// "this Mac", "this iPhone": how a sentence names the device it is shown on.
String get thisDeviceKind => AppPlatform.isMacOS
    ? 'Mac'
    : AppPlatform.isIOS
    ? 'iPhone'
    : AppPlatform.isAndroid
    ? 'phone'
    : 'computer';
