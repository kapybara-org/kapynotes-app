import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show Directory, File;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        computeHitSlop,
        kDoubleTapTimeout,
        kLongPressTimeout,
        kPrimaryButton,
        kSecondaryButton,
        kTouchSlop;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../calc/engine.dart';
import '../../calc/highlight.dart';
import '../../calc/keyword_help.dart';
import '../../crdt/text_diff.dart';
import '../../crdt/text_merge.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/platform.dart';
import '../../core/platform_spell_check.dart';
import '../../core/appearance.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../core/type_ahead.dart';
import '../../data/daily_separator.dart';
import '../../data/attachment_limits.dart';
import '../../data/note.dart';
import '../../data/task_details.dart';
import '../../data/task_folds.dart';
import '../../data/task_index.dart' show wordsDigest;
import '../../data/task_lines.dart';
import '../../data/note_format.dart';
import '../../data/shortcut_prefs.dart';
import '../compact_icon_button.dart';
import '../focus_ring.dart';
import '../notebook_paper.dart';
import '../page_toolbar.dart' show NotePathLine, PagePlace;
import '../celebrate.dart';
import '../kapy_cursor_peek.dart';
import '../kapy_page_peek.dart';
import 'editor_formatting.dart';
import 'highlighting_controller.dart';
import 'link_popover.dart';
import 'keyword_tooltip.dart';
import 'markdown_backdrop.dart';
import 'markdown_editing.dart';
import 'markdown_syntax.dart';
import 'table_cell_editor.dart';
import 'table_controls.dart';
import 'table_geometry.dart';
import 'note_find.dart';
import 'note_footer.dart';
import 'phone_format_bar.dart';
import '../note_day_scope.dart';
import 'note_header.dart';
import '../tag_ui.dart';
import '../../data/note_attachment.dart';
import 'package:file_selector/file_selector.dart';

import '../../images/image_clipboard.dart';
import '../../paste/clipboard_snapshot.dart';
import '../../paste/image_download.dart';
import '../../paste/markdown_text.dart' show cleanPastedText;
import '../../paste/note_text.dart';
import '../../paste/paste_converter.dart';
import '../../paste/paste_insertion.dart';
import '../../paste/paste_tree.dart';
import '../../paste/paste_writers.dart' show linkDestination;
import '../../sync/aead.dart' show randomKey;
import '../../images/image_codec.dart';
import '../../images/image_ingest.dart';
import '../../images/image_picker.dart';
import '../../audio/voice_player.dart';
import '../../data/blob_store.dart';
import '../../images/note_image_provider.dart';
import '../../files/file_ingest.dart';
import '../../files/file_picker.dart';
import '../../video/video_ingest.dart';
import '../../video/video_picker.dart';
import 'image_drop_target.dart';
import 'field_scroll_controller.dart';
import 'file_chip.dart';
import 'file_insertion.dart';
import 'image_insertion.dart';
import 'note_image_layout.dart';
import '../../audio/voice_recording_controller.dart';
import 'voice_chip.dart';
import 'voice_recording_bar.dart';
import 'voice_insertion.dart';
import 'note_image_view.dart';
import 'note_video_view.dart';
import 'paste_feedback.dart';
import 'remote_carets.dart';
import 'note_field.dart';
import 'note_sliver.dart'
    show LineSpan, LineTrailing, NoteFound, lineTrailingGap;
import 'task_details_chrome.dart';
import 'task_details_editing.dart';
import 'results_gutter.dart';
import 'editor_context_menu.dart';
import 'selection_bubble.dart';
import 'slash_command_menu.dart';
import 'slash_commands.dart';
import '../../sync/presence.dart';
import 'live_text_card.dart';

/// [edit] is where in the old body the change happened, as the editor saw
/// it; null when it cannot say. See [NotesStore.updateDocument].
typedef NoteDocumentChanged =
    void Function(
      String body,
      List<NoteFormatRange> formats,
      List<NoteAttachmentRef> attachments,
      TextEdit? edit,
    );

/// A note as the store holds it, for [NoteEditor.storedDocument].
typedef StoredNoteDocument = ({
  String body,
  List<NoteFormatRange> formats,
  List<NoteAttachmentRef> attachments,
});

/// Swappable at the slow boundary so the editor can prove its waiting state
/// without asking a widget test to decode a photograph in a real isolate.
typedef ImageBatchIngestor =
    Future<ImageBatch> Function(List<XFile> files, BlobStore store);

typedef VideoBatchIngestor =
    Future<VideoBatch> Function(List<XFile> files, BlobStore store);

typedef FileBatchIngestor =
    Future<FileBatch> Function(List<XFile> files, BlobStore store);

typedef ImagePrepared =
    void Function(NoteImageRef staged, NoteImageRef prepared);

typedef AttachmentUploadProgressFor =
    ValueListenable<double?> Function(String hash);

/// The note surface: one syntax-coloured text field with each line's live
/// result at the end of that line, or on a phone in a column beside it.
///
/// The two are kept in step by measuring the note's layout with the same
/// width, style and strut the field uses, and by sharing one scroll
/// controller — so a wrapped line, a font-scale change or a scroll all move
/// text and results together.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.noteId,
    required this.initialBody,
    this.initialFormats = const [],
    this.initialAttachments = const [],
    this.images,
    this.imageFetch,
    this.player,
    this.voiceStateFor,
    this.onOpenVoiceNote,
    this.recording,
    this.onRecordVoice,
    this.lastSlashCommand,
    this.onSlashCommandChosen,
    this.voiceActionBusy = false,
    this.clipboard = const ImageClipboard(),
    this.imageAcquirer,
    this.imageIngestor,
    this.imageFinalizer,
    this.onImagePrepared,
    this.onImagesRejected,
    this.videoAcquirer,
    this.cameraAcquirer,
    this.videoIngestor,
    this.videoAttachmentMaxBytes,
    this.fileAcquirer,
    this.fileIngestor,
    this.uploadProgressFor,
    this.typing = const [],
    this.remoteCarets,
    this.onActivity,
    this.onFocus,
    this.readOnly = false,
    this.readOnlyLabel = 'View only',
    this.readOnlyIcon = KapyIcons.visibilityOutlined,
    this.onReadOnlyPressed,
    this.idlePeekHeld,
    required this.engine,
    required this.highlighter,
    this.keepResultRoom = false,
    this.cramped = false,
    this.phone = false,
    required this.resultsVisible,
    required this.onDocumentChanged,
    this.storedDocument,
    required this.onSettingsPressed,
    required this.writingFont,
    this.editorTextScale = 1,
    required this.shortcuts,
    this.spellCheckEnabled = true,
    this.markdownEnabled = false,
    this.onMarkdownEnabledChanged,
    this.autofocus = false,
    this.startAtEnd = false,
    this.namedByPerson = true,
    this.onDefaultTitleEntered,
    this.initialCaret,
    this.onCaretChanged,
    this.ensureKeyboardVisible = false,
    this.lastUpdatedAt,
    this.createdAt,
    this.dailySeparatorsEnabled = false,
    this.paperStyle = PaperStyle.notepad,
    this.now,
    this.displayTime,
  });

  final String noteId;
  final String initialBody;
  final List<NoteFormatRange> initialFormats;
  final List<NoteAttachmentRef> initialAttachments;

  /// Where image bytes are read from. Null in the handful of tests that build
  /// an editor with no images in it.
  final BlobStore? images;

  /// Fetches bytes for an image that arrived by sync but has not downloaded.
  final NoteImageFetcher? imageFetch;

  /// Plays recordings. App-wide and shared, so starting one chip stops
  /// whichever was playing. Null in tests with no audio in them.
  final VoicePlayer? player;

  /// What the transcription queue currently thinks of a recording. A function
  /// rather than a value so the editor does not have to listen to the queue:
  /// the chip is rebuilt when the note is, which is often enough for a label.
  final VoiceChipState Function(NoteVoiceRef ref)? voiceStateFor;

  /// Opens the Summary/Transcript dialog.
  final void Function(NoteVoiceRef ref)? onOpenVoiceNote;

  /// The recording in progress, if this note is the one being recorded into.
  /// The footer shows the bar in place of the formatting row while it is.
  final VoiceRecordingController? recording;

  /// Starts a recording, or stops the one running.
  final VoidCallback? onRecordVoice;

  /// The command chosen last, highlighted when Commands opens.
  final SlashCommandType? lastSlashCommand;

  /// Each time a command is chosen from Commands.
  final ValueChanged<SlashCommandType>? onSlashCommandChosen;
  final bool voiceActionBusy;

  /// Where a pasted picture comes from. Swapped in tests, which have no
  /// system clipboard to put anything on.
  final ImageClipboard clipboard;

  /// Opens the camera or picker. Supplied by the page in production so the
  /// pending note can be remembered across Android activity recreation, and
  /// replaced by tests that have no camera behind them.
  final ImageFileAcquirer? imageAcquirer;

  /// Defaults to the production compression pipeline. Tests replace only this
  /// boundary and still exercise the real footer and toast lifecycle.
  final ImageBatchIngestor? imageIngestor;

  /// Finishes the storage copy behind an already-visible staged image.
  /// Injectable so a widget test can hold the compression boundary open.
  final Future<ImageIngestResult> Function(StagedImage staged, BlobStore store)?
  imageFinalizer;

  /// Writes a prepared ref against the note's latest attachment list. The
  /// production page routes this through NotesStore's atomic transform so an
  /// upload finishing beside a user edit cannot replace that edit.
  final ImagePrepared? onImagePrepared;

  /// Called when at least one file in a batch could not be added.
  final ValueChanged<ImageBatch>? onImagesRejected;

  final VideoFileAcquirer? videoAcquirer;

  /// The camera window on a Mac or PC, or null where there is none. What it
  /// keeps goes in where the caret is.
  final Future<List<XFile>> Function(BuildContext context)? cameraAcquirer;
  final VideoBatchIngestor? videoIngestor;

  /// Read when a selection is made rather than when the editor is built, so
  /// an in-app upgrade or a refreshed shared-space owner limit applies without
  /// remounting the note.
  final int Function()? videoAttachmentMaxBytes;

  /// Opens the system's file chooser. Replaced by tests.
  final AttachmentFileAcquirer? fileAcquirer;

  /// Defaults to [ingestFileAttachments], sized by [videoAttachmentMaxBytes] —
  /// the per-file limit is one number for every kind.
  final FileBatchIngestor? fileIngestor;

  /// Null while signed out. Media is then fully local and should clear as
  /// soon as preparation finishes rather than wait for a network that is not
  /// part of that session.
  final AttachmentUploadProgressFor? uploadProgressFor;

  /// Other members typing in this shared note right now.
  final List<Collaborator> typing;

  /// Where other people's carets in this note come from. Null for a note
  /// nobody else can open, which then draws no layer for them at all.
  final RemoteCaretSource? remoteCarets;

  /// This device's caret, and whether an edit moved it, for the people this
  /// note is shared with. Fires on every local change to the text or the
  /// selection, on focus and on scroll — never for text that came from them.
  final void Function(
    TextSelection selection,
    String text, {
    required bool edited,
  })?
  onActivity;

  /// Tells the workspace which split pane owns the keyboard. Kept separate
  /// from [onActivity], whose first post-frame report also runs for an editor
  /// that is visible but not active.
  final VoidCallback? onFocus;

  /// Keeps the note selectable and its links usable, while removing every
  /// local mutation path for a View only collaborator.
  final bool readOnly;

  /// What the footer calls [readOnly]: View only for the sharing role, or the
  /// note limit's own words, which [onReadOnlyPressed] then explains.
  final String readOnlyLabel;
  final KapyIconData readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;

  /// Whether something besides input, such as Kapy AI answering, should keep
  /// Kapy from peeking in at the page's corner right now.
  final bool Function()? idlePeekHeld;

  final CalcEngine engine;
  final Highlighter highlighter;

  /// Whether a line with a result shows it at the right of its row, as a
  /// phone does: beside writing that fits on one row short of it, and on a
  /// row of its own under writing that doesn't. Otherwise the result follows
  /// the writing at the end of its line, on a leader.
  final bool keepResultRoom;

  /// Whether the page around this editor is too short for its top and bottom
  /// padding, as on a phone on its side with the keyboard up. The lines take
  /// that room instead.
  final bool cramped;

  /// On a phone's note page (M09): its folders in the line above the title,
  /// and under it the note's day and time with its tags, which are added
  /// from More rather than from a + Tag of their own.
  final bool phone;
  final bool resultsVisible;
  final NoteDocumentChanged onDocumentChanged;

  /// The note as the store holds it this instant, which can be a frame ahead
  /// of [initialBody]: another device's words land in the store at once and
  /// reach this widget on the next build. Read on every edit, so an edit is
  /// never written over words the editor has not shown yet. Null reads this
  /// widget's own fields.
  final StoredNoteDocument? Function()? storedDocument;

  /// What the open-settings shortcut does. The footer has no gear of its own:
  /// settings live in the notes list, and this is the key that gets there
  /// from inside the note.
  final VoidCallback onSettingsPressed;
  final WritingFont writingFont;

  /// An editor-only multiplier. App-wide and device text scaling still arrive
  /// through MediaQuery, independently of this preference.
  final double editorTextScale;
  final ShortcutPrefs shortcuts;
  final bool spellCheckEnabled;

  /// Whether the note is written in markdown: its syntax drawn as it is
  /// typed, and the formatting controls writing markdown rather than styles
  /// kept beside the text. Off, the editor is exactly what it always was.
  final bool markdownEnabled;

  /// Lets a Markdown-only slash command ask before turning Markdown on.
  /// Optional for small editor harnesses; production supplies the persisted
  /// preference setter.
  final ValueChanged<bool>? onMarkdownEnabledChanged;
  final bool autofocus;
  final bool startAtEnd;

  /// Whether the person names this note rather than the model on the
  /// device. A new note they name opens with its title selected, so the
  /// first thing typed names it; one the model names opens on the line
  /// below, for the note itself.
  final bool namedByPerson;

  /// The person put the caret or a selection in the title while it is still
  /// [Note.untitled], to name the note themselves.
  final VoidCallback? onDefaultTitleEntered;

  /// Where the caret was left in this note earlier today, if it was.
  ///
  /// Takes precedence over [startAtEnd]: somebody coming back to a note
  /// within the day is in the middle of something, and the end of the note is
  /// not where they were. Null starts an append session as before, which is
  /// what a new day — or a note not opened yet today — should do.
  final int? initialCaret;

  /// Reports the caret so it can be offered back as [initialCaret] later.
  ///
  /// Fires on every move, like the body does on every keystroke, and is meant
  /// to be written through a coalescing store rather than straight to disk.
  final ValueChanged<int>? onCaretChanged;
  final bool ensureKeyboardVisible;
  final DateTime? lastUpdatedAt;

  /// When the note was written, which a phone's line under the title gives
  /// rather than the last edit, so typing leaves the line as it was.
  final DateTime? createdAt;
  final bool dailySeparatorsEnabled;

  /// The sheet behind the writing. Only [PaperStyle.ruled] needs anything of
  /// the editor, and only because its lines have to land under the rows.
  final PaperStyle paperStyle;
  final DateTime Function()? now;
  final DateTime Function(DateTime)? displayTime;

  /// Kapy peeks once after both typing and caret activity have been quiet for
  /// this long. A new activity starts a fresh one-shot wait.
  static const kapyPeekIdleDelay = Duration(seconds: 5);

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  static const _pasteAsPlainTextLabel = 'Paste Text';

  /// The first retry waits well past the 100 ms or so an IME that took the
  /// request needs to start moving the window; see
  /// [_windowMovedSinceKeyboardRequest].
  static const List<Duration> _keyboardRetryDelays = [
    Duration(milliseconds: 400),
    Duration(milliseconds: 250),
    Duration(milliseconds: 400),
    Duration(milliseconds: 600),
    Duration(milliseconds: 900),
    Duration(milliseconds: 1200),
    Duration(milliseconds: 1500),
  ];

  /// Whether the window has changed since the editor last asked for the
  /// keyboard. An IME that took the request is already moving it, and asking
  /// again then cancels the animation it started; Android can then leave the
  /// inset at zero under a keyboard that is up, so the bar goes and the editor
  /// takes the keyboard for dismissed (KAP-324).
  bool _windowMovedSinceKeyboardRequest = false;

  /// Whether the soft keyboard was up the last time the window was measured,
  /// which is what turns a metrics change into "the keyboard just went".
  bool _keyboardWasUp = false;

  /// How long the keyboard must stay down before the editor takes it as
  /// dismissed. Android can report a keyboard that is still coming up as gone
  /// for a frame or two while it restarts the animation; a dismissal stays
  /// gone.
  static const _keyboardGoneAfter = Duration(milliseconds: 500);
  Timer? _keyboardGoneTimer;

  /// How long the inset must hold still before the keyboard counts as up.
  /// Until then it is still coming up, and a fall to zero is Android starting
  /// its slide again from the bottom, which on a slow phone can take longer
  /// than [_keyboardGoneAfter] to show (KAP-324), not the reader putting it
  /// away.
  static const _keyboardSettleAfter = Duration(milliseconds: 500);
  Timer? _keyboardSettleTimer;
  bool _keyboardSettled = false;

  final PlatformSpellCheckService _spellCheckService =
      PlatformSpellCheckService();
  Locale? _spellCheckLocale;
  // Bumped when a word's corrections arrive, so a menu that opened without
  // them can fill itself in rather than stay wrong.
  final ValueNotifier<int> _correctionsArrived = ValueNotifier<int>(0);
  late HighlightingController _controller;
  final _fieldKey = GlobalKey<NoteFieldState>();
  final ScrollController _scrollController = FieldScrollController();

  /// The empty line under the pointer, which shows its "+".
  final _hoverLine = ValueNotifier<int?>(null);

  /// Ticks once the field has laid out a frame the editor built, for what is
  /// placed over its lines.
  final _fieldLaidOut = ValueNotifier<int>(0);
  final _lineMarks = ValueNotifier<List<_LineMark>>(const []);
  bool _lineMarksScheduled = false;
  late final _lineMarkSources = Listenable.merge([
    _controller,
    _focusNode,
    _hoverLine,
    _slashCommandMenu,
  ]);

  late final FocusNode _focusNode = NoRingFocusNode(
    debugLabel: 'note-editor:${widget.noteId}',
  );

  /// The grid each table in this note is drawn as.
  ///
  /// Worked out once per build inside [build]'s `LayoutBuilder`, the one place
  /// the writing column's width is known, and read by the three things that have
  /// to agree about it: the room each row reserves, the grid the backdrop paints,
  /// and — later — where a tap lands.
  final TableGeometryCache _tableGeometry = TableGeometryCache();
  Map<MarkdownTable, TableGeometry> _tableGrids = const {};

  /// The field that opens over a cell, and which cell it is over.
  ///
  /// While it is open the note is still being edited, even though the main field
  /// has given up focus — see [_editingNote], which is what keeps the rest of
  /// the note's markdown from flipping to source the moment a cell is tapped.
  final TableCellEditor _cellEditor = TableCellEditor();
  final TableControlsController _tableControls = TableControlsController();

  ({int tableStart, int row, int column})? _editingCell;

  /// Whether this note is being written in: its own field has focus, or one of
  /// its cells does.
  bool get _editingNote => _focusNode.hasFocus || _editingCell != null;

  /// The find in this note, kept from the first time its bar opened so that
  /// it opens again on the same words, and whether the bar is open.
  NoteFind? _find;
  bool _findOpen = false;

  /// Whether this note is being written in; see [_editingNote].
  bool get writing => _editingNote;
  late final _DailySeparatorFormatter _dailySeparatorFormatter;

  /// Folds and the first-time hint. Device-local; never written into the note.
  TaskFolds? _folds;
  Timer? _keyboardRetryTimer;
  Timer? _selectionToolbarTimer;

  /// How long a selection, or the page under it, keeps still before the
  /// bubble comes, so a drag or a scroll never flickers it.
  static const _selectionSettle = Duration(milliseconds: 150);

  /// A right-click selects the word under it on macOS, and that selection
  /// is for the menu it opens, not for the bubble.
  bool _rightClicked = false;
  Timer? _pasteOfferTimer;

  /// How many of the editor's edit menus are on screen. A count rather than a
  /// flag: a menu shown again can mount before the one it replaces goes.
  int _editMenus = 0;
  Timer? _keywordHoverTimer;
  Timer? _kapyPeekIdleTimer;
  VoidCallback? _kapyPeekDismiss;

  /// The pointer over the note, so a collaborator's folded caret can raise
  /// its name while it is pointed at. A notifier rather than state: it moves
  /// with every mouse event, and only the caret layer needs to hear it.
  final ValueNotifier<Offset?> _remoteHover = ValueNotifier<Offset?>(null);

  Map<int, LineResult> _results = const {};
  String? _totalText;
  String Function()? _describeTotal;
  bool _totalLeavesOut = false;
  String? _hoveredKeywordId;
  late TextEditingValue _lastValue;
  late List<NoteFormatRange> _formats;
  late List<NoteAttachmentRef> _attachments;
  final Map<NoteFormat, bool> _typingOverrides = {};
  NoteParagraphStyle? _paragraphOverride;
  final Map<int, _PointerDownDetails> _pointerDownDetails = {};

  /// A press still held where it landed, until just after it lifts. What the
  /// field selects meanwhile was picked by the press itself — a double click,
  /// a long press, a right click — not dragged out; see
  /// [_collapseLineTerminatorSelection].
  int? _stillPress;

  Set<NoteFormat>? _nextInsertedFormats;
  bool _imageActionBusy = false;
  bool _videoActionBusy = false;
  bool _fileActionBusy = false;
  bool _copyingRichSelection = false;

  final SlashCommandMenuController _slashCommandMenu =
      SlashCommandMenuController();
  final _selectionBubble = SelectionBubbleController();
  TextRange? _slashCommandRange;
  bool _slashCommandWasTyped = false;
  TextEditingValue? _manualSlashMenuValue;
  int? _dismissedSlashStart;
  bool _slashMenuSyncScheduled = false;

  /// The attachment list a programmatic edit has already worked out.
  ///
  /// Mirrors [_nextInsertedFormats]: an insert knows exactly where its images
  /// land, so it says so rather than leaving the change handler to infer it
  /// from a diff that cannot tell one placeholder from another.
  List<NoteAttachmentRef>? _nextAttachments;

  /// The style ranges a programmatic edit has already carried across itself.
  ///
  /// The same idea for the ranges kept beside the text: a markdown control
  /// writes markers in several places at once, and the one-stretch diff the
  /// change handler rebases by would read everything between them as retyped.
  List<NoteFormatRange>? _nextFormats;

  /// Bold switched on for the next word, and the like. See [MarkdownTyping].
  final MarkdownTyping _markdownTyping = MarkdownTyping();

  /// The shortcut just typed, which Backspace or Undo gives back as typed.
  /// See [MarkdownShortcut].
  final MarkdownShortcut _markdownShortcut = MarkdownShortcut();

  /// Whether inline markdown stays hidden even beside the caret: while the
  /// writer is typing, so markers disappear as they are completed, and until
  /// they next move the caret themselves.
  bool _markdownQuiet = true;

  /// Set around a caret move the editor makes itself, so it is not taken for
  /// the writer moving it.
  bool _ownSelectionChange = false;

  /// Attachments a recent edit took out, kept so Undo can put them back.
  ///
  /// Removing a picture is a text edit — the placeholder goes, and the ref
  /// falls away with its anchor. Undo restores the character but has nothing
  /// to restore the ref from, so what comes back is an orphan U+FFFC that
  /// renders as nothing and is stripped on the next load. The picture is gone,
  /// and the user watched their Undo appear to work.
  ///
  /// The match is deliberately an equality on the whole prior text rather than
  /// a heuristic: Undo restores exactly the text that was there, so anything
  /// less exact would risk reattaching a picture into a note the user has
  /// since retyped.
  final List<({String textBefore, NoteAttachmentRef ref})> _removedRefs = [];
  static const int _maxRemovedRefs = 20;

  /// The last converted paste, until the note holds anything else: its wash
  /// fades over what it wrote, and while [_pasteChipShown] its chip offers
  /// the clipboard's plain text instead.
  ConvertedPaste? _convertedPaste;

  /// Whether the paste's chip is up, which it is until the next keystroke or
  /// click.
  bool _pasteChipShown = false;

  /// Where the chip hangs from: the caret at the end of the paste, in the
  /// field's own coordinates, measured after layout and on every scroll.
  final _pasteCaret = ValueNotifier<Rect?>(null);

  bool _isEmpty = true;

  @override
  void initState() {
    super.initState();
    // A caret left here earlier today wins over the append session: the
    // blank line at the bottom exists to start something, and somebody
    // returning within the day is finishing something.
    final resumeAt = widget.readOnly ? null : widget.initialCaret;
    final appendSession =
        widget.startAtEnd && !widget.readOnly && resumeAt == null;
    final initialText = appendSession
        ? DailySeparator.prepareForAppend(widget.initialBody)
        : widget.initialBody;
    final pendingSeparatorLine = appendSession
        ? DailySeparator.trailingEmptySectionLine(widget.initialBody)
        : null;
    _storeBase = widget.initialBody;
    _storeShadow = widget.initialBody;
    _formats = normalizeNoteFormats(widget.initialFormats, initialText.length);
    _attachments = normalizeNoteAttachments(
      widget.initialAttachments,
      initialText,
    );
    _controller = HighlightingController(
      highlighter: widget.highlighter,
      palette: KapyTheme.darkPalette,
      writingFont: widget.writingFont,
      formats: _formats,
      markdown: widget.markdownEnabled,
      text: initialText,
    );
    _dailySeparatorFormatter = _DailySeparatorFormatter(
      enabled: widget.dailySeparatorsEnabled,
      lastUpdatedAt: widget.lastUpdatedAt ?? (widget.now ?? DateTime.now)(),
      now: widget.now ?? DateTime.now,
      displayTime: widget.displayTime ?? _localTime,
      pendingSeparatorLine: pendingSeparatorLine,
    );
    if (appendSession) {
      _controller.selection = TextSelection.collapsed(
        offset: initialText.length,
      );
    } else if (resumeAt != null) {
      // Clamped, because the note may have been shortened elsewhere — by
      // another device, or by an undo — since the offset was recorded.
      _controller.selection = TextSelection.collapsed(
        offset: resumeAt.clamp(0, initialText.length),
      );
    }
    _lastValue = _controller.value;
    _controller.addListener(_onControllerChanged);
    _focusNode.addListener(_handleFocusChanged);
    // Anchored to a rect that scrolling invalidates, so it goes rather than
    // drifts away from the link it points at.
    _scrollController.addListener(_handleEditorScroll);
    unawaited(_loadFolds());
    widget.shortcuts.addListener(_onShortcutsChanged);
    widget.player?.addListener(_onPlaybackChanged);
    _isEmpty = initialText.isEmpty;
    _evaluate();
    WidgetsBinding.instance.addObserver(this);
    // Opening a shared note is being in it, before anything is typed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportActivity(edited: false);
    });
    if (!widget.readOnly && widget.autofocus && widget.startAtEnd) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => resumeAt == null ? focusAtEnd() : focusHere(),
      );
    }
    _lineMarkSources.addListener(_scheduleLineMarks);
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.readOnly && widget.readOnly) {
      _keyboardRetryTimer?.cancel();
      _focusNode.unfocus();
      _dismissKapyPeek();
    }
    if (!identical(oldWidget.shortcuts, widget.shortcuts)) {
      oldWidget.shortcuts.removeListener(_onShortcutsChanged);
      widget.shortcuts.addListener(_onShortcutsChanged);
    }
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player?.removeListener(_onPlaybackChanged);
      widget.player?.addListener(_onPlaybackChanged);
    }
    if (oldWidget.writingFont != widget.writingFont) {
      _controller.writingFont = widget.writingFont;
    }
    if (oldWidget.markdownEnabled != widget.markdownEnabled) {
      _controller.markdown = widget.markdownEnabled;
      // A bold switched on for the next word, or a heading carried to the
      // next line, belongs to the styles the editor has just stopped writing.
      _typingOverrides.clear();
      _paragraphOverride = null;
      // Lists and code read differently to the calculator in markdown.
      _evaluate();
      unawaited(_requestSpellCheck());
      _scheduleSlashCommandMenuSync();
    }
    if (oldWidget.spellCheckEnabled != widget.spellCheckEnabled ||
        oldWidget.readOnly != widget.readOnly) {
      if (widget.readOnly || !widget.spellCheckEnabled) {
        _controller.spellingSuggestions = const [];
      } else {
        unawaited(_requestSpellCheck());
      }
    }
    // A new engine arrives when exchange rates land; re-evaluate so currency
    // lines light up without the user touching anything.
    if (!identical(oldWidget.engine, widget.engine)) {
      _controller.highlighter = widget.highlighter;
      _evaluate();
    }
    // The note changed under the editor — another device, another person —
    // and the text on screen is now behind the store. Take the new text and
    // keep the caret where the user left it, relative to the words around
    // it; only a store change that the editor did not itself send counts.
    if (widget.initialBody != oldWidget.initialBody) {
      _storeShadow = widget.initialBody;
      if (widget.initialBody != _storeBase) _takeStoreText();
    }
    if (widget.initialBody == _controller.text &&
        !listEquals(widget.initialFormats, _formats)) {
      _formats = normalizeNoteFormats(
        widget.initialFormats,
        _controller.text.length,
      );
      _controller.formats = _formats;
    }
    // Taken whenever the store's text is the one this editor's is built on,
    // even with a blank line opened for typing below it, so a picture that
    // finishes loading in a note just opened shows up in it.
    if (widget.initialBody == _storeBase &&
        !listEquals(widget.initialAttachments, _attachments)) {
      final merge = mergeTexts(
        base: _storeBase,
        local: _controller.text,
        remote: _storeBase,
      );
      _attachments = normalizeNoteAttachments([
        for (final ref in widget.initialAttachments)
          ref.copyWith(offset: merge.mapRemoteStart(ref.offset)),
      ], _controller.text);
    }
    _dailySeparatorFormatter
      ..enabled = widget.dailySeparatorsEnabled
      ..displayTime = widget.displayTime ?? _localTime
      ..syncLastUpdatedAt(widget.lastUpdatedAt);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.palette = context.palette;
    final locale =
        Localizations.maybeLocaleOf(context) ??
        WidgetsBinding.instance.platformDispatcher.locale;
    if (_spellCheckLocale != locale) {
      _spellCheckLocale = locale;
      unawaited(_requestSpellCheck());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lineMarkSources.removeListener(_scheduleLineMarks);
    _lineMarks.dispose();
    _hoverLine.dispose();
    _fieldLaidOut.dispose();
    _pasteCaret.dispose();
    LinkPopover.hide();
    KeywordTooltip.hide();
    _slashCommandMenu.dispose();
    _selectionBubble.dispose();
    _controller.removeListener(_onControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _scrollController.removeListener(_handleEditorScroll);
    widget.shortcuts.removeListener(_onShortcutsChanged);
    widget.player?.removeListener(_onPlaybackChanged);
    _spellCheckService.dispose();
    _correctionsArrived.dispose();
    _keyboardRetryTimer?.cancel();
    _keyboardGoneTimer?.cancel();
    _keyboardSettleTimer?.cancel();
    _selectionToolbarTimer?.cancel();
    _pasteOfferTimer?.cancel();
    _keywordHoverTimer?.cancel();
    _kapyPeekIdleTimer?.cancel();
    _dismissKapyPeek();
    _remoteHover.dispose();
    _cellEditor.dispose();
    _tableControls.dispose();
    _tableGeometry.dispose();
    _find?.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Tells the people this note is shared with where the caret is now.
  void _reportActivity({required bool edited}) {
    final report = widget.onActivity;
    if (report == null) return;
    final value = _controller.value;
    report(value.selection, value.text, edited: edited);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Presence ends when the app goes to the background; coming back to the
    // same note is being in it again.
    if (state == AppLifecycleState.resumed) _reportActivity(edited: false);
  }

  /// The note's field, once built.
  NoteFieldState? get _field => _fieldKey.currentState;

  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  void _handleEditorScroll() {
    LinkPopover.hide();
    _slashCommandMenu.hide();
    // The bubble lifts off while the page moves, and settles back over the
    // selection once it stops with the selection in view.
    if (_selectionBubble.isVisible || _selectionBubble.isLifted) {
      _selectionBubble.lift();
      _selectionToolbarTimer?.cancel();
      _selectionToolbarTimer = Timer(_selectionSettle, () {
        if (mounted) _showSelectionBubble();
      });
    }
    if (_pasteChipShown) _placePasteChip();
    _clearKeywordTooltip();
    _recordKapyPeekActivity();
    _syncTableCellEditorPosition();
    // Reading counts as being here, even with the caret parked.
    _reportActivity(edited: false);
  }

  bool _handleEditorScrollNotification(ScrollNotification notification) {
    if (!AppPlatform.isMobile ||
        notification.metrics.axis != Axis.vertical ||
        !_editingNote) {
      return false;
    }
    // A drag-backed start is a real reader gesture. Programmatic scrolling
    // (including keeping the caret visible) reports no drag details and keeps
    // the keyboard up. Dismissing at the start also works when the note is
    // already at an edge and the gesture produces overscroll rather than an
    // update.
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _keyboardRetryTimer?.cancel();
      FocusManager.instance.primaryFocus?.unfocus();
    }
    return false;
  }

  void focus() {
    if (widget.readOnly) return;
    _focusNode.requestFocus();
    _recordKapyPeekActivity();
    _scheduleKeyboardRetry();
  }

  /// Opens a fresh append position without writing empty lines to the note.
  /// The prepared spacing becomes durable only if the user actually types.
  void beginAppendSession() {
    if (!mounted || widget.readOnly) return;
    final currentText = _controller.text;
    final pendingSeparatorLine = DailySeparator.trailingEmptySectionLine(
      currentText,
    );
    final preparedText = DailySeparator.prepareForAppend(currentText);
    _dailySeparatorFormatter.beginAppendSession(pendingSeparatorLine);

    if (preparedText != currentText) {
      // This is presentation state, just like the initial blank line created
      // in initState. Keep it out of persistence until a real edit arrives.
      _controller.removeListener(_onControllerChanged);
      _formats = normalizeNoteFormats(_formats, preparedText.length);
      _controller.value = TextEditingValue(
        text: preparedText,
        selection: TextSelection.collapsed(offset: preparedText.length),
      );
      _controller.formats = _formats;
      _lastValue = _controller.value;
      _typingOverrides.clear();
      _paragraphOverride = null;
      _isEmpty = preparedText.isEmpty;
      _controller.addListener(_onControllerChanged);
      setState(_evaluate);
    }

    focusAtEnd();
  }

  /// Hands the caret up so it can be offered back tomorrow — or rather, later
  /// today.
  ///
  /// Only a collapsed selection: a range is a thing being done to the text,
  /// not a place in it, and restoring somebody's old highlight would be a
  /// stranger thing to come back to than a cursor.
  void _reportCaret(TextSelection selection) {
    final report = widget.onCaretChanged;
    if (report == null || widget.readOnly || !selection.isValid) return;
    if (!selection.isCollapsed) return;
    // Parked on a table row while one of its cells is open: not a place in the
    // note anybody could come back to.
    if (_editingCell != null) return;
    report(selection.baseOffset);
  }

  /// Focuses without moving the caret, and without scrolling to the bottom.
  ///
  /// The counterpart to [focusAtEnd] for a note reopened the same day: the
  /// whole point is that nothing moves. The field brings its own caret on
  /// screen when it takes focus, so a caret restored halfway up a long
  /// note is scrolled to rather than left off the top.
  void focusHere() {
    if (!mounted || widget.readOnly) return;
    _focusNode.requestFocus();
    _recordKapyPeekActivity();
    _scheduleKeyboardRetry();
  }

  /// Lets go of the keyboard, and of the one a closing menu is about to hand
  /// back to this editor.
  void releaseKeyboard() => _focusNode.unfocus();

  /// Places the caret after the note's final character and brings it on
  /// screen. A new note the person names opens with its title selected.
  void focusAtEnd() {
    if (!mounted || widget.readOnly) return;
    if (widget.namedByPerson && _controller.text == Note.blankBody) {
      _controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: Note.untitled.length,
      );
      _focusNode.requestFocus();
      _recordKapyPeekActivity();
      _scheduleKeyboardRetry();
      return;
    }
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _focusNode.requestFocus();
    _recordKapyPeekActivity();
    _scheduleKeyboardRetry();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _scheduleKeyboardRetry() {
    _keyboardRetryTimer?.cancel();
    if (widget.readOnly || !widget.ensureKeyboardVisible) return;
    // Try as soon as the editable connection exists, then again while
    // Android is still promoting FlutterView to the served input view.
    _requestKeyboard();
    _scheduleKeyboardRetryAt(0);
  }

  void _requestKeyboard() {
    _windowMovedSinceKeyboardRequest = false;
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  /// How far the soft keyboard reaches up the window, or zero when it is not
  /// there.
  ///
  /// Read from the view rather than from [MediaQuery]. A [Scaffold] hands its
  /// body a MediaQuery with the bottom inset taken out — that is how
  /// `resizeToAvoidBottomInset` avoids counting the keyboard twice — and the
  /// editor is a Scaffold body on a phone. Asking there always answers zero,
  /// so the guard below could never tell that the keyboard it was asking for
  /// had already arrived, and every note opened kept asking for five seconds.
  double get _keyboardInset => mounted ? View.of(context).viewInsets.bottom : 0;

  void _scheduleKeyboardRetryAt(int index) {
    if (index >= _keyboardRetryDelays.length) return;
    _keyboardRetryTimer = Timer(_keyboardRetryDelays[index], () {
      if (!mounted || !_focusNode.hasFocus || _keyboardInset > 0) {
        return;
      }
      // A rejected Android request has no Dart acknowledgement, but one the
      // IME took moves the window. Until a whole wait passes with the window
      // still, the last request is taken to be in hand.
      if (_windowMovedSinceKeyboardRequest) {
        _windowMovedSinceKeyboardRequest = false;
      } else {
        _requestKeyboard();
      }
      _scheduleKeyboardRetryAt(index + 1);
    });
  }

  /// The store's text this editor's own is built on: what it last wrote, or
  /// last took from the store. The text on screen is this plus whatever only
  /// the editor holds — a blank line opened for typing, a keystroke made while
  /// somebody else's words were on their way. Anything else the store holds is
  /// such words, not shown yet, and an edit is merged onto them rather than
  /// written over them.
  late String _storeBase;

  /// What the store holds as far as this widget alone can tell, for a page
  /// that cannot say: whatever the editor last wrote, or the page last built
  /// it with, whichever came later.
  late String _storeShadow;

  /// The note as the store holds it now, from the page if it can say.
  StoredNoteDocument get _stored =>
      widget.storedDocument?.call() ??
      (
        body: _storeShadow,
        formats: widget.initialFormats,
        attachments: widget.initialAttachments,
      );

  static bool _composingOpen(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  /// Writes the editor's document to the store.
  ///
  /// As it stands, normally. When the store has moved on from [_storeBase] —
  /// another device's words that arrived while a composition held them back,
  /// or in the frame before the page rebuilt — writing the editor's text
  /// would delete them, and the sync layer would send those deletions to
  /// every device. The edit is merged onto the store's text instead, and the
  /// editor takes the result as soon as the keyboard allows.
  void _commit(
    String text,
    List<NoteFormatRange> formats,
    List<NoteAttachmentRef> attachments, {
    TextEdit? edit,
  }) {
    final stored = _stored.body;
    if (stored == _storeBase) {
      _storeBase = text;
      _storeShadow = text;
      widget.onDocumentChanged(text, formats, attachments, edit);
      return;
    }
    final merge = mergeTexts(base: _storeBase, local: text, remote: stored);
    // The store is now this text with the other words in it, which is what
    // the next edit is merged onto until the editor takes them.
    _storeBase = text;
    _storeShadow = merge.text;
    widget.onDocumentChanged(
      merge.text,
      [
        for (final range in formats)
          NoteFormatRange(
            start: merge.mapLocalStart(range.start),
            end: merge.mapLocal(range.end),
            format: range.format,
          ),
      ],
      [
        for (final ref in attachments)
          ref.copyWith(offset: merge.mapLocalStart(ref.offset)),
      ],
      null,
    );
    _remotePending = true;
    _scheduleTake();
  }

  bool _takeScheduled = false;

  /// Takes the store's text once the change in hand has run its course: the
  /// keystroke that brought this on is written first, and the keyboard hears
  /// of the result after it.
  void _scheduleTake() {
    if (_takeScheduled) return;
    _takeScheduled = true;
    scheduleMicrotask(() {
      _takeScheduled = false;
      if (mounted && _remotePending) _takeStoreText();
    });
  }

  /// Puts the store's text into the controller without treating it as an
  /// edit, keeping whatever only the editor holds and the caret with the
  /// words it was between.
  ///
  /// Held while the IME is composing, unless everything up to the end of the
  /// composing word and the caret stays exactly where it is: moving text
  /// under an open composition confuses every soft keyboard, while words
  /// landing after it are nothing a keyboard can see. A composition ends at
  /// the next word boundary at the latest, and edits made meanwhile are
  /// merged, not written over; see [_commit].
  void _takeStoreText() {
    final stored = _stored;
    if (stored.body == _storeBase) {
      _remotePending = false;
      return;
    }
    final value = _controller.value;
    final merge = mergeTexts(
      base: _storeBase,
      local: value.text,
      remote: stored.body,
    );
    final newText = merge.text;
    final selection = value.selection.isValid
        ? value.selection.copyWith(
            baseOffset: merge.mapLocal(value.selection.baseOffset),
            extentOffset: merge.mapLocal(value.selection.extentOffset),
          )
        : TextSelection.collapsed(offset: newText.length);
    final composing = _composingOpen(value)
        ? TextRange(
            start: merge.mapLocal(value.composing.start),
            end: merge.mapLocal(value.composing.end),
          )
        : TextRange.empty;
    if (_composingOpen(value)) {
      final reach = math.max(value.selection.end, value.composing.end);
      final untouched =
          selection == value.selection &&
          composing == value.composing &&
          newText.length >= reach &&
          newText.startsWith(value.text.substring(0, reach));
      if (!untouched) {
        _remotePending = true;
        return;
      }
    }
    _remotePending = false;
    final editingCell = _editingCell;
    final mappedTableProbe = editingCell == null
        ? null
        : merge.mapLocal(
            math.min(editingCell.tableStart + 1, value.text.length),
          );
    _formats = normalizeNoteFormats([
      for (final range in stored.formats)
        NoteFormatRange(
          start: merge.mapRemoteStart(range.start),
          end: merge.mapRemoteEnd(range.end),
          format: range.format,
        ),
    ], newText.length);
    _attachments = normalizeNoteAttachments([
      for (final ref in stored.attachments)
        ref.copyWith(offset: merge.mapRemoteStart(ref.offset)),
    ], newText);
    _storeBase = stored.body;
    // The keyboard may already be applying a keystroke to the text as it was.
    _lastTake = newText == value.text || !_focusNode.hasFocus
        ? null
        : (from: value.text, to: newText, at: DateTime.now());
    _applyingRemote = true;
    try {
      _controller.formats = _formats;
      _controller.value = TextEditingValue(
        text: newText,
        selection: selection,
        composing: composing,
      );
    } finally {
      _applyingRemote = false;
    }
    _lastValue = _controller.value;
    if (editingCell != null && mappedTableProbe != null) {
      final table = markdownTableAt(
        _controller.markdownFor(newText),
        mappedTableProbe,
      );
      final columns = table == null ? 0 : markdownTableColumnCount(table);
      if (table == null ||
          editingCell.row >= table.rows.length ||
          editingCell.column >= columns) {
        _cellEditor.hide();
        _editingCell = null;
      } else {
        _editingCell = (
          tableStart: table.start,
          row: editingCell.row,
          column: editingCell.column,
        );
      }
    }
    _dailySeparatorFormatter.syncLastUpdatedAt(widget.lastUpdatedAt);
    setState(() {
      _isEmpty = newText.isEmpty;
      _evaluate();
    });
    if (_editingCell != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreTableCellEditor();
      });
    }
    unawaited(_requestSpellCheck(newText));
  }

  bool _applyingRemote = false;

  /// The store holds words the editor has not taken yet.
  bool _remotePending = false;

  /// What the last text taken from the store replaced, and when. See
  /// [_rebaseStaleInput].
  ({String from, String to, DateTime at})? _lastTake;

  /// How long after taking the store's text an edit from the keyboard is
  /// checked for having been built on the text before. The keyboard catches
  /// up within a round trip to the platform; this is generous for a slow one.
  static const _staleInputWindow = Duration(seconds: 2);

  /// The first input formatter: an edit from the keyboard built on the text
  /// the editor showed before it last took the store's.
  ///
  /// The platform keeps its own copy of the text. A keystroke it applied to
  /// that copy before hearing of the new text arrives built on the old one,
  /// and read against what is on screen it looks like the keystroke plus the
  /// deletion of every word that just arrived. Whichever reading is the
  /// smaller edit is the one the keyboard meant: the stale one is carried
  /// across the take, and the others pass untouched.
  TextEditingValue _rebaseStaleInput(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final take = _lastTake;
    if (take == null) return newValue;
    // Only the platform's own input can be built on text it has not heard
    // of yet. A table cell's edits, and its undo, are this editor's, made on
    // the text as it stands; taken for stale, deleting in a cell what just
    // arrived would be put back, and the note would stop matching the cell.
    if (!_focusNode.hasFocus || _editingCell != null) {
      _lastTake = null;
      return newValue;
    }
    if (oldValue.text != take.to ||
        DateTime.now().difference(take.at) > _staleInputWindow) {
      _lastTake = null;
      return newValue;
    }
    int size(TextEdit edit) =>
        edit.oldEnd - edit.start + edit.newEnd - edit.start;
    final asShown = size(diffTexts(oldValue.text, newValue.text));
    final asBefore = size(diffTexts(take.from, newValue.text));
    if (asBefore >= asShown) {
      // Built on what is shown: the keyboard has caught up.
      _lastTake = null;
      return newValue;
    }
    final merge = mergeTexts(
      base: take.from,
      local: newValue.text,
      remote: take.to,
    );
    TextRange mapRange(TextRange range) => range.isValid
        ? TextRange(
            start: merge.mapLocal(range.start),
            end: merge.mapLocal(range.end),
          )
        : range;
    // A second keystroke may be on its way built on this one.
    _lastTake = (from: newValue.text, to: merge.text, at: take.at);
    return TextEditingValue(
      text: merge.text,
      selection: newValue.selection.isValid
          ? newValue.selection.copyWith(
              baseOffset: merge.mapLocal(newValue.selection.baseOffset),
              extentOffset: merge.mapLocal(newValue.selection.extentOffset),
            )
          : newValue.selection,
      composing: mapRange(newValue.composing),
    );
  }

  /// The style ranges the editor is currently drawing.
  @visibleForTesting
  List<NoteFormatRange> get formatsForTest => _formats;

  /// Whether the caret or a selection is in the first line, where the title
  /// is written, while the person is in the note.
  bool get selectionInTitle {
    final selection = _controller.selection;
    if (!_focusNode.hasFocus || !selection.isValid) return false;
    final text = _controller.text;
    final newline = text.indexOf('\n');
    return selection.start <= (newline < 0 ? text.length : newline);
  }

  void _reportDefaultTitleEntered() {
    final report = widget.onDefaultTitleEntered;
    if (report == null || widget.readOnly || !selectionInTitle) return;
    final text = _controller.text;
    if (text == Note.untitled || text.startsWith(Note.blankBody)) report();
  }

  /// A caret put in a new note's [Note.untitled] takes the whole title, so
  /// what is typed replaces it rather than adding to it. Leaving the taken
  /// title to the right goes on to the line below it.
  bool _takeDefaultTitle(TextSelection previous, TextEditingValue value) {
    const title = Note.untitled;
    final text = value.text;
    final selection = value.selection;
    if (widget.readOnly ||
        !selection.isValid ||
        !selection.isCollapsed ||
        selection.baseOffset > title.length ||
        _composingOpen(value) ||
        !text.startsWith(title) ||
        (text.length > title.length && text[title.length] != '\n')) {
      return false;
    }
    const taken = TextSelection(baseOffset: 0, extentOffset: title.length);
    final leaving =
        previous == taken &&
        selection.baseOffset == title.length &&
        text.length > title.length;
    _controller.selection = leaving
        ? const TextSelection.collapsed(offset: title.length + 1)
        : taken;
    return true;
  }

  void _onControllerChanged() {
    _openFoldUnderCaret();
    _recordKapyPeekActivity();
    final value = _controller.value;
    if (_convertedPaste case final paste? when value.text != paste.text) {
      setState(() {
        _convertedPaste = null;
        _pasteChipShown = false;
      });
    }
    _scheduleSlashCommandMenuSync();
    _reportCaret(value.selection);
    final previous = _lastValue;
    if (_applyingRemote) {
      _lastValue = value;
      return;
    }
    _reportDefaultTitleEntered();
    // The composition that held the store's text back has ended, with a
    // keystroke or without one. The keystroke is written below; the store's
    // text is taken after it.
    if (_remotePending && !_composingOpen(value)) _scheduleTake();
    _reportActivity(edited: value.text != previous.text);
    if (value.text == previous.text) {
      final selectionChanged = value.selection != previous.selection;
      _lastValue = value;
      if (!selectionChanged) return;
      if (_collapseLineTerminatorSelection(value.selection)) return;
      if (_takeDefaultTitle(previous.selection, value)) return;
      // Tables draw as a grid with the setting off too, so this is not
      // inside the markdown branch below.
      if (_keepCaretOutOfTable(previous.selection, value.selection)) return;
      if (widget.markdownEnabled) {
        if (_keepCaretOutOfMarkdown(previous.selection, value.selection)) {
          return;
        }
        if (!_ownSelectionChange) {
          // The writer moved the caret: anything waiting to be typed is
          // off, and the syntax beside the caret may show again.
          _markdownTyping.clear();
          _markdownShortcut.clear();
          _markdownQuiet = false;
        }
      }
      _typingOverrides.clear();
      _paragraphOverride = null;
      _scheduleSelectionToolbar(value.selection);
      setState(() {});
      return;
    }
    _markdownQuiet = true;
    // Typing straight after a tap is writing, not asking to paste.
    _pasteOfferTimer?.cancel();

    // The text moved under the panel, so the rect it is pinned to no longer
    // describes the link.
    LinkPopover.hide();
    _clearKeywordTooltip();

    final insertedText = insertedTextForChange(previous.text, value.text);
    final forcedInsertedFormats = _nextInsertedFormats;
    _nextInsertedFormats = null;
    // Copied rather than used in place: a caller that forces "no styles"
    // passes a const set, and the newline branch below removes from this.
    final insertedFormats = <NoteFormat>{...?forcedInsertedFormats};
    final previousParagraphStyle =
        _paragraphOverride ??
        paragraphStyleForSelection(previous.text, _formats, previous.selection);
    if (forcedInsertedFormats == null) {
      for (final format in NoteFormat.values.where(
        (candidate) => candidate.isInline,
      )) {
        final active =
            _typingOverrides[format] ??
            selectionHasFormat(_formats, previous.selection, format);
        if (active) insertedFormats.add(format);
      }
      final paragraphFormat = previousParagraphStyle?.format;
      if (paragraphFormat != null) insertedFormats.add(paragraphFormat);
    }
    if (insertedText.contains('\n')) {
      insertedFormats.removeWhere((format) => format.isParagraph);
    }
    final forcedAttachments = _nextAttachments;
    _nextAttachments = null;
    var updatedAttachments =
        forcedAttachments ??
        rebaseNoteAttachments(
          oldText: previous.text,
          newText: value.text,
          attachments: _attachments,
          selectionStart: previous.selection.isValid
              ? previous.selection.start
              : null,
          selectionEnd: previous.selection.isValid
              ? previous.selection.end
              : null,
        );
    _rememberDropped(previous.text, _attachments, updatedAttachments);
    updatedAttachments = _restoreUndone(value.text, updatedAttachments);
    final forcedFormats = _nextFormats;
    _nextFormats = null;
    var updatedFormats =
        forcedFormats ??
        rebaseNoteFormats(
          oldText: previous.text,
          newText: value.text,
          formats: _formats,
          insertedFormats: insertedFormats,
        );
    // Not in markdown, where a style comes only from what is written: a
    // heading applied before markdown was switched on still draws, but no
    // longer hands a subtitle to the line after it.
    if (!widget.markdownEnabled &&
        insertedText.contains('\n') &&
        value.selection.isValid) {
      // A heading naturally introduces a subtitle. That new style remains
      // active across later lines until the writer explicitly cycles it.
      final nextStyle = switch (previousParagraphStyle) {
        NoteParagraphStyle.heading => NoteParagraphStyle.subtitle,
        NoteParagraphStyle.subtitle => NoteParagraphStyle.subtitle,
        NoteParagraphStyle.text => NoteParagraphStyle.text,
        null => NoteParagraphStyle.text,
      };
      updatedFormats = applyParagraphStyle(
        updatedFormats,
        value.text,
        value.selection,
        nextStyle,
      );
      _paragraphOverride = nextStyle;
    }
    _lastValue = value;
    _formats = updatedFormats;
    _attachments = updatedAttachments;
    _controller.formats = updatedFormats;
    _controller.spellingSuggestions = const [];
    setState(() {
      _isEmpty = value.text.isEmpty;
      _evaluate();
    });
    unawaited(_requestSpellCheck(value.text));
    _commit(
      value.text,
      updatedFormats,
      updatedAttachments,
      edit: previous.text == _storeBase ? _editBetween(previous, value) : null,
    );
  }

  /// Where the change from [before] to [after] happened, as far as the
  /// selections tell: from where the earlier of the two starts to where both
  /// end. Diffed inside, a line deleted between two that start alike is the
  /// line the writer deleted, not the end of one and the start of the next.
  static TextEdit? _editBetween(
    TextEditingValue before,
    TextEditingValue after,
  ) {
    final was = before.selection;
    final now = after.selection;
    if (!was.isValid || !now.isValid) return null;
    final tail = math.min(
      before.text.length - was.end,
      after.text.length - now.end,
    );
    if (tail < 0) return null;
    return (
      start: math.min(was.start, now.start),
      oldEnd: before.text.length - tail,
      newEnd: after.text.length - tail,
    );
  }

  Future<void> _requestSpellCheck([String? requestedText]) async {
    final text = requestedText ?? _controller.text;
    if (widget.readOnly || !widget.spellCheckEnabled || text.isEmpty) {
      if (_controller.spellingSuggestions.isNotEmpty) {
        _controller.spellingSuggestions = const [];
        if (mounted) setState(() {});
      }
      return;
    }
    final locale = _spellCheckLocale;
    if (locale == null) return;

    final suggestions = await _spellCheckService.fetchSpellCheckSuggestions(
      locale,
      text,
    );
    if (!mounted ||
        widget.readOnly ||
        !widget.spellCheckEnabled ||
        _controller.text != text ||
        suggestions == null) {
      return;
    }

    final filtered = suggestions
        .where((suggestion) {
          final range = suggestion.range;
          final exempt = _controller.isSpellingExempt(text, range);
          final overlapsAttachment = _attachments.any(
            (attachment) =>
                range.start <= attachment.offset &&
                range.end > attachment.offset,
          );
          return !exempt && !overlapsAttachment;
        })
        .toList(growable: false);

    if (_sameSpellingSuggestions(_controller.spellingSuggestions, filtered)) {
      return;
    }
    _controller.spellingSuggestions = filtered;
    setState(() {});
  }

  static bool _sameSpellingSuggestions(
    List<SuggestionSpan> left,
    List<SuggestionSpan> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.range != b.range || !listEquals(a.suggestions, b.suggestions)) {
        return false;
      }
    }
    return true;
  }

  /// The recording running in *this* note, if there is one.
  ///
  /// A recording started in another note carries on in the background; only
  /// the note it belongs to shows the bar, because only there does stopping it
  /// mean "put it here".
  VoiceRecordingSession? get _liveSession {
    final session = widget.recording?.session;
    return session != null && session.noteId == widget.noteId ? session : null;
  }

  NoteVoiceChip _voiceChip(NoteVoiceRef ref) {
    final player = widget.player;
    return NoteVoiceChip(
      key: ValueKey('note-voice-${ref.hash}-${ref.offset}'),
      ref: ref,
      state: widget.voiceStateFor?.call(ref) ?? VoiceChipState.idle,
      progress:
          player?.progressFor(ref.hash) ??
          const AlwaysStoppedAnimation<double?>(null),
      playing: player?.isPlaying(ref.hash) ?? false,
      opening: player?.isOpening(ref.hash) ?? false,
      failure: player?.failureFor(ref.hash),
      onPlayPause: player == null ? null : () => _playPause(ref),
      onOpen: widget.onOpenVoiceNote == null
          ? null
          : () => widget.onOpenVoiceNote!(ref),
      onRemove: widget.readOnly ? null : () => removeAttachment(ref.offset),
      onSeekFraction: player == null ? null : (f) => _seekVoice(ref, f),
    );
  }

  /// Play, pause, a recording ending, another one taking over.
  ///
  /// Only these; the play head deliberately does not come through here, so
  /// this fires a handful of times per recording rather than four times a
  /// second. Without it a chip went on showing a pause button after its
  /// recording had finished, because nothing had asked it to look again.
  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _playPause(NoteVoiceRef ref) async {
    final player = widget.player;
    if (player == null) return;
    // A press on a recording still on its way calls it off, as a pause would.
    if (player.isPlaying(ref.hash) || player.isOpening(ref.hash)) {
      await player.pause();
      return;
    }
    await player.play(ref.hash);
    if (mounted) setState(() {});
  }

  /// A tap on a chip's waveform.
  ///
  /// On the recording already loaded this is a scrub. On any other it is also
  /// a request to hear it — from there, which is the whole reason to aim at a
  /// point on a waveform rather than press play. It used to be neither: the
  /// tap was dropped unless that recording happened to be the live one.
  Future<void> _seekVoice(NoteVoiceRef ref, double fraction) async {
    final player = widget.player;
    if (player == null) return;
    if (player.activeHash == ref.hash) {
      final total = player.duration ?? ref.duration;
      await player.seek(total * fraction);
      return;
    }
    await player.play(ref.hash, from: ref.duration * fraction);
  }

  /// Records refs this edit took out, against the text they were taken from.
  ///
  /// Covers every way an attachment can go — the Remove menu item, a backspace
  /// over the placeholder, a selection replaced, a paste over it — because all
  /// of them arrive here as a shorter attachment list.
  void _rememberDropped(
    String textBefore,
    List<NoteAttachmentRef> before,
    List<NoteAttachmentRef> after,
  ) {
    if (before.length <= after.length) return;

    // Survivors are consumed by hash, so a note holding the same picture twice
    // records one removal rather than two. Which of the two copies it names
    // may be wrong, and that is safe: a wrong offset simply fails to match on
    // Undo and falls back to the old behaviour. It never restores the wrong
    // attachment, because the offset has to match exactly.
    final survivors = <String, int>{};
    for (final ref in after) {
      survivors[ref.hash] = (survivors[ref.hash] ?? 0) + 1;
    }
    var removed = 0;
    for (final ref in before) {
      final left = survivors[ref.hash] ?? 0;
      if (left > 0) {
        survivors[ref.hash] = left - 1;
        continue;
      }
      _removedRefs.add((textBefore: textBefore, ref: ref));
      removed++;
    }
    while (_removedRefs.length > math.max(_maxRemovedRefs, removed)) {
      _removedRefs.removeAt(0);
    }
  }

  /// Reattaches anything an Undo just brought the placeholder back for.
  ///
  /// Redo removes it again by the ordinary rebase, which pushes it back onto
  /// [_removedRefs] — so the pair keeps working however many times it is used.
  List<NoteAttachmentRef> _restoreUndone(
    String text,
    List<NoteAttachmentRef> attachments,
  ) {
    if (_removedRefs.isEmpty) return attachments;
    final orphans = orphanedAttachmentAnchors(text, attachments);
    if (orphans.isEmpty) return attachments;

    final restored = [...attachments];
    var changed = false;
    for (final offset in orphans) {
      final index = _removedRefs.lastIndexWhere(
        (entry) => entry.ref.offset == offset && entry.textBefore == text,
      );
      if (index < 0) continue;
      restored.add(_removedRefs.removeAt(index).ref);
      changed = true;
    }
    return changed ? normalizeNoteAttachments(restored, text) : attachments;
  }

  bool _formatActive(NoteFormat format) {
    if (widget.markdownEnabled) {
      final strong = format == NoteFormat.bold;
      final selection = _controller.selection;
      if (selection.isValid &&
          selection.isCollapsed &&
          (_markdownTyping.isPending(strong: strong, caret: selection.start) ||
              _markdownTyping.isHeld(
                strong: strong,
                caret: selection.start,
                text: _controller.text,
              ))) {
        return true;
      }
      return markdownSelectionHas(
        _controller.markdownFor(_controller.text),
        selection,
        strong ? MarkdownStyle.strong : MarkdownStyle.emphasis,
      );
    }
    return _typingOverrides[format] ??
        selectionHasFormat(_formats, _controller.selection, format);
  }

  NoteParagraphStyle? get _activeParagraphStyle =>
      _paragraphOverride ??
      paragraphStyleForSelection(
        _controller.text,
        _formats,
        _controller.selection,
      );

  /// The heading level of the selected lines in a markdown note, 0 for body
  /// text, null when they differ.
  int? get _markdownHeadingLevel =>
      markdownHeadingLevelForSelection(_controller.text, _controller.selection);

  bool _lineStyleActive(NoteLineStyle style) => widget.markdownEnabled
      ? markdownSelectionHasLineStyle(_controller.value, style)
      : selectionHasLineStyle(_controller.value, style);

  bool get _showIndentControls =>
      selectionHasListLine(_controller.value) ||
      (widget.markdownEnabled &&
          markdownSelectionHasListLine(_controller.value));

  /// Whether nesting goes by markdown's columns: in a markdown note, unless
  /// the list is in the app's own bullets, which keep nesting their own way.
  bool get _indentsAsMarkdown =>
      widget.markdownEnabled &&
      markdownSelectionHasListLine(_controller.value) &&
      !markdownSelectionStartsWithGlyphItem(_controller.value);

  bool _canIndent({required bool outdent}) => _indentsAsMarkdown
      ? canIndentMarkdownSelection(_controller.value, outdent: outdent)
      : canIndentSelection(_controller.value, outdent: outdent);

  /// What Undo does straight after a markdown shortcut: gives back what was
  /// typed. False when the last thing typed was not one.
  bool _undoMarkdownShortcut() {
    final typed = _markdownShortcut.typedFor(_controller.value);
    if (typed == null || widget.readOnly || !widget.markdownEnabled) {
      return false;
    }
    _markdownShortcut.clear();
    _controller.value = typed;
    return true;
  }

  /// Puts a markdown control's edit into the note.
  ///
  /// The edit says where it moved everything, so attachments and any styles
  /// the note already had are carried across it exactly rather than by the
  /// one-stretch diff an ordinary keystroke is rebased with. Nothing is
  /// inherited by the markers it wrote.
  void _applyMarkdownEdit(MarkdownEdit edit) {
    if (widget.readOnly) return;
    ContextMenuController.removeAny();
    _typingOverrides.clear();
    final next = edit.value;
    if (edit.changesText && next.text != _controller.text) {
      _nextInsertedFormats = const {};
      _nextFormats = normalizeNoteFormats([
        for (final range in _formats)
          NoteFormatRange(
            start: edit.map(range.start),
            end: edit.map(range.end, before: true),
            format: range.format,
          ),
      ], next.text.length);
      _nextAttachments = normalizeNoteAttachments([
        for (final ref in _attachments)
          ref.copyWith(offset: edit.map(ref.offset)),
      ], next.text);
      _controller.value = next;
    } else if (next.selection != _controller.selection) {
      _ownSelectionChange = true;
      try {
        _controller.selection = next.selection;
      } finally {
        _ownSelectionChange = false;
      }
    }
    _focusNode.requestFocus();
  }

  void _cycleParagraphStyle() {
    if (widget.readOnly) return;
    if (widget.markdownEnabled) {
      _applyMarkdownEdit(
        applyMarkdownHeading(
          _controller.value,
          nextMarkdownHeadingLevel(_markdownHeadingLevel),
        ),
      );
      return;
    }
    _applyParagraphStyle(nextParagraphStyle(_activeParagraphStyle));
  }

  void _applyParagraphStyle(NoteParagraphStyle style) {
    if (widget.readOnly) return;
    final selection = _controller.selection;
    if (!selection.isValid) return;
    _paragraphOverride = selection.isCollapsed ? style : null;
    _commitFormats(
      applyParagraphStyle(_formats, _controller.text, selection, style),
    );
    _focusNode.requestFocus();
  }

  void _toggleInlineFormat(NoteFormat format) {
    if (widget.readOnly) return;
    final selection = _controller.selection;
    if (!selection.isValid) return;
    ContextMenuController.removeAny();
    if (widget.markdownEnabled) {
      final markdown = _controller.markdownFor(_controller.text);
      final strong = format == NoteFormat.bold;
      final caret = selection.start;
      // Pressed again before anything was typed: switched back off.
      if (selection.isCollapsed &&
          _markdownTyping.isPending(strong: strong, caret: caret)) {
        setState(
          () => _markdownTyping.togglePending(strong: strong, caret: caret),
        );
        _focusNode.requestFocus();
        return;
      }
      // Pressed after a space typed at the end of bold, which the next word
      // would otherwise have joined: that word is plain instead.
      if (selection.isCollapsed &&
          _markdownTyping.isHeld(
            strong: strong,
            caret: caret,
            text: _controller.text,
          )) {
        setState(
          () => _markdownTyping.releaseHeld(
            strong: strong,
            text: _controller.text,
          ),
        );
        _focusNode.requestFocus();
        return;
      }
      final edit = toggleMarkdownEmphasis(
        _controller.value,
        markdown,
        strong: strong,
      );
      if (edit.pending) {
        setState(
          () => _markdownTyping.togglePending(strong: strong, caret: caret),
        );
        _focusNode.requestFocus();
        return;
      }
      _applyMarkdownEdit(edit);
      return;
    }
    if (selection.isCollapsed) {
      setState(() => _typingOverrides[format] = !_formatActive(format));
    } else {
      _typingOverrides.clear();
      _commitFormats(
        toggleNoteFormat(_formats, selection, format, _controller.text.length),
      );
    }
    _focusNode.requestFocus();
  }

  /// Adds already-stored images to the note at the caret.
  ///
  /// Public because three different gestures end here — the toolbar button,
  /// a drop onto the page, and whatever gets added next — and none of them
  /// should have to know how a placeholder is anchored.
  void insertImages(List<NoteAttachmentRef> refs) {
    if (widget.readOnly || refs.isEmpty) return;
    final base = _dailySeparatorFormatter.prepareProgrammaticAppend(
      _controller.value,
    );
    final selection = base.selection;
    final caret = selection.isValid ? selection.end : base.text.length;
    final raw = insertImagesIntoBody(
      body: base.text,
      existing: _attachments,
      caret: caret,
      incoming: refs,
    );
    final result = attachMediaUnderTask(bodyBefore: base.text, inserted: raw);
    if (result.body != raw.body) _usedDetails();
    _nextAttachments = result.attachments;
    // A picture carries no inline style, and must not inherit the bold the
    // writer happened to have switched on.
    _nextInsertedFormats = const {};
    _controller.value = TextEditingValue(
      text: result.body,
      selection: TextSelection.collapsed(offset: result.selection),
    );
    _focusNode.requestFocus();
  }

  /// Adds already-stored videos through the same block attachment insertion
  /// rule as pictures. Kept as a named entry point for pickers and tests so a
  /// caller never has to pretend a video is an image.
  void insertVideos(List<NoteVideoRef> refs) => insertImages(refs);

  /// Adds already-stored files at the caret, one to a line.
  void insertFileRefs(List<NoteFileRef> refs) {
    if (widget.readOnly || refs.isEmpty) return;
    final base = _dailySeparatorFormatter.prepareProgrammaticAppend(
      _controller.value,
    );
    final selection = base.selection;
    final caret = selection.isValid ? selection.end : base.text.length;
    final result = insertFilesIntoBody(
      body: base.text,
      existing: _attachments,
      caret: caret,
      incoming: refs,
    );
    _nextAttachments = result.attachments;
    _nextInsertedFormats = const {};
    _controller.value = TextEditingValue(
      text: result.body,
      selection: TextSelection.collapsed(offset: result.selection),
    );
    _focusNode.requestFocus();
  }

  /// Adds a finished recording to the note at the caret.
  ///
  /// The same shape as [insertImages] and for the same reason: the recording
  /// controller lives above the editor and must not know how a placeholder is
  /// anchored.
  void insertVoice(NoteVoiceRef ref) {
    if (widget.readOnly) return;
    final base = _dailySeparatorFormatter.prepareProgrammaticAppend(
      _controller.value,
    );
    final selection = base.selection;
    final caret = selection.isValid ? selection.end : base.text.length;
    final result = insertVoiceIntoBody(
      body: base.text,
      existing: _attachments,
      caret: caret,
      incoming: ref,
    );
    _nextAttachments = result.attachments;
    _nextInsertedFormats = const {};
    _controller.value = TextEditingValue(
      text: result.body,
      selection: TextSelection.collapsed(offset: result.selection),
    );
  }

  /// Inserts plain lines after the attachment at [afterOffset], or at the
  /// caret when there is none.
  ///
  /// What **Insert into note** does with a summary or a transcript. The text
  /// goes in as ordinary lines carrying no styles: it is the user's note now,
  /// to edit like anything else they typed.
  void insertPlainLines(String text, {int? afterOffset}) {
    if (widget.readOnly || text.isEmpty) return;
    final body = _controller.text;
    final int at;
    if (afterOffset != null && afterOffset < body.length) {
      final lineEnd = body.indexOf('\n', afterOffset);
      at = lineEnd < 0 ? body.length : lineEnd + 1;
    } else {
      final selection = _controller.selection;
      at = selection.isValid ? selection.end : body.length;
    }

    final needsLeading = at > 0 && body.codeUnitAt(at - 1) != 0x0A;
    final inserted = '${needsLeading ? '\n' : ''}$text\n';
    final next = body.substring(0, at) + inserted + body.substring(at);

    _nextAttachments = [
      for (final ref in _attachments)
        if (ref.offset < at)
          ref
        else
          ref.copyWith(offset: ref.offset + inserted.length),
    ];
    _nextInsertedFormats = const {};
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }

  /// Handles Paste, preferring a picture over text when the clipboard has one.
  ///
  /// Copying a screenshot and pressing Paste should put the screenshot in the
  /// note; that is what every other editor does and what nobody thinks twice
  /// about.
  ///
  /// Everything cheap is read in one go. A dictation app owns the clipboard
  /// only for as long as its synthetic Cmd+V takes to land, then puts back
  /// whatever was there before, so reads issued an await apart are liable to be
  /// describing two different clipboards — which is how a transcript used to
  /// lose to a picture copied minutes earlier. The bitmap is the one read left
  /// until it is wanted, being the only expensive one, so it is checked against
  /// the clipboard it was promised from before it goes into the note.
  Future<void> handlePaste(SelectionChangedCause cause) async {
    if (widget.readOnly) return;
    // Keep the insertion point from the moment Cmd+V arrived. An
    // accessibility-driven refocus can briefly clear the field's selection
    // while the promised clipboard value is being resolved.
    final startingValue = _controller.value;
    final store = widget.images;

    // A note without markdown takes its words from the platform's own text
    // call, as it always has; a markdown note takes them from the same read
    // as the rest of what it converts.
    final markdown = widget.markdownEnabled;
    final (plainText, snapshot, paths) = await (
      markdown ? Future<String?>.value() : _clipboardText(),
      markdown || store != null
          ? widget.clipboard.readSnapshot()
          : Future.value(const ClipboardSnapshot()),
      store == null
          ? Future<List<String>>.value(const [])
          : widget.clipboard.readImageFiles(),
    ).wait;
    if (!mounted) return;
    final capturedText = markdown ? snapshot.text : plainText;

    // A selection copied out of a note carries everything that was in it, so
    // it outranks the rest of the clipboard: the native bitmap alone would
    // reduce a mixed selection to its first picture, and the HTML would lose
    // what only a note holds.
    final fragment = store == null
        ? null
        : await NoteClipboardFragment.fromSnapshot(snapshot);
    if (!mounted) return;
    if (fragment != null) {
      await _insertClipboardFragment(
        fragment,
        cause,
        startingValue: startingValue,
      );
      return;
    }

    // In a markdown note, anything richer than plain words — a page, a
    // document, an AI's answer, an editor's code — is read for what it says,
    // as markdown, which only reads well drawn. A note without markdown
    // pastes as it always has. Lone pictures and plain words take the paths
    // below either way.
    final converted = markdown
        ? await convertPasteInBackground(snapshot)
        : null;
    if (!mounted) return;
    final rich = switch (converted?.kind) {
      null || PasteKind.text || PasteKind.nothing => null,
      _ => converted!.output,
    };
    if (rich != null && rich.hasWords) {
      _insertConvertedPaste(
        rich,
        cause,
        clipboardText: capturedText,
        startingValue: startingValue,
        clipboardFiles: snapshot.files,
      );
      return;
    }

    // Raw bitmap data — a screenshot tool, a browser's "copy image".
    if (store != null) {
      final pasted = await widget.clipboard.readImage();
      if (!mounted) return;
      if (pasted != null && await _clipboardStillHolds(capturedText)) {
        if (!mounted) return;
        if (!_beginImageAction()) return;
        try {
          final staged = await stageImage(
            source: pasted.bytes,
            sourceMime: mimeForFilename(pasted.name),
          );
          if (!mounted) return;
          if (staged.isOk) {
            final image = staged.staged!;
            // Keep the exact preview bytes under their temporary hash before
            // the note points at them. If the app closes during compression,
            // the persisted ref still opens instead of becoming a hole.
            await store.put(image.source);
            if (!mounted) return;
            insertImages([image.ref]);
            final result = await (widget.imageFinalizer ?? _finishStagedImage)(
              image,
              store,
            );
            final ready = result.isOk && result.image!.ref is NoteImageRef
                ? result.image!.ref as NoteImageRef
                : await storeStagedImageAsIs(image, store: store);
            _publishPreparedImage(image.ref, ready);
            return;
          }
          Toast.show(
            context,
            '${pasted.name} ${describeRejection(staged.rejection!)}',
            icon: KapyIcons.errorOutlined,
          );
        } catch (error, stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'Kapy Notes editor',
              context: ErrorDescription('while adding a pasted image'),
            ),
          );
          if (mounted) {
            Toast.show(
              context,
              'Could not add that image',
              icon: KapyIcons.errorOutlined,
            );
          }
        } finally {
          _endImageAction();
        }
      }
    }

    // Then a file copied in Finder or Explorer, which arrives as a path.
    if (paths.isNotEmpty) {
      await insertFiles([for (final path in paths) XFile(path)]);
      return;
    }
    if (!mounted) return;
    // Pictures and nothing else, from markup that only pointed at them.
    if (rich != null && rich.images.isNotEmpty) {
      _insertConvertedPaste(
        rich,
        cause,
        clipboardText: capturedText,
        startingValue: startingValue,
        clipboardFiles: snapshot.files,
      );
      return;
    }
    if (capturedText == null) return;
    if (converted case PasteConversion(kind: PasteKind.text, :final output)) {
      _insertConvertedPaste(
        output,
        cause,
        clipboardText: capturedText,
        startingValue: startingValue,
        clipboardFiles: snapshot.files,
      );
      return;
    }
    _insertPastedText(capturedText, cause, startingValue: startingValue);
  }

  /// Puts a converted paste into the note as one edit, so one undo takes all
  /// of it back out, fitted to the line it lands on (see [planPaste]).
  ///
  /// Pictures go in as placeholders at once — the clipboard's own bytes, or a
  /// quiet box while they download — and are prepared afterwards. Only their
  /// refs change when they are ready, never the text, so they add no undo
  /// steps of their own.
  void _insertConvertedPaste(
    PasteOutput output,
    SelectionChangedCause cause, {
    String? clipboardText,
    TextEditingValue? startingValue,
    List<String> clipboardFiles = const [],
  }) {
    if (widget.readOnly) return;
    final field = _field;
    if (field == null) return;
    final store = widget.images;
    final value = _controller.value;
    final selection = _selectionForPaste(value, startingValue);
    final target = _pasteTargetAt(value.text, selection.start);
    final insertion = planPaste(
      note: value.text,
      selection: selection,
      output: store == null ? output.withoutPictures() : output,
      target: target,
      clipboardText: clipboardText,
    );
    final nextText = value.text.replaceRange(
      insertion.start,
      insertion.end,
      insertion.text,
    );
    final delta = insertion.text.length - (insertion.end - insertion.start);
    final pictures = [
      for (final image in insertion.images)
        (
          ref: _pastedImagePlaceholder(
            image.image,
            insertion.start + image.offset,
          ),
          image: image.image,
        ),
    ];
    _nextAttachments = normalizeNoteAttachments([
      for (final ref in _attachments)
        if (ref.offset < insertion.start)
          ref
        else if (ref.offset >= insertion.end)
          ref.copyWith(offset: ref.offset + delta),
      for (final picture in pictures) picture.ref,
    ], nextText);
    _nextInsertedFormats = const {};
    field.userUpdateTextEditingValue(
      value.copyWith(
        text: nextText,
        selection: TextSelection.collapsed(
          offset: insertion.start + insertion.text.length,
        ),
        composing: TextRange.empty,
      ),
      cause,
    );
    _focusNode.requestFocus();
    if (store != null && pictures.isNotEmpty) {
      unawaited(_preparePastedImages(pictures, store, clipboardFiles));
    }

    // Written as something other than the clipboard's plain text, which a
    // code block or a table never is: the chip says so, and offers the plain
    // text instead.
    final plain = clipboardText ?? '';
    final words = cleanPastedText(plain);
    if (target != PasteTarget.text ||
        words.trim().isEmpty ||
        words == output.text) {
      return;
    }
    final pasted = _controller.text;
    _pasteCaret.value = null;
    setState(() {
      _convertedPaste = ConvertedPaste(
        range: TextRange(
          start: insertion.start,
          end: pasted.length - value.text.length + insertion.end,
        ),
        text: pasted,
        plainText:
            value.text.substring(insertion.start, selection.start) + plain,
      );
      _pasteChipShown = true;
    });
  }

  /// Plain text instead: what the paste wrote becomes the clipboard's plain
  /// text, written as Paste as plain text writes it, in an edit of its own,
  /// so one undo brings the formatted paste back.
  void _pastePlainInstead() {
    final paste = _convertedPaste;
    if (paste == null) return;
    _insertPastedText(
      paste.plainText,
      SelectionChangedCause.toolbar,
      startingValue: _controller.value.copyWith(
        selection: TextSelection(
          baseOffset: paste.range.start,
          extentOffset: paste.range.end,
        ),
      ),
    );
  }

  void _dismissPasteChip() {
    if (_pasteChipShown) setState(() => _pasteChipShown = false);
  }

  /// Measures where the paste's chip hangs from, as the field is scrolled
  /// now: the caret at the end of the paste.
  void _placePasteChip() {
    final paste = _convertedPaste;
    _pasteCaret.value = !_pasteChipShown || paste == null
        ? null
        : _field?.caretRectAt(TextPosition(offset: paste.range.end));
  }

  /// The rows the last converted paste wrote, across the writing column, in
  /// the page's coordinates: what its wash covers. Read as the wash paints,
  /// so it moves with the note.
  Rect? _pastedRows(ConvertedPaste paste, EdgeInsets padding, double width) {
    final field = _field;
    if (field == null || field.box == null) return null;
    // Line breaks at either end of a paste only open a line for it or close
    // the one it ends on; what it wrote is between them.
    var (first, last) = (paste.range.start, paste.range.end);
    while (first < last && paste.text.codeUnitAt(first) == 0x0A) {
      first++;
    }
    while (last > first && paste.text.codeUnitAt(last - 1) == 0x0A) {
      last--;
    }
    if (first == last) return null;
    // The rows of its first and last characters, or of their lines when
    // those are too far out of view to have been laid out.
    final lines = field.lines;
    final top =
        field
            .boxesFor(TextSelection(baseOffset: first, extentOffset: first + 1))
            .firstOrNull
            ?.top ??
        field.lineTop(lines.lineAt(first));
    final bottom =
        field
            .boxesFor(TextSelection(baseOffset: last - 1, extentOffset: last))
            .lastOrNull
            ?.bottom ??
        field.lineTop(lines.lineAt(last - 1) + 1);
    if (top == null || bottom == null) return null;
    return Rect.fromLTRB(0, top, width, bottom).shift(padding.topLeft);
  }

  /// What a paste may write where it lands: only words in a table, only the
  /// clipboard's own text in a code block.
  PasteTarget _pasteTargetAt(String text, int offset) {
    final analysis = _controller.markdownFor(text);
    for (final table in analysis.tables) {
      if (offset > table.start && offset < table.end) return PasteTarget.table;
    }
    final fence = RegExp(r'^\s*(```|~~~)');
    for (final block in analysis.blocks) {
      if (block.kind != MarkdownBlockKind.code) continue;
      final firstLineEnd = text.indexOf('\n', block.start);
      if (firstLineEnd < 0 || firstLineEnd >= block.end) continue;
      final fenced = fence.hasMatch(text.substring(block.start, firstLineEnd));
      final contentStart = fenced ? firstLineEnd + 1 : block.start;
      var contentEnd = block.end;
      final lastLineStart = text.lastIndexOf('\n', block.end - 1) + 1;
      if (fenced &&
          lastLineStart > firstLineEnd &&
          fence.hasMatch(text.substring(lastLineStart, block.end))) {
        contentEnd = lastLineStart - 1;
      }
      if (offset >= contentStart && offset <= contentEnd) {
        return PasteTarget.code;
      }
    }
    return PasteTarget.text;
  }

  /// What holds a pasted picture's place until it is prepared: the bytes
  /// themselves when the clipboard carried them, and otherwise a quiet box
  /// that remembers where to fetch them from.
  NoteImageRef _pastedImagePlaceholder(PasteImage image, int offset) {
    final bytes = image.bytes;
    final width = (image.width ?? 0).round();
    final height = (image.height ?? 0).round();
    final sized = width > 0 && height > 0;
    return NoteImageRef(
      offset: offset,
      hash: BlobStore.hashOf(
        bytes ?? Uint8List.fromList(utf8.encode(image.src ?? '')),
      ),
      key: randomKey(),
      mime: image.mime ?? 'image/png',
      width: sized ? width : 4,
      height: sized ? height : 3,
      bytes: bytes?.length ?? 0,
      widthFactor: image.widthFactor,
      isPreparing: true,
      previewBytes: bytes,
      src: bytes == null ? image.src : null,
    );
  }

  /// Fetches what pasted pictures still need and prepares them in order:
  /// downloads run side by side, compression one at a time.
  Future<void> _preparePastedImages(
    List<({NoteImageRef ref, PasteImage image})> pictures,
    BlobStore store, [
    List<String> clipboardFiles = const [],
  ]) async {
    final fetched = [
      for (final picture in pictures)
        picture.image.hasBytes
            ? Future.value((
                bytes: picture.image.bytes!,
                mime: picture.image.mime ?? 'image/png',
              ))
            : PastedImageDownloader.shared.fetch(
                picture.ref.src ?? '',
                clipboardFiles: clipboardFiles,
              ),
    ];
    for (var i = 0; i < pictures.length; i++) {
      final placeholder = pictures[i].ref;
      final source = await fetched[i];
      final staged = source == null
          ? null
          : (await stageImage(
              source: source.bytes,
              sourceMime: source.mime,
            )).staged;
      if (staged == null) {
        // Nothing usable came back. The place stays, with the address to try
        // again from.
        _publishPreparedImage(
          placeholder,
          placeholder.copyWith(isPreparing: false, previewBytes: null),
        );
        continue;
      }
      final local = NoteImageRef(
        offset: placeholder.offset,
        hash: staged.ref.hash,
        key: placeholder.key,
        mime: staged.ref.mime,
        width: staged.ref.width,
        height: staged.ref.height,
        bytes: staged.ref.bytes,
        widthFactor: placeholder.widthFactor,
        isPreparing: true,
        previewBytes: staged.source,
      );
      final keyed = StagedImage(
        ref: local,
        source: staged.source,
        sourceMime: staged.sourceMime,
      );
      try {
        await store.put(keyed.source);
        _publishPreparedImage(placeholder, local);
        final result = await (widget.imageFinalizer ?? _finishStagedImage)(
          keyed,
          store,
        );
        final ready = result.isOk && result.image!.ref is NoteImageRef
            ? result.image!.ref as NoteImageRef
            : await storeStagedImageAsIs(keyed, store: store);
        _publishPreparedImage(local, ready);
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Kapy Notes editor',
            context: ErrorDescription('while preparing a pasted image'),
          ),
        );
      }
    }
  }

  /// Tries a pasted picture's download again.
  void _retryPastedImage(NoteImageRef ref) {
    final store = widget.images;
    final address = ref.src;
    if (widget.readOnly || store == null || address == null) return;
    final loading = ref.copyWith(isPreparing: true);
    _publishPreparedImage(ref, loading);
    unawaited(
      _preparePastedImages([
        (ref: loading, image: PasteImage(src: address)),
      ], store),
    );
  }

  /// Pastes only the clipboard's plain-text representation.
  ///
  /// Normal Paste understands Kapy Notes fragments and images. This path
  /// deliberately skips those richer representations so a mixed selection
  /// becomes ordinary text and adopts the formatting at the insertion point.
  Future<void> _pastePlainText(SelectionChangedCause cause) async {
    if (widget.readOnly) return;
    final startingValue = _controller.value;
    final text = await _clipboardText();
    if (!mounted || text == null) return;
    _insertPastedText(text, cause, startingValue: startingValue);
  }

  /// The clipboard's plain text, or null when it holds none.
  Future<String?> _clipboardText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while capturing text for paste'),
        ),
      );
      return null;
    }
  }

  /// Whether the clipboard still holds the text this paste was promised.
  ///
  /// A dictation app restores the previous clipboard a moment after its Cmd+V,
  /// so a bitmap read later can belong to that older clipboard rather than to
  /// the paste that was asked for. The text tells the two apart: a picture
  /// genuinely copied alongside text still matches, a restored one does not.
  Future<bool> _clipboardStillHolds(String? capturedText) async =>
      await _clipboardText() == capturedText;

  /// Puts a selection copied out of a note back as it was: its words, their
  /// styles and every attachment it carried, stored here anew, all as one
  /// edit and so one undo step. A selection from a note of the other kind is
  /// rewritten for this one on the way in.
  Future<void> _insertClipboardFragment(
    NoteClipboardFragment fragment,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) async {
    final store = widget.images;
    if (store == null) return;
    var body = fragment.body;
    var formats = fragment.formats;
    Map<int, int>? anchors;
    final markdown = fragment.markdown;
    if (markdown != null && markdown != widget.markdownEnabled) {
      final converted = convertNote(
        body,
        toMarkdown: widget.markdownEnabled,
        formats: formats,
      );
      body = converted.text;
      formats = converted.formats;
      anchors = converted.anchors;
    }
    if (fragment.images.isEmpty && fragment.attachments.isEmpty) {
      _replaceSelectionWithFragment(
        body,
        const [],
        formats,
        cause,
        startingValue: startingValue,
      );
      return;
    }
    if (!_beginImageAction()) return;
    final picturesOnly = fragment.attachments.isEmpty;
    final progress = Toast.showProgress(
      context,
      picturesOnly ? 'Pasting with images…' : 'Pasting with attachments…',
    );
    try {
      final incoming = <NoteAttachmentRef>[];
      for (final image in fragment.images) {
        final result = await ingestImage(
          source: image.bytes,
          sourceMime: image.mime,
          store: store,
        );
        if (!mounted) {
          progress.dismiss();
          return;
        }
        if (!result.isOk || result.image!.ref is! NoteImageRef) {
          progress.error('Could not paste one of those images');
          return;
        }
        incoming.add(
          (result.image!.ref as NoteImageRef).copyWith(
            offset: image.offset,
            widthFactor: image.widthFactor,
          ),
        );
      }
      for (final attachment in fragment.attachments) {
        final ref = await _storeCarriedAttachment(attachment, store);
        if (!mounted) {
          progress.dismiss();
          return;
        }
        if (ref == null) {
          progress.error('Could not paste one of those attachments');
          return;
        }
        incoming.add(ref);
      }
      if (!_replaceSelectionWithFragment(
        body,
        [
          for (final ref in incoming)
            if ((anchors == null ? ref.offset : anchors[ref.offset])
                case final at?)
              ref.copyWith(offset: at),
        ],
        formats,
        cause,
        startingValue: startingValue,
      )) {
        progress.error('Could not paste that selection');
        return;
      }
      progress.success(
        picturesOnly ? 'Pasted with images' : 'Pasted with attachments',
      );
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while pasting a rich note selection'),
        ),
      );
      progress.error('Could not paste that selection');
    } finally {
      _endImageAction();
    }
  }

  /// Stores a file, voice note or video a paste carried, and returns its ref
  /// at its place in the fragment, or null when it could not be stored.
  ///
  /// A file or a video goes in the way a dropped one does, from a copy on
  /// disk under its own name, so it is held to the same limits and a video
  /// this device cannot play is refused. A voice note is stored as a
  /// recording is, keeping its transcript, summary and posts.
  Future<NoteAttachmentRef?> _storeCarriedAttachment(
    ClipboardFragmentAttachment attachment,
    BlobStore store,
  ) async {
    final copied = attachment.ref;
    if (copied is NoteVoiceRef) {
      return NoteVoiceRef(
        offset: copied.offset,
        hash: await store.put(
          attachment.bytes,
          extension: NoteVoiceRef.voiceExtension,
        ),
        key: randomKey(),
        mime: copied.mime,
        bytes: attachment.bytes.length,
        durationMs: copied.durationMs,
        peaks: copied.peaks,
        transcript: copied.transcript,
        summary: copied.summary,
        takes: copied.takes,
      );
    }
    final name = switch (copied) {
      NoteFileRef(:final name) => name,
      NoteVideoRef(:final extension) => 'video$extension',
      _ => null,
    };
    if (name == null) return null;
    final attachmentMaxBytes =
        widget.videoAttachmentMaxBytes?.call() ?? freeAttachmentMaxBytes;
    final directory = await Directory.systemTemp.createTemp('kapy-paste');
    try {
      final path = '${directory.path}/$name';
      await File(path).writeAsBytes(attachment.bytes);
      final files = [XFile(path, mimeType: copied.mime)];
      if (copied is NoteVideoRef) {
        final batch = widget.videoIngestor == null
            ? await ingestVideoFiles(
                files,
                store: store,
                attachmentMaxBytes: attachmentMaxBytes,
              )
            : await widget.videoIngestor!(files, store);
        return batch.videos.firstOrNull?.copyWith(
          offset: copied.offset,
          widthFactor: copied.widthFactor,
        );
      }
      final batch = widget.fileIngestor == null
          ? await ingestFileAttachments(
              files,
              store: store,
              attachmentMaxBytes: attachmentMaxBytes,
            )
          : await widget.fileIngestor!(files, store);
      return batch.files.firstOrNull?.copyWith(offset: copied.offset);
    } finally {
      await directory.delete(recursive: true);
    }
  }

  TextSelection _selectionForPaste(
    TextEditingValue value,
    TextEditingValue? startingValue,
  ) {
    bool fits(TextSelection candidate) =>
        candidate.isValid && candidate.end <= value.text.length;
    final startingSelection = startingValue?.selection;
    return startingValue?.text == value.text &&
            startingSelection != null &&
            fits(startingSelection)
        ? startingSelection
        : fits(value.selection)
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
  }

  bool _replaceSelectionWithFragment(
    String body,
    List<NoteAttachmentRef> attachments,
    List<NoteFormatRange> formats,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) {
    final field = _field;
    if (field == null) return false;
    final value = _controller.value;
    final selection = _selectionForPaste(value, startingValue);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      body,
    );
    final delta = body.length - (selection.end - selection.start);
    _nextAttachments = normalizeNoteAttachments([
      for (final ref in _attachments)
        if (ref.offset < selection.start)
          ref
        else if (ref.offset >= selection.end)
          ref.copyWith(offset: ref.offset + delta),
      for (final ref in attachments)
        ref.copyWith(offset: selection.start + ref.offset),
    ], nextText);
    if (formats.isNotEmpty) {
      _nextFormats = normalizeNoteFormats([
        ...rebaseNoteFormats(
          oldText: value.text,
          newText: nextText,
          formats: _formats,
          insertedFormats: const {},
        ),
        for (final range in formats)
          NoteFormatRange(
            start: selection.start + range.start,
            end: selection.start + range.end,
            format: range.format,
          ),
      ], nextText.length);
    }
    _nextInsertedFormats = const {};
    field.userUpdateTextEditingValue(
      value.copyWith(
        text: nextText,
        selection: TextSelection.collapsed(
          offset: selection.start + body.length,
        ),
        composing: TextRange.empty,
      ),
      cause,
    );
    _focusNode.requestFocus();
    return true;
  }

  /// Inserts a captured clipboard value through the same formatter and undo
  /// path as [NoteFieldState.pasteText], without consulting a clipboard a
  /// dictation app may already have restored.
  void _insertPastedText(
    String text,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) {
    if (widget.readOnly) return;
    final field = _field;
    if (field == null) return;
    final value = _controller.value;
    final selection = _selectionForPaste(value, startingValue);
    final collapsed = value.copyWith(
      selection: TextSelection.collapsed(offset: selection.end),
    );
    field.userUpdateTextEditingValue(
      collapsed.replaced(selection, text),
      cause,
    );
    _focusNode.requestFocus();
  }

  /// Sets one image's width, live, while the handle is being dragged.
  ///
  /// Only the editor's own copy moves here. Saving on every drag frame would
  /// write the note — and bump `updatedAt`, and mark it dirty for sync —
  /// dozens of times for one gesture, so the write waits for
  /// [_commitAttachments] when the drag ends.
  void _resizeImage(int offset, double factor) {
    if (widget.readOnly) return;
    var changed = false;
    final resized = [
      for (final ref in _attachments)
        if (ref is NoteImageRef &&
            ref.offset == offset &&
            ref.widthFactor != factor)
          (() {
            changed = true;
            return ref.copyWith(widthFactor: factor);
          })()
        else
          ref,
    ];
    if (!changed) return;
    setState(() => _attachments = resized);
  }

  void _commitAttachments() {
    if (widget.readOnly) return;
    _commit(_controller.text, _formats, _attachments);
  }

  /// Removes the image anchored at [offset], placeholder and all.
  ///
  /// The character is what an image *is*, so this is a text edit and takes the
  /// ordinary path: undo puts it back, and the ref falls away with the anchor
  /// it was reconciled against.
  void removeAttachment(int offset) {
    if (widget.readOnly) return;
    final text = _controller.text;
    if (offset < 0 || offset >= text.length) return;
    if (text.codeUnitAt(offset) != 0xFFFC) return;

    final next = text.substring(0, offset) + text.substring(offset + 1);
    // Stated rather than inferred. The caret is wherever the writer left it,
    // which is not necessarily on the picture they just chose to remove, and
    // one U+FFFC looks exactly like another to a diff.
    _nextAttachments = normalizeNoteAttachments([
      for (final ref in _attachments)
        if (ref.offset < offset)
          ref
        else if (ref.offset > offset)
          ref.copyWith(offset: ref.offset - 1),
    ], next);
    _nextInsertedFormats = const {};
    final value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: offset),
    );
    final field = _field;
    if (field != null) {
      field.userUpdateTextEditingValue(value, SelectionChangedCause.toolbar);
    } else {
      _controller.value = value;
    }
    _focusNode.requestFocus();
  }

  /// Scrolls the note until the line holding the attachment at [offset] is
  /// in view, from its top when it is taller than the note's window.
  void showAttachment(int offset) {
    final field = _field;
    if (field == null ||
        !_scrollController.hasClients ||
        offset < 0 ||
        offset > field.lines.textLength) {
      return;
    }
    final line = field.lines.lineAt(offset);
    final shownTop = field.lineTop(line);
    final shownBottom = field.lineTop(line + 1);
    if (shownTop == null || shownBottom == null) return;
    final position = _scrollController.position;
    var to = position.pixels;
    final top = shownTop + to;
    final bottom = shownBottom + to;
    if (bottom > to + position.viewportDimension) {
      to = bottom - position.viewportDimension;
    }
    if (top < to) to = top;
    unawaited(
      _scrollController.animateTo(
        to.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Opens the device's image entry point, compresses whatever comes back,
  /// and inserts it. Phones ask between the native camera and photo library;
  /// desktop opens its system file dialog.
  Future<void> pickAndInsertImages() async {
    final store = widget.images;
    if (store == null || !_beginImageAction()) return;
    try {
      final files = await (widget.imageAcquirer ?? acquireNoteImages)(context);
      if (files.isEmpty || !mounted) return;
      await _ingestAndInsertFiles(files, store);
    } finally {
      _endImageAction();
    }
  }

  /// Compresses and inserts files that arrived from anywhere — a picker or a
  /// drop. Reports whatever could not be added, by name.
  Future<void> insertFiles(List<XFile> files) async {
    final store = widget.images;
    if (store == null || files.isEmpty || !_beginImageAction()) return;
    try {
      await _ingestAndInsertFiles(files, store);
    } finally {
      _endImageAction();
    }
  }

  /// Pictures and playable videos become media; anything else is attached
  /// as a file, exactly as it is.
  Future<void> insertDroppedMedia(List<XFile> files) async {
    final images = <XFile>[];
    final videos = <XFile>[];
    final others = <XFile>[];
    for (final file in files) {
      final name = file.name;
      final dot = name.lastIndexOf('.');
      final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
      if (supportedImageExtensions.contains(extension)) {
        images.add(file);
      } else if (supportedVideoExtensions.contains(extension)) {
        videos.add(file);
      } else {
        others.add(file);
      }
    }
    if (images.isNotEmpty) await insertFiles(images);
    if (videos.isNotEmpty) await insertVideoFiles(videos);
    if (others.isNotEmpty) await insertAttachmentFiles(others);
  }

  /// Opens the file chooser and attaches whatever comes back, as-is.
  Future<void> pickAndInsertFileAttachments() async {
    final store = widget.images;
    if (store == null || !_beginFileAction()) return;
    try {
      final files = await (widget.fileAcquirer ?? acquireAttachmentFiles)();
      if (files.isEmpty || !mounted) return;
      await _ingestAndInsertFileAttachments(files, store);
    } finally {
      _endFileAction();
    }
  }

  /// Attaches files that arrived from anywhere — the chooser or a drop.
  Future<void> insertAttachmentFiles(List<XFile> files) async {
    final store = widget.images;
    if (store == null || files.isEmpty || !_beginFileAction()) return;
    try {
      await _ingestAndInsertFileAttachments(files, store);
    } finally {
      _endFileAction();
    }
  }

  bool _beginFileAction() {
    if (widget.readOnly) return false;
    if (_fileActionBusy) {
      Toast.show(
        context,
        'Another file is still being added',
        icon: KapyIcons.hourglassRounded,
      );
      return false;
    }
    setState(() => _fileActionBusy = true);
    return true;
  }

  void _endFileAction() {
    if (mounted && _fileActionBusy) {
      setState(() => _fileActionBusy = false);
    }
  }

  Future<void> _ingestAndInsertFileAttachments(
    List<XFile> files,
    BlobStore store,
  ) async {
    final count = files.length;
    final progress = Toast.showProgress(
      context,
      count == 1 ? 'Adding file…' : 'Adding $count files…',
    );
    final attachmentMaxBytes =
        widget.videoAttachmentMaxBytes?.call() ?? freeAttachmentMaxBytes;
    try {
      final batch = widget.fileIngestor == null
          ? await ingestFileAttachments(
              files,
              store: store,
              attachmentMaxBytes: attachmentMaxBytes,
            )
          : await widget.fileIngestor!(files, store);
      if (!mounted) {
        progress.dismiss();
        return;
      }
      insertFileRefs(batch.files);
      final added = batch.files.length;
      final rejected = batch.rejections.length;
      if (added == 0) {
        final first = batch.rejections.firstOrNull;
        progress.error(
          first == null
              ? 'Could not add that file'
              : '${first.name} ${describeFileRejection(first.reason, attachmentMaxBytes: attachmentMaxBytes)}',
        );
      } else if (rejected > 0) {
        final first = batch.rejections.first;
        progress.success(
          'Added $added ${added == 1 ? 'file' : 'files'}; '
          '${first.name} ${describeFileRejection(first.reason, attachmentMaxBytes: attachmentMaxBytes)}'
          '${rejected > 1 ? ' (and ${rejected - 1} more)' : ''}',
          icon: KapyIcons.warningRounded,
        );
      } else {
        progress.success(added == 1 ? 'File added' : '$added files added');
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while adding files'),
        ),
      );
      progress.error(
        count == 1 ? 'Could not add that file' : 'Could not add those files',
      );
    }
  }

  bool _beginImageAction() {
    if (widget.readOnly) return false;
    if (_imageActionBusy) {
      Toast.show(
        context,
        'Another image is still being added',
        icon: KapyIcons.hourglassRounded,
      );
      return false;
    }
    setState(() => _imageActionBusy = true);
    return true;
  }

  void _endImageAction() {
    if (mounted && _imageActionBusy) {
      setState(() => _imageActionBusy = false);
    }
  }

  /// Opens the camera, and puts the photo or video kept there where the
  /// caret is, the way the phone camera's land.
  Future<void> openCameraAndInsert() async {
    final acquire = widget.cameraAcquirer;
    if (acquire == null || widget.readOnly || widget.images == null) return;
    final files = await acquire(context);
    if (files.isEmpty || !mounted) return;
    await insertDroppedMedia(files);
  }

  Future<void> pickAndInsertVideos() async {
    final store = widget.images;
    if (store == null || !_beginVideoAction()) return;
    try {
      final files = await (widget.videoAcquirer ?? acquireNoteVideos)();
      if (files.isEmpty || !mounted) return;
      await _ingestAndInsertVideos(files, store);
    } finally {
      _endVideoAction();
    }
  }

  Future<void> insertVideoFiles(List<XFile> files) async {
    final store = widget.images;
    if (store == null || files.isEmpty || !_beginVideoAction()) return;
    try {
      await _ingestAndInsertVideos(files, store);
    } finally {
      _endVideoAction();
    }
  }

  bool _beginVideoAction() {
    if (widget.readOnly) return false;
    if (_videoActionBusy) {
      Toast.show(
        context,
        'Another video is still being added',
        icon: KapyIcons.hourglassRounded,
      );
      return false;
    }
    setState(() => _videoActionBusy = true);
    return true;
  }

  void _endVideoAction() {
    if (mounted && _videoActionBusy) {
      setState(() => _videoActionBusy = false);
    }
  }

  Future<void> _ingestAndInsertVideos(
    List<XFile> files,
    BlobStore store,
  ) async {
    final count = files.length;
    final progress = Toast.showProgress(
      context,
      count == 1 ? 'Adding video…' : 'Adding $count videos…',
    );
    final attachmentMaxBytes =
        widget.videoAttachmentMaxBytes?.call() ?? freeAttachmentMaxBytes;
    try {
      final batch = widget.videoIngestor == null
          ? await ingestVideoFiles(
              files,
              store: store,
              attachmentMaxBytes: attachmentMaxBytes,
            )
          : await widget.videoIngestor!(files, store);
      if (!mounted) {
        progress.dismiss();
        return;
      }
      insertVideos(batch.videos);
      final added = batch.videos.length;
      final rejected = batch.rejections.length;
      if (added == 0) {
        final first = batch.rejections.firstOrNull;
        progress.error(
          first == null
              ? 'Could not add that video'
              : '${first.name} ${describeVideoRejection(first.reason, attachmentMaxBytes: attachmentMaxBytes)}',
        );
      } else if (rejected > 0) {
        progress.success(
          'Added $added ${added == 1 ? 'video' : 'videos'}; '
          '$rejected could not be added',
          icon: KapyIcons.warningRounded,
        );
      } else {
        progress.success(added == 1 ? 'Video added' : '$added videos added');
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while adding video files'),
        ),
      );
      progress.error(
        count == 1 ? 'Could not add that video' : 'Could not add those videos',
      );
    }
  }

  Future<void> _ingestAndInsertFiles(List<XFile> files, BlobStore store) async {
    if (widget.imageIngestor == null) {
      await _stageAndInsertFiles(files, store);
      return;
    }

    final count = files.length;
    final progress = Toast.showProgress(
      context,
      count == 1 ? 'Adding image…' : 'Adding $count images…',
    );
    try {
      final batch = await widget.imageIngestor!(files, store);
      if (!mounted) {
        progress.dismiss();
        return;
      }
      insertImages(batch.images);
      if (batch.rejections.isNotEmpty) widget.onImagesRejected?.call(batch);

      final added = batch.images.length;
      final rejected = batch.rejections.length;
      if (added == 0) {
        final first = batch.rejections.firstOrNull;
        progress.error(
          first == null
              ? 'Could not add that image'
              : '${first.name} ${describeRejection(first.reason)}',
        );
      } else if (rejected > 0) {
        progress.success(
          'Added $added ${added == 1 ? 'image' : 'images'}; '
          '$rejected could not be added',
          icon: KapyIcons.warningRounded,
        );
      } else {
        progress.success(added == 1 ? 'Image added' : '$added images added');
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while adding image files'),
        ),
      );
      progress.error(
        count == 1 ? 'Could not add that image' : 'Could not add those images',
      );
    }
  }

  /// Makes every selected image part of the editor before compression starts.
  /// The encoded bytes themselves are the temporary image source, so the user
  /// sees exactly what they picked while the durable copy is prepared.
  Future<void> _stageAndInsertFiles(List<XFile> files, BlobStore store) async {
    final staged = <({String name, StagedImage image})>[];
    final rejections = <({String name, ImageRejection reason})>[];
    for (final file in files.take(20)) {
      final result = await stageImageFile(file);
      if (!mounted) return;
      if (result.isOk) {
        final image = result.staged!;
        // This is a fast local durability write, not the expensive image
        // preparation. It makes the optimistic ref crash-safe while its
        // compressed replacement is built in the background.
        await store.put(image.source);
        if (!mounted) return;
        staged.add((name: file.name, image: image));
        // Insert each image as soon as its own header has been read. A large
        // multi-select should not make the first preview wait for the last.
        insertImages([image.ref]);
      } else {
        rejections.add((name: file.name, reason: result.rejection!));
      }
    }
    for (final file in files.skip(20)) {
      rejections.add((name: file.name, reason: ImageRejection.tooLarge));
    }

    final prepared = <NoteAttachmentRef>[];
    for (final item in staged) {
      final result = await (widget.imageFinalizer ?? _finishStagedImage)(
        item.image,
        store,
      );
      final ready = result.isOk && result.image!.ref is NoteImageRef
          ? result.image!.ref as NoteImageRef
          : await storeStagedImageAsIs(item.image, store: store);
      prepared.add(ready);
      _publishPreparedImage(item.image.ref, ready);
    }

    if (rejections.isNotEmpty) {
      final batch = ImageBatch(images: prepared, rejections: rejections);
      if (widget.onImagesRejected case final report?) {
        report(batch);
      } else if (mounted) {
        final first = rejections.first;
        Toast.show(
          context,
          '${first.name} ${describeRejection(first.reason)}',
          icon: KapyIcons.errorOutlined,
        );
      }
    }
  }

  void _publishPreparedImage(NoteImageRef staged, NoteImageRef prepared) {
    final publish = widget.onImagePrepared;
    if (publish != null) {
      publish(staged, prepared);
      return;
    }
    if (!mounted) return;
    var changed = false;
    final updated = [
      for (final current in _attachments)
        if (!changed &&
            current is NoteImageRef &&
            current.hash == staged.hash &&
            listEquals(current.key, staged.key))
          (() {
            changed = true;
            return prepared.copyWith(
              offset: current.offset,
              widthFactor: current.widthFactor,
            );
          })()
        else
          current,
    ];
    if (!changed) return;
    setState(() => _attachments = updated);
    _commit(_controller.text, _formats, updated);
  }

  void _commitFormats(List<NoteFormatRange> formats) {
    if (widget.readOnly) return;
    _formats = formats;
    _controller.formats = formats;
    setState(() {});
    _commit(_controller.text, formats, _attachments);
  }

  void _toggleBullets() {
    if (widget.readOnly) return;
    if (widget.markdownEnabled) {
      _applyMarkdownEdit(
        toggleMarkdownLineStyle(_controller.value, NoteLineStyle.bullet),
      );
      return;
    }
    ContextMenuController.removeAny();
    _typingOverrides.clear();
    _nextInsertedFormats = const {};
    _controller.value = toggleLineStyle(
      _controller.value,
      NoteLineStyle.bullet,
    );
    _focusNode.requestFocus();
  }

  void _toggleChecklist() {
    if (widget.readOnly) return;
    if (widget.markdownEnabled) {
      _applyMarkdownEdit(
        toggleMarkdownLineStyle(_controller.value, NoteLineStyle.checklist),
      );
      return;
    }
    ContextMenuController.removeAny();
    _typingOverrides.clear();
    _nextInsertedFormats = const {};
    _controller.value = toggleLineStyle(
      _controller.value,
      NoteLineStyle.checklist,
    );
    _focusNode.requestFocus();
  }

  void _indentList({required bool outdent}) {
    if (widget.readOnly) return;
    if (_indentsAsMarkdown) {
      _applyMarkdownEdit(
        indentMarkdownSelection(_controller.value, outdent: outdent),
      );
      return;
    }
    ContextMenuController.removeAny();
    _nextInsertedFormats = const {};
    _controller.value = indentSelection(_controller.value, outdent: outdent);
    _focusNode.requestFocus();
  }

  Set<SlashCommandType> get _availableSlashCommands => {
    SlashCommandType.checklist,
    SlashCommandType.bulletedList,
    if (widget.images != null && widget.cameraAcquirer != null)
      SlashCommandType.camera,
    if (widget.images != null && !_imageActionBusy) SlashCommandType.image,
    if (widget.onRecordVoice != null && !widget.voiceActionBusy)
      SlashCommandType.voiceNote,
    SlashCommandType.table,
    SlashCommandType.divider,
    if (widget.images != null && !_videoActionBusy) SlashCommandType.video,
    if (widget.images != null && !_fileActionBusy) SlashCommandType.file,
    SlashCommandType.numberedList,
    SlashCommandType.heading1,
    SlashCommandType.heading2,
    SlashCommandType.heading3,
    SlashCommandType.formula,
    SlashCommandType.quote,
    SlashCommandType.codeBlock,
  };

  void _scheduleSlashCommandMenuSync() {
    if (_slashMenuSyncScheduled) return;
    _slashMenuSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _slashMenuSyncScheduled = false;
      if (mounted) _syncSlashCommandMenu();
    });
  }

  void _syncSlashCommandMenu() {
    if (widget.readOnly ||
        (!_focusNode.hasFocus && !_slashCommandMenu.searching)) {
      _manualSlashMenuValue = null;
      _slashCommandMenu.hide();
      return;
    }

    // Keep a manually opened mobile menu only while the editor value is
    // exactly where it opened; the first edit or caret move dismisses it.
    if (_slashCommandMenu.isVisible &&
        !_slashCommandWasTyped &&
        _manualSlashMenuValue == _controller.value) {
      return;
    }
    _manualSlashMenuValue = null;

    final invocation = slashCommandInvocation(_controller.value);
    final dismissed = _dismissedSlashStart;
    if (dismissed != null &&
        (dismissed >= _controller.text.length ||
            _controller.text.codeUnitAt(dismissed) != 0x2F ||
            invocation?.range.start != dismissed)) {
      _dismissedSlashStart = null;
    }
    if (invocation == null || invocation.range.start == dismissed) {
      _slashCommandMenu.hide();
      return;
    }

    final anchor = _slashAnchorAt(invocation.range.end);
    if (anchor == null) {
      _slashCommandMenu.hide();
      return;
    }
    _slashCommandRange = invocation.range;
    _slashCommandWasTyped = true;
    _manualSlashMenuValue = null;
    _showSlashCommandMenu(anchor: anchor, query: invocation.query);
  }

  Rect? _slashAnchorAt(int offset) {
    final field = _field;
    final box = field?.box;
    final caret = field?.caretRectAt(
      TextPosition(offset: offset.clamp(0, _controller.text.length)),
    );
    if (box == null || caret == null) return null;
    return Rect.fromPoints(
      box.localToGlobal(caret.topLeft),
      box.localToGlobal(caret.bottomRight),
    );
  }

  void _showSlashCommandMenu({
    required Rect anchor,
    required String query,
    bool search = false,
  }) {
    ContextMenuController.removeAny();
    LinkPopover.hide();
    _clearKeywordTooltip();
    _slashCommandMenu.show(
      context,
      anchor: anchor,
      query: query,
      available: _availableSlashCommands,
      markdownEnabled: widget.markdownEnabled,
      hints: {
        for (final (command, action) in const [
          (SlashCommandType.camera, ShortcutAction.openCamera),
          (SlashCommandType.image, ShortcutAction.insertImage),
          (SlashCommandType.voiceNote, ShortcutAction.recordVoiceNote),
          (SlashCommandType.video, ShortcutAction.insertVideo),
          (SlashCommandType.file, ShortcutAction.insertFile),
        ])
          if (widget.shortcuts.hintFor(action) case final binding?)
            command: binding.displayLabel,
      },
      lastCommand: widget.lastSlashCommand,
      search: search,
      onSelected: (choice) {
        widget.onSlashCommandChosen?.call(choice.type);
        unawaited(_runSlashCommand(choice));
      },
      onDismissed: _slashCommandMenuDismissed,
    );
  }

  /// The touch footer's `/` opens the same menu without putting a slash in
  /// the note. A tap-opened popup gives the screen to its choices, so it puts
  /// the software keyboard away until a choice returns to the editor.
  void _showInsertMenu({bool search = false}) {
    if (widget.readOnly) return;
    _dismissedSlashStart = null;
    _manualSlashMenuValue = null;
    final selection = _controller.selection;
    final caret = selection.isValid
        ? selection.extentOffset
        : _controller.text.length;
    if (AppPlatform.isMobile) _dismissKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.readOnly) return;
      final anchor = _slashAnchorAt(caret);
      if (anchor == null) return;
      _slashCommandRange = TextRange.collapsed(caret);
      _slashCommandWasTyped = false;
      _manualSlashMenuValue = _controller.value;
      _showSlashCommandMenu(anchor: anchor, query: '', search: search);
    });
    // Off a phone nothing else changes, so nothing else would bring the
    // frame the menu waits for.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _slashCommandMenuDismissed(bool userInitiated) {
    if (userInitiated && _slashCommandWasTyped) {
      _dismissedSlashStart = _slashCommandRange?.start;
    }
    // Closing the menu the "+" opened gives the keyboard back to the note.
    if (userInitiated && !_slashCommandWasTyped && !AppPlatform.isMobile) {
      _focusNode.requestFocus();
    }
    _slashCommandRange = null;
    _slashCommandWasTyped = false;
    _manualSlashMenuValue = null;
  }

  /// A table is not here: it draws as a grid whatever the setting says, so
  /// inserting one has nothing to ask about.
  static bool _requiresMarkdown(SlashCommandType command) => switch (command) {
    SlashCommandType.numberedList ||
    SlashCommandType.quote ||
    SlashCommandType.divider ||
    SlashCommandType.codeBlock ||
    SlashCommandType.heading3 ||
    SlashCommandType.formula => true,
    _ => false,
  };

  static String _markdownFeatureName(SlashCommandType command) =>
      switch (command) {
        SlashCommandType.table => 'Tables',
        SlashCommandType.numberedList => 'Numbered lists',
        SlashCommandType.quote => 'Quotes',
        SlashCommandType.divider => 'Dividers',
        SlashCommandType.codeBlock => 'Code blocks',
        SlashCommandType.heading3 => 'Third-level headings',
        SlashCommandType.formula => 'Formulas',
        _ => 'This command',
      };

  Future<bool> _confirmMarkdown(String feature) async {
    final canEnable = widget.onMarkdownEnabledChanged != null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn on Markdown?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Text(
            '$feature use Markdown. Turning it on '
            'changes how Markdown syntax is displayed in every note. Your '
            'text stays unchanged.',
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: context.palette.textPrimary,
              height: 1.4,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('enable-markdown-command'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(canEnable ? 'Turn on and continue' : 'Open Settings'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return false;
    if (!canEnable) {
      widget.onSettingsPressed();
      return false;
    }
    widget.onMarkdownEnabledChanged!(true);
    return true;
  }

  Future<void> _runSlashCommand(SlashCommandChoice choice) async {
    final range = _slashCommandRange;
    final typed = _slashCommandWasTyped;
    final source = _controller.text;
    _slashCommandRange = null;
    _slashCommandWasTyped = false;
    _manualSlashMenuValue = null;
    if (!AppPlatform.isMobile) _focusNode.requestFocus();
    if (range == null ||
        !range.isValid ||
        range.start < 0 ||
        range.end > source.length) {
      return;
    }

    var markdown = widget.markdownEnabled;
    if (_requiresMarkdown(choice.type) && !markdown) {
      markdown = await _confirmMarkdown(_markdownFeatureName(choice.type));
      if (!markdown || !mounted) {
        if (typed) _dismissedSlashStart = range.start;
        return;
      }
    }
    // A modal confirmation temporarily releases focus, but it cannot reserve
    // offsets against a concurrent remote edit. Refuse to write into a source
    // that moved while the question was open.
    if (_controller.text != source || range.end > _controller.text.length) {
      return;
    }
    if (typed &&
        !_controller.text.substring(range.start, range.end).startsWith('/')) {
      return;
    }

    switch (choice.type) {
      case SlashCommandType.table:
        final table = markdownTableTemplate(
          rows: choice.tableRows ?? 2,
          columns: choice.tableColumns ?? 2,
        );
        final firstHeader = table.indexOf('Column 1');
        final inserted = replaceWithSlashCommandBlock(
          _controller.value,
          range,
          table,
          selectionInBlock: TextSelection(
            baseOffset: firstHeader,
            extentOffset: firstHeader + 'Column 1'.length,
          ),
        );
        _replaceCommandValue(inserted);
        _openNewTable(inserted.selection.baseOffset);
        break;
      case SlashCommandType.checklist:
        if (typed) {
          _replaceCommandValue(
            replaceSlashCommandRange(
              _controller.value,
              range,
              markdown ? '- [ ] ' : uncheckedPrefix,
            ),
          );
        } else if (!_lineStyleActive(NoteLineStyle.checklist)) {
          _toggleChecklist();
        }
        break;
      case SlashCommandType.bulletedList:
        if (typed) {
          _replaceCommandValue(
            replaceSlashCommandRange(
              _controller.value,
              range,
              markdown ? '- ' : bulletPrefix,
            ),
          );
        } else if (!_lineStyleActive(NoteLineStyle.bullet)) {
          _toggleBullets();
        }
        break;
      case SlashCommandType.numberedList:
        if (typed) {
          _replaceCommandValue(
            replaceSlashCommandRange(_controller.value, range, '1. '),
          );
        } else {
          _applyOrderedListAtCaret();
        }
        break;
      case SlashCommandType.quote:
        if (typed) {
          _replaceCommandValue(
            replaceSlashCommandRange(_controller.value, range, '> '),
          );
        } else {
          _applyQuoteAtCaret();
        }
        break;
      case SlashCommandType.divider:
        _replaceCommandValue(
          replaceWithSlashCommandBlock(_controller.value, range, '---\n'),
        );
        break;
      case SlashCommandType.codeBlock:
        _replaceCommandValue(
          replaceWithSlashCommandBlock(
            _controller.value,
            range,
            '```\n\n```',
            selectionInBlock: const TextSelection.collapsed(offset: 4),
          ),
        );
        break;
      case SlashCommandType.camera:
        if (typed) _consumeSlashCommand(range);
        await openCameraAndInsert();
        break;
      case SlashCommandType.image:
        if (typed) _consumeSlashCommand(range);
        await pickAndInsertImages();
        break;
      case SlashCommandType.video:
        if (typed) _consumeSlashCommand(range);
        await pickAndInsertVideos();
        break;
      case SlashCommandType.file:
        if (typed) _consumeSlashCommand(range);
        await pickAndInsertFileAttachments();
        break;
      case SlashCommandType.voiceNote:
        if (typed) _consumeSlashCommand(range);
        widget.onRecordVoice?.call();
        break;
      case SlashCommandType.formula:
        _replaceCommandValue(
          replaceWithSlashCommandBlock(
            _controller.value,
            range,
            '\$\$\n\n\$\$',
            selectionInBlock: const TextSelection.collapsed(offset: 3),
          ),
        );
        break;
      case SlashCommandType.heading1 ||
          SlashCommandType.heading2 ||
          SlashCommandType.heading3:
        if (typed) _consumeSlashCommand(range);
        final level = switch (choice.type) {
          SlashCommandType.heading1 => 1,
          SlashCommandType.heading2 => 2,
          _ => 3,
        };
        if (markdown) {
          _applyMarkdownEdit(applyMarkdownHeading(_controller.value, level));
        } else {
          _applyParagraphStyle(
            level == 1
                ? NoteParagraphStyle.heading
                : NoteParagraphStyle.subtitle,
          );
        }
        break;
    }
  }

  void _consumeSlashCommand(TextRange range) {
    _replaceCommandValue(
      replaceSlashCommandRange(_controller.value, range, ''),
    );
  }

  void _replaceCommandValue(TextEditingValue value) {
    if (widget.readOnly || value == _controller.value) return;
    _nextInsertedFormats = const {};
    final field = _field;
    if (field == null) {
      _controller.value = value;
    } else {
      field.userUpdateTextEditingValue(value, SelectionChangedCause.toolbar);
    }
    _focusNode.requestFocus();
  }

  TextSelection _selectionAfterReplacement(
    TextSelection selection,
    TextRange range,
    int replacementLength,
  ) {
    int map(int offset) {
      if (offset <= range.start) return offset;
      if (offset <= range.end) return range.start + replacementLength;
      return offset + replacementLength - (range.end - range.start);
    }

    return TextSelection(
      baseOffset: map(selection.baseOffset),
      extentOffset: map(selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  void _applyOrderedListAtCaret() {
    final value = _controller.value;
    if (!value.selection.isValid) return;
    final line = markdownLinePrefix(value.text, value.selection.extentOffset);
    if (line.isOrdered) return;
    final range = line.isListItem
        ? TextRange(start: line.markerStart, end: line.contentStart)
        : TextRange.collapsed(line.contentStart);
    const marker = '1. ';
    _replaceCommandValue(
      replaceSlashCommandRange(
        value,
        range,
        marker,
        selection: _selectionAfterReplacement(
          value.selection,
          range,
          marker.length,
        ),
      ),
    );
  }

  void _applyQuoteAtCaret() {
    final value = _controller.value;
    if (!value.selection.isValid) return;
    final line = markdownLinePrefix(value.text, value.selection.extentOffset);
    if (line.isQuoted) return;
    final range = TextRange.collapsed(line.indentEnd);
    const marker = '> ';
    _replaceCommandValue(
      replaceSlashCommandRange(
        value,
        range,
        marker,
        selection: _selectionAfterReplacement(
          value.selection,
          range,
          marker.length,
        ),
      ),
    );
  }

  /// Opens the bar that finds words in this note, or takes the keyboard back
  /// to it, with its words selected to type over. Words selected on one line
  /// of the note are the ones it looks for. Desktop only.
  void openFind() {
    if (!AppPlatform.isDesktop) return;
    TypeAhead.hold();
    final find = _find ??= NoteFind()..query.addListener(_onFindChanged);
    final selection = _controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      final words = selection.textInside(_controller.text);
      if (!words.contains('\n')) find.query.text = words;
    }
    find.query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: find.query.text.length,
    );
    if (!_findOpen) {
      setState(() => _findOpen = true);
      _refreshFind(find);
      _revealFound();
    }
    find.field.requestFocus();
  }

  void _onFindChanged() {
    final find = _find;
    if (find == null || !_findOpen) return;
    final shown = find.currentMatch;
    if (!_refreshFind(find)) return;
    setState(() {});
    if (find.currentMatch != shown) _revealFound();
  }

  /// Finds the bar's words in the note as it shows now: see
  /// [NoteFind.refresh].
  bool _refreshFind(NoteFind find) {
    final selection = _controller.selection;
    return find.refresh(
      _controller.markdownFor(_controller.text),
      _controller.hiddenIn(_controller.text),
      from: selection.isValid ? selection.start : 0,
    );
  }

  void _stepFind({bool back = false}) {
    final find = _find;
    if (find == null || !_findOpen || find.matches.isEmpty) return;
    setState(() => find.step(back: back));
    _revealFound();
  }

  /// F3 steps through the matches from the note as well as from the bar, and
  /// ⌘G on a Mac, where F3 is the system's. Shift steps back.
  KeyEventResult _findKey(FocusNode node, KeyEvent event) {
    if (!_findOpen) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    for (final (activator, back) in [
      (const SingleActivator(LogicalKeyboardKey.f3), false),
      (const SingleActivator(LogicalKeyboardKey.f3, shift: true), true),
      if (AppPlatform.isMacOS) ...[
        (const SingleActivator(LogicalKeyboardKey.keyG, meta: true), false),
        (
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            meta: true,
            shift: true,
          ),
          true,
        ),
      ],
    ]) {
      if (!activator.accepts(event, keyboard)) continue;
      _stepFind(back: back);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Closes the find bar, with the match it was on selected in the note and
  /// the keyboard back in the note.
  void _closeFind() {
    if (!_findOpen) return;
    final match = _find?.currentMatch;
    setState(() => _findOpen = false);
    if (match != null) {
      _controller.selection = TextSelection(
        baseOffset: match.start,
        extentOffset: match.end,
      );
    }
    _focusNode.requestFocus();
  }

  /// Scrolls the match the find is on to the middle of the note, unless it
  /// shows already, and again on the frame after while the lines measured
  /// on the way move it. Folded details that hold it unfold first.
  void _revealFound([int attempts = 3]) {
    final match = _find?.currentMatch;
    if (match == null || attempts == 0) return;
    _openFoldAt(match.start);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_findOpen || _find?.currentMatch != match) return;
      final rect = _field?.caretRectAt(TextPosition(offset: match.start));
      if (rect == null || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final view = position.viewportDimension;
      if (rect.top >= 0 && rect.bottom <= view) return;
      final target = clampDouble(
        position.pixels + rect.center.dy - view / 2,
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 1) return;
      _scrollController.jumpTo(target);
      _revealFound(attempts - 1);
    });
  }

  /// What the find found, for the field to fill, while its bar is open: the
  /// match it is on as the selection is filled, which is what esc leaves of
  /// it, and the rest in clay.
  NoteFound? _found() {
    final find = _find;
    if (!_findOpen || find == null || find.matches.isEmpty) return null;
    final palette = context.palette;
    return (
      ranges: find.matches,
      current: find.current,
      color: palette.clay.withValues(alpha: 0.2),
      currentColor:
          DefaultSelectionStyle.of(context).selectionColor ?? palette.selection,
    );
  }

  /// Any key at all dismisses the link panel first. Escape is the one people
  /// reach for, but a panel that outlives the caret it was raised next to is
  /// wrong whichever key moved it.
  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
    if (_handleTableSelectionKey(event)) return KeyEventResult.handled;
    if (_slashCommandMenu.handleKeyEvent(event) ||
        _selectionBubble.handleKeyEvent(event)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) _rightClicked = false;
    // Link is only bound while words are selected; everywhere else its keys
    // are left for whatever else wants them.
    final selection = _controller.selection;
    if (event is KeyDownEvent &&
        !widget.readOnly &&
        selection.isValid &&
        !selection.isCollapsed &&
        (widget.shortcuts
                .bindingFor(ShortcutAction.formatLink)
                ?.activator
                .accepts(event, HardwareKeyboard.instance) ??
            false)) {
      unawaited(_startLink());
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      LinkPopover.hide();
      _clearKeywordTooltip();
      _recordKapyPeekActivity();
    }
    return _handleTabIndent(node, event);
  }

  Future<void> _loadFolds() async {
    final folds = await TaskFolds.open();
    if (!mounted) return;
    setState(() => _folds = folds);
  }

  void _usedDetails() {
    final folds = _folds;
    if (folds == null || folds.hintSeen) return;
    folds.markHintSeen();
    setState(() {});
  }

  String _foldKey(String words) => wordsDigest(words);

  String? _blockText;
  List<TaskBlock>? _blockCache;
  List<({TaskDetails details, bool folded})>? _foldedBlocks;

  List<TaskBlock> _blocks() {
    final text = _controller.text;
    if (_blockText != text || _blockCache == null) {
      _blockText = text;
      _blockCache = taskBlocks(text, attachments: _attachments);
      _foldedBlocks = null;
    }
    return _blockCache!;
  }

  /// The details blocks with whether each is folded, worked out once for the
  /// text and the folds as they are now: the layout asks per line.
  List<({TaskDetails details, bool folded})> _folded() {
    final blocks = _blocks();
    return _foldedBlocks ??= [
      for (final block in blocks)
        if (block.details != null)
          (details: block.details!, folded: _taskFolded(block.task)),
    ];
  }

  bool _taskFolded(TaskLine task) {
    final folds = _folds;
    final words = _controller.text.substring(task.textStart, task.end).trim();
    if (folds == null) return task.done;
    return folds.isFolded(widget.noteId, _foldKey(words), done: task.done);
  }

  bool get _caretInTask {
    final selection = _controller.selection;
    if (!selection.isValid) return false;
    final line = markdownLinePrefix(_controller.text, selection.extentOffset);
    return line.isTask &&
        selection.extentOffset >= line.contentStart &&
        _controller.text
            .substring(line.contentStart, line.lineEnd)
            .trim()
            .isNotEmpty;
  }

  void _dropIntoDetails() {
    final dropped = shiftEnterDetails(_controller.value);
    if (dropped == null) return;
    _controller.value = dropped;
    _usedDetails();
    _focusNode.requestFocus();
  }

  void _openFoldUnderCaret() {
    final selection = _controller.selection;
    if (selection.isValid) _openFoldAt(selection.extentOffset);
  }

  /// Unfolds the task details that hold [offset], if they are folded.
  void _openFoldAt(int offset) {
    final folds = _folds;
    if (folds == null) return;
    final text = _controller.text;
    final at = offset.clamp(0, text.length);
    for (final block in _blocks()) {
      final details = block.details;
      if (details == null || !_taskFolded(block.task)) continue;
      if (at < details.start || at > details.end) continue;
      final words = text.substring(block.task.textStart, block.task.end).trim();
      folds.setFolded(widget.noteId, _foldKey(words), folded: false);
      _foldedBlocks = null;
      setState(() {});
      return;
    }
  }

  void _toggleFold(TaskLine task) {
    final folds = _folds;
    if (folds == null) return;
    final words = _controller.text.substring(task.textStart, task.end).trim();
    folds.setFolded(widget.noteId, _foldKey(words), folded: !_taskFolded(task));
    _foldedBlocks = null;
    setState(() {});
  }

  /// Hides a folded task's details, leaving the first of those lines as a
  /// quiet row the preview is drawn on. The note's text is not touched.
  LineSpan _adjustTaskFold(int start, int end, LineSpan span) {
    if (start >= _controller.text.length) return span;
    final where = foldedLineFor(start, _folded());
    if (where == FoldedLine.keep) return span;
    if (where == FoldedLine.hidden) {
      return (
        span: span.span,
        placeholders: span.placeholders,
        folded: true,
        row: span.row,
        inset: span.inset,
        hang: span.hang,
      );
    }
    return (
      span: const TextSpan(text: ''),
      placeholders: const <PlaceholderDimensions>[],
      folded: false,
      row: EditorMetrics.page ? 22 : 44,
      inset: span.inset,
      hang: 0,
    );
  }

  /// Tab nests the current item, Shift+Tab lifts it out.
  ///
  /// Only claimed when the caret is actually on a list line. Everywhere else
  /// Tab is left to move focus, which is the only way to leave the editor from
  /// the keyboard.
  KeyEventResult _handleTabIndent(FocusNode node, KeyEvent event) {
    if (widget.readOnly) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    // Shift is the only modifier this owns. Anything else means the Tab
    // belongs to a shortcut passing through on its way up — Ctrl+Tab walks to
    // the next note — and claiming it here would silently nest a list item
    // instead, on exactly the lines where indenting is possible.
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (!_focusNode.hasFocus) return KeyEventResult.ignored;
    final pressed = keyboard.logicalKeysPressed;
    final outdent =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    if (_indentCode(outdent: outdent)) return KeyEventResult.handled;
    final attached = tabTaskDetails(_controller.value, detach: outdent);
    if (attached != null) {
      _controller.value = attached;
      _usedDetails();
      return KeyEventResult.handled;
    }
    if (!_showIndentControls) return KeyEventResult.ignored;
    // Claim the key even at the ends of the range, or Tab would silently fall
    // through to focus traversal exactly when the list stops moving.
    if (_canIndent(outdent: outdent)) {
      _indentList(outdent: outdent);
    }
    return KeyEventResult.handled;
  }

  /// Tab inside a fenced code block puts two spaces in, or at the start of
  /// each selected line, and Shift+Tab takes them back: the fences themselves
  /// are left alone. Says whether the caret was in a block's code.
  bool _indentCode({required bool outdent}) {
    final value = _controller.value;
    final selection = value.selection;
    if (!widget.markdownEnabled || !selection.isValid) return false;
    final analysis = _controller.markdownFor(value.text);
    for (final block in analysis.blocks) {
      final fences = analysis.fencesOf(block);
      if (fences == null) continue;
      final code = TextRange(
        start: fences.open.end + 1,
        end: fences.close == null ? block.end : fences.close!.start - 1,
      );
      if (code.end < code.start ||
          selection.start < code.start ||
          selection.end > code.end) {
        continue;
      }
      var text = value.text;
      var start = selection.start;
      var end = selection.end;
      if (selection.isCollapsed && !outdent) {
        text = text.replaceRange(start, start, '  ');
        start = end = start + 2;
      } else {
        final last = end > start && text.codeUnitAt(end - 1) == 0x0A
            ? end - 1
            : end;
        final lineStarts = <int>[];
        var at = text.lastIndexOf('\n', start - 1) + 1;
        while (at <= last) {
          lineStarts.add(at);
          final next = text.indexOf('\n', at);
          if (next < 0) break;
          at = next + 1;
        }
        for (final at in lineStarts.reversed) {
          final removed = outdent
              ? RegExp(r'^ {0,2}').stringMatch(text.substring(at))!.length
              : 0;
          final shift = outdent ? -removed : 2;
          text = outdent
              ? text.replaceRange(at, at + removed, '')
              : text.replaceRange(at, at, '  ');
          if (start > at) start = math.max(at, start + shift);
          if (end > at) end = math.max(at, end + shift);
        }
      }
      _nextInsertedFormats = const {};
      _controller.value = value.copyWith(
        text: text,
        selection: TextSelection(baseOffset: start, extentOffset: end),
      );
      return true;
    }
    return false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_tableControls.claims(event.position)) _tableControls.selected = null;
    _clearKeywordTooltip();
    _recordKapyPeekActivity();
    _selectionBubble.hide();
    _rightClicked = event.buttons & kSecondaryButton != 0;
    if (_rightClicked) {
      // The table controls open the table's menu for a right-click on its
      // grid.
      if (_tableFrames().any((frame) => frame.grid.contains(event.position))) {
        return;
      }
      _caretForSecondaryTapOnMisspelling(event.position);
    }
    _prefetchCorrectionsAt(event.position);
    // A new press is a new gesture — a second tap, a drag, a scroll — and
    // whatever the last tap was about to offer is no longer the question.
    _pasteOfferTimer?.cancel();
    final touch =
        event.kind == PointerDeviceKind.touch && !AppPlatform.hasPointer;
    _pointerDownDetails[event.pointer] = _PointerDownDetails(
      position: event.position,
      timeStamp: event.timeStamp,
      wasPrimary: event.buttons & kPrimaryButton != 0,
      wasTouch: touch,
      menuWasOpen: touch && _editMenus > 0,
      selection: _controller.selection,
      text: _controller.text,
    );
    _stillPress = event.pointer;
  }

  /// A press that moves as far as the field's own drag threshold is a drag,
  /// and whatever it selects was meant.
  ///
  /// This listener hears a move before the field's gesture recognizers do —
  /// they are fed by the pointer router, after the hit-test path — so the
  /// mark is gone before the drag's first selection lands.
  void _handlePointerMove(PointerMoveEvent event) {
    if (_stillPress != event.pointer) return;
    final down = _pointerDownDetails[event.pointer];
    if (down == null ||
        (event.position - down.position).distance >
            computeHitSlop(event.kind, null)) {
      _stillPress = null;
    }
  }

  void _releaseStillPress(int pointer) {
    if (_stillPress != pointer) return;
    // A quick double click is often only settled once the press is up, by
    // the gesture arena sweeping after this listener has heard it lift — so
    // the mark outlasts the event.
    scheduleMicrotask(() {
      if (_stillPress == pointer) _stillPress = null;
    });
  }

  /// A click below everything the note has been written into: the caret goes
  /// to the end of the note, where the field's own tap puts it (see
  /// [NoteFieldState.positionAt]), and nothing is written.
  ///
  /// Unless the note ends in something with no line of words to type on: a
  /// picture or another attachment, a table, a code or formula block, or a
  /// divider. A caret at its end is drawn inside the block, so one empty line
  /// opens under it, the line a Return there would have made. Only the one:
  /// the next click below lands on it.
  ///
  /// Returns whether the click was in that empty region, in which case there
  /// is nothing below it to be a checkbox, a link or a calculator word.
  bool _clickedBelowWriting(NoteFieldState field, Offset globalPosition) {
    if (widget.readOnly) return false;
    final box = field.box;
    final end = field.lineTop(field.lines.length);
    if (box == null || end == null) return false;
    if (globalPosition.dy <= box.localToGlobal(Offset(0, end)).dy) return false;
    final text = _controller.text;
    if (_endsInBlock(text)) {
      _controller.value = TextEditingValue(
        text: '$text\n',
        selection: TextSelection.collapsed(offset: text.length + 1),
      );
    }
    return true;
  }

  /// Whether [text]'s last line is a block rather than a line of words.
  bool _endsInBlock(String text) {
    final lastLine = text.lastIndexOf('\n') + 1;
    if (lastLine == text.length) return false;
    if (text.contains(NoteAttachmentRef.placeholder, lastLine)) return true;
    if (!widget.markdownEnabled) return false;
    final markdown = _controller.markdownFor(text);
    bool endsOn(int start, int end) => start <= lastLine && end >= text.length;
    if (markdown.tables.any((table) => endsOn(table.start, table.end)) ||
        markdown.maths.any(
          (math) => math.display && endsOn(math.start, math.end),
        )) {
      return true;
    }
    return markdown.blocks.any((block) {
      if (block.kind == MarkdownBlockKind.rule) {
        return endsOn(block.start, block.end);
      }
      final close = markdown.fencesOf(block)?.close;
      return close != null && endsOn(close.start, close.end);
    });
  }

  /// Moves the caret into the misspelling a right-click landed on.
  ///
  /// Windows and Linux leave the caret alone when the menu opens, so without
  /// this the corrections offered are for whatever word the caret was resting
  /// on, not the underlined one the pointer is over. macOS selects the word
  /// itself, and the selection toolbar answers for it there.
  ///
  /// Only when nothing is selected: a right-click inside a selection is about
  /// that selection, and taking it away would be the menu editing the note.
  void _caretForSecondaryTapOnMisspelling(Offset position) {
    if (widget.readOnly ||
        AppPlatform.isMacOS ||
        AppPlatform.isIOS ||
        _controller.spellingSuggestions.isEmpty) {
      return;
    }
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return;
    final field = _field;
    if (field == null || field.box == null) return;

    final offset = field.positionAt(position).offset;
    if (offset == selection.baseOffset) return;
    final onMisspelling = _controller.spellingSuggestions.any(
      (suggestion) =>
          offset >= suggestion.range.start && offset <= suggestion.range.end,
    );
    if (!onMisspelling) return;
    _focusNode.requestFocus();
    _controller.selection = TextSelection.collapsed(offset: offset);
  }

  /// Asks for the corrections of the misspelling under a press.
  ///
  /// A right-click shows its menu on the way back up, and a press-and-hold
  /// half a second later, so the answer is there before the menu is built.
  /// Nothing is asked for while somebody is only typing.
  void _prefetchCorrectionsAt(Offset position) {
    if (_controller.spellingSuggestions.isEmpty) return;
    final field = _field;
    if (field == null || field.box == null) return;
    final offset = field.positionAt(position).offset;
    for (final suggestion in _controller.spellingSuggestions) {
      if (offset >= suggestion.range.start && offset <= suggestion.range.end) {
        _correctionsFor(suggestion);
        return;
      }
    }
  }

  /// The corrections to offer for a misspelling, as far as they are known.
  ///
  /// Android and iOS send them with the spans. On desktop the first ask starts
  /// a lookup and comes back empty; [_correctionsArrived] rebuilds the menu
  /// when it lands, which is only ever visible if the press did not prefetch.
  List<String> _correctionsFor(SuggestionSpan misspelling) {
    if (misspelling.suggestions.isNotEmpty) return misspelling.suggestions;
    final range = misspelling.range;
    final text = _controller.text;
    if (range.end > text.length) return const [];
    final locale = _spellCheckLocale;
    if (locale == null) return const [];
    final word = text.substring(range.start, range.end);
    final known = _spellCheckService.cachedSuggestionsFor(locale, word);
    if (known != null) return known;
    unawaited(
      _spellCheckService.suggestionsFor(locale, text, range).then((
        suggestions,
      ) {
        if (!mounted || suggestions.isEmpty) return;
        _correctionsArrived.value++;
      }),
    );
    return const [];
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerDownDetails.remove(event.pointer);
    if (_stillPress == event.pointer) _stillPress = null;
  }

  /// What the editor claims about itself under the pointer. An I-beam over
  /// text, a hand over a checkbox or a link.
  static const MouseCursor _textCursor = SystemMouseCursors.text;
  MouseCursor _hoverCursor = _textCursor;

  void _handlePointerUp(PointerUpEvent event) {
    final down = _pointerDownDetails.remove(event.pointer);
    _releaseStillPress(event.pointer);
    if (down == null ||
        !down.wasPrimary ||
        event.timeStamp - down.timeStamp >= kLongPressTimeout ||
        (event.position - down.position).distance > kTouchSlop) {
      return;
    }
    final field = _field;
    if (field == null || field.box == null) return;
    // A press on a table's grip or "+" is the control's, not the note's.
    if (_tableControls.claims(down.position)) return;

    if (_clickedBelowWriting(field, event.position)) {
      _offerPasteAfterTap(down);
      return;
    }

    final offset = field.positionAt(event.position).offset;
    final pressed = down.selection;
    final length = _controller.text.length;
    final unmoved = !pressed.isValid
        ? _controller.value
        : _controller.value.copyWith(
            selection: down.text == _controller.text
                ? pressed
                : TextSelection(
                    baseOffset: math.min(pressed.baseOffset, length),
                    extentOffset: math.min(pressed.extentOffset, length),
                  ),
          );
    final task = _markdownTaskAt(field, event.position, offset);
    if (!widget.readOnly && task != null) {
      _nextInsertedFormats = const {};
      _controller.value = toggleMarkdownTask(unmoved, task.box);
      _focusNode.requestFocus();
      if (!task.checked) _celebrateCheck(field, event.position);
      return;
    }
    final checkboxStart = _checkboxAt(field, event.position, offset);
    if (!widget.readOnly && checkboxStart >= 0) {
      _nextInsertedFormats = const {};
      final wasUnchecked = _controller.text.startsWith(
        uncheckedPrefix,
        checkboxStart,
      );
      _controller.value = toggleCheckboxAt(unmoved, checkboxStart);
      _focusNode.requestFocus();
      // Only on the way in. Unticking something is a correction, and a
      // correction that throws confetti is mocking you.
      if (wasUnchecked) _celebrateCheck(field, event.position);
      return;
    }

    // Before links: a link inside a cell is reached by editing the cell, not
    // instead of it.
    if (_openTableCellAt(field, event.position, offset)) return;

    final hit = _linkAtPoint(field, event.position, offset);
    if (hit != null) {
      // The shortcut stays: someone who already knows it should not be made to
      // read a panel first.
      if (_isDirectOpenShortcut()) {
        unawaited(_openLink(hit.link));
        return;
      }
      _showLinkPopover(hit);
      return;
    }
    final keyword = _keywordAtPoint(field, event.position, offset);
    if (keyword != null) {
      _showKeywordTooltip(keyword);
      return;
    }
    _offerPasteAfterTap(down);
  }

  /// Offers Paste after a plain tap on a phone, when there is something to
  /// paste.
  ///
  /// Neither platform does on its own. Android hides its menu on every tap,
  /// and iOS opens one only for a second tap landing exactly on the caret, so
  /// Paste was a press-and-hold nobody finds. Only a tap that did nothing
  /// else arrives here: one that ticked a box, opened a link's panel or
  /// explained a calculator word has already been answered.
  ///
  /// It waits out a double tap, which selects a word instead, and asks the
  /// clipboard before showing anything, since a menu offering Paste with
  /// nothing to paste is only in the way. A tap on the caret while the menu is
  /// open puts it away, and so does a tap that ends a selection; a tap
  /// anywhere else brings it to the new caret.
  void _offerPasteAfterTap(_PointerDownDetails down) {
    _pasteOfferTimer?.cancel();
    if (widget.readOnly || !down.wasTouch) return;
    final before = down.selection;
    if (down.menuWasOpen && before.isValid && !before.isCollapsed) return;
    final putAwayAt = down.menuWasOpen ? before : null;
    _pasteOfferTimer = Timer(
      kDoubleTapTimeout,
      () => unawaited(_showPasteOffer(putAwayAt: putAwayAt)),
    );
  }

  Future<void> _showPasteOffer({TextSelection? putAwayAt}) async {
    final field = _field;
    final caret = _controller.selection;
    if (!mounted ||
        field == null ||
        !_focusNode.hasFocus ||
        !caret.isValid ||
        !caret.isCollapsed ||
        (putAwayAt != null && caret.baseOffset == putAwayAt.baseOffset)) {
      return;
    }
    final text = _controller.text;
    await field.clipboardStatus.update();
    if (!mounted ||
        !_focusNode.hasFocus ||
        _controller.text != text ||
        _controller.selection != caret ||
        field.clipboardStatus.value != ClipboardStatus.pasteable) {
      return;
    }
    // Does nothing when the menu is already up, as it is when iOS opened its
    // own for a tap on the caret.
    field.showToolbar();
  }

  /// Ticked boxes, and every box in the note.
  ///
  /// Markdown tasks count alongside the app's own boxes: a list is finished
  /// when neither kind has anything left open. With markdown off there are
  /// none, the way the old null was: a table is all that view holds. See
  /// HighlightingController.markdownFor.
  ({int done, int total}) _checklist() {
    final text = _controller.text;
    final tasks = _controller.markdownFor(text).tasks;
    final done =
        checkedPrefix.allMatches(text).length +
        tasks.where((task) => task.checked).length;
    return (
      done: done,
      total:
          done +
          uncheckedPrefix.allMatches(text).length +
          tasks.where((task) => !task.checked).length,
    );
  }

  /// Confetti over the box just ticked, with a fuller burst for the last one.
  ///
  /// The finale is deliberately rare: a note has to have had at least two
  /// boxes and none of them can be left, so it marks finishing a list rather
  /// than ticking a single stray item.
  void _celebrateCheck(NoteFieldState field, Offset tapPosition) {
    if (!mounted) return;
    final checklist = _checklist();
    final finale = checklist.done == checklist.total && checklist.total >= 2;
    Celebrate.at(context, tapPosition);
    if (!finale) return;

    final caret = _caretGlobalCenter(field);
    if (caret != null) Celebrate.at(context, caret, finale: true);
  }

  /// Where the caret is on screen, or null if it has nowhere to be.
  Offset? _caretGlobalCenter(NoteFieldState field) {
    final selection = _controller.selection;
    if (!selection.isValid) return null;
    final rect = field.caretRectAt(
      TextPosition(
        offset: selection.extentOffset.clamp(0, _controller.text.length),
      ),
    );
    final box = field.box;
    return rect == null || box == null
        ? null
        : box.localToGlobal(rect.topCenter);
  }

  void _handleFocusChanged() {
    // A markdown note shows its syntax only while it is being edited, so
    // what is drawn changes with focus.
    if (widget.markdownEnabled && mounted) {
      _markdownTyping.clear();
      _markdownShortcut.clear();
      setState(() => _markdownQuiet = true);
    } else if (mounted && AppPlatform.isMobile) {
      setState(() {});
    }
    if (_focusNode.hasFocus) {
      widget.onFocus?.call();
      _reportDefaultTitleEntered();
      _recordKapyPeekActivity();
      _reportActivity(edited: false);
      _scheduleSlashCommandMenuSync();
      return;
    }
    // Nothing left to raise a keyboard for. A retry still in flight would
    // otherwise put one up over a note nobody is writing in.
    _keyboardRetryTimer?.cancel();
    // The menu the "+" opened holds the keyboard in its own search.
    if (!_slashCommandMenu.searching) _slashCommandMenu.hide();
    // So does the bubble's address field.
    if (!_selectionBubble.editingLink) _selectionBubble.hide();
    _kapyPeekIdleTimer?.cancel();
    _clearKeywordTooltip();
    _kapyPeekIdleTimer = null;
    _dismissKapyPeek();
  }

  /// Gives the formatting bar a deliberate way out of editing on a phone. Cancelling
  /// the startup retry matters on Android: otherwise a retry already waiting
  /// in the timer could immediately raise the keyboard again.
  void _dismissKeyboard() {
    _keyboardRetryTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  /// Lets the editor go when the soft keyboard is dismissed out from under it.
  ///
  /// Android's Back button is swallowed by the IME while the keyboard is up:
  /// it closes, and the app is told nothing except that the window grew. The
  /// field is still focused, still holds an input connection, and asks for the
  /// keyboard back at the first excuse — so the keyboard the reader just
  /// dismissed reappears, which is the whole of the complaint. iOS's own
  /// hide-keyboard key leaves the same state behind.
  ///
  /// Giving the focus up is the only thing that makes the dismissal stick, and
  /// it is what the reader asked for: they wanted out of the note, not a
  /// caret blinking under a keyboard that keeps coming back.
  ///
  /// Desktop never reaches the body of this — no soft keyboard means the inset
  /// is always zero, so [_keyboardWasUp] is never true.
  @override
  void didChangeMetrics() {
    _windowMovedSinceKeyboardRequest = true;
    final wasUp = _keyboardWasUp;
    final inset = _keyboardInset;
    final isUp = inset > 0;
    _keyboardWasUp = isUp;
    if (mounted && AppPlatform.isMobile && isUp != wasUp) setState(() {});
    // A cell opened with the keyboard down was scrolled into view before the
    // keyboard had a height; now that it has one, the cell may be under it.
    if (isUp && _editingCell != null) _ensureCellVisible();
    if (isUp) {
      _keyboardGoneTimer?.cancel();
      if (!_keyboardSettled) {
        _keyboardSettleTimer?.cancel();
        _keyboardSettleTimer = Timer(
          _keyboardSettleAfter,
          () => _keyboardSettled = true,
        );
      }
      return;
    }
    _keyboardSettleTimer?.cancel();
    final settled = _keyboardSettled;
    _keyboardSettled = false;
    if (!wasUp || !settled) return;
    if (widget.readOnly || !_editingNote) return;
    // Backgrounding the app also takes the keyboard down, and focus should
    // survive that: it is the same note, still open, when the app comes back.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _keyboardRetryTimer?.cancel();
    _keyboardGoneTimer?.cancel();
    _keyboardGoneTimer = Timer(_keyboardGoneAfter, () {
      if (!mounted || _keyboardInset > 0) return;
      if (widget.readOnly || !_editingNote) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  void _recordKapyPeekActivity() {
    _kapyPeekIdleTimer?.cancel();
    _kapyPeekIdleTimer = null;
    _dismissKapyPeek();
    if (!mounted || widget.readOnly || !_focusNode.hasFocus) return;
    _kapyPeekIdleTimer = Timer(
      NoteEditor.kapyPeekIdleDelay,
      _showKapyPeekIfStillIdle,
    );
  }

  void _showKapyPeekIfStillIdle() {
    _kapyPeekIdleTimer = null;
    if (!mounted || !_focusNode.hasFocus) return;
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return;
    final field = _field;
    if (field == null) return;
    final caret = _caretGlobalCenter(field);
    if (caret == null) return;

    late final VoidCallback? dismiss;
    dismiss = KapyCursorPeek.showAt(
      context,
      caret,
      onDismissed: () {
        if (identical(_kapyPeekDismiss, dismiss)) _kapyPeekDismiss = null;
      },
    );
    _kapyPeekDismiss = dismiss;
  }

  void _dismissKapyPeek() {
    final dismiss = _kapyPeekDismiss;
    _kapyPeekDismiss = null;
    dismiss?.call();
  }

  /// The offset of the checkbox glyph under [globalPosition], or -1.
  ///
  /// Shared by the click handler and the hover cursor deliberately: the two
  /// cannot disagree if they ask the same question, so anything that shows a
  /// hand is something a click will actually toggle.
  int _checkboxAt(NoteFieldState field, Offset globalPosition, int textOffset) {
    final start = checkboxLineStartAt(_controller.text, textOffset);
    if (start < 0) return -1;
    final boxes = _onScreen(
      field,
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    if (boxes.isEmpty) return -1;
    // A forgiving margin: the glyph is small, and a pointer a few pixels off
    // is still aiming at it.
    return boxes.first.inflate(6).contains(globalPosition) ? start : -1;
  }

  /// The boxes around the text [range] holds in [field], on the screen.
  static List<Rect> _onScreen(NoteFieldState field, TextSelection range) {
    final box = field.box;
    if (box == null) return const [];
    return [
      for (final row in field.boxesFor(range))
        box.localToGlobal(Offset(row.left, row.top)) &
            Size(row.right - row.left, row.bottom - row.top),
    ];
  }

  /// The markdown task whose `[ ]` is under [globalPosition], if any.
  ///
  /// The same question [_checkboxAt] answers for the app's own boxes, with
  /// the same forgiving margin, for the same reason: the hover cursor and the
  /// click ask it alike, so anything that shows a hand is something a click
  /// will tick.
  MarkdownTask? _markdownTaskAt(
    NoteFieldState field,
    Offset globalPosition,
    int textOffset,
  ) {
    final markdown = _controller.markdownFor(_controller.text);
    for (final task in markdown.tasks) {
      if (task.box > textOffset + 1) break;
      if (textOffset > task.box + 4) continue;
      for (final rect in _onScreen(
        field,
        TextSelection(baseOffset: task.box, extentOffset: task.box + 3),
      )) {
        if (rect.inflate(6).contains(globalPosition)) return task;
      }
    }
    return null;
  }

  /// Turns the pointer into a hand over things a click acts on, a help cursor
  /// over explained calculator words, and leaves an I-beam everywhere else.
  ///
  /// Checkboxes and links are characters inside an editable field rather than
  /// widgets, so nothing gives them a cursor for free — without this the
  /// editor claims the whole surface is text and offers no hint that any of
  /// it can be clicked.
  void _handleHover(PointerHoverEvent event) {
    if (widget.remoteCarets != null) _remoteHover.value = event.position;
    final field = _field;
    var wanted = _textCursor;
    _KeywordHit? keyword;

    if (field != null && field.box != null) {
      final offset = field.positionAt(event.position).offset;
      // Link scanning is cached against the text, so hovering re-uses the
      // spans the highlighter already built rather than re-scanning the note.
      if ((!widget.readOnly &&
              (_checkboxAt(field, event.position, offset) >= 0 ||
                  _markdownTaskAt(field, event.position, offset) != null)) ||
          _linkAtPoint(field, event.position, offset) != null) {
        wanted = SystemMouseCursors.click;
      } else {
        keyword = _keywordAtPoint(field, event.position, offset);
        if (keyword != null) wanted = SystemMouseCursors.help;
      }
    }
    _scheduleKeywordTooltip(keyword);
    // Only on a change: a rebuild per mouse-move would be a needless frame.
    if (wanted != _hoverCursor) setState(() => _hoverCursor = wanted);
  }

  void _handleHoverExit() {
    _remoteHover.value = null;
    _clearKeywordTooltip();
    if (_hoverCursor != _textCursor) {
      setState(() => _hoverCursor = _textCursor);
    }
  }

  _KeywordHit? _keywordAtPoint(
    NoteFieldState field,
    Offset globalPosition,
    int textOffset,
  ) {
    final source = _controller.text;
    for (final span in _controller.spansFor(source)) {
      if (span.kind != HighlightKind.keyword ||
          textOffset < span.start ||
          textOffset > span.end) {
        continue;
      }
      final keyword = source.substring(span.start, span.end).toLowerCase();
      final message = calcKeywordHelp[keyword];
      if (message == null) continue;
      for (final rect in _onScreen(
        field,
        TextSelection(baseOffset: span.start, extentOffset: span.end),
      )) {
        if (rect.inflate(2).contains(globalPosition)) {
          return _KeywordHit(
            id: '${span.start}:${span.end}',
            keyword: keyword,
            message: message,
            rect: rect,
          );
        }
      }
    }
    return null;
  }

  void _scheduleKeywordTooltip(_KeywordHit? hit) {
    if (hit?.id == _hoveredKeywordId) return;
    _clearKeywordTooltip();
    if (hit == null) return;
    _hoveredKeywordId = hit.id;
    _keywordHoverTimer = Timer(const Duration(milliseconds: 500), () {
      _keywordHoverTimer = null;
      if (!mounted || _hoveredKeywordId != hit.id) return;
      _showKeywordTooltip(hit);
    });
  }

  void _showKeywordTooltip(_KeywordHit hit) {
    _keywordHoverTimer?.cancel();
    _keywordHoverTimer = null;
    _hoveredKeywordId = hit.id;
    LinkPopover.hide();
    KeywordTooltip.show(
      context,
      anchor: hit.rect,
      keyword: hit.keyword,
      message: hit.message,
    );
  }

  void _clearKeywordTooltip() {
    _keywordHoverTimer?.cancel();
    _keywordHoverTimer = null;
    _hoveredKeywordId = null;
    KeywordTooltip.hide();
  }

  /// The clicked link and the rect of the line it was clicked on, in global
  /// coordinates. A link that wraps has one box per line; the panel belongs
  /// against the one under the pointer, not against the whole run.
  _LinkHit? _linkAtPoint(
    NoteFieldState field,
    Offset globalPosition,
    int textOffset,
  ) {
    final links = _controller.linksFor(_controller.text);
    for (final link in links) {
      if (textOffset < link.start || textOffset > link.end) continue;
      for (final rect in _onScreen(
        field,
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      )) {
        if (rect.inflate(2).contains(globalPosition)) {
          return _LinkHit(link: link, rect: rect);
        }
      }
    }
    return null;
  }

  /// Cmd on Apple platforms, Ctrl everywhere else: the modifier that opens a
  /// link outright, skipping the panel. Touch has no modifier to hold, so a
  /// tap raises the panel like a click does — and a tap meant to put the
  /// caret inside a URL no longer launches a browser.
  bool _isDirectOpenShortcut() => AppPlatform.isMacOS || AppPlatform.isIOS
      ? HardwareKeyboard.instance.isMetaPressed
      : HardwareKeyboard.instance.isControlPressed;

  void _showLinkPopover(_LinkHit hit) {
    _clearKeywordTooltip();
    LinkPopover.show(
      context,
      anchor: hit.rect,
      label: hit.link.text,
      onOpen: () => unawaited(_openLink(hit.link)),
      onCopy: () => unawaited(_copyLink(hit.link)),
    );
  }

  NoteLink? _linkForSelection(TextSelection selection) =>
      noteLinkForSelection(_controller.linksFor(_controller.text), selection);

  Future<void> _openLink(NoteLink link) async {
    ContextMenuController.removeAny();
    var opened = false;
    try {
      opened = await launchUrl(link.uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    Toast.show(
      context,
      'Could not open ${link.uri.host}',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  /// Copies the selection, or the whole note when nothing is selected, with
  /// the list glyphs turned into ASCII. Ordinary copy is left alone: pasting
  /// a checklist back into another note should return it unchanged, and only
  /// this action promises to leave the app cleanly.
  Future<void> _copyPlainText(TextSelection selection) async {
    ContextMenuController.removeAny();
    final text = _controller.text;
    final source = selection.isValid && !selection.isCollapsed
        ? selection.textInside(text)
        : text;
    if (source.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: plainTextFrom(source)));
    if (mounted) Toast.show(context, 'Copied as plain text');
  }

  Future<void> _copyLink(NoteLink link) async {
    ContextMenuController.removeAny();
    await Clipboard.setData(ClipboardData(text: link.text));
    if (mounted) Toast.show(context, 'Link copied');
  }

  List<ContextMenuButtonItem> _linkContextMenuItems(NoteLink? link) {
    if (link == null) return const [];
    return [
      ContextMenuButtonItem(
        label: 'Open link',
        onPressed: () => unawaited(_openLink(link)),
      ),
      ContextMenuButtonItem(
        label: 'Copy link',
        onPressed: () => unawaited(_copyLink(link)),
      ),
    ];
  }

  /// The menu behind a right-click, a press-and-hold, a tap on a phone, or
  /// the keyboard.
  ///
  /// A phone shows the first few buttons of its toolbar and hides the rest
  /// behind More, so there the order is the design: the edit people came for
  /// leads — Copy with something selected, Paste with nothing — and the
  /// note's own actions follow. A pointer's menu is a column that shows
  /// everything, and keeps the order it has always had.
  Widget _contextMenu(BuildContext context, NoteFieldState field) {
    final selection = _controller.selection;
    final touch = !AppPlatform.hasPointer;
    // A table's text is hidden under its grid, so a right-click or a
    // press-and-hold there means the table, and gets the table's menu.
    if (!widget.readOnly) {
      final anchor = field.contextMenuAnchors.primaryAnchor;
      for (final frame in _tableFrames()) {
        final row = frame.rowAt(anchor.dy);
        final column = frame.columnAt(anchor.dx);
        if (row == null || column == null) continue;
        if (touch) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ContextMenuController.removeAny();
            _showTableMenu(
              frame,
              row: row,
              column: column,
              anchor: Rect.fromCenter(center: anchor, width: 0, height: 0),
            );
          });
        }
        return const SizedBox.shrink();
      }
    }
    final link = _linkForSelection(selection);
    final linkItems = _linkContextMenuItems(link);
    if (widget.readOnly) {
      final editItems = _editItems(field, selection);
      return NoteEditorContextMenu(
        anchors: field.contextMenuAnchors,
        buttonItems: [
          if (!touch) ...linkItems,
          ...editItems,
          if (touch) ...linkItems,
          if (_controller.text.isNotEmpty)
            ContextMenuButtonItem(
              label: 'Copy plain text',
              onPressed: () => unawaited(_copyPlainText(selection)),
            ),
        ],
      );
    }
    if (selection.isCollapsed) {
      final spellingItems = _spellingContextMenuItems(selection);
      final editItems = _editItems(field, selection);
      return NoteEditorContextMenu(
        anchors: field.contextMenuAnchors,
        buttonItems: [
          if (touch) ...editItems.where(_isPasteAction),
          ...spellingItems,
          ...linkItems,
          if (touch) ...editItems.where((item) => !_isPasteAction(item)),
          if (widget.images != null && touch)
            ContextMenuButtonItem(
              label: 'Add image',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(pickAndInsertImages());
              },
            ),
          if (widget.images != null && touch)
            ContextMenuButtonItem(
              label: 'Add video',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(pickAndInsertVideos());
              },
            ),
          if (widget.images != null && touch)
            ContextMenuButtonItem(
              label: 'Attach file',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(pickAndInsertFileAttachments());
              },
            ),
          // Touch only, beside Add Image: on a phone the footer
          // row has no space left, so the press-and-hold menu is
          // where every insert action already lives.
          if (widget.onRecordVoice != null && touch)
            ContextMenuButtonItem(
              label: 'Record voice note',
              onPressed: () {
                ContextMenuController.removeAny();
                widget.onRecordVoice!();
              },
            ),
          if (_controller.text.isNotEmpty)
            ContextMenuButtonItem(
              label: 'Copy plain text',
              onPressed: () => unawaited(_copyPlainText(selection)),
            ),
          if (!touch) ...editItems,
        ],
      );
    }
    return NoteEditorContextMenu(
      anchors: field.contextMenuAnchors,
      buttonItems: _selectionMenuItems(field, selection, linkItems),
    );
  }

  bool _isPasteAction(ContextMenuButtonItem item) =>
      item.type == ContextMenuButtonType.paste ||
      item.label == _pasteAsPlainTextLabel;

  /// Cut, Copy, Paste and Select All, followed by whatever else the platform
  /// adds. Copy and Cut take [selection] in every form at once where
  /// [_copiesRich] says, as the keyboard's do, and Paste goes through
  /// [handlePaste] wherever a picture can land, as the keyboard's does.
  ///
  /// The field's `contextMenuButtonItems` withholds every one of the four
  /// until the clipboard has been checked, and goes on withholding them if that
  /// check fails, which left a phone's menu without Copy for as long as the
  /// check took, or for good. Only Paste needs the answer; the builder rebuilds
  /// the menu when it comes.
  List<ContextMenuButtonItem> _editItems(
    NoteFieldState field,
    TextSelection selection,
  ) {
    const ownTypes = {
      ContextMenuButtonType.cut,
      ContextMenuButtonType.copy,
      ContextMenuButtonType.paste,
      ContextMenuButtonType.selectAll,
    };
    const cause = SelectionChangedCause.toolbar;
    final rich = _copiesRich(selection);
    VoidCallback fromMenu(Future<void> Function() action) => () {
      ContextMenuController.removeAny();
      unawaited(action());
    };
    return [
      if (field.cutEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: rich
              ? fromMenu(() => _copyAndCutRichSelection(selection, cause))
              : () => field.cutSelection(cause),
        ),
      if (field.copyEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: rich
              ? fromMenu(() => _copyRichSelection(selection))
              : () => field.copySelection(cause),
        ),
      if (field.pasteEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: widget.images == null
              ? () => unawaited(field.pasteText(cause))
              : fromMenu(() => handlePaste(cause)),
        ),
      if (field.pasteEnabled)
        ContextMenuButtonItem(
          label: _pasteAsPlainTextLabel,
          onPressed: () {
            ContextMenuController.removeAny();
            unawaited(_pastePlainText(SelectionChangedCause.toolbar));
          },
        ),
      if (field.selectAllEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () => field.selectAll(cause),
        ),
      for (final item in field.contextMenuButtonItems)
        if (!ownTypes.contains(item.type)) item,
    ];
  }

  /// The menu for selected text, on a phone's toolbar or behind a
  /// right-click.
  ///
  /// Copy leads, followed by Cut and the paste actions, because copying is
  /// what a selection is usually for. The rest follows in the order a phone's
  /// toolbar tucks it away: corrections, the platform's other actions, the
  /// link, and the note's own formatting, which the bubble also carries where
  /// there is a pointer.
  List<ContextMenuButtonItem> _selectionMenuItems(
    NoteFieldState field,
    TextSelection selection,
    List<ContextMenuButtonItem> linkItems,
  ) {
    final nativeItems = _editItems(field, selection);
    bool isCopy(ContextMenuButtonItem item) =>
        item.type == ContextMenuButtonType.copy;
    bool isCut(ContextMenuButtonItem item) =>
        item.type == ContextMenuButtonType.cut;
    bool isPrimaryEdit(ContextMenuButtonItem item) =>
        isCopy(item) || isCut(item) || _isPasteAction(item);
    ContextMenuButtonItem action(String label, VoidCallback onPressed) =>
        ContextMenuButtonItem(
          label: label,
          onPressed: () {
            ContextMenuController.removeAny();
            onPressed();
          },
        );
    return [
      ...nativeItems.where(isCopy),
      ...nativeItems.where(isCut),
      ...nativeItems.where(_isPasteAction),
      ..._spellingContextMenuItems(selection),
      ...nativeItems.where((item) => !isPrimaryEdit(item)),
      ...linkItems,
      ContextMenuButtonItem(
        label: 'Copy plain text',
        onPressed: () => unawaited(_copyPlainText(selection)),
      ),
      action('Bold', () => _toggleInlineFormat(NoteFormat.bold)),
      action('Italic', () => _toggleInlineFormat(NoteFormat.italic)),
      action('Bulleted list', _toggleBullets),
      action('Checklist', _toggleChecklist),
    ];
  }

  /// The misspelling a selection is asking about: the caret inside a word, or
  /// the word itself.
  ///
  /// Right-clicking a misspelling selects it on macOS, and holding one does
  /// the same under a finger, so a collapsed caret is not the only way someone
  /// arrives at the menu asking how the word is spelled.
  SuggestionSpan? _spellingSuggestionFor(TextSelection selection) {
    if (!selection.isValid) return null;
    for (final suggestion in _controller.spellingSuggestions) {
      final range = suggestion.range;
      if (selection.start >= range.start && selection.end <= range.end) {
        return suggestion;
      }
    }
    return null;
  }

  List<ContextMenuButtonItem> _spellingContextMenuItems(
    TextSelection selection,
  ) {
    final misspelling = _spellingSuggestionFor(selection);
    if (misspelling == null) return const [];

    final unique = <String>{};
    final replacements = [
      for (final suggestion in _correctionsFor(misspelling))
        if (unique.add(suggestion)) suggestion,
    ].take(3);
    return [
      for (final replacement in replacements)
        ContextMenuButtonItem(
          label: replacement.isEmpty ? 'Delete repeated word' : replacement,
          onPressed: () => _replaceMisspelling(misspelling, replacement),
        ),
    ];
  }

  void _replaceMisspelling(SuggestionSpan misspelling, String replacement) {
    ContextMenuController.removeAny();
    if (widget.readOnly) return;
    final field = _field;
    if (field == null) return;
    final value = _controller.value;
    final range = misspelling.range;
    if (range.start < 0 ||
        range.end <= range.start ||
        range.end > value.text.length) {
      return;
    }

    field.userUpdateTextEditingValue(
      value.copyWith(
        text: value.text.replaceRange(range.start, range.end, replacement),
        selection: TextSelection.collapsed(
          offset: range.start + replacement.length,
        ),
        composing: TextRange.empty,
      ),
      SelectionChangedCause.toolbar,
    );
    _focusNode.requestFocus();
  }

  /// Makes a picture a real one-character editor selection.
  ///
  /// A selection that already includes it is preserved, which is what makes
  /// right-clicking one picture inside a mixed text-and-image selection copy
  /// the whole selection instead of silently narrowing it first.
  void _selectImage(NoteImageRef ref) {
    final current = _controller.selection;
    if (!(current.isValid &&
        !current.isCollapsed &&
        current.start <= ref.offset &&
        current.end > ref.offset)) {
      _controller.selection = TextSelection(
        baseOffset: ref.offset,
        extentOffset: ref.offset + 1,
      );
    }
    _focusNode.requestFocus();
  }

  void _copyImageFromMenu(NoteImageRef ref) {
    ContextMenuController.removeAny();
    _selectImage(ref);
    unawaited(_copyRichSelection(_controller.selection));
  }

  Future<Uint8List?> _clipboardBytes(NoteAttachmentRef ref) async {
    final store = widget.images;
    if (store == null) return null;
    var bytes = await store.read(ref.hash);
    if (bytes != null || ref is! NoteImageRef) return bytes;
    final fetch = widget.imageFetch;
    if (fetch == null) return null;
    bytes = await fetch(ref.hash);
    if (bytes == null || BlobStore.hashOf(bytes) != ref.hash) return null;
    await store.put(bytes);
    return bytes;
  }

  /// Everything in [selection] a paste needs to rebuild it: its words, the
  /// styles over them, every picture with its bytes, and with
  /// [withAttachments] its files, voice notes and videos with theirs. An
  /// attachment that does not travel becomes the label it pastes as. Null
  /// when a picture's bytes cannot be had.
  Future<NoteClipboardFragment?> _clipboardFragment(
    TextSelection selection, {
    required bool withAttachments,
  }) async {
    final text = _controller.text;
    final refs = {for (final ref in _attachments) ref.offset: ref};
    final body = StringBuffer();
    final images = <ClipboardFragmentImage>[];
    final attachments = <ClipboardFragmentAttachment>[];
    final labels = <({int at, int growth})>[];
    var cursor = selection.start;
    for (
      var at = text.indexOf(NoteAttachmentRef.placeholder, cursor);
      at >= 0 && at < selection.end;
      at = text.indexOf(NoteAttachmentRef.placeholder, at + 1)
    ) {
      body.write(text.substring(cursor, at));
      cursor = at + 1;
      final ref = refs[at];
      final offset = body.length;
      if (ref is NoteImageRef) {
        final bytes = await _clipboardBytes(ref);
        if (bytes == null) return null;
        body.write(NoteAttachmentRef.placeholder);
        images.add(
          ClipboardFragmentImage(
            offset: offset,
            bytes: bytes,
            mime: ref.mime,
            width: ref.width,
            height: ref.height,
            widthFactor: ref.widthFactor,
          ),
        );
        continue;
      }
      if (withAttachments && ref != null && ref is! NoteUnknownRef) {
        final bytes = await _clipboardBytes(ref);
        if (bytes != null) {
          body.write(NoteAttachmentRef.placeholder);
          attachments.add(
            ClipboardFragmentAttachment(
              ref: ref.copyWith(offset: offset),
              bytes: bytes,
            ),
          );
          continue;
        }
      }
      final label = ref == null
          ? '[Attachment]'
          : NoteClipboardFragment.labelFor(ref);
      body.write(label);
      labels.add((at: at, growth: label.length - 1));
    }
    body.write(text.substring(cursor, selection.end));

    int moved(int offset) =>
        offset -
        selection.start +
        labels
            .where((label) => label.at < offset)
            .fold<int>(0, (sum, label) => sum + label.growth);
    return NoteClipboardFragment(
      body: body.toString(),
      images: images,
      attachments: attachments,
      formats: normalizeNoteFormats([
        for (final range in _formats)
          if (range.end > selection.start && range.start < selection.end)
            NoteFormatRange(
              start: moved(math.max(range.start, selection.start)),
              end: moved(math.min(range.end, selection.end)),
              format: range.format,
            ),
      ], body.length),
      markdown: widget.markdownEnabled,
    );
  }

  /// Copies [selection] in every form a clipboard holds at once: its
  /// markdown, or its text in a note without markdown; its HTML; and Kapy
  /// Notes' own fragment, which puts back every style and attachment when it
  /// is pasted into a note.
  Future<bool> _copyRichSelection(TextSelection selection) async {
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.start < 0 ||
        selection.end > _controller.text.length) {
      return false;
    }
    final selected = [
      for (final ref in _attachments)
        if (ref.offset >= selection.start && ref.offset < selection.end) ref,
    ];
    final selectedImages = selected.whereType<NoteImageRef>().toList();
    final selectionBytes = selectedImages.fold<int>(
      0,
      (sum, ref) => sum + ref.bytes,
    );
    if (selectedImages.length > maxClipboardFragmentImages ||
        selectionBytes > maxClipboardFragmentBytes) {
      if (mounted) {
        Toast.show(
          context,
          selectedImages.length > maxClipboardFragmentImages
              ? 'Copy up to $maxClipboardFragmentImages images at a time'
              : 'That image selection is too large to copy at once',
          icon: KapyIcons.errorOutlined,
          isError: true,
        );
      }
      return false;
    }
    // The rest travels only when the whole selection keeps to the same caps;
    // otherwise each pastes as its label.
    final withAttachments =
        selected.length <= maxClipboardFragmentImages &&
        selected.fold<int>(0, (sum, ref) => sum + ref.bytes) <=
            maxClipboardFragmentBytes;
    if (_copyingRichSelection) return false;
    _copyingRichSelection = true;
    try {
      final fragment = await _clipboardFragment(
        selection,
        withAttachments: withAttachments,
      );
      if (!mounted) return false;
      if (fragment == null) {
        Toast.show(
          context,
          'Could not copy that image',
          icon: KapyIcons.errorOutlined,
          isError: true,
        );
        return false;
      }
      await widget.clipboard.writeFragment(fragment);
      if (!mounted) return true;
      final imageOnly =
          fragment.images.length == 1 &&
          fragment.body == NoteAttachmentRef.placeholder;
      if (!withAttachments && selected.length > selectedImages.length) {
        Toast.show(
          context,
          'Copied without its attachments, which are too large to copy at '
          'once',
          icon: KapyIcons.warningRounded,
        );
      } else if (imageOnly) {
        Toast.show(context, 'Image copied');
      } else if (fragment.attachments.isNotEmpty) {
        Toast.show(context, 'Copied with attachments');
      } else if (fragment.images.isNotEmpty) {
        Toast.show(context, 'Copied with images');
      }
      return true;
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while copying from a note'),
        ),
      );
      if (mounted) {
        Toast.show(
          context,
          selectedImages.isEmpty
              ? 'Could not copy that'
              : 'Could not copy that image',
          icon: KapyIcons.errorOutlined,
          isError: true,
        );
      }
      return false;
    } finally {
      _copyingRichSelection = false;
    }
  }

  Future<void> _copyAndCutRichSelection(
    TextSelection selection,
    SelectionChangedCause cause,
  ) async {
    final before = _controller.value;
    if (!await _copyRichSelection(selection) || !mounted) return;
    if (_controller.value != before || _controller.selection != selection) {
      return;
    }
    _field?.userUpdateTextEditingValue(before.replaced(selection, ''), cause);
    _focusNode.requestFocus();
  }

  /// Whether [selection] is copied in every form at once (see
  /// [_copyRichSelection]) rather than as the field's own text.
  ///
  /// In a note without markdown only a selection that holds an attachment
  /// is, so that words alone reach other apps, and come back in, exactly as
  /// they always have. Either way there must be a store for what a paste
  /// brings back.
  bool _copiesRich(TextSelection selection) =>
      widget.images != null &&
      selection.isValid &&
      !selection.isCollapsed &&
      (widget.markdownEnabled ||
          _attachments.any(
            (ref) =>
                ref.offset >= selection.start && ref.offset < selection.end,
          ));

  /// Copy and Cut from the keyboard, through the rich copy where
  /// [_copiesRich] says, and the field's own elsewhere.
  void _handleCopyIntent(CopySelectionTextIntent intent) {
    if (intent.collapseSelection && widget.readOnly) return;
    final field = _field;
    if (field == null) return;
    final selection = _controller.value.selection;
    if (!_copiesRich(selection)) {
      if (intent.collapseSelection) {
        field.cutSelection(intent.cause);
      } else {
        field.copySelection(intent.cause);
      }
      return;
    }
    if (intent.collapseSelection) {
      unawaited(_copyAndCutRichSelection(selection, intent.cause));
    } else {
      unawaited(_copyRichSelection(selection));
    }
  }

  /// Double-clicking a blank line has no word to take, so the platform
  /// selects the line terminator instead — and so does a long press on
  /// Android, or a right click on a Mac. Nothing can be done with such a
  /// selection but harm: it hides the caret, opens the formatting toolbar over
  /// nothing, and a Paste from the menu would replace the line break instead
  /// of going in at it.
  ///
  /// Collapsing to a caret is what every other editor leaves you with there.
  /// Only a selection made by a press still held where it landed is caught,
  /// and only one of exactly one line break. Anything dragged out or reached
  /// from the keyboard stands, however little it holds: dragging over blank
  /// lines, Shift with the arrows or a click, and Select All in a note of
  /// nothing else are how somebody deletes a run of them at once, which is
  /// what collapsing every selection of bare line breaks used to prevent.
  ///
  /// Returns true when it took over, so the caller can leave the follow-up
  /// work to the change this triggers.
  bool _collapseLineTerminatorSelection(TextSelection selection) {
    if (_stillPress == null || HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    if (!selection.isValid || selection.end - selection.start != 1) {
      return false;
    }
    final text = _controller.text;
    if (selection.start < 0 ||
        selection.end > text.length ||
        text[selection.start] != '\n') {
      return false;
    }
    // Re-enters this listener, where the now-collapsed selection falls
    // straight through the check above.
    _controller.selection = TextSelection.collapsed(offset: selection.start);
    return true;
  }

  /// Keeps a caret out of the hidden structure at the start of a markdown
  /// line — a heading's `#`, a quote's `>`, a list's marker — which has
  /// nothing on screen to put a caret beside.
  ///
  /// A caret landing in it by a click, Home or an arrow up or down goes to
  /// where the line's words begin, which is where it looks as though it is.
  /// A caret stepped left out of the words by the arrow key goes on to the
  /// end of the line above instead, or Left would seem to do nothing at all.
  ///
  /// Returns true when it moved the caret, leaving the rest to the change
  /// that makes.
  bool _keepCaretOutOfMarkdown(TextSelection previous, TextSelection now) {
    if (!now.isValid || !now.isCollapsed) return false;
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return false;
    final markdown = _controller.markdownFor(_controller.text);
    final prefix = markdown.atomicPrefixAt(now.baseOffset);
    if (prefix == null || now.baseOffset == prefix.end) return false;
    // Only the arrow: Home, or ⌘← on a Mac, from the start of the words is
    // asking for the start of this line, which is where the caret already
    // is, and a click there is asking for the same.
    final keyboard = HardwareKeyboard.instance;
    final steppedLeft =
        keyboard.logicalKeysPressed.contains(LogicalKeyboardKey.arrowLeft) &&
        !keyboard.isMetaPressed &&
        previous.isValid &&
        previous.isCollapsed &&
        previous.baseOffset == prefix.end &&
        now.baseOffset < prefix.end;
    final target = steppedLeft && prefix.start > 0
        ? prefix.start - 1
        : prefix.end;
    // Re-enters this listener, where the caret is now somewhere allowed.
    _controller.selection = TextSelection.collapsed(offset: target);
    return true;
  }

  /// Keeps the note's own caret out of a table.
  ///
  /// A table is a grid and its pipes are hidden, so there is nowhere in the
  /// middle of one to put a caret — and the `|---|` row has nothing on screen
  /// at all. Its cells are edited in the field that opens over them instead.
  ///
  /// An arrow key that carries the caret into a table goes on into the grid:
  /// Down from the line above opens the first header cell, Up from below the
  /// first cell of the last row, the way a caret walks into a table in any
  /// word processor. Anything else that lands inside — a click on the gap
  /// between rows, a drag's end — steps out to the edge it came from. The two
  /// edges are left alone: standing at them is how a line is added above or
  /// below.
  ///
  /// Not while a cell is open: the caret is parked on that row on purpose,
  /// so that the field it belongs to has somewhere to keep it.
  bool _keepCaretOutOfTable(TextSelection previous, TextSelection now) {
    if (_editingCell != null) return false;
    if (!now.isValid || !now.isCollapsed) return false;
    final composing = _controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return false;
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      now.baseOffset,
    );
    if (table == null) return false;
    final fromBelow = previous.isValid && previous.baseOffset >= table.end;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final arrowed =
        keys.contains(LogicalKeyboardKey.arrowDown) ||
        keys.contains(LogicalKeyboardKey.arrowUp);
    final inside = now.baseOffset > table.start && now.baseOffset < table.end;
    // Down from an empty line lands exactly on the table's first character,
    // and Up from a long line under it on its last: an edge, but reached by
    // walking into the table rather than by standing beside it.
    final walkedOnto =
        arrowed &&
        previous.isValid &&
        ((now.baseOffset == table.start && previous.baseOffset < table.start) ||
            (now.baseOffset == table.end && previous.baseOffset > table.end));
    if (!inside && !walkedOnto) return false;
    if (arrowed && !widget.readOnly && _focusNode.hasFocus) {
      _scheduleTableCell(table.start, fromBelow ? table.rows.length - 1 : 0, 0);
      return true;
    }
    _controller.selection = TextSelection.collapsed(
      offset: fromBelow ? table.start : table.end,
    );
    return true;
  }

  /// Formatting appears once a selection settles, so a drag across a
  /// paragraph never flickers it: the bubble where there is a pointer, the
  /// platform's toolbar on a phone.
  void _scheduleSelectionToolbar(TextSelection selection) {
    _selectionToolbarTimer?.cancel();
    _selectionBubble.hide();
    if (!selection.isValid || selection.isCollapsed || !_focusNode.hasFocus) {
      return;
    }
    _selectionToolbarTimer = Timer(_selectionSettle, () {
      if (!mounted ||
          !_focusNode.hasFocus ||
          _controller.selection != selection) {
        return;
      }
      if (AppPlatform.hasPointer) {
        if (!_rightClicked) _showSelectionBubble();
      } else {
        _field?.showToolbar();
      }
    });
  }

  /// Raises the bubble over the selection, or brings the one showing up to
  /// date with it.
  void _showSelectionBubble() {
    if (!AppPlatform.hasPointer) return;
    final field = _field;
    final box = field?.box;
    final selection = _controller.selection;
    if (widget.readOnly ||
        field == null ||
        box == null ||
        !(_focusNode.hasFocus || _selectionBubble.editingLink) ||
        !selection.isValid ||
        selection.isCollapsed) {
      return;
    }
    final boxes = field.boxesFor(selection);
    final transform = box.getTransformTo(null);
    Rect line(TextBox row) => MatrixUtils.transformRect(
      transform,
      [
        for (final box in boxes)
          if (box.top == row.top) box.toRect(),
      ].reduce((a, b) => a.expandToInclude(b)),
    );
    final pane = context.findRenderObject()! as RenderBox;
    final within = MatrixUtils.transformRect(
      pane.getTransformTo(null),
      Offset.zero & pane.size,
    );
    // A selection the pane no longer shows, scrolled away or under a window
    // that shrank, takes the bubble with it rather than leave it over other
    // words, until it is back in view.
    if (boxes.isEmpty ||
        line(boxes.last).bottom <= within.top ||
        line(boxes.first).top >= within.bottom) {
      _selectionBubble.lift();
      return;
    }
    String? key(ShortcutAction action) =>
        widget.shortcuts.hintFor(action)?.displayLabel;
    final markdown = widget.markdownEnabled
        ? _controller.markdownFor(_controller.text)
        : null;
    bool marked(MarkdownStyle style) =>
        markdown != null && markdownSelectionHas(markdown, selection, style);
    _selectionBubble.show(
      context,
      above: line(boxes.first),
      below: line(boxes.last),
      within: within,
      block: _selectionBlockLabel,
      blocks: _selectionBlocks,
      markdownEnabled: widget.markdownEnabled,
      actions: [
        SelectionAction(
          name: 'bold',
          label: 'Bold',
          icon: KapyIcons.formatBoldRounded,
          active: _formatActive(NoteFormat.bold),
          shortcut: key(ShortcutAction.formatBold),
          onPressed: () =>
              _bubbleEdit(() => _toggleInlineFormat(NoteFormat.bold)),
        ),
        SelectionAction(
          name: 'italic',
          label: 'Italic',
          icon: KapyIcons.formatItalicRounded,
          active: _formatActive(NoteFormat.italic),
          shortcut: key(ShortcutAction.formatItalic),
          onPressed: () =>
              _bubbleEdit(() => _toggleInlineFormat(NoteFormat.italic)),
        ),
        SelectionAction(
          name: 'strikethrough',
          label: 'Strikethrough',
          icon: KapyIcons.strikethroughRounded,
          active: marked(MarkdownStyle.strikethrough),
          shortcut: key(ShortcutAction.formatStrikethrough),
          onPressed: () =>
              unawaited(_toggleMarkdownWrap('~~', 'Strikethrough')),
        ),
        SelectionAction(
          name: 'code',
          label: 'Inline code',
          icon: KapyIcons.inlineCodeRounded,
          active: marked(MarkdownStyle.code),
          shortcut: key(ShortcutAction.formatCode),
          onPressed: () => unawaited(_toggleMarkdownWrap('`', 'Inline code')),
        ),
        SelectionAction(
          name: 'link',
          label: 'Link',
          icon: KapyIcons.linkRounded,
          active: marked(MarkdownStyle.link),
          shortcut: key(ShortcutAction.formatLink),
          onPressed: () => unawaited(_startLink()),
        ),
      ],
      onLink: _linkSelection,
      onLinkClosed: _focusNode.requestFocus,
    );
  }

  /// A change from the bubble moves the selection, which takes the bubble
  /// away until it settles again; it was made from the bubble, so the
  /// bubble stays.
  void _bubbleEdit(VoidCallback edit) {
    edit();
    _showSelectionBubble();
  }

  /// What Text ▾ says the selection's line is.
  String get _selectionBlockLabel {
    if (widget.markdownEnabled) {
      final level = _markdownHeadingLevel ?? 0;
      if (level > 0) return 'Heading ${level.clamp(1, 3)}';
      final line = markdownLinePrefix(
        _controller.text,
        _controller.selection.start,
      );
      if (line.isTask) return 'Checklist';
      if (line.isOrdered) return 'Numbered list';
      if (line.isBullet) return 'Bulleted list';
      if (line.isQuoted) return 'Quote';
      return 'Text';
    }
    if (_lineStyleActive(NoteLineStyle.checklist)) return 'Checklist';
    if (_lineStyleActive(NoteLineStyle.bullet)) return 'Bulleted list';
    return switch (_activeParagraphStyle) {
      NoteParagraphStyle.heading => 'Heading 1',
      NoteParagraphStyle.subtitle => 'Heading 2',
      _ => 'Text',
    };
  }

  /// What Text ▾ offers, the way Commands words them.
  List<SelectionBlock> get _selectionBlocks => [
    SelectionBlock(
      label: 'Text',
      icon: KapyIcons.textFormatRounded,
      onSelected: () => _bubbleEdit(_turnIntoText),
    ),
    for (final (type, label, icon, trigger) in const [
      (SlashCommandType.heading1, 'Heading 1', KapyIcons.heading1Rounded, '#'),
      (SlashCommandType.heading2, 'Heading 2', KapyIcons.heading2Rounded, '##'),
      (
        SlashCommandType.heading3,
        'Heading 3',
        KapyIcons.heading3Rounded,
        '###',
      ),
      (
        SlashCommandType.bulletedList,
        'Bulleted list',
        KapyIcons.bulletedListRounded,
        '-',
      ),
      (
        SlashCommandType.numberedList,
        'Numbered list',
        KapyIcons.numberedListRounded,
        '1.',
      ),
      (
        SlashCommandType.checklist,
        'Checklist',
        KapyIcons.checklistRounded,
        '[ ]',
      ),
      (SlashCommandType.quote, 'Quote', KapyIcons.quoteRounded, '>'),
    ])
      SelectionBlock(
        label: label,
        icon: icon,
        trigger:
            widget.markdownEnabled ||
                (type != SlashCommandType.heading1 &&
                    type != SlashCommandType.heading2)
            ? trigger
            : null,
        requiresMarkdown: _requiresMarkdown(type),
        onSelected: () => unawaited(_turnInto(type)),
      ),
    SelectionBlock(
      label: 'Code block',
      icon: KapyIcons.codeRounded,
      trigger: '```',
      requiresMarkdown: true,
      onSelected: () => unawaited(_wrapInCodeBlock()),
    ),
  ];

  /// Text ▾'s Text: no heading, and out of a list.
  void _turnIntoText() {
    if (_lineStyleActive(NoteLineStyle.checklist)) _toggleChecklist();
    if (_lineStyleActive(NoteLineStyle.bullet)) _toggleBullets();
    if (widget.markdownEnabled) {
      _applyMarkdownEdit(applyMarkdownHeading(_controller.value, 0));
    } else {
      _applyParagraphStyle(NoteParagraphStyle.text);
    }
  }

  /// Text ▾'s other blocks, applied the way the same command from the "+"
  /// applies them, Markdown asked for where it is needed.
  Future<void> _turnInto(SlashCommandType type) async {
    final selection = _controller.selection;
    if (widget.readOnly || !selection.isValid) return;
    _slashCommandRange = TextRange.collapsed(selection.extentOffset);
    _slashCommandWasTyped = false;
    await _runSlashCommand(SlashCommandChoice(type));
    if (mounted) _showSelectionBubble();
  }

  /// Fences the selected lines as a code block.
  Future<void> _wrapInCodeBlock() async {
    final before = _controller.value;
    final selection = before.selection;
    if (widget.readOnly || !selection.isValid) return;
    if (!widget.markdownEnabled && !await _confirmMarkdown('Code blocks')) {
      return;
    }
    if (!mounted || _controller.text != before.text) return;
    final text = before.text;
    final start = selection.start == 0
        ? 0
        : text.lastIndexOf('\n', selection.start - 1) + 1;
    final next = text.indexOf('\n', selection.end);
    final end = next < 0 ? text.length : next;
    final code = text.substring(start, end);
    _replaceCommandValue(
      replaceSlashCommandRange(
        before,
        TextRange(start: start, end: end),
        '```\n$code\n```',
        selection: TextSelection(
          baseOffset: start + 4,
          extentOffset: start + 4 + code.length,
        ),
      ),
    );
    _showSelectionBubble();
  }

  /// Strikethrough and inline code, which only Markdown can write.
  Future<void> _toggleMarkdownWrap(String marker, String feature) async {
    final before = _controller.value;
    if (widget.readOnly ||
        !before.selection.isValid ||
        before.selection.isCollapsed) {
      return;
    }
    if (!widget.markdownEnabled && !await _confirmMarkdown(feature)) return;
    if (!mounted || _controller.text != before.text) return;
    _replaceCommandValue(toggleMarkdownWrap(before, marker));
    _showSelectionBubble();
  }

  /// Link: the bubble becomes a field for the address, Markdown asked for
  /// first in a plain note.
  Future<void> _startLink() async {
    final before = _controller.value;
    if (widget.readOnly ||
        !before.selection.isValid ||
        before.selection.isCollapsed) {
      return;
    }
    if (!widget.markdownEnabled) {
      if (!await _confirmMarkdown('Links')) return;
      if (!mounted || _controller.text != before.text) return;
      _controller.selection = before.selection;
      _focusNode.requestFocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    _selectionToolbarTimer?.cancel();
    _showSelectionBubble();
    _selectionBubble.editLink();
  }

  /// Links the selected words to [address], in Markdown.
  void _linkSelection(String address) {
    final value = _controller.value;
    final selection = value.selection;
    if (widget.readOnly || !selection.isValid || selection.isCollapsed) return;
    final words = value.text.substring(selection.start, selection.end);
    _replaceCommandValue(
      replaceSlashCommandRange(
        value,
        TextRange(start: selection.start, end: selection.end),
        '[$words](${linkDestination(address)})',
        selection: TextSelection(
          baseOffset: selection.start + 1,
          extentOffset: selection.start + 1 + words.length,
        ),
      ),
    );
  }

  /// Whether the phone's formatting bar is up: the keyboard is open on this
  /// note, or on a cell of its table.
  bool get _formatBarShown =>
      AppPlatform.isMobile &&
      !widget.readOnly &&
      _keyboardInset > 0 &&
      _editingNote;

  /// Whether the caret or selection sits inside a code block, which holds
  /// plain text and so takes none of the formatting.
  bool get _inCodeBlock {
    final selection = _controller.selection;
    if (!widget.markdownEnabled || !selection.isValid) return false;
    return _controller
        .markdownFor(_controller.text)
        .blocks
        .any(
          (block) =>
              block.kind == MarkdownBlockKind.code &&
              block.start <= selection.start &&
              selection.end <= block.end,
        );
  }

  /// The bar's buttons, each the same command as the desktop's bubble, the
  /// shortcut and the Commands menu. Inside a table cell they are the cell's
  /// row and column controls instead.
  List<FormatBarAction> _formatBarActions(
    ({MarkdownTable table, int row, int column})? cell,
  ) {
    if (cell != null) {
      final alignment = _tableColumnAlignment(cell.table, cell.column);
      return [
        FormatBarAction(
          key: 'footer-table-add-row',
          label: 'Insert row below',
          icon: KapyIcons.tableRowBelow,
          onPressed: () => _runOnOpenCell(TableCommand.rowBelow),
        ),
        FormatBarAction(
          key: 'footer-table-add-column',
          label: 'Insert column right',
          icon: KapyIcons.tableColumnRight,
          onPressed: () => _runOnOpenCell(TableCommand.columnRight),
        ),
        FormatBarAction(
          key: 'footer-table-align-column',
          label: switch (alignment) {
            MarkdownCellAlign.start => 'Column aligned left; change to center',
            MarkdownCellAlign.center => 'Column centered; change to right',
            MarkdownCellAlign.end => 'Column aligned right; change to left',
          },
          icon: switch (alignment) {
            MarkdownCellAlign.start => KapyIcons.alignLeft,
            MarkdownCellAlign.center => KapyIcons.alignCenter,
            MarkdownCellAlign.end => KapyIcons.alignRight,
          },
          active: alignment != MarkdownCellAlign.start,
          onPressed: () => _runOnOpenCell(switch (alignment) {
            MarkdownCellAlign.start => TableCommand.alignCenter,
            MarkdownCellAlign.center => TableCommand.alignEnd,
            MarkdownCellAlign.end => TableCommand.alignStart,
          }),
        ),
        FormatBarAction(
          key: 'footer-table-remove-row',
          label: 'Delete row',
          icon: KapyIcons.tableDeleteRow,
          onPressed: cell.row == 0
              ? null
              : () => _runOnOpenCell(TableCommand.deleteRow),
        ),
        FormatBarAction(
          key: 'footer-table-remove-column',
          label: 'Delete column',
          icon: KapyIcons.tableDeleteColumn,
          onPressed: markdownTableColumnCount(cell.table) <= 1
              ? null
              : () => _runOnOpenCell(TableCommand.deleteColumn),
        ),
      ];
    }
    final markdown = widget.markdownEnabled;
    final selection = _controller.selection;
    final analysis = markdown
        ? _controller.markdownFor(_controller.text)
        : null;
    final line = markdown && selection.isValid
        ? markdownLinePrefix(_controller.text, selection.extentOffset)
        : null;
    final inCode = _inCodeBlock;
    bool marked(MarkdownStyle style) =>
        analysis != null && markdownSelectionHas(analysis, selection, style);
    FormatBarAction action(
      String key,
      String label,
      KapyIconData? icon,
      VoidCallback? press, {
      bool active = false,
      bool plain = true,
      String? glyph,
    }) => FormatBarAction(
      key: key,
      label: label,
      icon: icon,
      glyph: glyph,
      active: active,
      onPressed: plain && inCode ? null : press,
    );
    return [
      action(
        'format-attach',
        'Attach',
        KapyIcons.imageOutlined,
        widget.images == null ? null : () => unawaited(_attachFromBar()),
      ),
      if (_showIndentControls) ...[
        action(
          'format-outdent',
          'Move out',
          KapyIcons.indentDecreaseRounded,
          _canIndent(outdent: true) ? () => _indentList(outdent: true) : null,
        ),
        action(
          'format-indent',
          'Move in',
          KapyIcons.indentIncreaseRounded,
          _canIndent(outdent: false) ? () => _indentList(outdent: false) : null,
        ),
      ] else
        action(
          'format-style',
          'Heading',
          KapyIcons.heading1Rounded,
          _cycleParagraphStyle,
          active: markdown
              ? (_markdownHeadingLevel ?? 0) > 0
              : _activeParagraphStyle != null &&
                    _activeParagraphStyle != NoteParagraphStyle.text,
        ),
      action(
        'format-bold',
        'Bold',
        KapyIcons.formatBoldRounded,
        () => _toggleInlineFormat(NoteFormat.bold),
        active: _formatActive(NoteFormat.bold),
      ),
      action(
        'format-italic',
        'Italic',
        KapyIcons.formatItalicRounded,
        () => _toggleInlineFormat(NoteFormat.italic),
        active: _formatActive(NoteFormat.italic),
      ),
      action(
        'format-checklist',
        'Checklist',
        KapyIcons.checklistRounded,
        _toggleChecklist,
        active: _lineStyleActive(NoteLineStyle.checklist),
      ),
      if (_caretInTask)
        action(
          'format-details',
          'Details',
          KapyIcons.alignLeft,
          _dropIntoDetails,
          active: _folds?.hintSeen == false,
        ),
      action(
        'format-bullets',
        'Bulleted list',
        KapyIcons.bulletedListRounded,
        _toggleBullets,
        active: _lineStyleActive(NoteLineStyle.bullet),
      ),
      action(
        'format-numbered',
        'Numbered list',
        KapyIcons.numberedListRounded,
        () => unawaited(_toggleBlock(SlashCommandType.numberedList)),
        active: line?.isOrdered ?? false,
      ),
      action(
        'format-quote',
        'Quote',
        KapyIcons.quoteRounded,
        () => unawaited(_toggleBlock(SlashCommandType.quote)),
        active: line?.isQuoted ?? false,
      ),
      action(
        'format-code',
        'Code',
        KapyIcons.inlineCodeRounded,
        _formatCode,
        active: inCode || marked(MarkdownStyle.code),
        plain: false,
      ),
      action(
        'format-link',
        'Link',
        KapyIcons.linkRounded,
        () => unawaited(_linkFromBar()),
        active: marked(MarkdownStyle.link),
      ),
      action('format-commands', 'Commands', null, _showInsertMenu, glyph: '/'),
    ];
  }

  /// The numbered list and the quote on the caret's line: taken off when the
  /// line has it, otherwise the same command the "+" menu runs.
  Future<void> _toggleBlock(SlashCommandType type) async {
    final value = _controller.value;
    final selection = value.selection;
    if (widget.readOnly || !selection.isValid) return;
    final line = markdownLinePrefix(value.text, selection.extentOffset);
    final marker = !widget.markdownEnabled
        ? null
        : switch (type) {
            SlashCommandType.numberedList when line.isOrdered => TextRange(
              start: line.markerStart,
              end: line.contentStart,
            ),
            SlashCommandType.quote when line.isQuoted => TextRange(
              start: line.indentEnd,
              end: line.quoteEnd,
            ),
            _ => null,
          };
    if (marker != null) {
      _replaceCommandValue(
        replaceSlashCommandRange(
          value,
          marker,
          '',
          selection: _selectionAfterReplacement(selection, marker, 0),
        ),
      );
      return;
    }
    _slashCommandRange = TextRange.collapsed(selection.extentOffset);
    _slashCommandWasTyped = false;
    await _runSlashCommand(SlashCommandChoice(type));
  }

  /// Code: inline on a selection, a block on a caret.
  void _formatCode() {
    final selection = _controller.selection;
    if (widget.readOnly || !selection.isValid || _inCodeBlock) return;
    if (selection.isCollapsed) {
      unawaited(_toggleBlock(SlashCommandType.codeBlock));
    } else {
      unawaited(_toggleMarkdownWrap('`', 'Inline code'));
    }
  }

  /// Link: asks for the address, then wraps the selection in it, or writes
  /// the address as its own link at a caret.
  ///
  /// The note can change while the prompt is open, from another device. The
  /// link still goes in when the same words are at the selection, or the same
  /// few characters around a caret, and when they are not it says so rather
  /// than vanish. The keyboard comes back
  /// either way.
  Future<void> _linkFromBar() async {
    final before = _controller.value;
    final selection = before.selection;
    if (widget.readOnly || !selection.isValid) return;
    void resumeWriting() {
      _focusNode.requestFocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    }

    if (!widget.markdownEnabled && !await _confirmMarkdown('Links')) {
      if (mounted) resumeWriting();
      return;
    }
    if (!mounted) return;
    final address = await askLinkAddress(context);
    if (!mounted) return;
    resumeWriting();
    if (address == null) return;
    final now = _controller.value;
    final from = selection.isCollapsed
        ? math.max(0, selection.start - 8)
        : selection.start;
    final to = selection.isCollapsed
        ? math.min(before.text.length, selection.end + 8)
        : selection.end;
    if (to > now.text.length ||
        now.text.substring(from, to) != before.text.substring(from, to)) {
      Toast.show(
        context,
        'Link not added, the note changed',
        icon: KapyIcons.errorOutlined,
      );
      return;
    }
    _controller.selection = selection;
    if (!selection.isCollapsed) {
      _linkSelection(address);
      return;
    }
    final words = address.replaceAllMapped(
      RegExp(r'[\\\[\]]'),
      (match) => '\\${match[0]}',
    );
    _replaceCommandValue(
      replaceSlashCommandRange(
        now,
        TextRange.collapsed(selection.start),
        '[$words](${linkDestination(address)})',
        selection: TextSelection(
          baseOffset: selection.start + 1,
          extentOffset: selection.start + 1 + words.length,
        ),
      ),
    );
  }

  /// Attach: asks what, then runs the command the "+" menu does.
  Future<void> _attachFromBar() async {
    final choice = await chooseAttachment(
      context,
      voice: widget.onRecordVoice != null && !widget.voiceActionBusy,
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case FormatBarAttachment.photo:
        await pickAndInsertImages();
      case FormatBarAttachment.video:
        await pickAndInsertVideos();
      case FormatBarAttachment.voice:
        widget.onRecordVoice?.call();
      case FormatBarAttachment.file:
        await pickAndInsertFileAttachments();
    }
  }

  void _evaluate() {
    // In markdown, the calculator reads the note with its code blanked and
    // its list markers made bullets; see MarkdownAnalysis.calculatorText.
    final evaluation = widget.engine.evaluateDocumentWithSummary(
      _controller.calculatorTextFor(_controller.text),
      titled: true,
    );
    _results = evaluation.results;
    _totalText = evaluation.totalText;
    _describeTotal = evaluation.describeTotal;
    _totalLeavesOut = evaluation.totalLeavesOut;
  }

  static DateTime _localTime(DateTime value) => value.toLocal();

  /// Sizes and builds every image in this note, keyed by its anchor.
  ///
  /// A line holding one image gets the blog treatment: full writing width,
  /// shortened only if it would otherwise push the text off the screen. A line
  /// holding several becomes a gallery of equal tiles that wrap — which is
  /// what the text engine does with adjacent inline widgets anyway, so the
  /// grid costs no layout code of its own.
  /// A zero-width, row-tall placeholder standing in for the first character of
  /// each table row, which is what reserves the room the grid is painted in.
  ///
  /// It stands in for a character rather than being added beside one. A
  /// `WidgetSpan` counts as exactly one character, and the field requires the
  /// span it paints to hold precisely the text the controller does — so
  /// adding one would shift every offset after it and put the caret in the wrong
  /// place. The whole row is hidden anyway, so standing in for its first
  /// character shows nothing that was not already invisible.
  ///
  /// The header keeps the `|---|` line underneath it, which is a line of the
  /// note in its own right and already as tall as a row, so the header asks only
  /// for whatever it needs beyond that.
  /// Opens the cell editor over the cell under [globalPosition], and says
  /// whether there was one.
  ///
  /// The row comes from the text offset and the column from where the press
  /// landed: a table's own text is hidden, so every glyph of a row sits at the
  /// left margin and only the vertical position means anything. The width is the
  /// grid's, which is why the geometry has to be the same one the backdrop
  /// painted from.
  bool _openTableCellAt(
    NoteFieldState field,
    Offset globalPosition,
    int textOffset,
  ) {
    if (widget.readOnly) return false;
    final markdown = _controller.markdownFor(_controller.text);
    final table = markdownTableAt(markdown, textOffset);
    if (table == null) return false;
    final geometry = _tableGrids[table];
    if (geometry == null || geometry.columns.isEmpty) return false;
    // Null on the `|---|` row, which is structure rather than a cell.
    final where = markdownTableCellAt(table, textOffset);
    if (where == null) return false;
    final row = table.rows[where.row];

    // The row's spacer is exactly as tall as the painted row, and the band
    // starts one placeholder overhead above the spacer's own box.
    final box = field.box;
    if (box == null ||
        field
            .boxesFor(
              TextSelection(baseOffset: row.start, extentOffset: row.start + 1),
            )
            .isEmpty) {
      return false;
    }
    final origin = box.localToGlobal(Offset.zero);
    final column = geometry.columnAt(globalPosition.dx - origin.dx);
    if (column == null) return false;

    final rect = _cellRect(field, table, where.row, column);
    if (rect == null) return false;
    _showCellEditor(table, where.row, column, rect);
    // The note's own field handles the same tap after this does, and on a
    // touch screen it asks for the keyboard as it does — taking focus from the
    // cell that was just opened. Once the tap is over, the cell takes it back.
    final opened = _editingCell;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingCell != opened || !_cellEditor.isVisible) return;
      if (!_cellEditor.focus.hasFocus) _cellEditor.focus.requestFocus();
    });
    return true;
  }

  /// Where one cell is drawn, in global coordinates.
  Rect? _cellRect(
    NoteFieldState field,
    MarkdownTable table,
    int row,
    int column,
  ) {
    final geometry = _tableGrids[table];
    final box = field.box;
    if (geometry == null || box == null || column >= geometry.columns.length) {
      return null;
    }
    final band = _tableRowBand(field, table, row);
    if (band == null) return null;
    final left = box.localToGlobal(Offset.zero).dx;
    return Rect.fromLTRB(
      left + geometry.columnLeft(column),
      band.top,
      left + geometry.columnLeft(column) + geometry.columns[column],
      band.bottom,
    );
  }

  /// Every table on screen where it is drawn, for the controls over it.
  List<TableFrame> _tableFrames() {
    final field = _field;
    final box = field?.box;
    if (field == null || box == null || !box.attached) return const [];
    final left = box.localToGlobal(Offset.zero).dx;
    final frames = <TableFrame>[];
    for (final MapEntry(key: table, value: geometry) in _tableGrids.entries) {
      final rowEdges = <double>[];
      for (var row = 0; row < table.rows.length; row++) {
        final band = _tableRowBand(field, table, row);
        if (band == null) break;
        if (row == 0) rowEdges.add(band.top);
        rowEdges.add(band.bottom);
      }
      if (rowEdges.length != table.rows.length + 1) continue;
      var x = left;
      final columnEdges = [x];
      for (final width in geometry.columns) {
        columnEdges.add(x += width);
      }
      frames.add(
        TableFrame(
          table: table.start,
          rowEdges: rowEdges,
          columnEdges: columnEdges,
        ),
      );
    }
    return frames;
  }

  @visibleForTesting
  List<TableFrame> get debugTableFrames => _tableFrames();

  MarkdownTable? _tableAt(int start) =>
      markdownTableAt(_controller.markdownFor(_controller.text), start);

  void _insertTableLine(TableFrame frame, TableAxis axis, int at) => unawaited(
    axis == TableAxis.row
        ? _runTableCommand(frame.table, TableCommand.rowBelow, row: at - 1)
        : _runTableCommand(
            frame.table,
            TableCommand.columnRight,
            column: at - 1,
          ),
  );

  void _moveTableLine(TableFrame frame, TableAxis axis, int from, int to) {
    final table = _tableAt(frame.table);
    if (table == null || widget.readOnly) return;
    final row = axis == TableAxis.row;
    _applyTableEdit(
      row
          ? moveMarkdownTableRow(_controller.value, table, from: from, to: to)
          : moveMarkdownTableColumn(
              _controller.value,
              table,
              from: from,
              to: to,
            ),
    );
    int moved(int i) => i == from
        ? to
        : from < to && i > from && i <= to
        ? i - 1
        : to < from && i >= to && i < from
        ? i + 1
        : i;
    _followTableEdit(
      table.start,
      rows: row ? moved : null,
      columns: row ? null : moved,
    );
  }

  void _resizeTableColumn(TableFrame frame, int column, double? width) {
    final table = _tableAt(frame.table);
    final geometry = table == null ? null : _tableGrids[table];
    if (table == null || geometry == null || widget.readOnly) return;
    final characters = width == null
        ? null
        : ((width - TableGeometry.padding * 2) / geometry.charWidth).round();
    _applyTableEdit(
      setMarkdownTableColumnWidth(
        _controller.value,
        table,
        column: column,
        width: characters,
      ),
    );
    _followTableEdit(table.start);
  }

  /// The menu for a row, a column, or a cell: a cell's leads with Cut, Copy
  /// and Paste, which act on [textItems] when the cell is open and on the
  /// cell's words when it is not.
  void _showTableMenu(
    TableFrame frame, {
    int? row,
    int? column,
    required Rect anchor,
  }) => unawaited(
    _openTableMenu(
      frame.table,
      row: row,
      column: column,
      at: anchor.width == 0 ? anchor.center : anchor.bottomLeft,
    ),
  );

  Future<void> _openTableMenu(
    int tableStart, {
    int? row,
    int? column,
    required Offset at,
    List<ContextMenuButtonItem>? textItems,
  }) async {
    final table = _tableAt(tableStart);
    if (table == null || widget.readOnly) return;
    final cell = row != null && column != null;
    // A grip picks a whole row or column for Delete, which an open cell
    // would otherwise take for itself. A phone keeps its cell open: its grips
    // only show beside one.
    if (!cell && AppPlatform.hasPointer && _editingCell != null) {
      _closeCellEditor();
    }
    final rows = table.rows.length;
    final columns = markdownTableColumnCount(table);
    bool has(ContextMenuButtonType type) =>
        textItems == null || textItems.any((item) => item.type == type);
    final command = await showTableMenu(
      context: context,
      position: at,
      sections: tableMenuSections(
        text: cell,
        row: row != null,
        column: column != null,
      ),
      alignment: column == null ? null : _tableColumnAlignment(table, column),
      enabled: (command) => switch (command) {
        TableCommand.cut => has(ContextMenuButtonType.cut),
        TableCommand.copy => has(ContextMenuButtonType.copy),
        TableCommand.paste => has(ContextMenuButtonType.paste),
        TableCommand.rowAbove || TableCommand.deleteRow => row! > 0,
        TableCommand.rowUp => row! > 1,
        TableCommand.rowDown => row! > 0 && row < rows - 1,
        TableCommand.columnBack => column! > 0,
        TableCommand.columnForward => column! < columns - 1,
        TableCommand.deleteColumn => columns > 1,
        _ => true,
      },
    );
    if (command == null || !mounted) return;
    await _runTableCommand(
      tableStart,
      command,
      row: row,
      column: column,
      textItems: textItems,
    );
  }

  /// Does [command] to the table at [tableStart], at [row] and [column].
  ///
  /// Every structural command is one edit of the note's text, and so one step
  /// of its undo history. An open cell and a picked row or column follow the
  /// words they were on.
  Future<void> _runTableCommand(
    int tableStart,
    TableCommand command, {
    int? row,
    int? column,
    List<ContextMenuButtonItem>? textItems,
  }) async {
    final table = _tableAt(tableStart);
    if (table == null || widget.readOnly) return;
    final value = _controller.value;
    final rows = table.rows.length;
    final columns = markdownTableColumnCount(table);
    if (row != null && (row < 0 || row >= rows)) return;
    if (column != null && (column < 0 || column >= columns)) return;
    int shift(int i, int at, int by) => i >= at ? i + by : i;
    int swap(int i, int a, int b) => i == a
        ? b
        : i == b
        ? a
        : i;
    final MarkdownEdit edit;
    int Function(int)? rowMap;
    int Function(int)? columnMap;
    switch (command) {
      case TableCommand.cut || TableCommand.copy || TableCommand.paste:
        if (row == null || column == null) return;
        return _tableClipboard(table, command, row, column, textItems);
      case TableCommand.rowAbove:
        if (row == null || row == 0) return;
        edit = insertMarkdownTableRow(value, table, after: row - 1);
        rowMap = (i) => shift(i, row, 1);
      case TableCommand.rowBelow:
        if (row == null) return;
        edit = insertMarkdownTableRow(value, table, after: row);
        rowMap = (i) => shift(i, row + 1, 1);
      case TableCommand.columnLeft:
        if (column == null) return;
        edit = insertMarkdownTableColumn(value, table, after: column - 1);
        columnMap = (i) => shift(i, column, 1);
      case TableCommand.columnRight:
        if (column == null) return;
        edit = insertMarkdownTableColumn(value, table, after: column);
        columnMap = (i) => shift(i, column + 1, 1);
      case TableCommand.rowUp || TableCommand.rowDown:
        if (row == null) return;
        final to = command == TableCommand.rowUp ? row - 1 : row + 1;
        edit = moveMarkdownTableRow(value, table, from: row, to: to);
        rowMap = (i) => swap(i, row, to);
      case TableCommand.columnBack || TableCommand.columnForward:
        if (column == null) return;
        final to = command == TableCommand.columnBack ? column - 1 : column + 1;
        edit = moveMarkdownTableColumn(value, table, from: column, to: to);
        columnMap = (i) => swap(i, column, to);
      case TableCommand.alignStart ||
          TableCommand.alignCenter ||
          TableCommand.alignEnd:
        if (column == null) return;
        edit = setMarkdownTableColumnAlign(
          value,
          table,
          column: column,
          align: command.align!,
        );
      case TableCommand.deleteRow:
        if (row == null || row == 0) return;
        edit = removeMarkdownTableRow(value, table, row: row);
        rowMap = (i) => i > row ? i - 1 : math.min(i, rows - 2);
      case TableCommand.deleteColumn:
        if (column == null || columns <= 1) return;
        edit = removeMarkdownTableColumn(value, table, column: column);
        columnMap = (i) => i > column ? i - 1 : math.min(i, columns - 2);
    }
    if (identical(edit.value, value) || edit.value.text == value.text) return;
    // Adding a row or column from the cell being edited goes on into it, the
    // way Tab past the last cell does.
    final open = _editingCell;
    final fromCell =
        open != null &&
        open.tableStart == tableStart &&
        (row == null || row == open.row) &&
        (column == null || column == open.column);
    _applyTableEdit(edit);
    _followTableEdit(
      tableStart,
      rows: fromCell && command == TableCommand.rowBelow
          ? (i) => i + 1
          : rowMap,
      columns: fromCell && command == TableCommand.columnRight
          ? (i) => i + 1
          : columnMap,
      keepPicked:
          command == TableCommand.rowUp ||
          command == TableCommand.rowDown ||
          command == TableCommand.columnBack ||
          command == TableCommand.columnForward,
    );
  }

  /// Takes an open cell and a picked row or column along with an edit to
  /// their table, through [rows] and [columns], which say where each index
  /// went. A picked line stays picked only when [keepPicked], so that a
  /// second ⌥⇧↓ moves the same row on.
  void _followTableEdit(
    int tableStart, {
    int Function(int)? rows,
    int Function(int)? columns,
    bool keepPicked = false,
  }) {
    final picked = _tableControls.selected;
    _tableControls.selected = !keepPicked || picked?.table != tableStart
        ? null
        : (
            table: tableStart,
            axis: picked!.axis,
            index:
                (picked.axis == TableAxis.row ? rows : columns)?.call(
                  picked.index,
                ) ??
                picked.index,
          );
    final open = _editingCell;
    if (open == null || open.tableStart != tableStart) return;
    _scheduleTableCell(
      tableStart,
      rows?.call(open.row) ?? open.row,
      columns?.call(open.column) ?? open.column,
    );
  }

  Future<void> _tableClipboard(
    MarkdownTable table,
    TableCommand command,
    int row,
    int column,
    List<ContextMenuButtonItem>? textItems,
  ) async {
    if (textItems != null) {
      final type = switch (command) {
        TableCommand.cut => ContextMenuButtonType.cut,
        TableCommand.copy => ContextMenuButtonType.copy,
        _ => ContextMenuButtonType.paste,
      };
      for (final item in textItems) {
        if (item.type == type) item.onPressed?.call();
      }
      return;
    }
    final cells = table.rows[row].cells;
    final words = column < cells.length
        ? _controller.text.substring(cells[column].start, cells[column].end)
        : '';
    if (command != TableCommand.paste) {
      await Clipboard.setData(ClipboardData(text: words));
      if (command == TableCommand.cut && words.isNotEmpty && mounted) {
        _applyTableEdit(
          setMarkdownTableCell(
            _controller.value,
            table,
            row: row,
            column: column,
            text: '',
          ),
        );
      }
      return;
    }
    final pasted = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (pasted == null || !mounted) return;
    final now = _tableAt(table.start);
    if (now == null || row >= now.rows.length) return;
    _applyTableEdit(
      setMarkdownTableCell(
        _controller.value,
        now,
        row: row,
        column: column,
        text: pasted.trim(),
      ),
    );
  }

  /// Keys for the row or column picked with its grip: Delete takes it away,
  /// the table's shortcuts act on it, Escape lets go, and any other key lets
  /// go and carries on as usual.
  bool _handleTableSelectionKey(KeyEvent event) {
    final picked = _tableControls.selected;
    if (picked == null || event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    final table = _tableAt(picked.table);
    final row = picked.axis == TableAxis.row;
    if (table == null ||
        picked.index >=
            (row ? table.rows.length : markdownTableColumnCount(table))) {
      _tableControls.selected = null;
      return false;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final plain =
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    if (key == LogicalKeyboardKey.escape) {
      _tableControls.selected = null;
      return true;
    }
    var command = tableCommandFor(event, columnMoves: true);
    if (plain &&
        (key == LogicalKeyboardKey.backspace ||
            key == LogicalKeyboardKey.delete)) {
      command = row ? TableCommand.deleteRow : TableCommand.deleteColumn;
    }
    const rowCommands = {
      TableCommand.rowAbove,
      TableCommand.rowBelow,
      TableCommand.rowUp,
      TableCommand.rowDown,
      TableCommand.deleteRow,
    };
    if (command != null && rowCommands.contains(command) == row) {
      unawaited(
        _runTableCommand(
          picked.table,
          command,
          row: row ? picked.index : null,
          column: row ? null : picked.index,
        ),
      );
      return true;
    }
    if (event is KeyDownEvent &&
        !HardwareKeyboard.instance.logicalKeysPressed.every(_isModifier)) {
      _tableControls.selected = null;
    }
    return false;
  }

  static bool _isModifier(LogicalKeyboardKey key) => {
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  }.contains(key);

  /// A command on the cell being edited, from the phone's footer.
  void _runOnOpenCell(TableCommand command) {
    final active = _activeTableCell();
    if (active == null) return;
    unawaited(
      _runTableCommand(
        active.table.start,
        command,
        row: active.row,
        column: active.column,
      ),
    );
  }

  /// The band one row of a table is painted in, in global coordinates.
  ///
  /// Worked out exactly as [MarkdownBackdrop] works it out — from the top of the
  /// row's line to the top of the line after it — so that the field opened over
  /// a cell covers the painted cell to the pixel. The header's band takes in the
  /// `|---|` line under it as well, which is how the grid draws it.
  ({double top, double bottom})? _tableRowBand(
    NoteFieldState field,
    MarkdownTable table,
    int row,
  ) {
    final box = field.box;
    if (box == null || row < 0 || row >= table.rows.length) return null;
    final line = table.rows[row];
    final end = line.header ? table.delimiterEnd : line.end;
    final lines = field.lines;
    final top = field.lineTop(lines.lineAt(line.start));
    final bottom = field.lineTop(
      lines.lineAt(math.max(line.start, end - 1)) + 1,
    );
    if (top == null || bottom == null || bottom <= top) return null;
    final origin = box.localToGlobal(Offset.zero).dy;
    return (top: origin + top, bottom: origin + bottom);
  }

  /// Where a collaborator's caret sits inside the painted grid.
  ///
  /// The source characters under a table are deliberately hidden and occupy
  /// almost no width, so the field cannot place a useful caret there.
  /// Resolve the source offset to its cell and ask the same geometry that drew
  /// the grid where the visible words are instead.
  Rect? _remoteTableCaretRect(int offset) {
    final field = _field;
    if (field == null) return null;
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      offset,
    );
    if (table == null) return null;
    final geometry = _tableGrids[table];
    if (geometry == null || geometry.columns.isEmpty) return null;
    // The delimiter has no editable cell. Keep an older client's caret
    // visible at the start of the header instead of leaving it in hidden text.
    final where = markdownTableCellAt(table, offset) ?? (row: 0, column: 0);
    final row = table.rows[where.row];
    final cellRect = _cellRect(field, table, where.row, where.column);
    final inCell = geometry.caretRectInCell(row, where.column, offset);
    if (cellRect == null || inCell == null) return null;
    // Centred in the row's own height by the geometry; the painted band can be
    // taller — a header's takes in the `|---|` line too — and the words are
    // centred in that.
    return inCell.shift(
      cellRect.topLeft +
          Offset(0, (cellRect.height - geometry.rowHeight(row)) / 2),
    );
  }

  /// The visible cells crossed by somebody else's selection.
  Iterable<Rect> _remoteTableSelectionRects(int start, int end) sync* {
    final field = _field;
    if (field == null) return;
    final low = math.min(start, end);
    final high = math.max(start, end);
    final markdown = _controller.markdownFor(_controller.text);
    for (final table in markdown.tables) {
      if (high < table.start || low > table.end) continue;
      for (var row = 0; row < table.rows.length; row++) {
        final fields = table.rows[row].cells;
        for (var column = 0; column < fields.length; column++) {
          final cell = fields[column];
          if (high <= cell.start || low >= cell.end) continue;
          final rect = _cellRect(field, table, row, column);
          if (rect != null) yield rect;
        }
      }
    }
  }

  /// Where the selection shows on a line of a table, which the grid draws
  /// in place of its hidden text: across a row while all of it is selected,
  /// over each cell selected whole, and over the words selected in a cell.
  /// Null on a line outside a table.
  List<Rect>? _tableSelectionOf(int line, TextRange selected) {
    final field = _field;
    if (field == null) return null;
    final lineStart = field.lines.startOf(line);
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      lineStart,
    );
    final geometry = table == null ? null : _tableGrids[table];
    if (table == null || geometry == null) return null;
    final row = table.rows.where((row) => row.start == lineStart).firstOrNull;
    // The `|---|` line: its header's band covers it.
    if (row == null) return const [];
    final start = lineStart + selected.start;
    final end = lineStart + selected.end;
    final lines = field.lines;
    final heights = field.layout.heights!;
    final last = lines.lineAt(
      math.max(row.start, (row.header ? table.delimiterEnd : row.end) - 1),
    );
    final height = heights.topOf(last + 1) - heights.topOf(line);
    final words = Offset(0, (height - geometry.rowHeight(row)) / 2);
    if (start <= row.start && end >= row.end) {
      return [Rect.fromLTWH(0, 0, geometry.width, height)];
    }
    return [
      for (
        var column = 0;
        column < row.cells.length && column < geometry.columns.length;
        column++
      )
        if (row.cells[column] case final cell
            when start < cell.end && end > cell.start)
          if (start <= cell.start && end >= cell.end)
            Rect.fromLTWH(
              geometry.columnLeft(column),
              0,
              geometry.columns[column],
              height,
            )
          else
            for (final rect in geometry.selectionInCell(
              row,
              column,
              math.max(start, cell.start),
              math.min(end, cell.end),
            ))
              rect.shift(words + Offset(geometry.columnLeft(column), 0)),
    ];
  }

  ({MarkdownTable table, int row, int column})? _activeTableCell() {
    final cell = _editingCell;
    if (cell == null) return null;
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      cell.tableStart,
    );
    if (table == null || cell.row < 0 || cell.row >= table.rows.length) {
      return null;
    }
    final columns = markdownTableColumnCount(table);
    if (cell.column < 0 || cell.column >= columns) return null;
    return (table: table, row: cell.row, column: cell.column);
  }

  void _scheduleTableCell(int tableStart, int row, int column) {
    setState(() {
      _editingCell = (tableStart: tableStart, row: row, column: column);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreTableCellEditor();
    });
  }

  void _restoreTableCellEditor() {
    final active = _activeTableCell();
    final field = _field;
    if (active == null || field == null) {
      _closeCellEditor();
      return;
    }
    final rect = _cellRect(field, active.table, active.row, active.column);
    if (rect == null) {
      _closeCellEditor();
      return;
    }
    _showCellEditor(active.table, active.row, active.column, rect);
  }

  void _syncTableCellEditorPosition() {
    if (!_cellEditor.isVisible) return;
    final active = _activeTableCell();
    final field = _field;
    final box = field?.box;
    if (active == null || field == null || box == null) return;
    final rect = _cellRect(field, active.table, active.row, active.column);
    if (rect == null) return;
    _cellEditor.moveTo(rect);
  }

  /// Tab: on to the next cell, or into a new row when there is no next one.
  ///
  /// The move waits for the next frame. Adding a row changes the note, and the
  /// grid a cell is placed against is only measured during layout — so asking
  /// before then would anchor the editor to a table that no longer exists.
  void _moveToCell({required bool backwards}) {
    final cell = _editingCell;
    if (cell == null || widget.readOnly) return;
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      cell.tableStart,
    );
    if (table == null) {
      _closeCellEditor();
      return;
    }
    var target = nextMarkdownTableCell(
      table,
      row: cell.row,
      column: cell.column,
      backwards: backwards,
    );
    var appended = false;
    if (target == null) {
      // Off the front finishes; off the end adds a row and carries on into it.
      if (backwards) {
        _closeCellEditor(before: true);
        return;
      }
      _applyTableEdit(appendMarkdownTableRow(_controller.value, table));
      target = (row: table.rows.length, column: 0);
      appended = true;
    }
    final next = target;

    // The table has not changed, so its current geometry is already the right
    // one. Move now rather than waiting for a post-frame callback: registering
    // one does not itself schedule a frame, and another Tab could otherwise
    // still see the cell we just left and repeat the same move.
    if (!appended) {
      final field = _field;
      final rect = field == null
          ? null
          : _cellRect(field, table, next.row, next.column);
      if (rect != null) _showCellEditor(table, next.row, next.column, rect);
      return;
    }

    // The appended row does not have geometry until the controller change has
    // rebuilt and laid out the note. Record the destination immediately, both
    // to schedule that frame and so key repeat cannot act on the old cell.
    _scheduleTableCell(table.start, next.row, next.column);
  }

  /// Return moves down in the same column, adding a row at the bottom just as
  /// Tab does. A cell is one source line no matter how many painted lines it
  /// wraps onto, so Return is navigation rather than a newline.
  void _moveDownTable() {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    final nextRow = active.row + 1;
    if (nextRow < active.table.rows.length) {
      final field = _field;
      final rect = field == null
          ? null
          : _cellRect(field, active.table, nextRow, active.column);
      if (rect != null) {
        _showCellEditor(active.table, nextRow, active.column, rect);
      }
      return;
    }
    _applyTableEdit(appendMarkdownTableRow(_controller.value, active.table));
    _scheduleTableCell(active.table.start, nextRow, active.column);
  }

  /// The arrow keys at the edge of a cell's words: on to the neighbouring
  /// cell, or out of the table altogether past its first or last one.
  ///
  /// Right and Left run through the cells in reading order, as Tab does, but
  /// never add a row: walking off the end of a table with an arrow key is
  /// leaving it.
  void _moveByArrow(AxisDirection direction) {
    final active = _activeTableCell();
    final field = _field;
    if (active == null || field == null) return;
    final table = active.table;
    ({int row, int column})? target;
    switch (direction) {
      case AxisDirection.up:
        target = active.row > 0
            ? (row: active.row - 1, column: active.column)
            : null;
      case AxisDirection.down:
        target = active.row + 1 < table.rows.length
            ? (row: active.row + 1, column: active.column)
            : null;
      case AxisDirection.left:
      case AxisDirection.right:
        target = nextMarkdownTableCell(
          table,
          row: active.row,
          column: active.column,
          backwards: direction == AxisDirection.left,
        );
    }
    if (target == null) {
      _closeCellEditor(
        before:
            direction == AxisDirection.up || direction == AxisDirection.left,
      );
      return;
    }
    final rect = _cellRect(field, table, target.row, target.column);
    if (rect == null) return;
    _showCellEditor(
      table,
      target.row,
      target.column,
      rect,
      caretAtStart: direction == AxisDirection.right,
    );
  }

  MarkdownCellAlign _tableColumnAlignment(MarkdownTable table, int column) =>
      table.aligns.elementAtOrNull(column) ?? MarkdownCellAlign.start;

  /// The note field's own undo history, asked directly.
  ///
  /// Not through an [UndoHistoryController]: its `undo` refuses until the
  /// latest change has been committed to the history, which happens half a
  /// second after it is made — so ⌘Z straight after typing in a cell would do
  /// nothing. The history itself folds that pending change in first.
  UndoManagerClient? _noteUndoHistory() {
    final root = _focusNode.context;
    if (root == null) return null;
    UndoManagerClient? found;
    root.visitAncestorElements((element) {
      if (element is StatefulElement &&
          element.widget is UndoHistory<TextEditingValue> &&
          element.state is UndoManagerClient) {
        found = element.state as UndoManagerClient;
        return false;
      }
      return true;
    });
    return found;
  }

  void _undoTableEdit({required bool redo}) {
    final history = _noteUndoHistory();
    if (history == null) return;
    redo ? history.redo() : history.undo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingCell != null) _restoreTableCellEditor();
    });
  }

  void _showCellEditor(
    MarkdownTable table,
    int row,
    int column,
    Rect rect, {
    bool caretAtStart = false,
  }) {
    final cells = table.rows[row].cells;
    final source = column < cells.length
        ? _controller.text.substring(cells[column].start, cells[column].end)
        : '';
    final target = (tableStart: table.start, row: row, column: column);
    final moved = _editingCell != target;
    if (moved) setState(() => _editingCell = target);
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final alignment = _tableColumnAlignment(table, column);
    final header = table.rows[row].header;
    final base = EditorMetrics.textStyle(
      palette.textPrimary,
      widget.writingFont,
      editorScale: widget.editorTextScale,
    );
    _cellEditor.show(
      context,
      anchor: rect,
      text: source,
      caretAtStart: caretAtStart,
      reset: moved,
      style: header
          ? _controller.markdownRunStyle(base, const {
              MarkdownStyle.tableHeader,
            }, accent)
          : base,
      textAlign: switch (alignment) {
        MarkdownCellAlign.start => TextAlign.left,
        MarkdownCellAlign.center => TextAlign.center,
        MarkdownCellAlign.end => TextAlign.right,
      },
      padding: TableGeometry.padding,
      cursorColor: accent,
      background: header ? palette.controlBackground : palette.paperColor,
      border: accent,
      onChanged: _commitCellText,
      onDone: _closeCellEditor,
      onTapOutside: _cellTappedOutside,
      passThrough: AppPlatform.isMobile ? _tableControls.claims : null,
      onTab: (backwards) => _moveToCell(backwards: backwards),
      onEnter: _moveDownTable,
      onArrow: _moveByArrow,
      onCommand: (command) => unawaited(
        _runTableCommand(table.start, command, row: row, column: column),
      ),
      onContextMenu: (menu) => unawaited(
        _openTableMenu(
          table.start,
          row: row,
          column: column,
          at: menu.at,
          textItems: menu.items,
        ),
      ),
      onUndo: () => _undoTableEdit(redo: false),
      onRedo: () => _undoTableEdit(redo: true),
    );
    if (moved) _ensureCellVisible();
  }

  /// Opens the table the slash menu has just written on its first cell, with
  /// the placeholder selected to type over, as a tapped cell is opened.
  void _openNewTable(int offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final field = _field;
      if (!mounted || field == null) return;
      final table = markdownTableAt(
        _controller.markdownFor(_controller.text),
        offset,
      );
      final rect = table == null ? null : _cellRect(field, table, 0, 0);
      if (table == null || rect == null) return;
      _showCellEditor(table, 0, 0, rect);
      final cell = _cellEditor.field;
      cell.selection = TextSelection(
        baseOffset: 0,
        extentOffset: cell.text.length,
      );
    });
  }

  /// Scrolls the note just far enough for the open cell to be seen, clear of a
  /// software keyboard and of the toolbar over it.
  ///
  /// The cell's field is in an overlay, outside the note's scroll view, so
  /// nothing brings it into view the way a caret in the note is brought there.
  void _ensureCellVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final active = _activeTableCell();
      final field = _field;
      final box = field?.box;
      if (active == null || field == null || box == null) return;
      final rect = _cellRect(field, active.table, active.row, active.column);
      if (rect == null) return;
      final view = box.localToGlobal(Offset.zero) & box.size;
      final media = MediaQuery.of(context);
      final keyboardTop = media.size.height - media.viewInsets.bottom;
      const margin = 12.0;
      final top = view.top + margin;
      final bottom = math.min(view.bottom, keyboardTop) - margin;
      var delta = 0.0;
      if (rect.bottom > bottom) delta = rect.bottom - bottom;
      if (rect.top - delta < top) delta = rect.top - top;
      if (delta.abs() < 1) return;
      final position = _scrollController.position;
      final to = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _scrollController.jumpTo(to);
      _syncTableCellEditorPosition();
    });
  }

  /// Splices what the cell now says back into the one note string, per
  /// keystroke, exactly as typing into the note does — so the CRDT, presence and
  /// undo all behave as they always have. A cell that grows as it wraps is
  /// kept clear of a soft keyboard, as the note's caret is.
  void _commitCellText(String text) {
    final cell = _editingCell;
    if (cell == null || widget.readOnly) return;
    final table = markdownTableAt(
      _controller.markdownFor(_controller.text),
      cell.tableStart,
    );
    if (table == null) {
      _closeCellEditor();
      return;
    }
    final edit = setMarkdownTableCell(
      _controller.value,
      table,
      row: cell.row,
      column: cell.column,
      text: text,
    );
    if (!edit.changesText) return;
    _applyTableEdit(edit);
    if (_keyboardInset > 0) _ensureCellVisible();
  }

  /// A press outside the open cell finishes it — unless it is on the same
  /// table, where it is choosing another cell. Closing first would hand the
  /// note the keyboard only for the next cell to take it back, and on a phone
  /// the keyboard went down in that exchange and stayed down.
  void _cellTappedOutside(Offset position) {
    if (_tableControls.claims(position)) return;
    final active = _activeTableCell();
    final field = _field;
    final box = field?.box;
    if (active != null && field != null && box != null && !widget.readOnly) {
      final table = active.table;
      final geometry = _tableGrids[table];
      final first = _tableRowBand(field, table, 0);
      final last = _tableRowBand(field, table, table.rows.length - 1);
      if (geometry != null && first != null && last != null) {
        final left = box.localToGlobal(Offset.zero).dx;
        final grid = Rect.fromLTRB(
          left,
          first.top,
          left + geometry.width,
          last.bottom,
        );
        if (grid.contains(position)) return;
      }
    }
    _closeCellEditor();
  }

  /// Finishes editing a cell and gives the note its caret back.
  ///
  /// The caret has been parked on the row, among the table's hidden text, and
  /// cannot stay there: whatever was typed next would land between pipes. It
  /// goes to the line after the table, or to the one before it when [before],
  /// which is where Up out of the header or Left out of the first cell lead.
  void _closeCellEditor({bool before = false}) {
    if (_editingCell == null && !_cellEditor.isVisible) return;
    final active = _activeTableCell();
    _cellEditor.hide();
    if (mounted) setState(() => _editingCell = null);
    if (active != null) {
      final text = _controller.text;
      final table = active.table;
      final offset = before
          ? math.max(0, table.start - 1)
          : math.min(text.length, table.end + 1);
      _controller.selection = TextSelection.collapsed(offset: offset);
    }
    _focusNode.requestFocus();
  }

  /// One undoable change that also carries the note's own formats and
  /// attachments across it.
  ///
  /// Stated rather than inferred, the way [removeAttachment] does it: a table
  /// edit moves whole rows, and a diff would have to guess where everything
  /// after them went.
  void _applyTableEdit(MarkdownEdit edit) {
    final next = edit.value;
    _nextInsertedFormats = const {};
    _nextFormats = normalizeNoteFormats([
      for (final range in _formats)
        NoteFormatRange(
          start: edit.map(range.start),
          end: edit.map(range.end, before: true),
          format: range.format,
        ),
    ], next.text.length);
    _nextAttachments = normalizeNoteAttachments([
      for (final ref in _attachments)
        ref.copyWith(offset: edit.map(ref.offset)),
    ], next.text);
    // While a cell is open the note's caret is parked at the start of that
    // row. Not somewhere else in the note: the field scrolls its caret into
    // view after every change, and one left above a long table would drag the
    // note back up there on every keystroke.
    final active = _activeTableCell();
    final parked = active == null
        ? next
        : next.copyWith(
            selection: TextSelection.collapsed(
              offset: edit.map(active.table.rows[active.row].start),
            ),
            composing: TextRange.empty,
          );
    final field = _field;
    if (field == null) {
      _controller.value = parked;
    } else {
      // A keyboard cause, never the toolbar's. For any other cause the field
      // asks for the keyboard, which takes focus from the open cell — and the
      // next key typed lands in the table's hidden pipes instead.
      field.userUpdateTextEditingValue(parked, SelectionChangedCause.keyboard);
    }
  }

  Object? _titleKey;
  _TitleLayout? _title;

  /// Where the note's title, its first line, falls on the page, laid out from
  /// the very runs the field draws it with. Null off the page, for a note
  /// with no words on its first line, and for a title holding a picture or a
  /// formula, which keeps it as an ordinary line.
  ///
  /// The room under a title for its meta row cannot come from the line's own
  /// height: whatever makes a row taller sets the words lower in it as well.
  /// Nor from its line break, which has to stay a break: an empty line under
  /// the title would otherwise have no row of its own, and a caret on it
  /// would stand at the end of the title's row. So the last letter on the
  /// title's last row is drawn by a placeholder that reaches down past the
  /// row by the room. The row grows downwards and the words stay at its top.
  /// It is redone only when the title or what it is laid out from changes.
  _TitleLayout? _layOutTitle(
    BuildContext context,
    TextStyle style,
    StrutStyle strut,
    double width,
    TextScaler scaler,
    Object layoutKey,
    Iterable<int> pictures,
  ) {
    final text = _controller.text;
    final newline = text.indexOf('\n');
    final end = newline < 0 ? text.length : newline;
    final words = text.substring(0, end);
    if (words.trim().isEmpty || pictures.any((offset) => offset < end)) {
      _titleKey = null;
      return _title = null;
    }
    final key = (words, width, style, scaler, layoutKey);
    if (key == _titleKey) return _title;
    _titleKey = key;
    final full = _controller.spansIn(context, style)(0, end).span as TextSpan;
    final runs = <TextSpan>[];
    var at = 0;
    for (final run in full.children ?? const <InlineSpan>[]) {
      if (at >= end) break;
      if (run is! TextSpan || run.children != null) return _title = null;
      runs.add(run);
      at += run.text?.length ?? 0;
    }
    if (at != end) return _title = null;

    // An empty placeholder after the words, to find where the text engine
    // puts the top of one in the last row: level with the surrounding run's
    // ascent, not with the row's top.
    final painter =
        TextPainter(
            text: TextSpan(
              style: full.style,
              children: [
                ...runs,
                const WidgetSpan(
                  alignment: PlaceholderAlignment.top,
                  child: SizedBox.shrink(),
                ),
              ],
            ),
            textDirection: TextDirection.ltr,
            strutStyle: strut,
            textScaler: scaler,
          )
          ..setPlaceholderDimensions(const [
            PlaceholderDimensions(
              size: Size.zero,
              alignment: PlaceholderAlignment.top,
            ),
          ])
          ..layout(maxWidth: width);
    final lines = painter.computeLineMetrics();
    final last = lines.last;
    final row = Rect.fromLTWH(
      0,
      lines.fold(0.0, (top, line) => top + line.height) - last.height,
      width,
      last.height,
    );
    final spacerTop = painter.inlinePlaceholderBoxes!.last.top;

    // The letter: one character standing alone, so not a space, a surrogate
    // pair or a letter with a mark on it.
    TextBox? glyph;
    var letter = end;
    for (final character in words.characters.toList().reversed) {
      letter -= character.length;
      if (character.length != 1 || character.trim().isEmpty) continue;
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: letter, extentOffset: letter + 1),
      );
      if (boxes.isEmpty) continue;
      if (boxes.last.bottom <= row.top) break;
      glyph = boxes.last;
      break;
    }
    final trimmed = words.trimRight();
    final wordBoxes = painter
        .getBoxesForSelection(
          TextSelection(
            baseOffset: trimmed.lastIndexOf(RegExp(r'\s')) + 1,
            extentOffset: trimmed.length,
          ),
        )
        .where((box) => box.bottom > row.top);
    painter.dispose();
    if (glyph == null) return _title = null;

    var start = 0;
    final run = runs.firstWhere((run) {
      start += run.text?.length ?? 0;
      return letter < start;
    });
    final drawn = TextSpan(
      text: words[letter],
      style: full.style?.merge(run.style) ?? run.style,
    );
    final measure = TextPainter(
      text: drawn,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final baseline = measure.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    measure.dispose();
    // The field scales a placeholder's widget by the text scale at the size
    // of the note's own words, the span it sits in, so the letter is drawn
    // unscaled at the size that comes out right once that scale is applied:
    // the size the rest of the title is drawn at.
    final rootSize = full.style?.fontSize ?? kDefaultFontSize;
    final letterSize = drawn.style?.fontSize ?? rootSize;
    final inline = scaler.scale(rootSize) / rootSize;
    return _title = (
      letter: letter,
      drawn: TextSpan(
        text: drawn.text,
        style: drawn.style?.copyWith(
          fontSize: scaler.scale(letterSize) / inline,
        ),
      ),
      inline: inline,
      width: glyph.right - glyph.left,
      top: last.baseline - spacerTop - baseline,
      row: row,
      spacerTop: spacerTop - row.top,
      word: wordBoxes.isEmpty
          ? null
          : Rect.fromLTRB(
              wordBoxes.map((box) => box.left).reduce(math.min),
              row.top,
              wordBoxes.map((box) => box.right).reduce(math.max),
              row.bottom,
            ),
    );
  }

  /// The note's folders in the line above its title, scrolled with it.
  Widget _pathLine(
    List<PagePlace> folders,
    void Function(String folderId, {required bool behind})? onOpenFolder,
    EdgeInsets padding,
  ) => ClipRect(
    child: ListenableBuilder(
      listenable: _scrollController,
      builder: (context, line) => Stack(
        children: [
          Positioned(
            left: padding.left,
            right: padding.right,
            top:
                padding.top -
                EditorMetrics.pathRow -
                EditorMetrics.pathGap -
                (_scrollController.hasClients ? _scrollController.offset : 0),
            child: line!,
          ),
        ],
      ),
      child: NotePathLine(folders: folders, onOpenFolder: onOpenFolder),
    ),
  );

  /// The title's underline and the meta row under it, scrolled with the
  /// text they belong to.
  Widget _titleMarks(_TitleLayout title, EdgeInsets padding, double column) {
    final checklist = _checklist();
    final now = (widget.now ?? DateTime.now)();
    final displayTime = widget.displayTime ?? (time) => time.toLocal();
    final shelved = TagShelf.maybeOf(context) != null;
    final scale = title.row.height / EditorMetrics.titleRow;
    return ClipRect(
      child: ListenableBuilder(
        listenable: _scrollController,
        builder: (context, meta) {
          final y =
              padding.top -
              (_scrollController.hasClients ? _scrollController.offset : 0);
          return Stack(
            children: [
              Positioned(
                left: padding.left,
                right: AppPlatform.isMobile ? padding.right : null,
                top: y + title.row.bottom + EditorMetrics.metaGap * scale,
                child: meta!,
              ),
            ],
          );
        },
        child: _ReportsHeight(
          onHeight: widget.phone ? _onPhoneMetaHeight : null,
          child: NoteMetaRow(
            day: NoteDayScope.maybeOf(context)?.dayOf(widget.noteId),
            edited: displayTime(
              (widget.phone ? widget.createdAt : null) ??
                  widget.lastUpdatedAt ??
                  now,
            ),
            today: displayTime(now),
            done: checklist.done,
            tasks: checklist.total,
            total: _totalText,
            describeTotal: _describeTotal,
            totalLeavesOut: _totalLeavesOut,
            typing: widget.typing,
            readOnlyLabel: widget.readOnly ? widget.readOnlyLabel : null,
            readOnlyIcon: widget.readOnlyIcon,
            onReadOnlyPressed: widget.onReadOnlyPressed,
            tags: shelved ? NoteTagChips(noteId: widget.noteId) : null,
            addTag: shelved && !widget.phone
                ? NoteAddTag(noteId: widget.noteId)
                : null,
            phone: widget.phone,
            width: column,
          ),
        ),
      ),
    );
  }

  /// The room between the title and the body, for the meta row. On a phone
  /// that is its one line, or as many lines as it wraps onto.
  double _titleRoom(TextScaler textScaler) {
    final scale = widget.editorTextScale;
    if (!widget.phone) {
      return textScaler.scale(EditorMetrics.titleReserve * scale);
    }
    return textScaler.scale(
          (EditorMetrics.metaGap + EditorMetrics.metaBottom) * scale,
        ) +
        math.max(
          _phoneMetaHeight,
          textScaler.scale(EditorMetrics.phoneMetaRow * scale),
        );
  }

  /// How tall a phone's meta row came out, once its facts and tags wrapped.
  double _phoneMetaHeight = 0;

  void _onPhoneMetaHeight(double height) {
    if (!mounted || height == _phoneMetaHeight) return;
    setState(() => _phoneMetaHeight = height);
  }

  /// The faint "+" beside an empty line, the caret's or the pointer's, that
  /// opens Commands there.
  Widget _emptyLineMarks(EdgeInsets padding) {
    _scheduleLineMarks();
    return ListenableBuilder(
      listenable: Listenable.merge([_lineMarks, _scrollController]),
      builder: (context, _) {
        final y =
            padding.top -
            (_scrollController.hasClients ? _scrollController.offset : 0);
        final palette = context.palette;
        return Stack(
          children: [
            for (final mark in _lineMarks.value) ...[
              if (AppPlatform.hasPointer)
                Positioned(
                  left: padding.left - _lineCommandsExtent - 12,
                  top: y + mark.middle - _lineCommandsExtent / 2,
                  child: Semantics(
                    button: true,
                    label: 'Commands',
                    onTap: () => _openCommandsAt(mark.line),
                    excludeSemantics: true,
                    child: ExcludeFocus(
                      child: CompactIconButton(
                        key: const ValueKey('line-commands'),
                        tooltip: 'Commands',
                        extent: _lineCommandsExtent,
                        selected: mark.hovered,
                        foregroundColor: mark.hovered
                            ? palette.textPrimary
                            : palette.lineCommand,
                        onPressed: () => _openCommandsAt(mark.line),
                        icon: KapyIcon(KapyIcons.addRounded, size: 16),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  /// The language and Copy in the header of each fenced code block whose
  /// fence is hidden, in the row the fence keeps, which the backdrop rules
  /// off: Paper's code block.
  Widget _codeHeaders(
    EdgeInsets padding,
    MarkdownAnalysis markdown,
    MarkdownConcealment concealment,
    double width,
  ) {
    final headers = [
      for (final block in markdown.blocks)
        if (markdown.fencesOf(block) case final fences?
            when concealment.hides(fences.open.start, fences.open.end))
          (block: block, fences: fences, at: fences.open.start),
    ];
    if (headers.isEmpty) return const SizedBox.shrink();
    // The field places its lines as it lays them out, after this is built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fieldLaidOut.value++);
    return ListenableBuilder(
      listenable: Listenable.merge([_scrollController, _fieldLaidOut]),
      builder: (context, _) {
        final field = _field;
        return Stack(
          children: [
            if (field != null)
              for (final header in headers)
                if (field.lineTop(field.lines.lineAt(header.at))
                    case final top?)
                  if (field.lineTop(field.lines.lineAt(header.at) + 1)
                      case final bottom?)
                    Positioned(
                      left: padding.left,
                      width: width,
                      top:
                          padding.top +
                          top +
                          (bottom - top) *
                              EditorMetrics.codeGapBefore /
                              EditorMetrics.codeOpenRow,
                      height:
                          (bottom - top) *
                          EditorMetrics.codeHeader /
                          EditorMetrics.codeOpenRow,
                      child: _CodeBlockHeader(
                        inset:
                            (bottom - top) *
                            EditorMetrics.codeInset /
                            EditorMetrics.codeOpenRow,
                        language: header.fences.language,
                        onCopy: () =>
                            unawaited(_copyCode(header.block, header.fences)),
                      ),
                    ),
          ],
        );
      },
    );
  }

  Future<void> _copyCode(MarkdownBlock block, MarkdownCodeFences fences) async {
    final text = _controller.text;
    final start = math.min(fences.open.end + 1, text.length);
    final end = math.max(start, fences.close?.start ?? block.end);
    final code = text.substring(start, end).replaceFirst(RegExp(r'\n$'), '');
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) Toast.show(context, 'Code copied');
  }

  /// Measures the empty lines that get a "+" once the field has laid out,
  /// since a line's place is only known then.
  void _scheduleLineMarks() {
    if (_lineMarksScheduled) return;
    _lineMarksScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lineMarksScheduled = false;
      if (!mounted) return;
      final field = _field;
      final selection = _controller.selection;
      final caretLine =
          _focusNode.hasFocus &&
              selection.isValid &&
              selection.isCollapsed &&
              !_slashCommandMenu.isVisible
          ? _emptyLineAt(selection.baseOffset)
          : null;
      final hoverLine = _hoverLine.value;
      // The field's rects are scrolled; the marks keep the text's own place
      // and scroll with it.
      final scrolled = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final marks = field == null || field.box == null || _isEmpty
          ? const <_LineMark>[]
          : [
              for (final line in {?caretLine, ?hoverLine})
                if (field.caretRectAt(TextPosition(offset: line))
                    case final caret?)
                  (
                    line: line,
                    middle: caret.center.dy + scrolled,
                    hovered: line == hoverLine,
                  ),
            ];
      if (!listEquals(marks, _lineMarks.value)) _lineMarks.value = marks;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  static const double _lineCommandsExtent = 22;

  /// Where the line holding [offset] starts, when there is nothing on it.
  int? _emptyLineAt(int offset) {
    final text = _controller.text;
    if (offset < 0 || offset > text.length) return null;
    final start = offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    final end = text.indexOf('\n', start);
    return (end < 0 ? text.length : end) == start ? start : null;
  }

  /// The empty line under the pointer at [global], if there is one.
  int? _emptyLineUnder(Offset global, double rowHeight) {
    final field = _field;
    final box = field?.box;
    if (field == null || box == null) return null;
    final line = _emptyLineAt(field.positionAt(global).offset);
    final caret = line == null
        ? null
        : field.caretRectAt(TextPosition(offset: line));
    if (caret == null) return null;
    final middle = box.localToGlobal(caret.center);
    return (global.dy - middle.dy).abs() <= rowHeight / 2 ? line : null;
  }

  void _openCommandsAt(int line) {
    _hoverLine.value = null;
    _controller.selection = TextSelection.collapsed(offset: line);
    _focusNode.requestFocus();
    _showInsertMenu(search: !AppPlatform.isMobile);
  }

  /// A number in a table's cell: a sign, a currency, digits and a percent.
  static final _tableNumber = RegExp(r'^[+\-−]?[₹$€£]?\d[\d.,]*%?$');

  /// What stands in each attachment's place in the text, [drawnWidth] wide.
  ///
  /// The field draws a placeholder's widget scaled by [inline], the text
  /// scale at the size of the note's words, the way it draws the words. So
  /// each attachment is laid out at its size over [inline], with its own
  /// words unscaled, and the text engine is told the size it comes out at:
  /// it grows with the writing, and its words grow once.
  Map<int, NoteImageSpan> _buildAttachmentSpans(
    double drawnWidth,
    double viewportHeight,
    double inline,
  ) {
    final store = widget.images;
    if (_attachments.isEmpty || store == null) return const {};
    final columnWidth = drawnWidth / inline;

    // Tall images are capped rather than allowed to fill the screen: a note is
    // writing with pictures in it, not a gallery with captions.
    final maxHeight =
        (viewportHeight.isFinite && viewportHeight > 0
            ? viewportHeight * 0.6
            : 420.0) /
        inline;
    final body = _controller.text;

    final spans = <int, NoteImageSpan>{};
    for (final ref in _attachments) {
      // Every kind must be answered for. A ref this build cannot draw still
      // occupies a placeholder, and leaving it out of the span map would leave
      // the text engine rendering a bare U+FFFC — an invisible character the
      // caret can land inside — where a newer build shows an attachment.
      // Both chips stretch to whatever they are handed, and what the text
      // engine hands a placeholder is the rest of the line — so unlike an
      // image, which carries its own measured box, they have to be told the
      // width or they would fill the column and take the slack back.
      if (ref is NoteVoiceRef) {
        final chip = _voiceChip(ref);
        spans[ref.offset] = (
          width: columnWidth,
          height: noteVoiceChipHeight + noteImageGap,
          child: SizedBox(width: columnWidth, child: chip),
        );
        continue;
      }
      if (ref is NoteFileRef) {
        spans[ref.offset] = (
          width: columnWidth,
          height: noteFileChipHeight + noteImageGap,
          child: SizedBox(
            width: columnWidth,
            child: NoteFileChip(
              key: ValueKey('note-file-${ref.hash}-${ref.offset}'),
              ref: ref,
              store: store,
              fetch: widget.imageFetch,
              uploadProgress: ref.isUploaded
                  ? null
                  : widget.uploadProgressFor?.call(ref.hash),
              onRemove: widget.readOnly
                  ? null
                  : () => removeAttachment(ref.offset),
            ),
          ),
        );
        continue;
      }
      if (ref is NoteVideoRef) {
        final box = imageBoxFor(
          countOnLine: 1,
          columnWidth: columnWidth,
          aspectRatio: ref.aspectRatio,
          maxHeight: maxHeight,
          widthFactor: ref.widthFactor,
        );
        spans[ref.offset] = (
          width: box.width,
          height: box.height + noteImageGap,
          child: NoteVideoView(
            key: ValueKey('note-video-${ref.hash}-${ref.offset}'),
            ref: ref,
            box: box,
            store: store,
            fetch: widget.imageFetch,
            uploadProgress: ref.isUploaded
                ? null
                : widget.uploadProgressFor?.call(ref.hash),
            onRemove: widget.readOnly
                ? null
                : () => removeAttachment(ref.offset),
          ),
        );
        continue;
      }
      if (ref is! NoteImageRef) {
        spans[ref.offset] = (
          width: columnWidth,
          height: _UnknownChip.height + noteImageGap,
          child: SizedBox(width: columnWidth, child: const _UnknownChip()),
        );
        continue;
      }
      final onLine = imagesOnLineAt(body, ref.offset, _attachments);
      final box = imageBoxFor(
        countOnLine: onLine,
        columnWidth: columnWidth,
        aspectRatio: ref.aspectRatio,
        maxHeight: maxHeight,
        widthFactor: ref.widthFactor,
      );
      final selection = _controller.selection;
      final selected =
          selection.isValid &&
          !selection.isCollapsed &&
          selection.start <= ref.offset &&
          selection.end > ref.offset;
      spans[ref.offset] = (
        width: box.width,
        // The vertical padding the view draws is part of the box the text
        // engine has to reserve, or the line clips its own image.
        height: box.height + noteImageGap,
        child: NoteImageView(
          key: ValueKey('note-image-${ref.hash}-${ref.offset}'),
          ref: ref,
          box: box,
          store: store,
          columnWidth: columnWidth,
          // Only a picture that has its line to itself: a tile's width comes
          // from how many share the row.
          resizable: !widget.readOnly && onLine <= 1,
          selected: selected,
          fetch: widget.imageFetch,
          uploadProgress: ref.isUploaded || ref.isPreparing
              ? null
              : widget.uploadProgressFor?.call(ref.hash),
          onSelect: () => _selectImage(ref),
          onOpen: () => NoteImageViewer.open(
            context,
            ref: ref,
            store: store,
            fetch: widget.imageFetch,
          ),
          onCopy: () => _copyImageFromMenu(ref),
          onResize: widget.readOnly
              ? null
              : (factor) => _resizeImage(ref.offset, factor),
          onResizeEnd: widget.readOnly ? null : _commitAttachments,
          onRemove: widget.readOnly ? null : () => removeAttachment(ref.offset),
          onRetry: widget.readOnly || ref.src == null
              ? null
              : () => _retryPastedImage(ref),
        ),
      );
    }
    return {
      for (final MapEntry(key: offset, value: span) in spans.entries)
        offset: (
          width: span.width * inline,
          height: span.height * inline,
          child: span.child,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // No home indicator inset here: the footer below runs under it and keeps
    // its own controls clear of it, so an inset on the text would only open a
    // second gap above a bar that already covers that strip.
    var basePadding = AppPlatform.isMobile
        ? EditorMetrics.phonePadding
        : EditorMetrics.padding;
    // A phone on its side, with the keyboard up, has no room to spare: the
    // lines take the padding rather than being pushed out of sight.
    if (widget.cramped) basePadding = basePadding.copyWith(top: 0, bottom: 0);
    final noteFolders = EditorMetrics.page || widget.phone
        ? NoteFolders.maybeOf(context)
        : null;
    final folders = <PagePlace>[
      for (final folder
          in noteFolders?.tree.pathOfNote(widget.noteId) ?? const [])
        (name: folder.name, folderId: folder.id),
    ];
    if (folders.isNotEmpty) {
      basePadding = basePadding.copyWith(
        top: basePadding.top + EditorMetrics.pathRow + EditorMetrics.pathGap,
      );
    }
    final textStyle = EditorMetrics.textStyle(
      palette.textPrimary,
      widget.writingFont,
      editorScale: widget.editorTextScale,
    );
    final strut = EditorMetrics.strut(
      widget.writingFont,
      editorScale: widget.editorTextScale,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final writingSize = textStyle.fontSize ?? kDefaultFontSize;
    final mobileTableCell = AppPlatform.isMobile ? _activeTableCell() : null;
    final statusShown = widget.readOnly || widget.typing.isNotEmpty;

    // A drop lands on the page as a whole, not on the text field: dragging a
    // picture over a note and having to aim at the caret would be worse than
    // useless. Where it goes is decided by the caret already in the note.
    final page = Container(
      color: palette.paperColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The words move with the pane, when the window is resized
                // or the sidebar opens, and the bubble over a selection
                // goes with them.
                if (_selectionBubble.isVisible) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _selectionBubble.isVisible) {
                      _showSelectionBubble();
                    }
                  });
                }
                // Results take width only from their own lines, so prose,
                // checklists, and journals keep the full writing width.
                final resultsVisible =
                    widget.resultsVisible && _results.isNotEmpty;
                final textPaneWidth = constraints.maxWidth;

                // The page centres a column of [EditorMetrics.columnWidth].
                final side = math.max(
                  basePadding.left,
                  (textPaneWidth - EditorMetrics.columnWidth) / 2,
                );
                final padding = basePadding.copyWith(left: side, right: side);

                // Must match the text field's own content box exactly, right
                // down to the sliver it holds back for the caret.
                final trailingGap = side - EditorMetrics.caretMargin;
                final contentWidth = EditorMetrics.textLayoutWidth(
                  textPaneWidth - padding.left - trailingGap,
                );

                // Measure the exact span the field will paint, at the exact
                // width it will paint into.
                // Images are sized here and nowhere else: this is the first
                // point at which the writing column's width is known, and an
                // image that fills the column has to be told what that is.
                // Attachments are laid out into a slightly narrower column
                // than the text; see noteAttachmentColumnSlack for the line
                // that goes missing without it.
                final attachmentWidth = math.max(
                  1.0,
                  contentWidth - noteAttachmentColumnSlack,
                );

                // Paper's attachments fill the column. What the text engine is
                // told of them stays [attachmentWidth] wide, so the line under
                // one survives; the attachment itself is drawn the column wide.
                final drawnWidth = contentWidth;

                final markdown = _controller.markdownFor(_controller.text);
                // Markdown is shown as written only in a note being edited:
                // blocks with the caret in them, inline markers with the
                // caret against them — and those not while typing. A table is
                // never shown as written at all, wherever the caret is; see
                // MarkdownAnalysis.concealFor.
                final editing = _editingNote && !widget.readOnly;
                _controller.markdownReveal = (
                  blocks: editing,
                  edges: editing && !_markdownQuiet,
                );
                final concealment = _controller.markdownConcealment();
                if (_findOpen) _refreshFind(_find!);

                // Every table's grid, fitted to the writing column so that a
                // wide one shrinks and wraps rather than running off the side of
                // a phone. Worked out here for the same reason images are sized
                // here: it is the first point at which the width is known.
                final rowHeight = textScaler.scale(
                  EditorMetrics.lineHeight * widget.editorTextScale,
                );
                // Paper's cells are 15px words on 20px lines in rows of 36,
                // and a number in one is set in the mono face at 14.
                final cellStyle = textStyle.copyWith(
                  fontSize: textStyle.fontSize! * 15 / 16,
                  height: 20 / 15,
                );
                _tableGrids = {
                  for (final table in markdown.tables)
                    table: _tableGeometry.of(
                      table: table,
                      analysis: markdown,
                      base: cellStyle,
                      scaler: textScaler,
                      fitToWidth: drawnWidth,
                      fill: true,
                      minRowHeight: textScaler.scale(
                        EditorMetrics.tableRow * widget.editorTextScale,
                      ),
                      style: (palette, Theme.of(context).colorScheme.primary),
                      runStyle: (base, styles, words) {
                        var drawn = _controller.markdownRunStyle(
                          base,
                          styles,
                          Theme.of(context).colorScheme.primary,
                          words: words,
                        );
                        if (!styles.contains(MarkdownStyle.tableHeader) &&
                            _tableNumber.hasMatch(words.trim())) {
                          drawn = drawn.copyWith(
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                            fontSize: base.fontSize! * 14 / 15,
                            color: switch (words.trim()[0]) {
                              '+' => palette.codeString,
                              '-' || '−' => palette.textSecondary,
                              _ => drawn.color,
                            },
                          );
                        }
                        // The pill inline code has in the text can be a plain
                        // background in a grid painted behind it: there is no
                        // selection to show over it there. A formula in a cell
                        // is drawn as its TeX, which is code too.
                        return styles.contains(MarkdownStyle.code) ||
                                styles.contains(MarkdownStyle.math)
                            ? drawn.copyWith(
                                backgroundColor: palette.controlBackground,
                              )
                            : drawn;
                      },
                    ),
                };

                _controller.setMathWidthDuringLayout(attachmentWidth);
                _controller.setTableRowsDuringLayout({
                  for (final table in markdown.tables)
                    for (final row in table.rows)
                      if (_tableGrids[table] case final grid?)
                        row.start:
                            grid.rowHeight(row) /
                            textScaler.scale(widget.editorTextScale),
                });
                final spacers = {
                  for (final MapEntry(:key, :value) in _buildAttachmentSpans(
                    drawnWidth,
                    constraints.maxHeight,
                    textScaler.scale(writingSize) / writingSize,
                  ).entries)
                    key: (
                      width: math.min(value.width, attachmentWidth),
                      height: value.height,
                      child: value.child,
                    ),
                };
                final layoutKey = (
                  widget.writingFont,
                  widget.editorTextScale,
                  _formats,
                  widget.markdownEnabled,
                  concealment.key,
                );
                _controller.setImageSpansDuringLayout(spacers);
                final title = _layOutTitle(
                  context,
                  textStyle,
                  strut,
                  contentWidth,
                  textScaler,
                  layoutKey,
                  spacers.keys,
                );
                // The title's last letter stands in for the room under it,
                // drawn at the top of a placeholder that reaches below the
                // row, so the line under the title starts below the room.
                if (title != null) {
                  final height =
                      title.row.height -
                      title.spacerTop +
                      _titleRoom(textScaler);
                  // The field scales the placeholder's widget once more, so
                  // its lengths go in unscaled.
                  final inline = title.inline;
                  spacers[title.letter] = (
                    width: title.width,
                    height: height,
                    child: SizedBox(
                      width: title.width / inline,
                      height: height / inline,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            top: title.top / inline,
                            child: RichText(
                              text: title.drawn,
                              textScaler: TextScaler.noScaling,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  _controller.setImageSpansDuringLayout(spacers);
                }
                if (_editingCell != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _syncTableCellEditorPosition();
                  });
                }
                final checkboxes = _controller.plainCheckboxes(
                  _controller.text,
                );
                final chips = _controller.linkChips(_controller.text);
                final leaderColor = palette.textTertiary.withValues(alpha: 0.3);

                // The chip follows the paste's caret once the field has laid
                // it out, wherever this layout put it.
                if (_pasteChipShown) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _placePasteChip();
                  });
                }

                final note = MouseRegion(
                  opaque: false,
                  onHover: widget.readOnly || !AppPlatform.hasPointer
                      ? null
                      : (event) => _hoverLine.value = _emptyLineUnder(
                          event.position,
                          rowHeight,
                        ),
                  onExit: (_) => _hoverLine.value = null,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: textPaneWidth,
                              child: NotebookPaper(
                                style: widget.paperStyle,
                                lineHeight: rowHeight,
                                topInset:
                                    padding.top +
                                    (title == null
                                        ? 0
                                        : title.row.bottom +
                                              _titleRoom(textScaler)),
                                scroll: _scrollController,
                                child: Stack(
                                  children: [
                                    if (_isEmpty)
                                      _Placeholder(
                                        padding: padding,
                                        style: textStyle,
                                        strut: strut,
                                        writingFont: widget.writingFont,
                                        phone: widget.phone,
                                      ),
                                    // A note with a table always needs it, even
                                    // on a device with markdown switched off. A
                                    // plain note gains no layer it did not have.
                                    if (widget.markdownEnabled ||
                                        markdown.tables.isNotEmpty ||
                                        checkboxes.isNotEmpty ||
                                        chips.isNotEmpty)
                                      Positioned.fill(
                                        child: IgnorePointer(
                                          child: MarkdownBackdrop(
                                            analysis: markdown,
                                            concealment: concealment,
                                            grids: _tableGrids,
                                            scroll: _scrollController,
                                            field: () => _field,
                                            colors: MarkdownBackdropColors(
                                              quiet: palette.textSecondary,
                                              rule: palette.separator,
                                              quoteBar: palette.quoteBar,
                                              panel: palette.controlBackground,
                                              panelBorder:
                                                  palette.controlBorder,
                                              codePanel: palette.codePanel,
                                              codeChip: palette.codeChip,
                                              accent: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              onAccent: Theme.of(
                                                context,
                                              ).colorScheme.onPrimary,
                                              box: palette.checkboxBorder,
                                              chip: palette.controlBackground,
                                              chipInk: palette.textMuted,
                                            ),
                                            checkboxes: checkboxes,
                                            chips: chips,
                                            markerRoom: _controller
                                                .markdownMarkerRoom(
                                                  textStyle,
                                                  textScaler,
                                                ),
                                          ),
                                        ),
                                      ),
                                    if (_convertedPaste case final paste?)
                                      Positioned.fill(
                                        child: PasteWash(
                                          key: ObjectKey(paste),
                                          repaint: _scrollController,
                                          rows: () => _pastedRows(
                                            paste,
                                            padding,
                                            contentWidth,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned.fill(
                        child: _buildField(
                          padding,
                          textStyle,
                          strut,
                          columnWidth: contentWidth,
                          trailingOf: resultsVisible
                              ? (line) => switch (_results[line]) {
                                  null => null,
                                  final result when widget.keepResultRoom => (
                                    child: ResultChip(
                                      result: result,
                                      collapsedWidth: contentWidth,
                                    ),
                                    leader: null,
                                    right: contentWidth,
                                    room:
                                        ResultChip.widthOf(context, result) +
                                        lineTrailingGap,
                                    height: ResultChip.heightOf(
                                      context,
                                      result,
                                      contentWidth,
                                    ),
                                  ),
                                  final result => (
                                    child: ResultChip(
                                      result: result,
                                      collapsedWidth: contentWidth / 2,
                                      look: ResultChipLook.pill,
                                    ),
                                    leader: ResultLeader(
                                      key: ValueKey('result-leader-$line'),
                                      color: leaderColor,
                                    ),
                                    right: contentWidth,
                                    room: 0.0,
                                    height: 0.0,
                                  ),
                                }
                              : null,
                        ),
                      ),
                      if (!widget.readOnly && markdown.tables.isNotEmpty)
                        Positioned.fill(
                          child: TableControlsLayer(
                            frames: _tableFrames,
                            repaint: Listenable.merge([
                              _scrollController,
                              _controller,
                            ]),
                            scroll: _scrollController,
                            controller: _tableControls,
                            editing: switch (_editingCell) {
                              final cell? => (
                                table: cell.tableStart,
                                row: cell.row,
                                column: cell.column,
                              ),
                              null => null,
                            },
                            touch: !AppPlatform.hasPointer,
                            onInsert: _insertTableLine,
                            onMove: _moveTableLine,
                            onResize: _resizeTableColumn,
                            onMenu: _showTableMenu,
                          ),
                        ),
                      if (noteFolders != null && folders.isNotEmpty)
                        Positioned.fill(
                          child: _pathLine(
                            folders,
                            noteFolders.onOpenFolder,
                            padding,
                          ),
                        ),
                      if (title != null)
                        Positioned.fill(
                          child: _titleMarks(
                            title,
                            padding,
                            textPaneWidth - padding.horizontal,
                          ),
                        ),
                      if (!widget.readOnly)
                        Positioned.fill(child: _emptyLineMarks(padding)),
                      if (widget.markdownEnabled)
                        Positioned.fill(
                          child: _codeHeaders(
                            padding,
                            markdown,
                            concealment,
                            contentWidth,
                          ),
                        ),
                      if (widget.remoteCarets case final source?)
                        Positioned.fill(
                          child: RemoteCaretLayer(
                            noteId: widget.noteId,
                            source: source,
                            controller: _controller,
                            scroll: _scrollController,
                            field: () => _field,
                            hover: _remoteHover,
                            tableCaretRect: _remoteTableCaretRect,
                            tableSelectionRects: _remoteTableSelectionRects,
                          ),
                        ),
                      // Only where there is room for it beside the writing.
                      if (textPaneWidth >= EditorMetrics.columnWidth + 120)
                        Positioned(
                          right: -6,
                          bottom: 0,
                          child: KapyPagePeek(
                            held: widget.idlePeekHeld,
                            activity: _controller,
                          ),
                        ),
                      if (_pasteChipShown)
                        Positioned.fill(
                          child: ValueListenableBuilder(
                            valueListenable: _pasteCaret,
                            builder: (context, caret, _) => caret == null
                                ? const SizedBox.shrink()
                                : PasteChip(
                                    key: ObjectKey(_convertedPaste),
                                    caret: caret.shift(padding.topLeft),
                                    shortcut: widget.shortcuts
                                        .hintFor(
                                          ShortcutAction.pasteAsPlainText,
                                        )
                                        ?.keycapLabel,
                                    onPlainText: _pastePlainInstead,
                                    onDismissed: _dismissPasteChip,
                                  ),
                          ),
                        ),
                    ],
                  ),
                );
                // The find bar pushes the note down rather than lying over
                // what it finds. The note keeps the page's whole height for
                // sizing its pictures, so none of them change as it opens.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_findOpen)
                      NoteFindBar(
                        find: _find!,
                        side: side,
                        onNext: _stepFind,
                        onPrevious: () => _stepFind(back: true),
                        onClose: _closeFind,
                      ),
                    Expanded(child: note),
                  ],
                );
              },
            ),
          ),
          if (!widget.readOnly && _liveSession != null) ...[
            if (widget.recording?.liveText case final text?)
              LiveTextCard(
                text: text,
                prefs: widget.recording!.live!.prefs,
                paused: _liveSession!.paused,
                wide: !AppPlatform.isMobile,
              ),
            VoiceRecordingBar(
              session: _liveSession!,
              onPause: widget.recording?.pause,
              onResume: widget.recording?.resume,
              onStop: widget.onRecordVoice,
              onCancel: () => unawaited(widget.recording!.cancel()),
            ),
          ]
          else if (!AppPlatform.isMobile)
            SizedBox(height: MediaQuery.paddingOf(context).bottom)
          else ...[
            if (statusShown)
              NoteFooter(
                typing: widget.typing,
                readOnly: widget.readOnly,
                readOnlyLabel: widget.readOnlyLabel,
                readOnlyIcon: widget.readOnlyIcon,
                onReadOnlyPressed: widget.onReadOnlyPressed,
              ),
            if (_formatBarShown)
              PhoneFormatBar(
                actions: _formatBarActions(mobileTableCell),
                tapGroup: mobileTableCell == null ? EditableText : _cellEditor,
                onDismissKeyboard: _dismissKeyboard,
              )
            else if (!statusShown)
              SizedBox(height: MediaQuery.paddingOf(context).bottom),
          ],
        ],
      ),
    );

    return ImageDropTarget(
      enabled: !widget.readOnly && widget.images != null,
      onFiles: (files) => unawaited(insertDroppedMedia(files)),
      // Without semantics of its own, which would gather the page's labels
      // into one.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: _findKey,
        child: page,
      ),
    );
  }

  Widget _buildField(
    EdgeInsets padding,
    TextStyle textStyle,
    StrutStyle strut, {
    required double columnWidth,
    required LineTrailing? Function(int line)? trailingOf,
  }) {
    // The field places its lines as it lays them out, after this is built, so
    // the details marks read those places on the frame after.
    if (_blocks().any((block) => block.details != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fieldLaidOut.value++;
      });
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: padding.left,
            top: padding.top,
            bottom: padding.bottom,
          ),
          child: Focus(
            // Not a focus stop of its own; it only watches the field below for Tab
            // before the app's traversal shortcuts can claim it.
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _handleEditorKey,
            child: Actions(
              actions: {
                UndoTextIntent: _ShortcutUndoAction(_undoMarkdownShortcut),
              },
              child: _textField(textStyle, strut, columnWidth, trailingOf),
            ),
          ),
        ),
        Positioned.fill(
          child: ListenableBuilder(
            listenable: _fieldLaidOut,
            builder: (context, _) => TaskDetailsChrome(
              field: _field,
              text: _controller.text,
              caret: _controller.selection.isValid
                  ? _controller.selection.extentOffset
                  : -1,
              folded: _taskFolded,
              onToggle: _toggleFold,
              showHint: _folds != null && !_folds!.hintSeen,
              origin: Offset(padding.left, padding.top),
            ),
          ),
        ),
      ],
    );
  }

  Widget _textField(
    TextStyle textStyle,
    StrutStyle strut,
    double columnWidth,
    LineTrailing? Function(int line)? trailingOf,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleEditorScrollNotification,
      child: MouseRegion(
        // Hover only. The cursor itself goes to the field below: it builds
        // its own MouseRegion around the text, and the innermost region under
        // the pointer is the one that decides, so setting it here would be
        // silently overridden.
        onHover: _handleHover,
        onExit: (_) => _handleHoverExit(),
        child: Listener(
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          // The field builds its copy and paste with `Action.overridable`, so
          // these take their place: the rich copy, and the paste that brings
          // pictures along.
          child: Actions(
            actions: {
              CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
                onInvoke: (intent) {
                  _handleCopyIntent(intent);
                  return null;
                },
              ),
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (intent) => handlePaste(intent.cause),
              ),
            },
            // A cleared shortcut binds nothing; the footer button beside it is
            // still there, and is now the only way in.
            child: CallbackShortcuts(
              bindings: {
                ?widget.shortcuts
                        .bindingFor(ShortcutAction.cycleTextStyle)
                        ?.activator:
                    _cycleParagraphStyle,
                ?widget.shortcuts
                    .bindingFor(ShortcutAction.formatBold)
                    ?.activator: () =>
                    _toggleInlineFormat(NoteFormat.bold),
                ?widget.shortcuts
                    .bindingFor(ShortcutAction.formatItalic)
                    ?.activator: () =>
                    _toggleInlineFormat(NoteFormat.italic),
                ?widget.shortcuts
                    .bindingFor(ShortcutAction.formatStrikethrough)
                    ?.activator: () =>
                    unawaited(_toggleMarkdownWrap('~~', 'Strikethrough')),
                ?widget.shortcuts
                    .bindingFor(ShortcutAction.formatCode)
                    ?.activator: () =>
                    unawaited(_toggleMarkdownWrap('`', 'Inline code')),
                ?widget.shortcuts
                    .bindingFor(ShortcutAction.pasteAsPlainText)
                    ?.activator: () =>
                    unawaited(_pastePlainText(SelectionChangedCause.keyboard)),
                if (widget.readOnly && AppPlatform.isMacOS) ...{
                  const SingleActivator(LogicalKeyboardKey.tab): () =>
                      _focusNode.nextFocus(),
                  const SingleActivator(
                    LogicalKeyboardKey.tab,
                    shift: true,
                  ): () =>
                      _focusNode.previousFocus(),
                },
                if (AppPlatform.isWindows || AppPlatform.isLinux)
                  const SingleActivator(
                    LogicalKeyboardKey.keyY,
                    control: true,
                  ): () => Actions.maybeInvoke(
                    _focusNode.context!,
                    const RedoTextIntent(SelectionChangedCause.keyboard),
                  ),
                // The Mac's own Paste and Match Style, alongside whatever
                // the setting above says.
                if (AppPlatform.isMacOS)
                  const SingleActivator(
                    LogicalKeyboardKey.keyV,
                    meta: true,
                    alt: true,
                    shift: true,
                  ): () => unawaited(
                    _pastePlainText(SelectionChangedCause.keyboard),
                  ),
                ?widget.shortcuts
                        .bindingFor(ShortcutAction.formatBullets)
                        ?.activator:
                    _toggleBullets,
                ?widget.shortcuts
                        .bindingFor(ShortcutAction.formatChecklist)
                        ?.activator:
                    _toggleChecklist,
                if (!widget.readOnly && widget.onRecordVoice != null)
                  ?widget.shortcuts
                          .bindingFor(ShortcutAction.recordVoiceNote)
                          ?.activator:
                      widget.onRecordVoice!,
                if (!widget.readOnly && widget.images != null) ...{
                  if (widget.cameraAcquirer != null)
                    ?widget.shortcuts
                        .bindingFor(ShortcutAction.openCamera)
                        ?.activator: () =>
                        unawaited(openCameraAndInsert()),
                  ?widget.shortcuts
                      .bindingFor(ShortcutAction.insertImage)
                      ?.activator: () =>
                      unawaited(pickAndInsertImages()),
                  ?widget.shortcuts
                      .bindingFor(ShortcutAction.insertVideo)
                      ?.activator: () =>
                      unawaited(pickAndInsertVideos()),
                  ?widget.shortcuts
                      .bindingFor(ShortcutAction.insertFile)
                      ?.activator: () =>
                      unawaited(pickAndInsertFileAttachments()),
                },
                ?widget.shortcuts
                        .bindingFor(ShortcutAction.openSettings)
                        ?.activator:
                    widget.onSettingsPressed,
              },
              child: NoteField(
                key: _fieldKey,
                mouseCursor: _hoverCursor,
                controller: _controller,
                focusNode: _focusNode,
                scrollController: _scrollController,
                autofocus: !widget.readOnly && widget.autofocus,
                readOnly: widget.readOnly,
                style: textStyle,
                strut: strut,
                columnWidth: columnWidth,
                trailingOf: trailingOf,
                selectionOf: _tableSelectionOf,
                adjustSpan: _adjustTaskFold,
                found: _found(),
                cursorWidth: EditorMetrics.cursorWidth,
                cursorHeight: EditorMetrics.cursorHeight(
                  widget.writingFont,
                  editorScale: widget.editorTextScale,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
                cursorRadius: const Radius.circular(1),
                cursorColor: Theme.of(context).colorScheme.primary,
                inputFormatters: [
                  _StaleInputFormatter(_rebaseStaleInput),
                  _dailySeparatorFormatter,
                  if (widget.markdownEnabled) ...[
                    _MarkdownShortcutFormatter(
                      _controller.markdownFor,
                      _markdownShortcut,
                    ),
                    _MarkdownTypingFormatter(
                      _controller.markdownFor,
                      _markdownTyping,
                    ),
                    _MarkdownStructureFormatter(_controller.markdownFor),
                  ],
                  TaskDetailsFormatter(onEnteredDetails: _usedDetails),
                  _ListContinuationFormatter(
                    markdown: widget.markdownEnabled
                        ? _controller.markdownFor
                        : null,
                  ),
                  // In markdown `- ` already is a list item, and turning it
                  // into a bullet glyph would take the markdown away.
                  if (!widget.markdownEnabled) const _ListShorthandFormatter(),
                  // Whatever the markdown setting: tables draw either way.
                  // After the others, so the line it opens under a table
                  // carries whatever they made of the edit (Bold's markers
                  // included) rather than splitting it. Not for a staged
                  // edit: those carry formats and pictures worked out for the
                  // text as it was sent, and a line added here would shift
                  // every one after it.
                  _TableEdgeFormatter(
                    _controller.markdownFor,
                    staged: () =>
                        _nextAttachments != null || _nextFormats != null,
                  ),
                  // Last, so it sees whatever the others made of the edit: a
                  // continuation or a shorthand landing on a picture's line
                  // has to be moved off it too.
                  const _ImageLineFormatter(),
                ],
                contextMenuBuilder: (context, field) => _EditMenuPresence(
                  // Counted, not read off the field: a tap on a phone needs to
                  // know whether it is putting a menu away.
                  onPresence: (shown) => _editMenus += shown ? 1 : -1,
                  child: ListenableBuilder(
                    // Rebuilds the menu when a word's corrections arrive after
                    // it opened, and when the clipboard answers: until it has,
                    // the field offers no Paste at all. Either way the menu is
                    // not left half-answered.
                    listenable: Listenable.merge([
                      _correctionsArrived,
                      field.clipboardStatus,
                    ]),
                    builder: (context, _) => _contextMenu(context, field),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<ImageIngestResult> _finishStagedImage(
  StagedImage staged,
  BlobStore store,
) => finishStagedImage(staged, store: store);

/// A link and where it was drawn, paired so the panel can be put against it.
class _LinkHit {
  const _LinkHit({required this.link, required this.rect});

  final NoteLink link;
  final Rect rect;
}

class _KeywordHit {
  const _KeywordHit({
    required this.id,
    required this.keyword,
    required this.message,
    required this.rect,
  });

  final String id;
  final String keyword;
  final String message;
  final Rect rect;
}

class _PointerDownDetails {
  const _PointerDownDetails({
    required this.position,
    required this.timeStamp,
    required this.wasPrimary,
    required this.wasTouch,
    required this.menuWasOpen,
    required this.selection,
    required this.text,
  });

  final Offset position;
  final Duration timeStamp;
  final bool wasPrimary;

  /// A finger on a touch device, rather than a mouse, a trackpad or a pen.
  final bool wasTouch;

  /// Whether the edit menu was showing when the press began, which is what
  /// makes a tap on the caret put it away rather than bring it back.
  final bool menuWasOpen;

  /// The selection the press began with.
  final TextSelection selection;

  /// The text the press began with, which [selection] belongs to.
  final String text;
}

/// Reports an edit menu arriving on screen and leaving it.
///
/// Flutter keeps whether its toolbar is showing to itself — the overlay that
/// knows is marked for tests — but the editor builds the menu, so it can watch
/// its own widget come and go instead.
class _EditMenuPresence extends StatefulWidget {
  const _EditMenuPresence({required this.onPresence, required this.child});

  final ValueChanged<bool> onPresence;
  final Widget child;

  @override
  State<_EditMenuPresence> createState() => _EditMenuPresenceState();
}

class _EditMenuPresenceState extends State<_EditMenuPresence> {
  @override
  void initState() {
    super.initState();
    widget.onPresence(true);
  }

  @override
  void dispose() {
    widget.onPresence(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.padding,
    required this.style,
    required this.strut,
    required this.writingFont,
    this.phone = false,
  });

  final EdgeInsets padding;
  final TextStyle style;
  final StrutStyle strut;
  final WritingFont writingFont;

  /// A phone's blank page (M11) says only "Start typing…", in the body's
  /// own size.
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Positioned.fill(
      child: IgnorePointer(
        child: Padding(
          padding: padding,
          child: Align(
            alignment: Alignment.topLeft,
            child: phone
                ? Text(
                    'Start typing…',
                    key: const ValueKey('note-placeholder'),
                    style: style.copyWith(color: palette.textTertiary),
                    strutStyle: strut,
                  )
                : Text.rich(
                    TextSpan(
                      style: style.copyWith(color: palette.textTertiary),
                      children: [
                        TextSpan(
                          text: 'Start typing…\n',
                          style: paragraphTextStyle(
                            style,
                            NoteParagraphStyle.heading,
                            writingFont: writingFont,
                            primaryColor: palette.textTertiary,
                          ),
                        ),
                        TextSpan(
                          text: 'Notes and quick calculations\n\n',
                          style: paragraphTextStyle(
                            style,
                            NoteParagraphStyle.subtitle,
                            writingFont: writingFont,
                            secondaryColor: palette.textTertiary,
                          ),
                        ),
                        const TextSpan(text: 'Try a few things\n'),
                        const TextSpan(text: 'Make text '),
                        const TextSpan(
                          text: 'bold',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const TextSpan(text: ' or '),
                        const TextSpan(
                          text: 'italic',
                          style: TextStyle(fontStyle: FontStyle.italic),
                        ),
                        const TextSpan(text: '.\n'),
                        const TextSpan(text: '• Keep ideas easy to scan\n'),
                        const TextSpan(text: '☐ Add a checklist\n\n'),
                        const TextSpan(text: '20% of 80\n'),
                        const TextSpan(text: '10rs to usd\n'),
                        const TextSpan(text: 'Idea details '),
                        TextSpan(
                          text: '// inline note',
                          style: TextStyle(
                            color: palette.comment,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                    strutStyle: strut,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Continues a list when Enter is pressed and exits it from an empty item.
/// Turns `- ` and `[] ` at the start of a line into a real list marker.
///
/// The space is part of the trigger, not decoration. `-5` on its own line is
/// a negative number this app evaluates, and the engine says so explicitly —
/// it excludes `-` from the leading-operator continuation "because `-5` on
/// its own is a perfectly good negative number". Requiring the space keeps
/// the two apart: `-5` stays arithmetic, `- ` becomes a bullet. Bulleting a
/// line does make it prose, since the engine deliberately skips list lines,
/// so the conversion is a real change of meaning — and undo is one keystroke
/// away, which is where every editor with this feature leaves it.
///
/// The bullet matches the depth the line is already at, so shorthand typed
/// inside a nested list gets that level's glyph rather than the first's.
/// Keeps a picture's line to itself; see [keepImageLinesToThemselves].
///
/// A formatter rather than a check in the change listener, because this has to
/// happen *before* the value is applied: the field runs these on typing,
/// on the IME's own updates, and on `userUpdateTextEditingValue`, which is how
/// paste and the selection toolbar reach the note. Repairing afterwards would
/// show the text beside the picture for a frame and cost a second undo step.
class _ImageLineFormatter extends TextInputFormatter {
  const _ImageLineFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => keepImageLinesToThemselves(oldValue, newValue);
}

class _ListShorthandFormatter extends TextInputFormatter {
  const _ListShorthandFormatter();

  static const _bullet = ['-'];
  static const _checklist = ['[]', '[ ]'];

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selection = oldValue.selection;
    if (!selection.isValid || !selection.isCollapsed) return newValue;
    final caret = selection.extentOffset;
    // Only the space that completes the shorthand, and only when it is being
    // typed rather than pasted over something.
    if (newValue.text != oldValue.text.replaceRange(caret, caret, ' ')) {
      return newValue;
    }

    final text = oldValue.text;
    final lineStart = caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;
    var indentEnd = lineStart;
    while (indentEnd < caret &&
        (text[indentEnd] == ' ' || text[indentEnd] == '\t')) {
      indentEnd++;
    }

    final typed = text.substring(indentEnd, caret);
    final String marker;
    if (_bullet.contains(typed)) {
      marker = bulletPrefixForDepth(
        (indentEnd - lineStart) ~/ listIndentUnit.length,
      );
    } else if (_checklist.contains(typed)) {
      marker = uncheckedPrefix;
    } else {
      return newValue;
    }

    // The marker carries its own trailing space, so the typed one is spent
    // rather than added.
    return TextEditingValue(
      text: text.replaceRange(indentEnd, caret, marker),
      selection: TextSelection.collapsed(offset: indentEnd + marker.length),
      composing: TextRange.empty,
    );
  }
}

/// See [separateTypingFromTables].
class _TableEdgeFormatter extends TextInputFormatter {
  const _TableEdgeFormatter(this.markdown, {required this.staged});

  final MarkdownAnalysis Function(String text) markdown;

  /// Whether the edit on its way carries formats or pictures of its own.
  final bool Function() staged;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (staged()) return newValue;
    return separateTypingFromTables(
          oldValue,
          newValue,
          markdown(oldValue.text),
        ) ??
        newValue;
  }
}

/// Markdown that behaves like formatting rather than like characters: Bold
/// switched on with nothing selected wraps what is typed next, a space or
/// Return at the end of a styled word steps out of the style, and emptying a
/// styled word takes its hidden markers with it.
class _MarkdownTypingFormatter extends TextInputFormatter {
  const _MarkdownTypingFormatter(this.markdown, this.typing);

  final MarkdownAnalysis? Function(String text) markdown;
  final MarkdownTyping typing;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final analysis = markdown(oldValue.text);
    if (analysis == null) return newValue;
    return markdownTypingEdit(oldValue, newValue, analysis, typing) ?? newValue;
  }
}

/// Markdown shortcuts as they are typed, and Backspace straight after one
/// giving back what was typed. See [markdownShortcutEdit].
class _MarkdownShortcutFormatter extends TextInputFormatter {
  const _MarkdownShortcutFormatter(this.markdown, this.shortcut);

  final MarkdownAnalysis Function(String text) markdown;
  final MarkdownShortcut shortcut;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => markdownShortcutEdit(oldValue, newValue, markdown, shortcut) ?? newValue;
}

/// Undo, unless a markdown shortcut was the last thing typed: then what was
/// typed comes back as plain text, as Backspace would give it.
class _ShortcutUndoAction extends ContextAction<UndoTextIntent> {
  _ShortcutUndoAction(this.undoShortcut);

  final bool Function() undoShortcut;

  @override
  Object? invoke(UndoTextIntent intent, [BuildContext? context]) {
    if (undoShortcut()) return null;
    return callingAction?.invoke(intent);
  }
}

/// Keystrokes that act on a line's hidden markdown as one piece: Backspace
/// at the start of a heading or list item takes the whole `## ` or `- [ ] `
/// away.
class _MarkdownStructureFormatter extends TextInputFormatter {
  const _MarkdownStructureFormatter(this.markdown);

  final MarkdownAnalysis? Function(String text) markdown;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final analysis = markdown(oldValue.text);
    if (analysis == null) return newValue;
    return markdownStructureEdit(oldValue, newValue, analysis) ?? newValue;
  }
}

/// Carries a keystroke the platform built on text the editor has since
/// replaced across to the text it shows. First in line, so the formatters
/// after it see the edit the writer made. See
/// [NoteEditorState._rebaseStaleInput].
class _StaleInputFormatter extends TextInputFormatter {
  const _StaleInputFormatter(this.rebase);

  final TextEditingValue Function(TextEditingValue, TextEditingValue) rebase;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => rebase(oldValue, newValue);
}

class _ListContinuationFormatter extends TextInputFormatter {
  const _ListContinuationFormatter({this.markdown});

  /// How the note reads as markdown, when it does: markdown lists and quotes
  /// then continue too, and nothing continues inside a code block, where a
  /// line that starts `- ` is code. The app's own bullets and boxes go on
  /// continuing their own way everywhere else.
  final MarkdownAnalysis? Function(String text)? markdown;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final analysis = markdown?.call(oldValue.text);
    if (analysis != null) {
      final caret = oldValue.selection.extentOffset;
      final inCode = analysis.codeBlocks.any(
        (block) => block.start <= caret && caret <= block.end,
      );
      if (inCode) return newValue;
      final continued = continueMarkdownLine(oldValue, newValue);
      if (continued != null) return continued;
    }
    final selection = oldValue.selection;
    if (!selection.isValid || !selection.isCollapsed) return newValue;
    final caret = selection.extentOffset;
    if (newValue.text != oldValue.text.replaceRange(caret, caret, '\n')) {
      return newValue;
    }

    final lineStart = caret == 0
        ? 0
        : oldValue.text.lastIndexOf('\n', caret - 1) + 1;
    var prefixStart = lineStart;
    while (prefixStart < caret &&
        (oldValue.text[prefixStart] == ' ' ||
            oldValue.text[prefixStart] == '\t')) {
      prefixStart++;
    }
    String? prefix;
    for (final candidate in [
      ...bulletPrefixes,
      uncheckedPrefix,
      checkedPrefix,
    ]) {
      if (oldValue.text.startsWith(candidate, prefixStart)) {
        prefix = candidate;
        break;
      }
    }
    if (prefix == null) return newValue;

    final lineEnd = oldValue.text.indexOf('\n', caret);
    final contentEnd = lineEnd < 0 ? oldValue.text.length : lineEnd;
    final content = oldValue.text.substring(
      prefixStart + prefix.length,
      contentEnd,
    );
    final indent = oldValue.text.substring(lineStart, prefixStart);

    if (content.trim().isEmpty) {
      // Enter on an empty item steps out one level at a time, and only leaves
      // the list once the item is back at the margin. Both swallow the
      // newline: the keypress is the user backing out, not adding a line.
      if (indent.isNotEmpty) {
        final removed = indent.length < listIndentUnit.length
            ? indent.length
            : listIndentUnit.length;
        final shallower = isBulletPrefix(prefix)
            ? bulletPrefixForDepth(
                (indent.length - removed) ~/ listIndentUnit.length,
              )
            : prefix;
        return TextEditingValue(
          // One replaceRange rather than two, so the offsets below do not
          // have to account for an edit made before them.
          text: oldValue.text.replaceRange(
            prefixStart - removed,
            prefixStart + prefix.length,
            shallower,
          ),
          selection: TextSelection.collapsed(offset: caret - removed),
          composing: TextRange.empty,
        );
      }
      final withoutEmptyItem = oldValue.text.replaceRange(
        prefixStart,
        prefixStart + prefix.length,
        '',
      );
      return TextEditingValue(
        text: withoutEmptyItem,
        selection: TextSelection.collapsed(offset: caret - prefix.length),
      );
    }

    // The new item keeps the depth of the one it came from; without this a
    // nested list would jump back to the margin on every Enter. Keeping the
    // depth means keeping that depth's bullet, so the glyph is carried over
    // rather than reset to the first level's.
    final continuation =
        indent + (isBulletPrefix(prefix) ? prefix : uncheckedPrefix);
    return newValue.copyWith(
      text: newValue.text.replaceRange(caret + 1, caret + 1, continuation),
      selection: TextSelection.collapsed(
        offset: caret + 1 + continuation.length,
      ),
      composing: TextRange.empty,
    );
  }
}

/// Inserts a dated section together with the first appended text of a new day.
/// Opening a note never writes an empty section, and the same formatter also
/// covers an editor that remains open across midnight.
class _DailySeparatorFormatter extends TextInputFormatter {
  _DailySeparatorFormatter({
    required this.enabled,
    required DateTime lastUpdatedAt,
    required this.now,
    required this.displayTime,
    String? pendingSeparatorLine,
  }) : _lastUpdatedAt = lastUpdatedAt,
       _pendingSeparatorLine = pendingSeparatorLine;

  bool enabled;
  DateTime _lastUpdatedAt;
  String? _pendingSeparatorLine;
  final DateTime Function() now;
  DateTime Function(DateTime) displayTime;

  void syncLastUpdatedAt(DateTime? value) {
    if (value != null && value.isAfter(_lastUpdatedAt)) {
      _lastUpdatedAt = value;
    }
  }

  void beginAppendSession(String? pendingSeparatorLine) {
    _pendingSeparatorLine = pendingSeparatorLine;
  }

  /// Applies the same delayed new-day boundary before an attachment insert.
  ///
  /// Image and voice buttons update the controller directly, so they never
  /// pass through [formatEditUpdate]. Keeping this beside that formatter's
  /// logic prevents widget dictation and footer actions from silently
  /// bypassing daily sections.
  TextEditingValue prepareProgrammaticAppend(TextEditingValue value) {
    final editedAt = now();
    final previousEdit = _lastUpdatedAt;
    _lastUpdatedAt = editedAt;
    if (!enabled) {
      _pendingSeparatorLine = null;
      return value;
    }
    final pendingSeparatorLine = _pendingSeparatorLine;
    if (pendingSeparatorLine == null &&
        DailySeparator.isSameDay(
          previousEdit,
          editedAt,
          displayTime: displayTime,
        )) {
      return value;
    }
    if (!value.selection.isValid ||
        !value.selection.isCollapsed ||
        value.selection.end != value.text.length) {
      return value;
    }

    final separated = pendingSeparatorLine == null
        ? DailySeparator.append(
            value.text,
            previousEdit,
            displayTime: displayTime,
          )
        : DailySeparator.appendLine(value.text, pendingSeparatorLine);
    _pendingSeparatorLine = null;
    if (separated == value.text) return value;
    return value.copyWith(
      text: separated,
      selection: TextSelection.collapsed(offset: separated.length),
      composing: TextRange.empty,
    );
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (oldValue.text == newValue.text) return newValue;

    final editedAt = now();
    final previousEdit = _lastUpdatedAt;
    _lastUpdatedAt = editedAt;
    if (!enabled) {
      _pendingSeparatorLine = null;
      return newValue;
    }
    final pendingSeparatorLine = _pendingSeparatorLine;
    if (pendingSeparatorLine == null &&
        DailySeparator.isSameDay(
          previousEdit,
          editedAt,
          displayTime: displayTime,
        )) {
      return newValue;
    }

    // The app focuses the final line on open. Restricting the automatic
    // section to an append keeps an intentional edit higher in the note from
    // being moved elsewhere.
    final appendsAtEnd =
        oldValue.selection.isCollapsed &&
        oldValue.selection.end == oldValue.text.length &&
        newValue.text.length > oldValue.text.length &&
        newValue.text.startsWith(oldValue.text);
    if (!appendsAtEnd) return newValue;

    final separated = pendingSeparatorLine == null
        ? DailySeparator.append(
            oldValue.text,
            previousEdit,
            displayTime: displayTime,
          )
        : DailySeparator.appendLine(oldValue.text, pendingSeparatorLine);
    _pendingSeparatorLine = null;
    if (separated == oldValue.text) return newValue;

    final shift = separated.length - oldValue.text.length;
    final added = newValue.text.substring(oldValue.text.length);
    return newValue.copyWith(
      text: '$separated$added',
      selection: _shiftSelection(newValue.selection, shift),
      composing: _shiftRange(newValue.composing, shift),
    );
  }

  static TextSelection _shiftSelection(TextSelection selection, int amount) {
    if (!selection.isValid) return selection;
    return selection.copyWith(
      baseOffset: selection.baseOffset + amount,
      extentOffset: selection.extentOffset + amount,
    );
  }

  static TextRange _shiftRange(TextRange range, int amount) {
    if (!range.isValid || range.isCollapsed) return TextRange.empty;
    return TextRange(start: range.start + amount, end: range.end + amount);
  }
}

/// What an attachment written by a newer build looks like here.
///
/// Deliberately plain and deliberately short: it is a placeholder for one line
/// of a note, not an upsell. The ref behind it is kept whole and pushed back
/// untouched, so a user who edits this note on an older device loses nothing —
/// this chip is the visible half of that promise.
class _UnknownChip extends StatelessWidget {
  const _UnknownChip();

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: noteImageGap),
      child: Container(
        height: height,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: palette.controlBackground,
          borderRadius: BorderRadius.circular(AppRadii.compact),
          border: Border.all(color: palette.controlBorder),
        ),
        child: Text(
          'Needs a newer Kapy Notes',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTypeScale.small,
            color: palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// The note's title as laid out on the page: [row] is its last row and
/// [word] its last word on that row. [letter] is where the letter drawn by
/// the placeholder under the title stands, [drawn] that letter as the field
/// would draw it, [width] its advance, and [top] how far down the
/// placeholder it is drawn so it sits on the row's baseline.
///
/// [spacerTop] is how far below the row's top a placeholder in it starts.
typedef _TitleLayout = ({
  int letter,

  /// The letter as the placeholder draws it: unscaled, at the size that
  /// [inline] brings to the title's.
  TextSpan drawn,

  /// The scale the field gives the placeholder's widget. Every length the
  /// placeholder is given is divided by it.
  double inline,
  double width,
  double top,
  Rect row,
  double spacerTop,
  Rect? word,
});

/// An empty line with a "+" beside it: where it starts, its middle in the
/// field, and whether the caret or the pointer is on it.
typedef _LineMark = ({int line, double middle, bool hovered});

/// A code block's header on the page: its language, and Copy.
class _CodeBlockHeader extends StatelessWidget {
  const _CodeBlockHeader({
    required this.inset,
    required this.language,
    required this.onCopy,
  });

  /// How far in from the panel's edges the language and Copy sit.
  final double inset;
  final String language;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final quiet = context.palette.textTertiary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Row(
        children: [
          Expanded(
            child: Text(
              language,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontSize: 11.5,
                fontWeight: AppWeight.font(AppWeight.rowTitle),
                fontVariations: AppWeight.wght(AppWeight.rowTitle),
                color: quiet,
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Copy code',
            excludeSemantics: true,
            onTap: onCopy,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: const ValueKey('code-copy'),
                behavior: HitTestBehavior.opaque,
                onTap: onCopy,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KapyIcon(KapyIcons.copyRounded, size: 13, color: quiet),
                    const SizedBox(width: 5),
                    Text(
                      'Copy',
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontSize: 12,
                        fontWeight: AppWeight.font(AppWeight.section),
                        fontVariations: AppWeight.wght(AppWeight.section),
                        color: quiet,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tells [onHeight] how tall its child came out, after each layout that
/// changes it.
class _ReportsHeight extends SingleChildRenderObjectWidget {
  const _ReportsHeight({required this.onHeight, required super.child});

  final ValueChanged<double>? onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportsHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReportsHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderReportsHeight extends RenderProxyBox {
  _RenderReportsHeight(this.onHeight);

  ValueChanged<double>? onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final onHeight = this.onHeight;
    final height = size.height;
    if (onHeight == null || height == _reported) return;
    _reported = height;
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
