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

  /// **Write**, from a widget on the Home Screen, its Lock Screen twin, or a
  /// control. A draft continues the note last written in instead of starting
  /// another, and there is nothing to do on arrival but be in it.
  continueWriting,

  /// **Dictate**. The same note, with a recording started in it.
  dictate,

  /// **Capture**. The same note, with its camera open over it.
  capture;

  /// Whether this arrival belongs in the note last written in.
  ///
  /// Every widget action does. The widget is a way back into the notebook,
  /// not a way to add to the pile: a note per tap would shred a notebook into
  /// one-line fragments, and on a plan that caps how many notes an account
  /// may hold it would spend that allowance on them. Only an ordinary launch
  /// starts a note.
  bool get continuesLastNote => this != LaunchIntent.open;
}

/// The widgets' half of the app: one tap, and the user is back in the note
/// they were writing, below where they stopped, with the keyboard up — and,
/// for two of the three actions, with the camera or the recorder already
/// going.
///
/// Which action was tapped is the only thing the platform has to say. It says
/// it once, on the way in, and the app spends it: what to write, and where,
/// is the app's own business and always was.
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
  ///
  /// The platform answers once and then forgets, so this is also how a tap
  /// that arrives while the app is already running is collected: whoever asks
  /// next gets it, and nobody gets it twice.
  static Future<LaunchIntent> launchIntent() async {
    if (!AppPlatform.isMobile) return LaunchIntent.open;
    try {
      final name = await channel
          .invokeMethod<String>('launchIntent')
          .timeout(_answerDeadline);
      return _named(name);
    } catch (_) {
      // A desktop host, a platform with no handler registered, or one that
      // never answered. All three mean the same thing to the user.
      return LaunchIntent.open;
    }
  }

  /// The intent the platform named, or [LaunchIntent.open] for a name this
  /// version of the app does not know — an older app under a newer widget.
  static LaunchIntent _named(String? name) {
    for (final intent in LaunchIntent.values) {
      if (intent.name == name) return intent;
    }
    return LaunchIntent.open;
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
    if (!intent.continuesLastNote || last == null) {
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
