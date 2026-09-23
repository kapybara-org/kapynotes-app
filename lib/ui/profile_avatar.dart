import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// A stable DiceBear avatar that does not disclose an email address or user
/// id in the request seed.
Uri diceBearAvatarUri(String seed) => Uri.https(
  'api.dicebear.com',
  '/10.x/initials/png',
  {'seed': _seedHash(seed).toRadixString(16), 'size': '128'},
);

/// Profile picture with a deterministic DiceBear default and a local initial
/// behind it for offline launches.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.seed,
    required this.name,
    required this.extent,
    this.image,
    this.ring,
    this.ringWidth = 1.5,
  });

  final String seed;
  final String name;
  final double extent;
  final String? image;
  final Color? ring;
  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final custom = _dataImage(image);
    final provider = custom == null
        ? NetworkImage(diceBearAvatarUri(seed).toString())
        : MemoryImage(custom) as ImageProvider<Object>;
    final fallback = _fallback(context);

    return Container(
      width: extent,
      height: extent,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: ring == null
            ? null
            : Border.all(color: ring!, width: ringWidth),
        color: palette.controlBackground,
      ),
      padding: ring == null ? EdgeInsets.zero : EdgeInsets.all(ringWidth),
      child: ClipOval(
        child: Image(
          image: provider,
          width: extent,
          height: extent,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // A new photo replaces the old one when it is ready, not a blank.
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.selectedBackground,
      child: Center(
        child: Text(
          _initial(name),
          style: TextStyle(
            fontSize: extent * 0.42,
            fontWeight: FontWeight.w400,
            color: palette.textPrimary,
            height: 1,
          ),
          textScaler: TextScaler.noScaling,
        ),
      ),
    );
  }
}

/// Photos already decoded, by their data URL, most recently used last.
///
/// [MemoryImage] compares its bytes by identity, so bytes decoded afresh on
/// every build missed the image cache each time: the photo was decoded again
/// and nothing was drawn meanwhile, and a list showing faces on every row
/// flickered with each keystroke that rebuilt it.
final Map<String, Uint8List?> _decodedPhotos = {};
const int _decodedPhotoLimit = 64;

Uint8List? _dataImage(String? value) {
  if (value == null || !value.startsWith('data:image/')) return null;
  if (_decodedPhotos.containsKey(value)) {
    final bytes = _decodedPhotos.remove(value);
    return _decodedPhotos[value] = bytes;
  }
  final bytes = _decodeDataImage(value);
  _decodedPhotos[value] = bytes;
  if (_decodedPhotos.length > _decodedPhotoLimit) {
    _decodedPhotos.remove(_decodedPhotos.keys.first);
  }
  return bytes;
}

Uint8List? _decodeDataImage(String value) {
  final marker = value.indexOf('base64,');
  if (marker < 0) return null;
  try {
    return base64.decode(value.substring(marker + 7));
  } on FormatException {
    return null;
  }
}

String _initial(String value) {
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (char.trim().isNotEmpty) return char.toUpperCase();
  }
  return '?';
}

int _seedHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
