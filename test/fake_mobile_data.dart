import 'dart:async';

import 'package:kapy_notes/core/mobile_data.dart';

/// A phone whose connection the test moves between mobile data and Wi-Fi.
class FakeMobileData extends MobileData {
  FakeMobileData({this.onlyMobile = false});

  bool onlyMobile;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  Future<bool> inUse() async => onlyMobile;

  @override
  Stream<bool> changes() => _changes.stream;

  void move({required bool onlyMobile}) {
    this.onlyMobile = onlyMobile;
    _changes.add(onlyMobile);
  }
}
