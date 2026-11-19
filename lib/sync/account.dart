import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/kapy_chat_book.dart';
import '../billing/billing.dart';
import '../billing/note_limit.dart';
import '../billing/plan_terms.dart';
import '../data/local_store.dart';
import '../data/notes_store.dart';
import '../data/tags.dart';
import '../data/task_library.dart';
import 'auth_api.dart';
import 'device_name.dart';
import 'key_bundle.dart';
import 'task_sync.dart';
import 'identity.dart';
import 'image_sync.dart';
import 'joining.dart';
import 'key_store.dart';
import 'recovery_key.dart';
import 'sharing.dart';
import 'space_keyring.dart';
import '../speech/speech_api.dart';
import 'sync_api.dart';
import 'sync_service.dart';
import 'sync_state.dart';
import 'sealed_box.dart';
import 'trust.dart';
import 'vault.dart';

/// Where the account stands, from the UI's point of view.
enum AccountState {
  /// Reading the keystore. Brief, and only at launch.
  restoring,
  signedOut,

  /// A newly created account has proved its email but has not yet chosen the
  /// name collaborators will see.
  needsProfile,

  /// Signed in, but this account has never chosen a passphrase. Nothing can
  /// sync until it does — there is no key to seal anything with.
  needsPassphrase,

  /// Signed in on a device that has never unlocked. The notes are on the
  /// server and unreadable until the passphrase or the recovery key arrives.
  locked,

  /// Signing in as somebody else on a device that already holds notes. There
  /// is no safe default — pushing them hands one person's notes to another
  /// account, discarding them destroys work — so the choice is the user's.
  needsAccountDecision,

  /// Encryption was reset on another device, so the key this device held no
  /// longer opens the account. It has been let go; every note here stays,
  /// and nothing syncs until the new passphrase or recovery key arrives.
  keysChanged,

  ready,
}

/// Owns the session, the key, and the sync loop, and is the only thing the UI
/// has to talk to.
///
/// Authentication and encryption are deliberately kept apart inside it:
/// signing in proves who you are, and the passphrase proves you can read. The
/// server can mint a session; it can never mint a key.
class Account extends ChangeNotifier {
  Account({
    required AuthApi auth,
    required SyncApi Function(String token) syncApi,
    required KeyStore keys,
    required NotesStore notes,
    required SyncState state,
    required LocalStore store,
    required TaskLibrary tasks,
    required TagStore tags,
    KapyChatBook? chats,
    SyncService Function({
      required SyncApi api,
      required Vault vault,
      required SpaceKeyring keyring,
    })?
    syncServiceFactory,
  }) : _auth = auth,
       _syncApiFor = syncApi,
       _keys = keys,
       _notes = notes,
       _state = state,
       _store = store,
       _tasks = tasks,
       _tags = tags,
       _chats = chats,
       _syncServiceFactory = syncServiceFactory;

  final AuthApi _auth;
  final SyncApi Function(String token) _syncApiFor;

  /// Builds the speech client for a token. Null when this build has no
  /// transcription in it — a test, or a server with none configured — in which
  /// case [speech] stays null and the queue never runs.
  SpeechApi Function(String token)? speechApiFor;

  /// What this account has bought, and the way to buy more. Set once by
  /// `main` and never torn down with sync: a purchase belongs to the session,
  /// not to the unlocked vault, so it follows this object's user rather than
  /// living inside [_start]. Null in a build with nothing wired up to sell.
  Billing? get billing => _billing;
  set billing(Billing? value) {
    _billing?.removeListener(_onBilling);
    _billing = value;
    value?.addListener(_onBilling);
  }

  Billing? _billing;
  Object? _coverage;

  /// Whether plans are enforced, for when there is no account to ask. Set
  /// once by `main`, like [billing]; null in a build that never limits.
  PlanTerms? planTerms;

  /// Which notes the plan leaves editable. Set once by `main` beside
  /// [planTerms]; null in a build that never limits.
  NoteLimit? noteLimit;

  /// What the server syncs for this account follows what billing says it
  /// has, so a change there — a purchase, a refund, a trial ending — is the
  /// cue for sync to ask about the spaces it is holding back. Billing
  /// notifies for much else besides, so only those three fields count.
  void _onBilling() {
    final now = _billing?.entitlements;
    final coverage = now == null ? null : (now.plan, now.sync, now.trialEndsAt);
    if (coverage == _coverage) return;
    _coverage = coverage;
    _sync?.recheckCoverage();
    _sync?.planChanged();
  }

  final KeyStore _keys;
  final NotesStore _notes;
  final SyncState _state;
  final LocalStore _store;
  final SyncService Function({
    required SyncApi api,
    required Vault vault,
    required SpaceKeyring keyring,
  })?
  _syncServiceFactory;

  AccountState _accountState = AccountState.restoring;
  AccountUser? _user;
  String? _token;

  /// The task index and the notes' documents, which sync keeps while it
  /// runs and the library itself keeps the rest of the time.
  final TaskLibrary _tasks;

  /// The person's tags and which notes carry them, synced while signed in.
  final TagStore _tags;

  /// Kapy AI's chats, synced while signed in with Pro; null in a build or a
  /// test with none.
  final KapyChatBook? _chats;
  SyncService? _sync;
  Sharing? _sharing;
  Joining? _joining;
  SpeechApi? _speech;
  ImageSync? _images;
  SpaceKeyring? _keyring;
  TrustStore? _trust;
  String? _lastError;
  String? _signedOutReason;
  SyncStatus? _syncStatus;

  AccountState get state => _accountState;

  /// Why this device is signed out when nobody signed it out: the server
  /// ended its session. Null after a sign-out, a deletion, or a fresh install.
  String? get signedOutReason => _signedOutReason;

  static const String sessionEndedReason =
      'Your session ended. Sign in again to keep syncing. '
      'Your notes are still on this device.';
  AccountUser? get user => _user;

  /// The current session token, for API clients built outside this object.
  String? get token => _token;
  String? get lastError => _lastError;
  SyncService? get sync => _sync;

  /// Shared spaces, once the account is unlocked. Null before that: there is
  /// no key to share anything with.
  Sharing? get sharing => _sharing;

  /// Several invitations at once, a space's link, and who is waiting to be
  /// let in. Null while signed out — and against an API that is not the real
  /// HTTP one, as in tests that drive [Account] with a fake server.
  Joining? get joining => _joining;

  /// Transcription, once there is a session to do it under.
  ///
  /// Null while signed out, which is the honest answer: consent, minutes and
  /// job ids all hang off an account, and there is nothing sensible to do with
  /// any of them without one.
  SpeechApi? get speech => _speech;

  /// Fetches image bytes this device does not have yet.
  ///
  /// Null until the account is unlocked, which is correct: the file keys live
  /// inside the sealed note payload, so before the vault opens there is no way
  /// to decrypt a picture even if it downloaded.
  Future<Uint8List?> Function(String hash)? get imageFetch => _images?.fetch;

  /// Per-attachment upload progress for the media tile currently painting it.
  /// Null while signed out, where adding media is wholly local and therefore
  /// has no network wait to represent.
  ValueListenable<double?> Function(String hash)? get uploadProgressFor {
    final images = _images;
    return images?.progressFor;
  }

  bool get isSyncing => _sync?.status == SyncStatus.syncing;

  /// Restores whatever the last run left behind. Called once, off the first
  /// frame: a keystore read is a platform channel round trip and the editor
  /// should not wait on it.
  Future<void> restore() async {
    // Loads the sync state with the documents, whose replica comes from it.
    await _tasks.load();
    // A build from before tags read the record stream past any tag records
    // without keeping them, so the first time this one runs it reads the
    // stream again from the start. Tasks merge again to no effect.
    if (!await _tags.load() && _tasks.index.cursor > 0) {
      _tasks.index.recordCursor(0);
    }
    final token = await _keys.readToken();
    if (token == null) {
      // A key and an owner with no session left: the server ended it on an
      // earlier launch, and the reason still stands.
      if (await _keys.readUser() != null) _signedOutReason = sessionEndedReason;
      return _moveTo(AccountState.signedOut);
    }

    switch (await _checkSession(token)) {
      case SessionActive(:final user):
        _token = token;
        _user = user;
        await _keys.writeUser(user);
        if (user.needsName) {
          _moveTo(AccountState.needsProfile);
        } else {
          await _resume();
        }
      case SessionRejected():
        // Asked twice, and told no both times: expired, revoked, or signed
        // out on another device.
        await _endSession();
      case SessionUnreachable():
        // Not asked. Nothing has been revoked, so nothing is thrown away —
        // this device carries on as whoever it was, and the sync layer will
        // find out soon enough if the session really has gone.
        //
        // This is the ordinary case far more often than it looks: the app
        // opens at login, before the network is up, and an update relaunches
        // it the instant the installer lets go.
        final cached = await _keys.readUser();
        if (cached == null) {
          // A session from before this device cached who it belonged to.
          // Nothing to resume as, but still nothing to revoke.
          _moveTo(AccountState.signedOut);
          return;
        }
        _token = token;
        _user = cached;
        if (cached.needsName) {
          _moveTo(AccountState.needsProfile);
        } else {
          await _resume();
        }
    }
  }

  Future<void> signIn({required String email, required String password}) =>
      _afterAuth(() => _auth.signIn(email: email, password: password));

  /// Returns true when a code is on its way, so the screen can move on to
  /// asking for it.
  Future<bool> sendCode(String email) =>
      _reportable(() => _auth.sendCode(email));

  Future<void> signInWithCode({required String email, required String code}) =>
      _afterAuth(() => _auth.signInWithCode(email: email, code: code));

  Future<bool> requestPasswordReset(String email) =>
      _reportable(() => _auth.requestPasswordReset(email));

  /// True when the password was changed. Signing in is left to the caller: a
  /// reset should not hand a session to whoever happens to be holding the
  /// device the code was typed on.
  Future<bool> resetPassword({
    required String email,
    required String code,
    required String password,
  }) => _reportable(
    () => _auth.resetPassword(email: email, code: code, password: password),
  );

  /// Runs something whose only outcomes are "it worked" and "here is why not".
  Future<bool> _reportable(Future<AuthResult> Function() attempt) async {
    _lastError = null;
    final result = await attempt();
    final ok = result is AuthCodeSent || result is AuthPasswordChanged;
    if (!ok) {
      _lastError = switch (result) {
        AuthRejected(:final message) => message,
        AuthUnreachable(:final message) => message,
        _ => 'That did not work.',
      };
    }
    notifyListeners();
    return ok;
  }

  Future<void> _afterAuth(Future<AuthResult> Function() attempt) async {
    _lastError = null;
    final result = await attempt();
    switch (result) {
      case AuthSignedIn(:final token, :final user):
        // The key on this device opens one account. Anyone else signing in
        // starts without it, and without what was kept for that account.
        final previous = await _keys.readUser();
        if (previous?.id != user.id) await _keys.forgetMasterKey();
        if (previous != null && previous.id != user.id) _forgetAccountData();
        _signedOutReason = null;
        _token = token;
        _user = user;
        await _keys.writeToken(token);
        // So a later launch that cannot reach the server still knows whose
        // device this is.
        await _keys.writeUser(user);
        if (user.needsName) {
          _moveTo(AccountState.needsProfile);
        } else {
          await _resume();
        }
      case AuthNeedsVerification(:final email):
        _lastError = 'Confirm $email, then sign in.';
        _moveTo(AccountState.signedOut);
      case AuthCodeSent(:final email):
        _lastError = 'A code is on its way to $email.';
        _moveTo(AccountState.signedOut);
      case AuthRejected(:final message):
      case AuthUnreachable(:final message):
        _lastError = message;
        _moveTo(AccountState.signedOut);
      case AuthPasswordChanged():
        // Not reachable: resetting goes through [resetPassword], which never
        // expects a session. Named rather than defaulted so that adding a
        // result here has to be thought about.
        _moveTo(AccountState.signedOut);
      case AuthProfileUpdated():
        _moveTo(AccountState.signedOut);
    }
  }

  /// Saves the public profile. The optional image is a compact data URL so it
  /// can travel with a space roster without exposing note or storage keys.
  Future<bool> updateProfile({
    required String name,
    String? image,
    bool replaceImage = false,
  }) async {
    final token = _token;
    if (token == null) return false;
    final clean = name.trim();
    if (clean.isEmpty ||
        clean.runes.length > 50 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(clean)) {
      _lastError = 'Enter a name between 1 and 50 characters.';
      notifyListeners();
      return false;
    }

    _lastError = null;
    final result = await _auth.updateProfile(
      token: token,
      name: clean,
      image: image,
      replaceImage: replaceImage,
    );
    switch (result) {
      case AuthProfileUpdated(:final user):
        _user = user;
        await _keys.writeUser(user);
        if (_accountState == AccountState.needsProfile) {
          await _resume();
        } else {
          notifyListeners();
          final sharing = _sharing;
          if (sharing != null) unawaited(sharing.refresh());
        }
        return true;
      case AuthRejected(:final message):
      case AuthUnreachable(:final message):
        _lastError = message;
        notifyListeners();
        return false;
      default:
        _lastError = 'Could not update your profile.';
        notifyListeners();
        return false;
    }
  }

  /// Works out what a signed-in account still needs before it can sync.
  Future<void> _resume() async {
    final user = _user!;

    // Notes already on this device that belong to a different account are the
    // one thing that must not be decided quietly.
    if (_state.accountId != null &&
        _state.accountId != user.id &&
        _notes.allNotes.isNotEmpty) {
      return _moveTo(AccountState.needsAccountDecision);
    }
    _state.adopt(user.id);

    final cached = await _keys.readMasterKey();
    if (cached != null) return _start(Vault.fromMasterKey(cached));

    final bundle = await _syncApiFor(_token!).fetchKeyBundle();
    _bundle = bundle;
    if (bundle == null) return _moveTo(AccountState.needsPassphrase);
    if (await _adoptPendingKey(bundle)) return;
    _moveTo(
      bundle.generation > _state.keyGeneration && _state.hasSynced
          ? AccountState.keysChanged
          : AccountState.locked,
    );
  }

  /// A reset this device sent and the server took, with the app stopped
  /// before it could adopt the new key. Adopted now if it opens the account;
  /// otherwise the reset never landed, and the key goes.
  Future<bool> _adoptPendingKey(KeyBundle bundle) async {
    final pending = await _keys.readPendingMasterKey();
    if (pending == null) return false;
    final identity = bundle.identity;
    final opens =
        identity != null &&
        await IdentityKeys.unwrap(identity, pending) != null;
    if (opens) await _keys.writeMasterKey(pending);
    await _keys.forgetPendingMasterKey();
    if (!opens) return false;
    _markSeen(bundle);
    // Its recovery key was never shown, so Settings asks for another.
    _putForThisAccount(_unsavedEntry, true);
    _adoptGeneration(bundle.generation);
    await _start(Vault.fromMasterKey(pending));
    return true;
  }

  /// This device now holds the key of [generation]. Past a reset, everything
  /// it holds is owed to the account again: the notes in full, and the task,
  /// tag and chat records under the ids the new key gives them.
  void _adoptGeneration(int generation) {
    if (generation <= _state.keyGeneration) return;
    _state.beginRejoin(generation);
    _tasks.index.clear();
    _tags.forgetAccount();
    _chats?.forgetAccount();
  }

  /// The server said encryption was reset elsewhere. A key this device
  /// already holds that opens the new bundle — an older build that was
  /// unlocked with the new passphrase — is simply kept. Any other is let go.
  ///
  /// Sync is halted by then and calls nothing again, so a fetch that fails
  /// is asked again on a backoff of its own until it is answered.
  Future<void> _onKeysChanged(SyncKeysChangedException error) async {
    _keysChangedTimer?.cancel();
    _keysChangedTimer = null;
    final token = _token;
    if (token == null) return;
    final KeyBundle? bundle;
    try {
      bundle = await _syncApiFor(token).fetchKeyBundle();
    } on SyncException {
      if (_token != token || _keysChangedTimer != null) return;
      final delay = keysChangedRetry * (1 << _keysChangedFailures.clamp(0, 6));
      _keysChangedFailures++;
      _keysChangedTimer = Timer(delay, () => unawaited(_onKeysChanged(error)));
      return;
    }
    _keysChangedFailures = 0;
    if (_token != token || bundle == null) return;
    if (bundle.generation <= _state.keyGeneration) return;
    _bundle = bundle;
    final cached = await _keys.readMasterKey();
    final identity = bundle.identity;
    if (cached != null &&
        identity != null &&
        await IdentityKeys.unwrap(identity, cached) != null) {
      _markSeen(bundle);
      _adoptGeneration(bundle.generation);
      await _start(Vault.fromMasterKey(cached));
      return;
    }
    _teardownSync();
    await _keys.forgetMasterKey();
    _moveTo(AccountState.keysChanged);
  }

  /// The first wait before [_onKeysChanged] asks for the bundle again after
  /// a failed fetch, doubled with each failure in a row, to about five
  /// minutes.
  Duration keysChangedRetry = const Duration(seconds: 5);
  Timer? _keysChangedTimer;
  int _keysChangedFailures = 0;

  /// What the sync status line says. A device waiting for the passphrase
  /// set by a reset elsewhere has no sync running, and still says why.
  SyncStatus? get syncStatus => _accountState == AccountState.keysChanged
      ? SyncStatus.keysChanged
      : _sync?.status;

  /// The reset made on another device, for a device that has to ask for the
  /// new passphrase to say when and where.
  KeyChange? get resetElsewhere => _bundle?.changes.reset;

  /// First run for this account: makes the keys, publishes the wrapped copies,
  /// and hands back the recovery key.
  ///
  /// Returned rather than stored because this is the only moment it exists in
  /// the clear, and the caller is expected to make saving it a step the user
  /// cannot skip past.
  Future<RecoveryKey?> createPassphrase(String passphrase) async {
    final api = _syncApiFor(_token!);
    final setup = await Vault.create(passphrase: passphrase);
    try {
      await api.createKeyBundle(
        KeyBundle(
          wrappedMasterKey: setup.wrappedMasterKey,
          kdf: setup.kdf,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
        ),
      );
    } on SyncException catch (error) {
      _lastError = error.message;
      notifyListeners();
      return null;
    }
    await _keys.writeMasterKey(setup.vault.masterKeyForKeystore);
    await _start(setup.vault);
    return RecoveryKey(setup.recoveryKey);
  }

  /// Returns false for a passphrase that does not open the bundle. There is
  /// nothing to distinguish that from a tampered one, and the answer a person
  /// needs is the same either way.
  Future<bool> unlock(String passphrase) => _unlockWith(
    (bundle) => Vault.unlockWithPassphrase(
      passphrase: passphrase,
      kdf: bundle.kdf,
      wrappedMasterKey: bundle.wrappedMasterKey,
    ),
  );

  Future<bool> unlockWithRecoveryKey(String typed) {
    final key = RecoveryKey.parse(typed);
    if (key == null) return Future.value(false);
    return _unlockWith((bundle) async {
      final wrapped = bundle.recoveryWrappedMasterKey;
      if (wrapped == null) return null;
      return Vault.unlockWithRecoveryKey(
        recoveryKey: key,
        recoveryWrappedMasterKey: wrapped,
      );
    });
  }

  Future<bool> _unlockWith(Future<Vault?> Function(KeyBundle) open) async {
    final api = _syncApiFor(_token!);
    final bundle = await api.fetchKeyBundle();
    _typedOldKey = false;
    if (bundle == null) {
      _moveTo(AccountState.needsPassphrase);
      return false;
    }
    _bundle = bundle;
    final vault = await open(bundle);
    if (vault == null) {
      _typedOldKey = bundle.generation > 1 && await _opensArchive(api, open);
      notifyListeners();
      return false;
    }
    _markSeen(bundle);

    await _keys.writeMasterKey(vault.masterKeyForKeystore);
    _adoptGeneration(bundle.generation);
    await _start(vault);
    return true;
  }

  /// Whether what was typed opens the seals from before the last reset.
  Future<bool> _opensArchive(
    SyncApi api,
    Future<Vault?> Function(KeyBundle) open,
  ) async {
    try {
      final archive = await api.fetchKeyArchive();
      if (archive == null) return false;
      final old = await open(
        KeyBundle(
          wrappedMasterKey: archive.wrappedMasterKey,
          kdf: archive.kdf,
          recoveryWrappedMasterKey: archive.recoveryWrappedMasterKey,
        ),
      );
      old?.wipe();
      return old != null;
    } on SyncException {
      return false;
    }
  }

  /// The last unlock failed because what was typed is the passphrase or
  /// recovery key from before a reset.
  bool get typedOldKey => _typedOldKey;
  bool _typedOldKey = false;

  /// Answers the account-switch question: keep these notes and push them into
  /// the new account, or let go of them.
  Future<void> resolveAccountSwitch({required bool keepLocalNotes}) async {
    if (_accountState != AccountState.needsAccountDecision) return;
    if (!keepLocalNotes) {
      _notes.forgetEverything();
      _tags.clear();
      _chats?.forgetEverything();
    }
    _state.adopt(_user!.id);
    await _resume();
  }

  Future<void> _start(Vault vault) async {
    final api = _syncApiFor(_token!);
    final trust = _trust ??= TrustStore(_store)..load();
    final keyring = SpaceKeyring(
      userId: _user!.id,
      store: _store,
      trust: trust,
    );
    final images = ImageSync(api: api, store: _notes.blobs, notes: _notes);
    final docs = _tasks.docs;
    final service =
        _syncServiceFactory?.call(api: api, vault: vault, keyring: keyring) ??
        SyncService(
          notes: _notes,
          state: _state,
          api: api,
          keyring: keyring,
          docs: docs,
          images: images,
          tasks: TaskSync(
            api: api,
            vault: vault,
            index: _tasks.index,
            tags: _tags,
            chats: _chats,
            chatsOn: () => _billing?.hasPro ?? false,
            docs: docs,
            noteIsLive: (noteId) => _notes.byId(noteId) != null,
            deletedNotes: () => [
              for (final stone in _notes.tombstones)
                if (_notes.byId(stone.id) == null) stone.id,
            ],
          ),
          vault: vault,
        );
    _teardownSync();
    // After the teardown, which clears it. Building it before was the bug that
    // left every signed-in session with no speech client, so a recording went
    // straight to "Sign in to transcribe" no matter who was signed in.
    _speech = speechApiFor?.call(_token!);
    _images = images;
    _keyring = keyring;
    _syncStatus = null;
    _sync = service
      ..addListener(notifyListeners)
      ..addListener(_onSyncStatus)
      ..onKeysChanged = (error) => unawaited(_onKeysChanged(error));
    _tasks.attachSync(service.reconcileTasksNow);
    _sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: _notes,
      sync: service,
      images: images,
    )..addListener(notifyListeners);
    final sharing = _sharing!;
    _joining = api is HttpSyncApi
        ? Joining(
            send: api.send,
            refreshSpaces: sharing.refresh,
            requestSync: service.requestSync,
          )
        : null;
    _moveTo(AccountState.ready);
    // Before the first pass rather than after it: the app is already in front
    // of the user by the time this runs, and a change that lands while that
    // pass is in flight would otherwise have nothing to arrive on.
    service.resume();
    unawaited(_refreshKeys());
    await service.syncNow();
    unawaited(_reportDevice());
  }

  void _teardownSync() {
    _keysChangedTimer?.cancel();
    _keysChangedTimer = null;
    _keysChangedFailures = 0;
    final images = _images;
    _joining?.dispose();
    _joining = null;
    _sharing?.dispose();
    _sharing = null;
    _images = null;
    _speech = null;
    _sync?.dispose();
    _sync = null;
    images?.dispose();
    _keyring?.clear();
    _keyring = null;
    _tasks.detachSync();
  }

  /// A sync call was refused for want of a session. A 401 from anything
  /// between here and the server proves nothing, so the server is asked, and
  /// the device signs out only if it says the session has gone. Otherwise the
  /// sync service keeps retrying on its own backoff.
  void _onSyncStatus() {
    final status = _sync?.status;
    if (status == _syncStatus) return;
    _syncStatus = status;
    if (status == SyncStatus.signedOut) unawaited(_confirmSession());
  }

  Future<void> _confirmSession() async {
    final token = _token;
    if (token == null) return;
    if (await _checkSession(token) is! SessionRejected) return;
    if (_token == token) await _endSession();
  }

  /// Asks again before believing a no, since ending a session wipes the key.
  Future<SessionCheck> _checkSession(String token) async {
    final check = await _auth.checkSession(token);
    return check is SessionRejected ? _auth.checkSession(token) : check;
  }

  /// The server ended this device's session: signed out with the reason and
  /// the notes kept. The key goes, because a session ended from another
  /// device may be ending this one for being lost, and whoever holds it then
  /// should need the passphrase as well as the password.
  Future<void> _endSession() async {
    _teardownSync();
    _token = null;
    _user = null;
    await _keys.forgetToken();
    await _keys.forgetMasterKey();
    _signedOutReason = sessionEndedReason;
    _moveTo(AccountState.signedOut);
  }

  /// Ends every other device's session. This one stays signed in, unless
  /// the server says its own session has already ended.
  Future<RevokeOthers> signOutOtherDevices() async {
    final token = _token;
    if (token == null) return RevokeOthers.sessionEnded;
    final result = await _auth.revokeOtherSessions(token);
    if (result == RevokeOthers.sessionEnded) unawaited(_confirmSession());
    return result;
  }

  /// What is kept for the account rather than for the device.
  void _forgetAccountData() {
    _state.clearCursor();
    // Its ids and its seal are the account's; the next account pulls its own,
    // and until then the library rebuilds the index from the documents.
    _tasks.index.clear();
    _tags.forgetAccount();
  }

  /// Signing out drops the session and the key. It never touches the notes:
  /// they are the user's, they are on their device, and a sign-out is not a
  /// delete.
  Future<void> signOut() async {
    final token = _token;
    _teardownSync();
    _token = null;
    _user = null;
    _signedOutReason = null;
    _forgetAccountData();
    await _keys.clear();
    if (token != null) await _auth.signOut(token);
    _moveTo(AccountState.signedOut);
  }

  /// Closes the account on the server and leaves this device signed out.
  ///
  /// Deliberately reachable from every signed-in state, including a locked
  /// one. Somebody who has lost both the passphrase and the recovery key can
  /// do nothing else with the account they have — deleting it and starting
  /// again is their only way forward, and a delete that needed the key would
  /// be withheld from exactly the person who needs it.
  ///
  /// The notes on this device are kept, for the same reason [signOut] keeps
  /// them: they are the user's, and closing a server account is not a request
  /// to erase their writing. What goes is the account, everything the server
  /// held for it, and the key material this device was holding.
  ///
  /// Returns false and sets [lastError] if the server refused, leaving the
  /// session intact so it can be tried again. An account that still owns
  /// shared spaces is refused: each has to be handed over or stopped first,
  /// and [ownedSpacesBlockingDeletion] names them.
  Future<bool> deleteAccount(String confirmation) async {
    final token = _token;
    if (token == null) return false;

    _ownedSpacesBlockingDeletion = const [];
    try {
      await _syncApiFor(token).deleteAccount(confirmation);
    } on SyncRefusedException catch (error) {
      if (error.code == 'owned-spaces') {
        final spaces = error.body['spaces'];
        _ownedSpacesBlockingDeletion = spaces is List
            ? [
                for (final space in spaces)
                  if (space is Map && space['name'] is String)
                    space['name'] as String,
              ]
            : const [];
        _lastError =
            'Hand over or stop sharing the spaces you own first: '
            '${_ownedSpacesBlockingDeletion.join(', ')}.';
      } else {
        // A 400: the typed address did not match. Worth saying plainly,
        // because the alternative reading — that deletion is broken — is
        // worse.
        _lastError = 'That is not the email address on this account.';
      }
      notifyListeners();
      return false;
    } on SyncProtocolException {
      _lastError = 'That is not the email address on this account.';
      notifyListeners();
      return false;
    } catch (error) {
      _lastError = 'Could not reach the server. Try again when you are online.';
      notifyListeners();
      return false;
    }

    // The account is gone, so there is no session left to revoke: tear the
    // local half down directly rather than calling signOut, whose sign-out
    // request would now be answered with a 401.
    _teardownSync();
    _token = null;
    _user = null;
    _lastError = null;
    _signedOutReason = null;
    _forgetAccountData();
    await _keys.clear();
    _moveTo(AccountState.signedOut);
    return true;
  }

  List<String> _ownedSpacesBlockingDeletion = const [];

  /// The shared spaces the last deletion attempt was refused over, by name.
  List<String> get ownedSpacesBlockingDeletion => _ownedSpacesBlockingDeletion;

  // -------------------------------------------------------------------------
  // Changing the passphrase and the recovery key, from an unlocked device.
  //
  // Both re-seal the master key this device already holds and nothing else,
  // so no note is re-encrypted and every other unlocked device carries on
  // untouched. Neither asks for the old passphrase — forgetting it is the
  // usual reason to change it — so the server asks for an emailed code
  // instead, and every write names the bundle version it read.

  KeyBundle? _bundle;

  /// The key bundle as this device last read it. Null until the first read.
  KeyBundle? get keyBundle => _bundle;

  bool get hasRecoveryKey => _bundle?.recoveryWrappedMasterKey != null;

  /// What this device calls itself in "changed from Sanjay's MacBook".
  /// Replaceable for tests, where there is no platform to ask.
  Future<String?> Function(String? ownerName) deviceName = (owner) =>
      thisDeviceName(ownerName: owner);

  static const String _seenEntry = 'keys.seen.v1';
  static const String _unsavedEntry = 'keys.recoveryUnsaved.v1';
  static const String _nudgedEntry = 'keys.recoveryNudged.v1';
  static const String _reportedEntry = 'keys.deviceReported.v1';

  Object? _forThisAccount(String entry) {
    final saved = _store.read<Map<String, Object?>>(entry);
    return saved != null && saved['account'] == _user?.id
        ? saved['value']
        : null;
  }

  void _putForThisAccount(String entry, Object? value) => _store.put(
    entry,
    value == null ? null : {'account': _user?.id, 'value': value},
  );

  void _markSeen(KeyBundle bundle) =>
      _putForThisAccount(_seenEntry, bundle.version);

  /// The passphrase change made on another device since this one last
  /// unlocked, for a locked device to explain before anything is typed. Null
  /// on a device that never unlocked, which has nothing to compare against.
  KeyChange? get passphraseChangedSinceUnlock {
    final seen = _forThisAccount(_seenEntry);
    final bundle = _bundle;
    if (seen is! int || bundle == null || bundle.version <= seen) return null;
    return bundle.changes.passphrase;
  }

  /// A recovery key was committed and the person never confirmed saving it,
  /// most likely because the app stopped in between. The old key no longer
  /// works, so Settings asks for another.
  bool get recoveryKeyUnsaved => _forThisAccount(_unsavedEntry) == true;

  /// The one quiet suggestion an account from before recovery keys gets.
  bool get offersRecoveryNudge =>
      _accountState == AccountState.ready &&
      _bundle != null &&
      !hasRecoveryKey &&
      _forThisAccount(_nudgedEntry) != true;

  void recoveryNudgeShown() {
    _putForThisAccount(_nudgedEntry, true);
    notifyListeners();
  }

  Future<void> _refreshKeys() async {
    final token = _token;
    if (token == null) return;
    try {
      final api = _syncApiFor(token);
      final bundle = await api.fetchKeyBundle();
      if (bundle == null || _token != token) return;
      _bundle = bundle;
      _markSeen(bundle);
      _archive = bundle.generation > 1 ? await api.fetchKeyArchive() : null;
      notifyListeners();
    } on SyncException {
      // Offline: Settings shows what it last knew, and the next start asks.
    }
  }

  /// The notes from before the last reset, while the server keeps them.
  KeyArchive? _archive;

  /// Whether there are notes from before a reset to bring back.
  bool get canRestore => _archive != null;

  /// The day the notes from before the reset stop being kept, when known.
  DateTime? get restorableUntil =>
      (_archive?.retiredAt ?? _bundle?.changes.reset?.at)?.add(KeyArchive.kept);

  /// Brings back the notes from before the last reset, with the passphrase
  /// or recovery key that opened them then. The key from before is held
  /// only for this, and wiped after.
  Future<RestoreResult> restoreFromArchive(String typed) async {
    final token = _token;
    final sync = _sync;
    if (token == null) return const RestoreOffline();
    if (sync == null || state != AccountState.ready) {
      return const RestoreLocked();
    }
    final api = _syncApiFor(token);
    try {
      final archive = _archive = await api.fetchKeyArchive();
      if (archive == null) {
        notifyListeners();
        return const RestoreGone();
      }
      final old = await _openArchive(archive, typed);
      if (old == null) return const RestoreWrongKey();
      try {
        final restored = await sync.restoreArchive(
          old,
          (after) => api.pullArchiveLog(after: after),
        );
        if (restored == null) return const RestoreLocked();
        return RestoreDone(added: restored.added, changed: restored.changed);
      } finally {
        old.wipe();
      }
    } on SyncTransientException {
      return const RestoreOffline();
    } on SyncException {
      return const RestoreRefused();
    }
  }

  Future<Vault?> _openArchive(KeyArchive archive, String typed) async {
    final key = RecoveryKey.parse(typed);
    final wrapped = archive.recoveryWrappedMasterKey;
    if (key != null && wrapped != null) {
      final vault = await Vault.unlockWithRecoveryKey(
        recoveryKey: key,
        recoveryWrappedMasterKey: wrapped,
      );
      if (vault != null) return vault;
    }
    return Vault.unlockWithPassphrase(
      passphrase: typed,
      kdf: archive.kdf,
      wrappedMasterKey: archive.wrappedMasterKey,
    );
  }

  /// At most hourly, so a sync pass costs nothing extra.
  Future<void> _reportDevice() async {
    final token = _token;
    if (token == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _forThisAccount(_reportedEntry);
    if (last is int && now - last < Duration.millisecondsPerHour) return;
    final name = await deviceName(_user?.name);
    if (name == null || _token != token) return;
    try {
      await _syncApiFor(
        token,
      ).reportDevice(name: name, platform: thisDevicePlatform);
      _putForThisAccount(_reportedEntry, now);
    } on SyncException {
      // Only ever a nicer sentence on another device; the next pass retries.
    }
  }

  /// Emails a code for [action]. Null when it is on its way.
  Future<KeyCodeProblem?> sendKeyCode(KeyProofAction action) async {
    final token = _token;
    if (token == null) return KeyCodeProblem.offline;
    try {
      await _syncApiFor(token).sendKeyProof(action);
      return null;
    } on SyncTransientException catch (error) {
      return error.status == 429
          ? KeyCodeProblem.tooSoon
          : KeyCodeProblem.offline;
    } on SyncException {
      return KeyCodeProblem.offline;
    }
  }

  /// Trades the emailed code for the proof a change carries.
  Future<({String? proof, KeyCodeProblem? problem})> verifyKeyCode(
    KeyProofAction action,
    String code,
  ) async {
    final token = _token;
    if (token == null) return (proof: null, problem: KeyCodeProblem.offline);
    try {
      final proof = await _syncApiFor(
        token,
      ).verifyKeyProof(action, code.replaceAll(RegExp(r'\s'), ''));
      return (proof: proof, problem: null);
    } on SyncRefusedException catch (error) {
      return (
        proof: null,
        problem: switch (error.code) {
          'code-expired' => KeyCodeProblem.expired,
          'code-tries' => KeyCodeProblem.tooManyTries,
          _ => KeyCodeProblem.wrong,
        },
      );
    } on SyncException {
      return (proof: null, problem: KeyCodeProblem.offline);
    }
  }

  /// Seals the master key under [passphrase], ready to send — and to send
  /// again, unchanged, if the first attempt never reached the server.
  Future<PreparedPassphrase?> preparePassphrase(String passphrase) async {
    final vault = await _copyOfVault();
    if (vault == null) return null;
    try {
      final sealed = await vault.rewrapForPassphrase(passphrase);
      return PreparedPassphrase._(sealed.wrappedMasterKey, sealed.kdf);
    } finally {
      vault.wipe();
    }
  }

  /// A new recovery key and the master key sealed under it. Shown only once
  /// the server has taken it; zeroed by [recoveryKeySaved].
  Future<PreparedRecoveryKey?> prepareRecoveryKey() async {
    final vault = await _copyOfVault();
    if (vault == null) return null;
    try {
      final made = await vault.rewrapForRecoveryKey();
      return PreparedRecoveryKey._(
        RecoveryKey(made.recoveryKey),
        made.recoveryWrappedMasterKey,
      );
    } finally {
      vault.wipe();
    }
  }

  Future<Vault?> _copyOfVault() async {
    final cached = await _keys.readMasterKey();
    return cached == null
        ? null
        : Vault.fromMasterKey(Uint8List.fromList(cached));
  }

  /// Sends a prepared change, on the bundle version as the server has it now.
  ///
  /// A change that lost to one made elsewhere to something else — the
  /// passphrase here, the recovery key there — goes through once more on the
  /// new version, since neither undoes the other. One that lost to a change
  /// of the same thing is reported, never pressed over the top of it.
  Future<KeyChangeResult> commitKeyChange(
    PreparedKeyChange change, {
    String? proof,
  }) async {
    final token = _token;
    if (token == null) return const KeyChangeOffline();
    final api = _syncApiFor(token);
    final recovery = change is PreparedRecoveryKey;
    final wasUnsaved = recoveryKeyUnsaved;
    if (recovery) _putForThisAccount(_unsavedEntry, true);
    final device = await deviceName(_user?.name);

    KeyChangeResult settle(KeyChangeResult result) {
      if (recovery && result is! KeyChangeDone && result is! KeyChangeOffline) {
        // Only this attempt's mark goes. A key an earlier attempt put on the
        // server and never showed still needs replacing.
        _putForThisAccount(_unsavedEntry, wasUnsaved ? true : null);
      }
      notifyListeners();
      return result;
    }

    try {
      var bundle = await api.fetchKeyBundle();
      for (var attempt = 0; ; attempt++) {
        if (bundle == null) return settle(const KeyChangeRefused());
        _bundle = bundle;
        if (change._appliedTo(bundle)) return settle(const KeyChangeDone());
        try {
          switch (change) {
            case PreparedPassphrase():
              await api.changePassphrase(
                expectedVersion: bundle.version,
                proof: proof ?? '',
                wrappedMasterKey: change.wrappedMasterKey,
                kdf: change.kdf,
                device: device,
              );
            case PreparedRecoveryKey():
              await api.changeRecoveryKey(
                expectedVersion: bundle.version,
                proof: proof,
                recoveryWrappedMasterKey: change.recoveryWrappedMasterKey,
                device: device,
              );
          }
          await _refreshKeys();
          return settle(const KeyChangeDone());
        } on SyncRefusedException catch (error) {
          if (error.code == 'proof-required') {
            return settle(const KeyChangeNeedsCode());
          }
          if (error.code != 'bundle-changed' || attempt > 0) {
            return settle(const KeyChangeRefused());
          }
          final before = change._sameKind(bundle.changes);
          bundle = await api.fetchKeyBundle();
          final after = bundle == null
              ? null
              : change._sameKind(bundle.changes);
          if (after != null && after != before) {
            _bundle = bundle;
            _markSeen(bundle!);
            return settle(KeyChangeLostRace(after));
          }
        }
      }
    } on SyncTransientException {
      return settle(const KeyChangeOffline());
    } on SyncException {
      return settle(const KeyChangeRefused());
    }
  }

  /// The person has the recovery key somewhere safe. Its bytes go now.
  void recoveryKeySaved(PreparedRecoveryKey change) {
    change.key.bytes.fillRange(0, change.key.bytes.length, 0);
    _putForThisAccount(_unsavedEntry, null);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Resetting encryption, from a locked device: the last resort.
  //
  // A new master key, new identity keys and new seals, sent as one request.
  // Every note on this device stays, and goes up again under the new key;
  // every other device keeps its own and adds them back once it unlocks.

  /// What a reset would touch. Null when the server cannot be reached.
  Future<ResetPreview?> resetPreview() async {
    final token = _token;
    if (token == null) return null;
    try {
      return await _syncApiFor(token).fetchResetPreview();
    } on SyncException {
      return null;
    }
  }

  /// How many of [preview]'s personal notes this device has no copy of.
  int notesOnlyOnServer(ResetPreview preview) {
    final here = {
      for (final note in _notes.allNotes)
        if (note.spaceId == null || note.spaceId == _state.personalSpaceId)
          note.id,
    };
    return preview.personalNoteIds.where((id) => !here.contains(id)).length;
  }

  /// Every key a reset needs, made once, so a retry after a dropped
  /// connection sends exactly the same request.
  Future<PreparedReset> prepareReset(String passphrase) async {
    final setup = await Vault.create(passphrase: passphrase);
    final identity = await IdentityKeys.generate();
    return PreparedReset._(
      setup,
      await identity.wrapUnder(setup.vault.masterKeyForKeystore),
    );
  }

  /// Sends a prepared reset against the bundle this device last read. Lost
  /// to any change made since — a passphrase changed or a reset elsewhere —
  /// it changes nothing, and says what won.
  Future<KeyChangeResult> commitReset(
    PreparedReset reset, {
    required String proof,
  }) async {
    final token = _token;
    final read = _bundle;
    if (token == null) return const KeyChangeOffline();
    if (read == null) return const KeyChangeRefused();
    final api = _syncApiFor(token);
    final setup = reset._setup;
    final device = await deviceName(_user?.name);
    await _keys.writePendingMasterKey(setup.vault.masterKeyForKeystore);

    KeyBundle bundle;
    try {
      try {
        final landed = await api.resetEncryption(
          expectedVersion: read.version,
          proof: proof,
          wrappedMasterKey: setup.wrappedMasterKey,
          kdf: setup.kdf,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
          identity: reset._identity,
          device: device,
        );
        bundle = KeyBundle(
          wrappedMasterKey: setup.wrappedMasterKey,
          kdf: setup.kdf,
          recoveryWrappedMasterKey: setup.recoveryWrappedMasterKey,
          identity: reset._identity,
          version: landed.version,
          generation: landed.generation,
          changes: KeyChanges(
            reset: KeyChange(at: DateTime.now(), device: device),
          ),
        );
      } on SyncRefusedException catch (error) {
        if (error.code == 'proof-required') return const KeyChangeNeedsCode();
        if (error.code != 'bundle-changed') {
          await _keys.forgetPendingMasterKey();
          return const KeyChangeRefused();
        }
        final now = await api.fetchKeyBundle();
        if (now == null || !reset._appliedTo(now)) {
          await _keys.forgetPendingMasterKey();
          if (now == null) return const KeyChangeRefused();
          _bundle = now;
          final byReset = now.generation > read.generation;
          final change = byReset ? now.changes.reset : now.changes.passphrase;
          return change == null
              ? const KeyChangeRefused()
              : KeyChangeLostRace(change, byReset: byReset);
        }
        bundle = now;
      }
    } on SyncTransientException {
      return const KeyChangeOffline();
    } on SyncException {
      await _keys.forgetPendingMasterKey();
      return const KeyChangeRefused();
    } finally {
      notifyListeners();
    }

    _bundle = bundle;
    _markSeen(bundle);
    _putForThisAccount(_unsavedEntry, true);
    await _keys.writeMasterKey(setup.vault.masterKeyForKeystore);
    await _keys.forgetPendingMasterKey();
    _adoptGeneration(bundle.generation);
    await _start(setup.vault);
    return const KeyChangeDone();
  }

  /// The person has the reset's recovery key somewhere safe.
  void resetRecoveryKeySaved(PreparedReset reset) {
    reset.recoveryKey.bytes.fillRange(0, reset.recoveryKey.bytes.length, 0);
    _putForThisAccount(_unsavedEntry, null);
    notifyListeners();
  }

  void _moveTo(AccountState next) {
    if (_accountState == next) {
      notifyListeners();
      return;
    }
    _accountState = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardownSync();
    noteLimit?.dispose();
    planTerms?.dispose();
    billing?.dispose();
    super.dispose();
  }
}

/// The 32 bytes that can open an account when the passphrase is gone.
class RecoveryKey {
  const RecoveryKey(this.bytes);
  final Uint8List bytes;

  /// Grouped for reading aloud and writing down. Crockford's alphabet, which
  /// drops the characters people confuse — no I, L, O or U — so a key copied
  /// by hand off a screen still works.
  String get formatted => formatRecoveryKey(bytes);

  static Uint8List? parse(String typed) => parseRecoveryKey(typed);
}

/// Why an emailed code did not come, or did not work.
enum KeyCodeProblem { offline, tooSoon, wrong, expired, tooManyTries }

/// A key change sealed and ready to send. Built once, so a retry after a
/// dropped connection sends exactly the same thing — and can tell, from the
/// bundle, that the first attempt had already landed.
sealed class PreparedKeyChange {
  const PreparedKeyChange();

  bool _appliedTo(KeyBundle bundle);
  KeyChange? _sameKind(KeyChanges changes);
}

class PreparedPassphrase extends PreparedKeyChange {
  const PreparedPassphrase._(this.wrappedMasterKey, this.kdf);
  final SealedBox wrappedMasterKey;
  final KdfParams kdf;

  @override
  bool _appliedTo(KeyBundle bundle) =>
      _same(bundle.wrappedMasterKey, wrappedMasterKey);

  @override
  KeyChange? _sameKind(KeyChanges changes) => changes.passphrase;
}

class PreparedRecoveryKey extends PreparedKeyChange {
  const PreparedRecoveryKey._(this.key, this.recoveryWrappedMasterKey);
  final RecoveryKey key;
  final SealedBox recoveryWrappedMasterKey;

  @override
  bool _appliedTo(KeyBundle bundle) {
    final current = bundle.recoveryWrappedMasterKey;
    return current != null && _same(current, recoveryWrappedMasterKey);
  }

  @override
  KeyChange? _sameKind(KeyChanges changes) => changes.recoveryKey;
}

bool _same(SealedBox a, SealedBox b) =>
    listEquals(a.cipherText, b.cipherText) && listEquals(a.nonce, b.nonce);

/// A reset made and ready to send: the new master key sealed both ways and
/// the new identity keys sealed under it.
class PreparedReset {
  PreparedReset._(this._setup, this._identity)
    : recoveryKey = RecoveryKey(_setup.recoveryKey);

  final VaultSetup _setup;
  final WireIdentity _identity;

  /// Shown once the server has taken the reset, and zeroed by
  /// [Account.resetRecoveryKeySaved].
  final RecoveryKey recoveryKey;

  bool _appliedTo(KeyBundle bundle) =>
      _same(bundle.wrappedMasterKey, _setup.wrappedMasterKey);
}

/// How bringing back the notes from before a reset went.
sealed class RestoreResult {
  const RestoreResult();
}

class RestoreDone extends RestoreResult {
  const RestoreDone({required this.added, required this.changed});
  final int added;
  final int changed;
}

/// What was typed opens neither the passphrase nor the recovery key from
/// before the reset.
class RestoreWrongKey extends RestoreResult {
  const RestoreWrongKey();
}

/// No longer kept: past its 30 days, or never there.
class RestoreGone extends RestoreResult {
  const RestoreGone();
}

/// This device can't read or write notes until sync is unlocked here.
class RestoreLocked extends RestoreResult {
  const RestoreLocked();
}

class RestoreOffline extends RestoreResult {
  const RestoreOffline();
}

class RestoreRefused extends RestoreResult {
  const RestoreRefused();
}

sealed class KeyChangeResult {
  const KeyChangeResult();
}

class KeyChangeDone extends KeyChangeResult {
  const KeyChangeDone();
}

/// The proof expired or was used; a fresh code puts it right.
class KeyChangeNeedsCode extends KeyChangeResult {
  const KeyChangeNeedsCode();
}

/// Another device changed the same thing first. Nothing changed here.
class KeyChangeLostRace extends KeyChangeResult {
  const KeyChangeLostRace(this.change, {this.byReset = false});
  final KeyChange change;

  /// What won was a reset rather than a passphrase change.
  final bool byReset;
}

/// Nobody answered. Nothing changed yet, as far as this device knows.
class KeyChangeOffline extends KeyChangeResult {
  const KeyChangeOffline();
}

class KeyChangeRefused extends KeyChangeResult {
  const KeyChangeRefused();
}
