import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/daily_separator.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import 'platform.dart';

/// How the app was opened, as far as it changes what the user meets.
enum LaunchIntent {
  /// The icon, a recent-apps card, anything ordinary. A draft typed on the
  /// way in becomes a note of its own.
  open,

  /// The Write widget on the Home Screen, or its Lock Screen twin. A draft
  /// continues the note last written in instead of starting another.
  continueWriting,
}

/// The Write widget's half of the app: one tap, and the user is back in the
/// note they were writing, below where they stopped, with the keyboard up.
///
/// Continuing rather than creating is the whole point. A widget that made a
/// note per tap would shred a notebook into one-line fragments, and on a plan
/// that caps how many notes an account may hold it would spend that allowance
/// on them. The widget is a way back into the notebook, not a way to add to
/// the pile.
class QuickCapture {
  const QuickCapture._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('kapynotes/quick_capture');

  /// How long the platform gets to say why the app was opened.
  ///
  /// It knows the answer before Dart starts, so this is never actually
  /// waited out. The deadline is here so that a host which somehow never
  /// replies costs a fraction of a second rather than stranding the app on
  /// its launch surface — and even that fraction is spent on a surface the
  /// user can already type into.
  static const Duration _answerDeadline = Duration(milliseconds: 400);

  /// Why the app was opened, according to the platform.
  ///
  /// Safe to start before storage is read and to await once it has been:
  /// nothing here touches a note. Answering [LaunchIntent.open] is the
  /// fallback for every failure, because opening normally is what an app that
  /// cannot tell should do.
  static Future<LaunchIntent> launchIntent() async {
    if (!AppPlatform.isMobile) return LaunchIntent.open;
    try {
      final name = await channel
          .invokeMethod<String>('launchIntent')
          .timeout(_answerDeadline);
      return name == LaunchIntent.continueWriting.name
          ? LaunchIntent.continueWriting
          : LaunchIntent.open;
    } catch (_) {
      // A desktop host, a platform with no handler registered, or one that
      // never answered. All three mean the same thing to the user.
      return LaunchIntent.open;
    }
  }

  /// Files [draft] — whatever was typed on the launch surface before storage
  /// finished loading — and returns the note it belongs to.
  ///
  /// Continuing appends at the same position opening the note by hand would
  /// have prepared: one blank line below the last of it. With nothing to
  /// continue, because this is a first launch or the last note was deleted on
  /// another device, the most recently edited note is simply the one that
  /// gets created.
  static Note file(NotesStore notes, String draft, LaunchIntent intent) {
    final last = notes.lastEditedNote;
    if (intent != LaunchIntent.continueWriting || last == null) {
      return notes.create(body: draft);
    }
    // Nothing was typed on the way in — the usual case, since storage loads
    // faster than a first keystroke. The note is already where it should be.
    if (draft.isEmpty) return last;

    // Formats are offsets into the text and the text only grows here, so they
    // survive the append untouched.
    notes.updateDocument(
      last.id,
      '${DailySeparator.prepareForAppend(last.body)}$draft',
      last.formats,
    );
    return notes.byId(last.id) ?? last;
  }
}
