import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:kapy_notes/core/mobile_data.dart';

/// A phone whose connection the test moves, read through the real mappings.
class FakeMobileData extends MobileData {
  FakeMobileData({bool onlyMobile = false})
    : _results = [
        onlyMobile ? ConnectivityResult.mobile : ConnectivityResult.wifi,
      ];

  List<ConnectivityResult> _results;
  final StreamController<bool> _unmetered = StreamController<bool>.broadcast();

  @override
  Future<bool> inUse() async => MobileData.isOnlyMobile(_results);

  @override
  Future<bool> unmeteredNow() async => MobileData.isUnmetered(_results);

  @override
  Stream<bool> unmetered() => _unmetered.stream;

  void move(List<ConnectivityResult> results) {
    _results = results;
    _unmetered.add(MobileData.isUnmetered(results));
  }
}
