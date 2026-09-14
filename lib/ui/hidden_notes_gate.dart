import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../sync/aead.dart' show randomBytes;
import '../sync/key_store.dart';

const int _hiddenCredentialVersion = 1;

/// The authentication boundary around Hidden Notes.
///
/// It owns credentials, not unlocked state. The caller deliberately asks
/// [unlock] every time the folder is entered and forgets the result as soon as
/// the folder is left.
abstract interface class HiddenNotesGate {
  /// Makes sure this device has a way back into Hidden Notes.
  ///
  /// Used before the first note is hidden, so a note can never disappear
  /// behind a credential the reader did not finish creating.
  Future<bool> ensureConfigured(BuildContext context);

  /// Authenticates one entry into Hidden Notes.
  Future<bool> unlock(BuildContext context);
}

enum DeviceAuthenticationResult { authenticated, canceled, unavailable, failed }

/// The phone's screen-lock authentication, abstracted so UI tests never need
/// a biometric sensor or a platform channel.
abstract interface class DeviceAuthenticator {
  Future<DeviceAuthenticationResult> authenticate();
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  LocalDeviceAuthenticator([LocalAuthentication? authentication])
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<DeviceAuthenticationResult> authenticate() async {
    try {
      if (!await _authentication.isDeviceSupported()) {
        return DeviceAuthenticationResult.unavailable;
      }
      final authenticated = await _authentication.authenticate(
        localizedReason: 'Unlock Hidden Notes',
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
      return authenticated
          ? DeviceAuthenticationResult.authenticated
          : DeviceAuthenticationResult.canceled;
    } on LocalAuthException catch (error) {
      return switch (error.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout => DeviceAuthenticationResult.canceled,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware =>
          DeviceAuthenticationResult.unavailable,
        _ => DeviceAuthenticationResult.failed,
      };
    } on PlatformException {
      // Older platform implementations can still report a plugin failure in
      // the pre-3.0 shape. It must deny access rather than becoming a PIN
      // fallback, because a temporary plugin failure is not "no device lock".
      return DeviceAuthenticationResult.failed;
    }
  }
}

/// Device-local Hidden Notes credentials.
///
/// The marker or PIN verifier lives in the platform's protected credential
/// store. A strict [SecureStore] is intentional: swallowing a failed write
/// would let a note be hidden without leaving any way to unlock it next time.
class DefaultHiddenNotesGate implements HiddenNotesGate {
  DefaultHiddenNotesGate({
    SecureStore? store,
    DeviceAuthenticator? deviceAuthenticator,
    bool? useSystemAuthentication,
    Future<Uint8List> Function(String pin, Uint8List salt)? pinDeriver,
  }) : _store = store ?? const PlatformSecureStore(),
       _deviceAuthenticator = deviceAuthenticator ?? LocalDeviceAuthenticator(),
       _pinDeriver = pinDeriver ?? _derivePin,
       _useSystemAuthentication =
           useSystemAuthentication ?? AppPlatform.isMobile;

  static const String credentialKey = 'kapynotes.hiddenNotesCredential';
  final SecureStore _store;
  final DeviceAuthenticator _deviceAuthenticator;
  final Future<Uint8List> Function(String pin, Uint8List salt) _pinDeriver;
  final bool _useSystemAuthentication;

  @override
  Future<bool> ensureConfigured(BuildContext context) async {
    final existing = await _read(context);
    if (existing is _ReadFailed || !context.mounted) return false;
    final credential = (existing as _ReadCredential).value;
    if (credential != null) return true;

    if (_useSystemAuthentication) {
      final result = await _deviceAuthenticator.authenticate();
      if (!context.mounted) return false;
      switch (result) {
        case DeviceAuthenticationResult.authenticated:
          return _write(context, const _SystemCredential());
        case DeviceAuthenticationResult.unavailable:
          break;
        case DeviceAuthenticationResult.canceled:
          return false;
        case DeviceAuthenticationResult.failed:
          await _showFailure(
            context,
            'Could not use this device\'s authentication. Hidden Notes stayed locked.',
          );
          return false;
      }
    }

    if (!context.mounted) return false;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CreatePinDialog(),
    );
    if (pin == null || !context.mounted) return false;
    final salt = randomBytes(16);
    final verifier = await _pinDeriver(pin, salt);
    if (!context.mounted) return false;
    return _write(context, _PinCredential(salt: salt, verifier: verifier));
  }

  @override
  Future<bool> unlock(BuildContext context) async {
    final read = await _read(context);
    if (read is _ReadFailed || !context.mounted) return false;
    final credential = (read as _ReadCredential).value;
    if (credential == null) return ensureConfigured(context);

    switch (credential) {
      case _SystemCredential():
        final result = await _deviceAuthenticator.authenticate();
        if (!context.mounted) return false;
        if (result == DeviceAuthenticationResult.authenticated) return true;
        if (result == DeviceAuthenticationResult.failed ||
            result == DeviceAuthenticationResult.unavailable) {
          await _showFailure(
            context,
            result == DeviceAuthenticationResult.unavailable
                ? 'This device\'s authentication is no longer available. Hidden Notes stayed locked.'
                : 'Authentication failed. Hidden Notes stayed locked.',
          );
        }
        return false;
      case _PinCredential():
        final unlocked = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _UnlockPinDialog(
            verify: (pin) async => _constantTimeEquals(
              await _pinDeriver(pin, credential.salt),
              credential.verifier,
            ),
          ),
        );
        return unlocked ?? false;
    }
  }

  Future<_ReadResult> _read(BuildContext context) async {
    try {
      final raw = await _store.read(credentialKey);
      if (raw == null) return const _ReadCredential(null);
      final credential = _Credential.parse(raw);
      if (credential == null) {
        if (context.mounted) {
          await _showFailure(
            context,
            'The Hidden Notes credential on this device is damaged. Hidden Notes stayed locked.',
          );
        }
        return const _ReadFailed();
      }
      return _ReadCredential(credential);
    } catch (_) {
      if (context.mounted) {
        await _showFailure(
          context,
          'The secure credential store could not be read. Hidden Notes stayed locked.',
        );
      }
      return const _ReadFailed();
    }
  }

  Future<bool> _write(BuildContext context, _Credential credential) async {
    try {
      await _store.write(credentialKey, credential.encode());
      return true;
    } catch (_) {
      if (context.mounted) {
        await _showFailure(
          context,
          'The secure credential store could not save the Hidden Notes credential.',
        );
      }
      return false;
    }
  }

  static Future<void> _showFailure(BuildContext context, String message) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Hidden Notes'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(message),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
}

sealed class _Credential {
  const _Credential();

  String encode();

  static _Credential? parse(String encoded) {
    try {
      final raw = jsonDecode(encoded);
      if (raw is! Map || raw['v'] != _hiddenCredentialVersion) return null;
      return switch (raw['method']) {
        'system' => const _SystemCredential(),
        'pin' => _parsePin(raw),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

  static _PinCredential? _parsePin(Map<dynamic, dynamic> raw) {
    final saltText = raw['salt'];
    final verifierText = raw['verifier'];
    if (saltText is! String || verifierText is! String) return null;
    try {
      final salt = Uint8List.fromList(base64Decode(saltText));
      final verifier = Uint8List.fromList(base64Decode(verifierText));
      if (salt.length != 16 || verifier.length != 32) return null;
      return _PinCredential(salt: salt, verifier: verifier);
    } on FormatException {
      return null;
    }
  }
}

class _SystemCredential extends _Credential {
  const _SystemCredential();

  @override
  String encode() =>
      jsonEncode({'v': _hiddenCredentialVersion, 'method': 'system'});
}

class _PinCredential extends _Credential {
  const _PinCredential({required this.salt, required this.verifier});

  final Uint8List salt;
  final Uint8List verifier;

  @override
  String encode() => jsonEncode({
    'v': _hiddenCredentialVersion,
    'method': 'pin',
    'salt': base64Encode(salt),
    'verifier': base64Encode(verifier),
  });
}

sealed class _ReadResult {
  const _ReadResult();
}

class _ReadCredential extends _ReadResult {
  const _ReadCredential(this.value);

  final _Credential? value;
}

class _ReadFailed extends _ReadResult {
  const _ReadFailed();
}

/// Slow enough that copying the protected credential record does not turn its
/// four-digit PIN into an instant offline lookup, and kept off the UI isolate.
Future<Uint8List> _derivePin(String pin, Uint8List salt) {
  final saltCopy = Uint8List.fromList(salt);
  return Isolate.run(() async {
    final derived = await Argon2id(
      memory: 19 * 1024,
      iterations: 2,
      parallelism: 1,
      hashLength: 32,
    ).deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: saltCopy);
    return Uint8List.fromList((await derived.extract()).bytes);
  });
}

bool _constantTimeEquals(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

class _CreatePinDialog extends StatefulWidget {
  const _CreatePinDialog();

  @override
  State<_CreatePinDialog> createState() => _CreatePinDialogState();
}

class _CreatePinDialogState extends State<_CreatePinDialog> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pin.text;
    if (pin.length != 4) {
      setState(() => _error = 'Enter four digits.');
      return;
    }
    if (pin != _confirmation.text) {
      setState(() => _error = 'The PINs do not match.');
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create a Hidden Notes PIN'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            AppPlatform.isMobile
                ? 'System authentication is not set up, so Hidden Notes will '
                      'use a 4-digit PIN on this device.'
                : 'Use a 4-digit PIN to protect Hidden Notes on this device.',
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: context.palette.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _PinField(
            key: const ValueKey('hidden-pin-create'),
            controller: _pin,
            label: 'PIN',
            autofocus: true,
          ),
          const SizedBox(height: 12),
          _PinField(
            key: const ValueKey('hidden-pin-confirm'),
            controller: _confirmation,
            label: 'Confirm PIN',
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              key: const ValueKey('hidden-pin-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Create PIN')),
    ],
  );
}

class _UnlockPinDialog extends StatefulWidget {
  const _UnlockPinDialog({required this.verify});

  final Future<bool> Function(String pin) verify;

  @override
  State<_UnlockPinDialog> createState() => _UnlockPinDialogState();
}

class _UnlockPinDialogState extends State<_UnlockPinDialog> {
  final TextEditingController _pin = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    if (_pin.text.length != 4) {
      setState(() => _error = 'Enter your four-digit PIN.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final correct = await widget.verify(_pin.text);
    if (!mounted) return;
    if (correct) {
      Navigator.of(context).pop(true);
      return;
    }
    _pin.clear();
    setState(() {
      _checking = false;
      _error = 'That PIN is not correct.';
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Unlock Hidden Notes'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PinField(
            key: const ValueKey('hidden-pin-unlock'),
            controller: _pin,
            label: 'PIN',
            autofocus: true,
            enabled: !_checking,
            onSubmitted: (_) => unawaited(_submit()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              key: const ValueKey('hidden-pin-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _checking ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _checking ? null : () => unawaited(_submit()),
        child: Text(_checking ? 'Checking…' : 'Unlock'),
      ),
    ],
  );
}

class _PinField extends StatelessWidget {
  const _PinField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.enabled = true,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    enabled: enabled,
    obscureText: true,
    keyboardType: TextInputType.number,
    textInputAction: onSubmitted == null
        ? TextInputAction.next
        : TextInputAction.done,
    maxLength: 4,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    onSubmitted: onSubmitted,
    decoration: InputDecoration(labelText: label, counterText: ''),
  );
}
