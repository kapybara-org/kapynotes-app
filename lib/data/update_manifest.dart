/// A release newer than the running build, as advertised by the manifest.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.build,
    required this.notesUrl,
    this.windows,
  });

  final String version;
  final int build;
  final String notesUrl;

  /// The Windows installer and its signature. Null in a manifest written
  /// before the app downloaded its own updates, and in any that simply leaves
  /// it out — macOS never needs it, because Sparkle reads its own appcast.
  final UpdatePackage? windows;

  static AvailableUpdate? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final version = decoded['version'];
    final build = decoded['build'];
    if (version is! String || version.isEmpty) return null;
    if (build is! int) return null;
    final notes = decoded['notesUrl'];
    return AvailableUpdate(
      version: version,
      build: build,
      notesUrl: notes is String ? notes : '',
      windows: UpdatePackage.fromJson(decoded['windows']),
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'build': build,
    'notesUrl': notesUrl,
    if (windows != null) 'windows': windows!.toJson(),
  };
}

/// One installer, as the release job describes it in `latest.json`.
class UpdatePackage {
  const UpdatePackage({
    required this.url,
    required this.length,
    required this.signature,
  });

  final Uri url;

  /// The exact size in bytes. A download that ends anywhere else is not the
  /// file the signature was made over, and is not worth hashing to find out.
  final int length;

  /// Base64 DER, DSA over the file's SHA-1: the scheme WinSparkle defined,
  /// which the release job has always used. See [verifyInstallerSignature].
  final String signature;

  /// Only over HTTPS. The signature is what makes the file safe to run, but
  /// there is no reason to fetch fifty megabytes that anyone on the path can
  /// swap out, only to find that out after the last byte.
  static UpdatePackage? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final url = decoded['url'];
    final length = decoded['length'];
    final signature = decoded['dsaSignature'];
    if (url is! String || length is! int || signature is! String) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (length <= 0 || signature.isEmpty) return null;
    return UpdatePackage(url: uri, length: length, signature: signature);
  }

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    'length': length,
    'dsaSignature': signature,
  };
}
