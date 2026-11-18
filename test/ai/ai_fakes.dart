import 'package:kapy_notes/ai/answer_engine.dart';
import 'package:kapy_notes/ai/device_model.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/local_tools.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/notes_store.dart';

import '../billing/billing_fakes.dart';

/// A store that never touches the disk.
class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'kapy-ai-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;

  @override
  void putNow(String key, Object? value) => data[key] = value;
}

final DateTime testNow = DateTime(2026, 11, 17, 12);

/// A note as the store keeps it.
Map<String, Object?> noteJson(
  String id,
  String body, {
  DateTime? updated,
  bool hidden = false,
  bool archived = false,
}) {
  final at = (updated ?? testNow).millisecondsSinceEpoch;
  return {
    'id': id,
    'body': body,
    'createdAt': at,
    'updatedAt': at,
    if (hidden) 'hiddenAt': at,
    if (archived) 'archivedAt': at,
  };
}

Future<NotesStore> notesWith(
  List<Map<String, Object?>> notes, {
  LocalStore? store,
}) async {
  final local = store ?? MemoryStore();
  local.data['notes.v1'] = notes;
  final loaded = NotesStore(local, now: () => testNow);
  await loaded.load();
  return loaded;
}

/// Billing that has heard from the server: Pro or Free.
Future<Billing> billingOn({required bool pro}) async {
  final api = FakeBillingApi()..answer = () => entitlementsFor(pro: pro);
  final session = FakeSession();
  final billing = billingFor(session, api);
  session.signIn('user-1');
  for (var i = 0; i < 20 && billing.entitlements == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return billing;
}

/// The device's model, scripted.
class FakeDeviceModel extends DeviceModel {
  FakeDeviceModel([
    this.state = const DeviceModelState(
      status: DeviceModelStatus.builtIn,
      model: apple,
    ),
  ]);

  static const KapyModel apple = KapyModel(
    kind: KapyModelKind.device,
    id: 'apple',
    label: 'Apple Intelligence',
  );
  static const KapyModel gemma = KapyModel(
    kind: KapyModelKind.device,
    id: 'gemma',
    label: 'Gemma',
  );

  @override
  DeviceModelState state;

  final List<AnswerRequest> asked = [];
  Object? failure;
  int downloads = 0;
  int cancels = 0;

  void set(DeviceModelState next) {
    state = next;
    notifyListeners();
  }

  @override
  int get noteChars => 10000;

  @override
  Future<void> refresh() async {}

  @override
  void download() => downloads++;

  @override
  void cancel() => cancels++;

  @override
  Future<void> remove() async {}

  bool mobileData = false;
  int wifiDownloads = 0;

  @override
  Future<bool> onMobileData() async => mobileData;

  @override
  void downloadOnWifi() => wifiDownloads++;

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    asked.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'device answer';
  }
}

/// Codex or Claude Code, scripted.
class FakeLocalTool implements LocalTool {
  FakeLocalTool(this.kind, {this.status = KapyAccountStatus.connected});

  @override
  final KapyAccountKind kind;
  KapyAccountStatus status;
  final List<AnswerRequest> asked = [];
  Object? failure;

  KapyModel get model => KapyModel(
    kind: kind == KapyAccountKind.codex
        ? KapyModelKind.codex
        : KapyModelKind.claudeCode,
    id: 'm',
    label: 'Model',
  );

  @override
  Future<LocalToolCheck> check() async => (
    status: status,
    models: status == KapyAccountStatus.connected ? [model] : <KapyModel>[],
  );

  @override
  Future<String> answer(KapyModel model, AnswerRequest request) async {
    asked.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'tool answer';
  }
}

/// Lets microtasks and listeners settle.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
