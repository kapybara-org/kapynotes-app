import '../data/note.dart';
import '../data/notes_store.dart';

/// A note a question read, as it is sent.
class ReadNote {
  const ReadNote({
    required this.id,
    required this.title,
    required this.text,
    required this.edited,
  });

  final String id;
  final String title;
  final String text;
  final DateTime edited;
}

/// What a question read, and how many notes it could have.
class Retrieval {
  const Retrieval({required this.notes, required this.matching});

  final List<ReadNote> notes;

  /// The notes with at least one of the question's words, plus the "This
  /// note" chip's note when it had none: "Read 3 of the 7 matching notes".
  final int matching;
}

/// How much a model is sent.
class RetrievalBudget {
  const RetrievalBudget({
    required this.notes,
    required this.chars,
    required this.charsPerNote,
  });

  final int notes;
  final int chars;
  final int charsPerNote;

  /// Kapy AI Cloud's contract, and the person's own accounts, whose models
  /// read at least as much.
  static const RetrievalBudget cloud = RetrievalBudget(
    notes: 12,
    chars: 48000,
    charsPerNote: 12000,
  );

  /// One model's context, shared by every note.
  factory RetrievalBudget.device(int chars) =>
      RetrievalBudget(notes: 12, chars: chars, charsPerNote: chars);
}

/// A note shorter than this is not worth reading once the budget is nearly
/// spent: a few lines from the middle of the twelfth note mislead more than
/// they inform.
const int _minimumUsefulChars = 400;

/// The longest title the cloud contract takes.
const int _maxTitleChars = 200;

/// The notes a question should read, best first, never a hidden one.
///
/// A question is not a search query: "what did I plan for the trip to
/// Lisbon?" holds two words worth looking for. So it is split the way the
/// notes list splits a search ([noteSearchTerms]), the words that carry no
/// meaning are dropped, and each note is scored by how many of the rest it
/// holds in the same text the list searches ([Note.searchText]), a word in
/// the title counting three times. "Today", "yesterday" and "this week" are
/// read as when a note was edited rather than as words in it, so "summarise
/// what I wrote yesterday" finds yesterday's notes. Recency breaks ties.
///
/// [noteId] is the "This note" chip: read first whatever it holds, unless it
/// is hidden, and on its own when nothing else matches.
Retrieval retrieve({
  required NotesStore store,
  required String question,
  required RetrievalBudget budget,
  String? noteId,
}) {
  final terms = questionTerms(question);
  final window = _editedWithin(question, store.now());
  final scored = <({Note note, int score})>[];
  for (final note in [...store.notes, ...store.archivedNotes]) {
    if (note.isHidden || note.id == noteId) continue;
    var score = _score(note, terms);
    if (window != null &&
        !note.updatedAt.isBefore(window.from) &&
        note.updatedAt.isBefore(window.to)) {
      score += 2;
    }
    if (score > 0) scored.add((note: note, score: score));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : b.note.updatedAt.compareTo(a.note.updatedAt);
  });

  final chip = noteId == null ? null : _visible(store, noteId);
  final ranked = [?chip, for (final entry in scored) entry.note];

  final read = <ReadNote>[];
  var spent = 0;
  for (final note in ranked) {
    if (read.length == budget.notes) break;
    final room = budget.chars - spent;
    if (room < _minimumUsefulChars) break;
    var text = note.searchText;
    final cap = room < budget.charsPerNote ? room : budget.charsPerNote;
    if (text.length > cap) text = text.substring(0, cap);
    spent += text.length;
    read.add(
      ReadNote(
        id: note.id,
        title: note.title.length > _maxTitleChars
            ? note.title.substring(0, _maxTitleChars)
            : note.title,
        text: text,
        edited: note.updatedAt,
      ),
    );
  }
  return Retrieval(notes: read, matching: ranked.length);
}

/// The notes in [notes] that are still there and still not hidden.
///
/// Run on the way out, after everything else: a note hidden while the model
/// was being chosen, or a path that forgot to filter, still never leaves.
List<ReadNote> readableNotes(NotesStore store, List<ReadNote> notes) => [
  for (final note in notes)
    if (_visible(store, note.id) != null) note,
];

Note? _visible(NotesStore store, String id) {
  for (final note in store.allNotes) {
    if (note.id == id) return note.isHidden ? null : note;
  }
  return null;
}

/// The words of [question] worth looking for: the notes list's terms, with
/// punctuation trimmed off their ends and English stop words dropped, and
/// the words [_editedWithin] reads as a time.
List<String> questionTerms(String question) {
  final terms = <String>[];
  for (final raw in noteSearchTerms(question)) {
    final term = raw.replaceAll(_edges, '').replaceFirst(_possessive, '');
    if (term.length < 2 ||
        _stopWords.contains(term) ||
        _timeWords.contains(term)) {
      continue;
    }
    if (!terms.contains(term)) terms.add(term);
  }
  return terms;
}

/// The days a question names, as a span of edit times.
({DateTime from, DateTime to})? _editedWithin(String question, DateTime now) {
  final words = question.toLowerCase();
  final today = DateTime(now.year, now.month, now.day);
  if (words.contains('yesterday')) {
    return (from: today.subtract(const Duration(days: 1)), to: today);
  }
  if (words.contains('today')) {
    return (from: today, to: today.add(const Duration(days: 1)));
  }
  if (words.contains('week')) {
    return (
      from: today.subtract(const Duration(days: 6)),
      to: today.add(const Duration(days: 1)),
    );
  }
  return null;
}

const Set<String> _timeWords = {'today', 'yesterday', 'week'};

int _score(Note note, List<String> terms) {
  if (terms.isEmpty) return 0;
  final title = note.title.toLowerCase();
  final lines = [
    for (final line in note.searchText.split('\n'))
      line.toLowerCase().replaceAll(_whitespace, ' '),
  ];
  var score = 0;
  for (final term in terms) {
    if (title.contains(term)) {
      score += 3;
    } else if (lines.any((line) => line.contains(term))) {
      score += 1;
    }
  }
  return score;
}

final RegExp _edges = RegExp(r"^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$", unicode: true);
final RegExp _possessive = RegExp(r"['’]s$");
final RegExp _whitespace = RegExp(r'\s+');

/// English words that say nothing about which note is meant, and the words
/// a question to a notes app is made of ("find", "notes", "summarise").
final Set<String> _stopWords =
    ('about above after again all also am an and any are as at be '
            'because been before being below between both but by can could did '
            'do does doing done down during each either else ever every few '
            'find for from further get give got had has have having he her here '
            'hers him his how if in into is it its just know let like list me '
            'mine more most my myself no nor not note notes now of off on once '
            'only or other our ours out over own please same say said she '
            'should show so some such tell than that the their theirs them then '
            'there these they thing things this those through to too under '
            'until up us very was we were what when where which while who whom '
            'why will with would wrote write written you your yours anything '
            'something summarise summarize summary')
        .split(' ')
        .toSet();
