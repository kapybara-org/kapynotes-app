import '../calc/engine.dart';
import 'local_store.dart';
import 'note.dart';
import 'notes_store.dart';

/// The note a first launch opens into.
///
/// Deliberately a real note rather than a tour: it is created through the
/// ordinary [NotesStore.create], syncs like any other, and can be rewritten or
/// thrown away. The teaching happens when the reader changes 12.40 and the
/// column on the right moves with them, which no carousel of screenshots can
/// do.
///
/// Three rules govern the content, and `test/welcome_note_test.dart` holds
/// all three:
///
///  * **No currency.** A new install has no exchange rates until the first
///    refresh lands, and until then `12.40 eur` evaluates to a bare `12.4`
///    with the currency quietly dropped. A first impression cannot afford a
///    line that is wrong until the network turns up.
///  * **One dimension throughout.** Every result folds into the running sum,
///    so a stray `9 km` here would leave both the `total` line and the
///    footer readout reading in miles. Plain numbers keep the two agreeing.
///  * **Prose that reads as prose.** [CalcEngine.looksLikeMath] decides both
///    what is evaluated and what is coloured, so a sentence carrying a colon
///    or the word `sum` gets syntax highlighting sprayed through the middle
///    of it. Only the demo, the total and the closing invitation light up —
///    and the invitation is meant to, since seeing `20% of 60` coloured is
///    half of what it is inviting.
///
/// The prose is written as whole sentences and left to wrap. Hand-wrapping it
/// to the phone's writing column — about twenty-six characters beside the
/// results gutter — only wraps a second time and leaves an orphan word on a
/// line of its own; a sentence that wraps once reads as a paragraph on a
/// phone and as one line on a desktop. The whole note has to fit on screen at
/// 390x760 without scrolling, because the invitation at the end is the part
/// that gets somebody typing.
const String welcomeNoteBody = '''
Welcome to Kapy Notes

This note is also a calculator.

Coffee: 12.40
Oats: 3.99
Pastries: 6.50

total

Edit any number above and the results keep up. Everything else stays exactly as you wrote it.

Now try 20% of 60, or 9 km in miles.
''';

/// Whether this install has met the welcome note yet.
///
/// Recorded as a revision rather than a flag so that a later release can
/// introduce a different first run without showing this one to everybody
/// again — and so that bumping [welcomeRevision] is the whole of the decision.
class Onboarding {
  const Onboarding(this._store);

  final LocalStore _store;

  static const String storeKey = 'onboarding.v1';

  /// Raise when [welcomeNoteBody] changes enough to be worth showing twice.
  static const int welcomeRevision = 1;

  int get shownRevision => _store.read<int>(storeKey) ?? 0;

  bool get hasSeenWelcome => shownRevision >= welcomeRevision;

  /// Seeds the welcome note, or returns null when it does not belong here.
  ///
  /// Only ever into an empty store: a device that already holds notes — a
  /// reinstall whose session outlived it, or a sync that arrived first — is
  /// somebody continuing, not somebody starting.
  Note? seedWelcomeNote(NotesStore notes) {
    if (hasSeenWelcome || !notes.isEmpty) return null;
    markWelcomeShown();
    return notes.create(body: welcomeNoteBody);
  }

  /// The welcome note as it stands, made again if it was edited or deleted.
  ///
  /// What "Welcome note" in settings opens. Matching on the exact body is what
  /// keeps a second visit from stacking up copies, while still leaving a note
  /// the user has since made their own alone.
  Note openWelcomeNote(NotesStore notes) {
    markWelcomeShown();
    for (final note in notes.notes) {
      if (note.body == welcomeNoteBody) return note;
    }
    return notes.create(body: welcomeNoteBody);
  }

  /// Written through [LocalStore.putNow]: the launch that shows the note is
  /// also the launch most likely to be killed from the app switcher a moment
  /// later, and a coalesced write would greet them with it all over again.
  void markWelcomeShown() => _store.putNow(storeKey, welcomeRevision);
}
