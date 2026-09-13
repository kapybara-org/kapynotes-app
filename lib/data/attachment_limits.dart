/// Per-file ciphertext ceilings mirrored from the shared server contract.
/// The server remains authoritative; these let the picker refuse an oversized
/// video before reading it into memory or opening a decoder.
const int freeAttachmentMaxBytes = 25 * 1024 * 1024;
const int proAttachmentMaxBytes = 100 * 1024 * 1024;

/// Resolves who pays for one note's files. The active account is freshest for
/// a space it owns, especially immediately after an upgrade. A shared space
/// owned by somebody else must use that owner's server-provided limit instead.
int resolveAttachmentMaxBytes({
  required String? accountUserId,
  required String? spaceOwnerId,
  required int? accountMaxBytes,
  required int? spaceMaxBytes,
}) {
  final ownedByAccount =
      spaceOwnerId == null ||
      (accountUserId != null && spaceOwnerId == accountUserId);
  if (ownedByAccount) {
    return accountMaxBytes ?? spaceMaxBytes ?? freeAttachmentMaxBytes;
  }
  return spaceMaxBytes ?? freeAttachmentMaxBytes;
}
