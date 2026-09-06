/// Blocking, reporting, and the terms accepted before sharing.
///
/// Mirrors `packages/contract/src/safety.ts`. The shape of all three is
/// decided by one fact: notes are end-to-end encrypted, so the server cannot
/// look at what is in them.
///
/// Blocking and reporting an invitation need no plaintext, which is why they
/// carry the weight here — and it happens that the invitation, not the note,
/// is the surface a stranger can reach an unwilling person through. Reporting
/// a note's contents is the one thing that has to ask, and it asks plainly.
library;

/// A person this account will not accept invitations from.
class Block {
  final String email;
  final DateTime createdAt;

  const Block({required this.email, required this.createdAt});

  static Block? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final email = raw['email'];
    final createdAt = DateTime.tryParse(raw['createdAt'] as String? ?? '');
    if (email is! String || createdAt == null) return null;
    return Block(email: email, createdAt: createdAt.toLocal());
  }
}

enum ReportKind {
  /// An invitation that arrived. Entirely unencrypted, so a report of one
  /// needs nothing from this device but the token.
  invitation,

  /// A note inside a shared space. May carry its text, but only if asked.
  note,

  /// A person in a space, for behaviour rather than for one note.
  member,
}

enum ReportReason {
  spam,
  harassment,
  sexualContent,
  violence,
  impersonation,
  other;

  /// The wire value. Kebab-case, matching the contract's enum.
  String get wire => switch (this) {
    ReportReason.spam => 'spam',
    ReportReason.harassment => 'harassment',
    ReportReason.sexualContent => 'sexual-content',
    ReportReason.violence => 'violence',
    ReportReason.impersonation => 'impersonation',
    ReportReason.other => 'other',
  };

  /// What the person choosing it reads.
  String get label => switch (this) {
    ReportReason.spam => 'Spam or unwanted invitations',
    ReportReason.harassment => 'Harassment or bullying',
    ReportReason.sexualContent => 'Sexual content',
    ReportReason.violence => 'Violence or threats',
    ReportReason.impersonation => 'Pretending to be someone else',
    ReportReason.other => 'Something else',
  };
}

/// What is being reported, and what the app is able to say about it.
///
/// The three named constructors exist so that a caller cannot assemble a
/// report that names a note without a space, or an invitation without its
/// token — the server refuses those, and there is no reason to let the UI
/// build one in the first place.
class ReportTarget {
  final ReportKind kind;
  final String? token;
  final String? spaceId;
  final String? noteId;
  final String? email;

  /// The note's text, when there is one to offer. Held here so the dialog can
  /// show what would be sent, and sent only if the person says so.
  final String? noteBody;

  /// An invitation, by its token. Nothing encrypted is involved.
  const ReportTarget.invitation({
    required String this.token,
    this.email,
  }) : kind = ReportKind.invitation,
       spaceId = null,
       noteId = null,
       noteBody = null;

  /// A note. [noteBody] is what *could* be attached, and is not attached
  /// unless the person reporting chooses to.
  const ReportTarget.note({
    required String this.spaceId,
    required String this.noteId,
    required String this.noteBody,
  }) : kind = ReportKind.note,
       token = null,
       email = null;

  const ReportTarget.member({
    required String this.spaceId,
    required String this.email,
  }) : kind = ReportKind.member,
       token = null,
       noteId = null,
       noteBody = null;

  /// Whether this report has anything encrypted it could offer to disclose.
  bool get canAttachContent => noteBody != null && noteBody!.trim().isNotEmpty;

  /// A short description of what is being reported, for the dialog's heading.
  String get what => switch (kind) {
    ReportKind.invitation => 'this invitation',
    ReportKind.note => 'this note',
    ReportKind.member => email ?? 'this person',
  };
}

/// Whether this account has agreed to the rules of a shared space, and to
/// which version of them.
class TermsStatus {
  final int acceptedVersion;
  final int currentVersion;
  final DateTime? acceptedAt;

  const TermsStatus({
    required this.acceptedVersion,
    required this.currentVersion,
    this.acceptedAt,
  });

  bool get isAccepted => acceptedVersion >= currentVersion;

  /// What a device assumes before it has asked: nothing agreed. Erring this
  /// way shows the sheet once too often rather than letting somebody share
  /// without ever having seen it.
  static const TermsStatus unknown = TermsStatus(
    acceptedVersion: 0,
    currentVersion: sharingTermsVersion,
  );

  static TermsStatus? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final accepted = raw['acceptedVersion'];
    final current = raw['currentVersion'];
    if (accepted is! int || current is! int) return null;
    return TermsStatus(
      acceptedVersion: accepted,
      currentVersion: current,
      acceptedAt: DateTime.tryParse(raw['acceptedAt'] as String? ?? '')?.toLocal(),
    );
  }
}

/// The version of the sharing terms this build presents. Matches
/// `SHARING_TERMS_VERSION`.
const int sharingTermsVersion = 1;

/// The error code the server answers with when an account tries to share
/// before accepting. Matches `TERMS_REQUIRED`.
const String termsRequiredCode = 'sharing-terms-required';

/// Where a report is answered from, and the address both stores require to be
/// published. Matches `SAFETY_CONTACT`.
const String safetyContact = 'hello@kapynotes.com';

/// How quickly we say a report is answered. Apple asks for "timely
/// responses"; a promise nobody wrote down is not one.
const int reportResponseDays = 2;

/// The rules of a shared space, shown before somebody can take part in one.
///
/// Deliberately short and in the second person. A wall of legal text that
/// nobody reads satisfies a form and protects no one; this has to be
/// readable in the ten seconds somebody will actually give it, with the full
/// terms a tap away.
const String sharingTermsSummary =
    'A shared space is somewhere other people can read and write. By sharing '
    'you agree not to use it to harass anyone, to send unwanted invitations, '
    'or to share sexual content involving children, threats, or anything '
    'illegal.\n\n'
    'Your notes stay encrypted and we cannot read them. That also means we '
    'cannot find a problem on our own — if somebody does any of this to you, '
    'block them and report it, and we will act on it.';
