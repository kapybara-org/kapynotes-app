/// Whether voice notes are reachable in this build.
///
/// On from 1.14.0. The flag stays for one release as the way to turn the
/// feature off without a rollback, and goes with 1.15.
///
/// What it was for: version 1.13.0 shipped attachments before they carried a
/// `kind`, and its reader requires `width` and `height` on every ref, so it
/// cannot see a recording at all. Measured against 1.13.0's own code, that
/// turns out to matter in exactly one case — the op log saves the rest:
///
///   * Reading a note holding a recording: the recording is invisible there
///     but untouched.
///   * Typing in that note: the attachment register is only rewritten when the
///     parsed list differs from the rendered one, and on 1.13.0 both are
///     empty, so no attachment op is emitted at all.
///   * Syncing or snapshotting it: registers are copied raw, never re-parsed.
///   * **Adding or removing a picture in that note**: the register is rewritten
///     from a list that build could not fully parse, and the recording is lost
///     for every device.
///
/// So the exposure is one action, on a device that has not updated, in a note
/// that holds both a recording and a picture. See
/// `docs/voice-notes.md` and the tests in `test/crdt/`.
const bool voiceNotesEnabled = bool.fromEnvironment(
  'KAPY_VOICE_NOTES',
  defaultValue: true,
);
