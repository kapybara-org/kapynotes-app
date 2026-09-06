
import 'package:flutter/foundation.dart';

import '../data/notes_store.dart';
import 'auth_api.dart';
import 'key_bundle.dart';
import 'key_store.dart';
import 'recovery_key.dart';
import 'sync_api.dart';
import 'sync_service.dart';
import 'sync_state.dart';
import 'vault.dart';

/// Where the account stands, from the UI's point of view.
enum AccountState {
  /// Reading the keystore. Brief, and only at launch.
  restoring,
  signedOut,

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
    SyncService Function({
      required SyncApi api,
      required Vault vault,
    })?
    syncServiceFactory,
  }) : _auth = auth,
       _syncApiFor = syncApi,
       _keys = keys,
       _notes = notes,
       _state = state,
       _syncServiceFactory = syncServiceFactory;

  final AuthApi _auth;
  final SyncApi Function(String token) _syncApiFor;
  final KeyStore _keys;
  final NotesStore _notes;
  final SyncState _state;
  final SyncService Function({required SyncApi api, required Vault vault})?
  _syncServiceFactory;

  AccountState _accountState = AccountState.restoring;
  AccountUser? _user;
  String? _token;
  SyncService? _sync;
  String? _lastError;

  AccountState get state => _accountState;
  AccountUser? get user => _user;
  String? get lastError => _lastError;
  SyncService? get sync => _sync;
  bool get isSyncing => _sync?.status == SyncStatus.syncing;

  /// Restores whatever the last run left behind. Called once, off the first
  /// frame: a keystore read is a platform channel round trip and the editor
  /// should not wait on it.
  Future<void> restore() async {
    _state.load();
    final token = await _keys.readToken();
    if (token == null) return _moveTo(AccountState.signedOut);

    final user = await _auth.currentUser(token);
    if (user == null) {
      // The session expired or was revoked. The notes stay; only the session
      // is gone, and signing in again picks them up where they were.
      await _keys.clear();
      return _moveTo(AccountState.signedOut);
    }

    _token = token;
    _user = user;
    await _resume();
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
        _token = token;
        _user = user;
        await _keys.writeToken(token);
        await _resume();
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
    }
  }

  /// Works out what a signed-in account still needs before it can sync.
  Future<void> _resume() async {
    final user = _user!;

    // Notes already on this device that belong to a different account are the
    // one thing that must not be decided quietly.
    if (_state.accountId != null &&
        _state.accountId != user.id &&
        _notes.notes.isNotEmpty) {
      return _moveTo(AccountState.needsAccountDecision);
    }
    _state.adopt(user.id);

    final cached = await _keys.readMasterKey();
    if (cached != null) return _start(Vault.fromMasterKey(cached));

    final bundle = await _syncApiFor(_token!).fetchKeyBundle();
    _moveTo(
      bundle == null ? AccountState.needsPassphrase : AccountState.locked,
    );
  }

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
  Future<bool> unlock(String passphrase) =>
      _unlockWith((bundle) => Vault.unlockWithPassphrase(
            passphrase: passphrase,
            kdf: bundle.kdf,
            wrappedMasterKey: bundle.wrappedMasterKey,
          ));

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
    final bundle = await _syncApiFor(_token!).fetchKeyBundle();
    if (bundle == null) {
      _moveTo(AccountState.needsPassphrase);
      return false;
    }
    final vault = await open(bundle);
    if (vault == null) return false;

    await _keys.writeMasterKey(vault.masterKeyForKeystore);
    await _start(vault);
    return true;
  }

  /// Answers the account-switch question: keep these notes and push them into
  /// the new account, or let go of them.
  Future<void> resolveAccountSwitch({required bool keepLocalNotes}) async {
    if (_accountState != AccountState.needsAccountDecision) return;
    if (!keepLocalNotes) _notes.forgetEverything();
    _state.adopt(_user!.id);
    await _resume();
  }

  Future<void> _start(Vault vault) async {
    final service =
        _syncServiceFactory?.call(api: _syncApiFor(_token!), vault: vault) ??
        SyncService(
          notes: _notes,
          state: _state,
          api: _syncApiFor(_token!),
          vault: vault,
        );
    _sync?.dispose();
    _sync = service..addListener(notifyListeners);
    _moveTo(AccountState.ready);
    // Before the first pass rather than after it: the app is already in front
    // of the user by the time this runs, and a change that lands while that
    // pass is in flight would otherwise have nothing to arrive on.
    service.resume();
    await service.syncNow();
  }

  /// Signing out drops the session and the key. It never touches the notes:
  /// they are the user's, they are on their device, and a sign-out is not a
  /// delete.
  Future<void> signOut() async {
    final token = _token;
    _sync?.dispose();
    _sync = null;
    _token = null;
    _user = null;
    _state.clearCursor();
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
  /// session intact so it can be tried again.
  Future<bool> deleteAccount(String confirmation) async {
    final token = _token;
    if (token == null) return false;

    try {
      await _syncApiFor(token).deleteAccount(confirmation);
    } on SyncProtocolException {
      // A 400: the typed address did not match. Worth saying plainly, because
      // the alternative reading — that deletion is broken — is worse.
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
    _sync?.dispose();
    _sync = null;
    _token = null;
    _user = null;
    _lastError = null;
    _state.clearCursor();
    await _keys.clear();
    _moveTo(AccountState.signedOut);
    return true;
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
    _sync?.dispose();
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
