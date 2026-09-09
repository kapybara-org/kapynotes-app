import '../data/note_attachment.dart';

/// The part of the summary prompt the user owns.
///
/// Kept in step with `DEFAULT_SUMMARY_INSTRUCTION` in the contract, which is
/// what the server falls back to when a request carries no instruction. The
/// app shows this exact text in the editor rather than a description of it,
/// so that what somebody edits is what actually runs — an editor pre-filled
/// with a paraphrase would be a lie about what changing it does.
const String defaultSummaryInstruction =
    'Give a title of at most eight words and three to six key points.\n'
    'Each point is one complete sentence stating what was said, decided, or '
    'to be done, in the order it came up.';

/// The ceiling the contract puts on an instruction, mirrored so the editor
/// can stop somebody rather than let the server refuse them.
const int instructionMaxChars = 2000;

/// What each preset actually asks for.
///
/// Held in the app rather than on the note or the server: this is copy, it
/// will be improved, and improving it should not need a migration or a
/// deploy. A take records the *kind* it came from, so an old post keeps its
/// label even after the wording behind that label changes.
String instructionFor(VoiceTakeKind kind, {String? custom}) => switch (kind) {
  VoiceTakeKind.x =>
    'Write one post for X (Twitter) of at most 260 characters, in the '
        'first person, saying the most interesting thing in the transcript. '
        'Plain sentences. No hashtags, no emoji, and no thread.',
  VoiceTakeKind.linkedin =>
    'Write one LinkedIn post of 80 to 150 words, in the first person. Open '
        'with the point rather than a preamble, then two or three short '
        'paragraphs. No hashtags, no emoji, and none of "excited to share".',
  VoiceTakeKind.custom => (custom ?? '').trim(),
};
