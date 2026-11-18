import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import 'platform.dart';

/// How much memory this device has, where the answer is cheap to get.
///
/// Asked for one reason: a model that needs more RAM than the machine has
/// will be killed by the OS partway through loading, and the user will have
/// spent several hundred megabytes of their data to find that out. Offering
/// the download at all is the decision this informs.
///
/// Returns null when the platform will not say. Null means "go ahead" — it is
/// better to let somebody try and fail than to hide a working feature from a
/// machine we simply could not measure.
class DeviceMemory {
  DeviceMemory({
    MethodChannel channel = const MethodChannel(_channelName),
    File? procMeminfo,
    int? Function()? windowsTotal,
  }) : _channel = channel,
       _procMeminfo = procMeminfo ?? File('/proc/meminfo'),
       _windowsTotal = windowsTotal ?? _globalMemoryStatus;

  /// The same channel the summariser uses. One channel per subject area, and
  /// "what can this device do" is that subject.
  static const String _channelName = 'kapynotes/summaries';

  final MethodChannel _channel;
  final File _procMeminfo;
  final int? Function() _windowsTotal;

  int? _cached;

  /// Total physical memory in bytes, or null if unknown.
  ///
  /// Cached after the first answer: RAM does not change while the app runs,
  /// and this is read every time the settings pane opens.
  Future<int?> total() async {
    final known = _cached;
    if (known != null) return known;
    final measured = await _measure();
    if (measured != null && measured > 0) _cached = measured;
    return measured;
  }

  Future<int?> _measure() async {
    // Linux and Android both publish it in a file, which is one read and no
    // native code at all.
    if (AppPlatform.isLinux || AppPlatform.isAndroid) {
      return _fromProcMeminfo();
    }
    if (AppPlatform.isMacOS || AppPlatform.isIOS) {
      try {
        final bytes = await _channel.invokeMethod<int>('physicalMemory');
        return (bytes ?? 0) > 0 ? bytes : null;
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
    }
    if (AppPlatform.isWindows) {
      try {
        return _windowsTotal();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// `ullTotalPhys` from `GlobalMemoryStatusEx`, the Windows counterpart of
  /// `MemTotal`: the physical memory the OS can use, a little under what is
  /// installed.
  ///
  /// The struct is 64 bytes: two 32-bit fields, `dwLength` first, then seven
  /// 64-bit ones starting with `ullTotalPhys`. It is allocated with
  /// kernel32's own `LocalAlloc`, zeroed, so the call needs nothing beyond
  /// the library it already reads.
  static int? _globalMemoryStatus() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final localAlloc = kernel32
        .lookupFunction<
          Pointer<Uint64> Function(Uint32, IntPtr),
          Pointer<Uint64> Function(int, int)
        >('LocalAlloc');
    final localFree = kernel32
        .lookupFunction<
          IntPtr Function(Pointer<Uint64>),
          int Function(Pointer<Uint64>)
        >('LocalFree');
    final globalMemoryStatusEx = kernel32
        .lookupFunction<
          Int32 Function(Pointer<Uint64>),
          int Function(Pointer<Uint64>)
        >('GlobalMemoryStatusEx');
    const zeroInit = 0x40;
    final status = localAlloc(zeroInit, 64);
    if (status == nullptr) return null;
    try {
      status.cast<Uint32>().value = 64;
      if (globalMemoryStatusEx(status) == 0) return null;
      return status[1];
    } finally {
      localFree(status);
    }
  }

  /// Reads `MemTotal:` out of `/proc/meminfo`, which is in kibibytes.
  Future<int?> _fromProcMeminfo() async {
    try {
      if (!await _procMeminfo.exists()) return null;
      for (final line in await _procMeminfo.readAsLines()) {
        if (!line.startsWith('MemTotal:')) continue;
        final match = RegExp(r'(\d+)').firstMatch(line);
        if (match == null) return null;
        return int.parse(match.group(1)!) * 1024;
      }
    } catch (_) {
      // An unreadable /proc is a machine we do not get to measure, not a
      // machine that fails.
    }
    return null;
  }
}
