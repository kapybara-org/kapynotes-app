import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'platform.dart';

/// Whether this phone is on mobile data, where a download costs its owner by
/// the byte.
///
/// Only phones are asked. A laptop tethered to a phone looks like Wi-Fi to its
/// OS, so there is nothing true to say about it. A phone with Wi-Fi or
/// Ethernet as well as mobile data downloads over those, so only mobile data
/// on its own counts.
class MobileData {
  /// A model download bigger than this asks first on mobile data. Smaller ones
  /// cost less than a few minutes of video, and asking would be noise.
  static const int askAboveBytes = 200 * 1000 * 1000;

  /// Built on first use, so a desktop never touches the plugin.
  Connectivity get _connectivity => Connectivity();

  Future<bool> inUse() async {
    if (!AppPlatform.isMobile) return false;
    try {
      return isOnlyMobile(await _connectivity.checkConnectivity());
    } catch (_) {
      // A phone that will not say is not charged for what it does not know.
      return false;
    }
  }

  /// Whether the phone is on Wi-Fi or Ethernet right now.
  Future<bool> unmeteredNow() async {
    try {
      return isUnmetered(await _connectivity.checkConnectivity());
    } catch (_) {
      return false;
    }
  }

  /// Whether the phone is on Wi-Fi or Ethernet, each time the connection
  /// changes. Not "off mobile data": a phone in a tunnel reports no connection
  /// at all, and a download started then would fail and stop waiting.
  Stream<bool> unmetered() =>
      _connectivity.onConnectivityChanged.map(isUnmetered);

  /// Mobile data with nothing cheaper beside it. A VPN over mobile data is
  /// still mobile data.
  @visibleForTesting
  static bool isOnlyMobile(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.mobile) && !isUnmetered(results);

  @visibleForTesting
  static bool isUnmetered(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet);
}
