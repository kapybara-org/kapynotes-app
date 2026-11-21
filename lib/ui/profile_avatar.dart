import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Profile picture: the photo somebody uploaded, or their initials drawn
/// here, so a face never asks anybody else's server for anything.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.name,
    required this.extent,
    this.image,
    this.ring,
    this.ringWidth = 1.5,
  });

  final String name;
  final double extent;
  final String? image;
  final Color? ring;
  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final photo = _dataImage(image);
    final initials = _initials(context);

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
        child: photo == null
            ? initials
            : Image(
                image: MemoryImage(photo),
                width: extent,
                height: extent,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                // A new photo replaces the old one when it is ready, not a
                // blank.
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => initials,
              ),
      ),
    );
  }

  Widget _initials(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.selectedBackground,
      child: Center(
        child: Text(
          avatarInitial(name),
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

/// What a face without a photo shows: the first character of the first word
/// in [name] that doesn't open with punctuation, capitalised. A name with no
/// such word shows '?'.
String avatarInitial(String name) {
  for (final word in name.split(RegExp(r'\s+'))) {
    if (word.isEmpty || word.startsWith(_punctuation)) continue;
    return word.characters.first.toUpperCase();
  }
  return '?';
}

final _punctuation = RegExp(r'^\p{P}', unicode: true);
