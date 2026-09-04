/// Where the app talks to.
///
/// Overridable at build time so a development build can point at a local
/// server without editing source that would then be easy to commit by
/// accident: `flutter run --dart-define=KAPYNOTES_API=http://localhost:3000/`.
const String kApiBaseUrl = String.fromEnvironment(
  'KAPYNOTES_API',
  defaultValue: 'https://api.kapynotes.com/',
);

/// Whether this build has a server to sync with. False disables the account
/// UI entirely rather than showing controls that cannot work.
const bool kSyncEnabled = bool.fromEnvironment(
  'KAPYNOTES_SYNC',
  defaultValue: true,
);
