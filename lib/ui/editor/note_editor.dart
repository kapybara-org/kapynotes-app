import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle, Locale;

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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../calc/engine.dart';
import '../../calc/highlight.dart';
import '../../calc/keyword_help.dart';
import '../../crdt/text_diff.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/platform.dart';
import '../../core/platform_spell_check.dart';
import '../../core/appearance.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/daily_separator.dart';
import '../../data/attachment_limits.dart';
import '../../data/note_format.dart';
import '../../data/shortcut_prefs.dart';
import '../notebook_paper.dart';
import '../celebrate.dart';
import '../kapy_cursor_peek.dart';
import 'blank_line_highlight.dart';
import 'editor_formatting.dart';
import 'highlighting_controller.dart';
import 'line_metrics.dart';
import 'link_popover.dart';
import 'keyword_tooltip.dart';
import 'markdown_backdrop.dart';
import 'markdown_editing.dart';
import 'markdown_syntax.dart';
import 'table_cell_editor.dart';
import 'table_geometry.dart';
import 'note_footer.dart';
import '../../data/note_attachment.dart';
import 'package:file_selector/file_selector.dart';

import '../../images/image_clipboard.dart';
import '../../images/image_codec.dart';
import '../../images/image_ingest.dart';
import '../../images/image_picker.dart';
import '../../audio/voice_player.dart';
import '../../data/blob_store.dart';
import '../../images/note_image_provider.dart';
import '../../video/video_ingest.dart';
import '../../video/video_picker.dart';
import 'image_drop_target.dart';
import 'image_insertion.dart';
import 'note_image_layout.dart';
import '../../audio/voice_recording_controller.dart';
import 'voice_chip.dart';
import 'voice_recording_bar.dart';
import 'voice_insertion.dart';
import 'note_image_view.dart';
import 'note_video_view.dart';
import 'remote_carets.dart';
import 'results_gutter.dart';
import 'scroll_passthrough.dart';
import 'selection_formatting_toolbar.dart';
import 'slash_command_menu.dart';
import 'slash_commands.dart';
import '../../sync/presence.dart';

typedef NoteDocumentChanged =
    void Function(
      String body,
      List<NoteFormatRange> formats,
      List<NoteAttachmentRef> attachments,
    );

/// Swappable at the slow boundary so the editor can prove its waiting state
/// without asking a widget test to decode a photograph in a real isolate.
typedef ImageBatchIngestor =
    Future<ImageBatch> Function(List<XFile> files, BlobStore store);

typedef VideoBatchIngestor =
    Future<VideoBatch> Function(List<XFile> files, BlobStore store);

typedef ImagePrepared =
    void Function(NoteImageRef staged, NoteImageRef prepared);

typedef AttachmentUploadProgressFor =
    ValueListenable<double?> Function(String hash);

/// The note surface: one syntax-coloured text field with a live results
/// column pinned to it.
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
    this.voiceActionBusy = false,
    this.clipboard = const ImageClipboard(),
    this.imageAcquirer,
    this.imageIngestor,
    this.imageFinalizer,
    this.onImagePrepared,
    this.onImagesRejected,
    this.videoAcquirer,
    this.videoIngestor,
    this.videoAttachmentMaxBytes,
    this.uploadProgressFor,
    this.typing = const [],
    this.remoteCarets,
    this.onActivity,
    this.onFocus,
    this.readOnly = false,
    this.readOnlyLabel = 'View only',
    this.readOnlyIcon = Icons.visibility_outlined,
    this.onReadOnlyPressed,
    required this.engine,
    required this.highlighter,
    required this.gutterWidth,
    required this.resultsVisible,
    required this.onDocumentChanged,
    required this.onGutterWidthChanged,
    required this.onResultsVisibilityChanged,
    required this.onGutterWidthReset,
    required this.onSettingsPressed,
    required this.writingFont,
    this.editorTextScale = 1,
    required this.shortcuts,
    this.spellCheckEnabled = true,
    this.markdownEnabled = false,
    this.onMarkdownEnabledChanged,
    this.showDivider = true,
    this.hideEmptyResults = false,
    this.autofocus = false,
    this.startAtEnd = false,
    this.initialCaret,
    this.onCaretChanged,
    this.ensureKeyboardVisible = false,
    this.lastUpdatedAt,
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
  final VideoBatchIngestor? videoIngestor;

  /// Read when a selection is made rather than when the editor is built, so
  /// an in-app upgrade or a refreshed shared-space owner limit applies without
  /// remounting the note.
  final int Function()? videoAttachmentMaxBytes;

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
  final IconData readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;

  final CalcEngine engine;
  final Highlighter highlighter;
  final double gutterWidth;
  final bool resultsVisible;
  final NoteDocumentChanged onDocumentChanged;
  final ValueChanged<double> onGutterWidthChanged;
  final ValueChanged<bool> onResultsVisibilityChanged;
  final VoidCallback onGutterWidthReset;

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
  final bool showDivider;
  final bool hideEmptyResults;
  final bool autofocus;
  final bool startAtEnd;

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

  static const List<Duration> _keyboardRetryDelays = [
    Duration(milliseconds: 100),
    Duration(milliseconds: 150),
    Duration(milliseconds: 250),
    Duration(milliseconds: 400),
    Duration(milliseconds: 600),
    Duration(milliseconds: 900),
    Duration(milliseconds: 1200),
    Duration(milliseconds: 1500),
  ];

  /// Whether the soft keyboard was up the last time the window was measured,
  /// which is what turns a metrics change into "the keyboard just went".
  bool _keyboardWasUp = false;

  final PlatformSpellCheckService _spellCheckService =
      PlatformSpellCheckService();
  Locale? _spellCheckLocale;
  // Bumped when a word's corrections arrive, so a menu that opened without
  // them can fill itself in rather than stay wrong.
  final ValueNotifier<int> _correctionsArrived = ValueNotifier<int>(0);
  late HighlightingController _controller;
  final GlobalKey _textFieldKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'note-editor:${widget.noteId}',
  );
  final LineMeasurer _measurer = LineMeasurer();

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

  /// Where each line of the note was last measured to start, which is what the
  /// grid behind the text is painted from. A cell's editor is placed from the
  /// same numbers, or it would sit a few pixels off the cell it edits.
  LineOffsets? _lineOffsets;
  List<int>? _lineStarts;
  String? _lineStartsText;
  ({int tableStart, int row, int column})? _editingCell;

  /// Whether this note is being written in: its own field has focus, or one of
  /// its cells does.
  bool get _editingNote => _focusNode.hasFocus || _editingCell != null;
  late final _DailySeparatorFormatter _dailySeparatorFormatter;
  Timer? _keyboardRetryTimer;
  Timer? _selectionToolbarTimer;
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

  /// What the blank-line highlight has to follow.
  late final Listenable _selectionRepaint = Listenable.merge([
    _controller,
    _scrollController,
    _focusNode,
  ]);
  Set<NoteFormat>? _nextInsertedFormats;
  bool _imageActionBusy = false;
  bool _videoActionBusy = false;
  bool _copyingRichSelection = false;

  final SlashCommandMenuController _slashCommandMenu =
      SlashCommandMenuController();
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
    if (widget.initialBody != oldWidget.initialBody &&
        widget.initialBody != _controller.text) {
      _applyRemoteBody();
    }
    if (widget.initialBody == _controller.text &&
        !listEquals(widget.initialFormats, _formats)) {
      _formats = normalizeNoteFormats(
        widget.initialFormats,
        _controller.text.length,
      );
      _controller.formats = _formats;
    }
    if (widget.initialBody == _controller.text &&
        !listEquals(widget.initialAttachments, _attachments)) {
      _attachments = normalizeNoteAttachments(
        widget.initialAttachments,
        _controller.text,
      );
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
    LinkPopover.hide();
    KeywordTooltip.hide();
    _slashCommandMenu.dispose();
    _controller.removeListener(_onControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _scrollController.removeListener(_handleEditorScroll);
    widget.shortcuts.removeListener(_onShortcutsChanged);
    widget.player?.removeListener(_onPlaybackChanged);
    _spellCheckService.dispose();
    _correctionsArrived.dispose();
    _keyboardRetryTimer?.cancel();
    _selectionToolbarTimer?.cancel();
    _pasteOfferTimer?.cancel();
    _keywordHoverTimer?.cancel();
    _kapyPeekIdleTimer?.cancel();
    _dismissKapyPeek();
    _remoteHover.dispose();
    _cellEditor.dispose();
    _tableGeometry.dispose();
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

  /// The field's render object, for drawing other people's carets over it.
  RenderEditable? _fieldEditable() {
    final root = _textFieldKey.currentContext?.findRenderObject();
    return root == null ? null : _findRenderEditable(root);
  }

  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  void _handleEditorScroll() {
    LinkPopover.hide();
    _slashCommandMenu.hide();
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
  /// whole point is that nothing moves. `EditableText` brings its own caret
  /// on screen when it takes focus, so a caret restored halfway up a long
  /// note is scrolled to rather than left off the top.
  void focusHere() {
    if (!mounted || widget.readOnly) return;
    _focusNode.requestFocus();
    _recordKapyPeekActivity();
    _scheduleKeyboardRetry();
  }

  /// Places the caret after the note's final character and brings it on screen.
  void focusAtEnd() {
    if (!mounted || widget.readOnly) return;
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
    // Try as soon as the editable connection exists, then probe quickly while
    // Android is still promoting FlutterView to the served input view.
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    _scheduleKeyboardRetryAt(0);
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
      // A rejected Android request has no Dart acknowledgement. Backoff keeps
      // the recovery window broad without repeatedly waking an IME that has
      // already started its animation.
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
      _scheduleKeyboardRetryAt(index + 1);
    });
  }

  /// Puts the store's text into the controller without treating it as an
  /// edit, mapping the selection across the change so the caret stays with
  /// the words it was between.
  ///
  /// Deferred while the IME is composing: replacing the text under an open
  /// composition confuses every soft keyboard, and a composition ends at the
  /// next word boundary at the latest.
  void _applyRemoteBody() {
    final value = _controller.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      _remotePending = true;
      return;
    }
    _remotePending = false;
    final newText = widget.initialBody;
    final editingCell = _editingCell;
    final mappedTableProbe = editingCell == null
        ? null
        : mapOffsetAcross(
            diffTexts(value.text, newText),
            math.min(editingCell.tableStart + 1, value.text.length),
          );
    final selection = mapSelectionAcrossEdit(
      value.text,
      newText,
      value.selection,
    );
    _formats = normalizeNoteFormats(widget.initialFormats, newText.length);
    _attachments = normalizeNoteAttachments(widget.initialAttachments, newText);
    _applyingRemote = true;
    try {
      _controller.formats = _formats;
      _controller.value = TextEditingValue(text: newText, selection: selection);
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
  bool _remotePending = false;

  /// The style ranges the editor is currently drawing.
  @visibleForTesting
  List<NoteFormatRange> get formatsForTest => _formats;

  void _onControllerChanged() {
    _recordKapyPeekActivity();
    final value = _controller.value;
    _scheduleSlashCommandMenuSync();
    _reportCaret(value.selection);
    final previous = _lastValue;
    if (_applyingRemote) {
      _lastValue = value;
      return;
    }
    if (_remotePending &&
        !(value.composing.isValid && !value.composing.isCollapsed) &&
        widget.initialBody != value.text) {
      // The composition that held the remote text back has ended.
      _lastValue = value;
      _applyRemoteBody();
      return;
    }
    _reportActivity(edited: value.text != previous.text);
    if (value.text == previous.text) {
      final selectionChanged = value.selection != previous.selection;
      _lastValue = value;
      if (!selectionChanged) return;
      if (_collapseLineTerminatorSelection(value.selection)) return;
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
    widget.onDocumentChanged(value.text, updatedFormats, updatedAttachments);
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

  Widget _voiceChip(NoteVoiceRef ref) {
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
    for (final ref in before) {
      final left = survivors[ref.hash] ?? 0;
      if (left > 0) {
        survivors[ref.hash] = left - 1;
        continue;
      }
      _removedRefs.add((textBefore: textBefore, ref: ref));
    }
    while (_removedRefs.length > _maxRemovedRefs) {
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
    final result = insertImagesIntoBody(
      body: base.text,
      existing: _attachments,
      caret: caret,
      incoming: refs,
    );
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

  /// Routes the toolbar's own Paste button through [handlePaste].
  ///
  /// The keyboard shortcut goes through `PasteTextIntent`, which is
  /// overridable; this button calls `pasteText` on the editable directly and
  /// would otherwise quietly paste nothing when the clipboard holds a picture.
  List<ContextMenuButtonItem> _withImagePaste(
    List<ContextMenuButtonItem> items,
  ) {
    if (widget.readOnly || widget.images == null) return items;
    return [
      for (final item in items)
        if (item.type == ContextMenuButtonType.paste)
          ContextMenuButtonItem(
            type: item.type,
            label: item.label,
            onPressed: () {
              ContextMenuController.removeAny();
              unawaited(handlePaste(SelectionChangedCause.toolbar));
            },
          )
        else
          item,
    ];
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
    // accessibility-driven refocus can briefly clear EditableText's selection
    // while the promised clipboard value is being resolved.
    final startingValue = _editableTextState()?.textEditingValue;
    final store = widget.images;

    // Kapy Notes rich HTML carries the positions of every selected image, so it
    // outranks the clipboard's native bitmap: reading only that would reduce a
    // mixed selection to its first picture and lose the text around it.
    final (capturedText, fragment, paths) = await (
      _clipboardText(),
      store == null
          ? Future<NoteClipboardFragment?>.value()
          : widget.clipboard.readFragment(),
      store == null
          ? Future<List<String>>.value(const [])
          : widget.clipboard.readImageFiles(),
    ).wait;
    if (!mounted) return;

    if (fragment != null) {
      await _insertClipboardFragment(
        fragment,
        cause,
        startingValue: startingValue,
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
    if (!mounted || capturedText == null) return;
    _insertPastedText(capturedText, cause, startingValue: startingValue);
  }

  /// Pastes only the clipboard's plain-text representation.
  ///
  /// Normal Paste understands Kapy Notes fragments and images. This path
  /// deliberately skips those richer representations so a mixed selection
  /// becomes ordinary text and adopts the formatting at the insertion point.
  Future<void> _pastePlainText(SelectionChangedCause cause) async {
    if (widget.readOnly) return;
    final startingValue = _editableTextState()?.textEditingValue;
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

  Future<void> _insertClipboardFragment(
    NoteClipboardFragment fragment,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) async {
    final store = widget.images;
    if (store == null || fragment.images.isEmpty) return;
    if (!_beginImageAction()) return;
    final progress = Toast.showProgress(context, 'Pasting with images…');
    try {
      final incoming = <NoteImageRef>[];
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
      if (!_replaceSelectionWithFragment(
        fragment.body,
        incoming,
        cause,
        startingValue: startingValue,
      )) {
        progress.error('Could not paste that selection');
        return;
      }
      progress.success('Pasted with images');
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
    List<NoteImageRef> images,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) {
    final editable = _editableTextState();
    if (editable == null) return false;
    final value = editable.textEditingValue;
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
      for (final image in images)
        image.copyWith(offset: selection.start + image.offset),
    ], nextText);
    _nextInsertedFormats = const {};
    editable.userUpdateTextEditingValue(
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
  /// path as [EditableTextState.pasteText], without consulting a clipboard a
  /// dictation app may already have restored.
  void _insertPastedText(
    String text,
    SelectionChangedCause cause, {
    TextEditingValue? startingValue,
  }) {
    if (widget.readOnly) return;
    final editable = _editableTextState();
    if (editable == null) return;
    final value = editable.textEditingValue;
    final selection = _selectionForPaste(value, startingValue);
    final collapsed = value.copyWith(
      selection: TextSelection.collapsed(offset: selection.end),
    );
    editable.userUpdateTextEditingValue(
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
    widget.onDocumentChanged(_controller.text, _formats, _attachments);
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
    final editable = _editableTextState();
    if (editable != null) {
      editable.userUpdateTextEditingValue(value, SelectionChangedCause.toolbar);
    } else {
      _controller.value = value;
    }
    _focusNode.requestFocus();
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

  Future<void> insertDroppedMedia(List<XFile> files) async {
    final images = <XFile>[];
    final videos = <XFile>[];
    for (final file in files) {
      final name = file.name;
      final dot = name.lastIndexOf('.');
      final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
      if (supportedImageExtensions.contains(extension)) {
        images.add(file);
      } else if (supportedVideoExtensions.contains(extension)) {
        videos.add(file);
      }
    }
    if (images.isNotEmpty) await insertFiles(images);
    if (videos.isNotEmpty) await insertVideoFiles(videos);
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
    widget.onDocumentChanged(_controller.text, _formats, updated);
  }

  void _commitFormats(List<NoteFormatRange> formats) {
    if (widget.readOnly) return;
    _formats = formats;
    _controller.formats = formats;
    setState(() {});
    widget.onDocumentChanged(_controller.text, formats, _attachments);
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
    if (widget.images != null && !_imageActionBusy) SlashCommandType.image,
    if (widget.onRecordVoice != null && !widget.voiceActionBusy)
      SlashCommandType.voiceNote,
    SlashCommandType.table,
    SlashCommandType.divider,
    if (widget.images != null && !_videoActionBusy) SlashCommandType.video,
    SlashCommandType.numberedList,
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
    if (widget.readOnly || !_focusNode.hasFocus) {
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
    final editable = _fieldEditable();
    if (editable == null || !editable.hasSize) return null;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: offset.clamp(0, _controller.text.length)),
    );
    return Rect.fromPoints(
      editable.localToGlobal(caret.topLeft),
      editable.localToGlobal(caret.bottomRight),
    );
  }

  void _showSlashCommandMenu({required Rect anchor, required String query}) {
    ContextMenuController.removeAny();
    LinkPopover.hide();
    _clearKeywordTooltip();
    _slashCommandMenu.show(
      context,
      anchor: anchor,
      query: query,
      available: _availableSlashCommands,
      markdownEnabled: widget.markdownEnabled,
      onSelected: (choice) => unawaited(_runSlashCommand(choice)),
      onDismissed: _slashCommandMenuDismissed,
    );
  }

  /// The touch footer's `/` opens the same menu without putting a slash in
  /// the note. A tap-opened popup gives the screen to its choices, so it puts
  /// the software keyboard away until a choice returns to the editor.
  void _showInsertMenu() {
    if (widget.readOnly) return;
    _dismissedSlashStart = null;
    _manualSlashMenuValue = null;
    final selection = _controller.selection;
    final caret = selection.isValid
        ? selection.extentOffset
        : _controller.text.length;
    _dismissKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.readOnly) return;
      final anchor = _slashAnchorAt(caret);
      if (anchor == null) return;
      _slashCommandRange = TextRange.collapsed(caret);
      _slashCommandWasTyped = false;
      _manualSlashMenuValue = _controller.value;
      _showSlashCommandMenu(anchor: anchor, query: '');
    });
  }

  void _slashCommandMenuDismissed(bool userInitiated) {
    if (userInitiated && _slashCommandWasTyped) {
      _dismissedSlashStart = _slashCommandRange?.start;
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
    SlashCommandType.codeBlock => true,
    _ => false,
  };

  static String _markdownFeatureName(SlashCommandType command) =>
      switch (command) {
        SlashCommandType.table => 'Tables',
        SlashCommandType.numberedList => 'Numbered lists',
        SlashCommandType.quote => 'Quotes',
        SlashCommandType.divider => 'Dividers',
        SlashCommandType.codeBlock => 'Code blocks',
        _ => 'This command',
      };

  Future<bool> _confirmMarkdownFor(SlashCommandType command) async {
    final canEnable = widget.onMarkdownEnabledChanged != null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn on Markdown?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Text(
            '${_markdownFeatureName(command)} use Markdown. Turning it on '
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
    if (range == null ||
        !range.isValid ||
        range.start < 0 ||
        range.end > source.length) {
      return;
    }

    var markdown = widget.markdownEnabled;
    if (_requiresMarkdown(choice.type) && !markdown) {
      markdown = await _confirmMarkdownFor(choice.type);
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
        _replaceCommandValue(
          replaceWithSlashCommandBlock(
            _controller.value,
            range,
            table,
            selectionInBlock: TextSelection(
              baseOffset: firstHeader,
              extentOffset: firstHeader + 'Column 1'.length,
            ),
          ),
        );
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
      case SlashCommandType.image:
        if (typed) _consumeSlashCommand(range);
        await pickAndInsertImages();
        break;
      case SlashCommandType.video:
        if (typed) _consumeSlashCommand(range);
        await pickAndInsertVideos();
        break;
      case SlashCommandType.voiceNote:
        if (typed) _consumeSlashCommand(range);
        widget.onRecordVoice?.call();
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
    final editable = _editableTextState();
    if (editable == null) {
      _controller.value = value;
    } else {
      editable.userUpdateTextEditingValue(value, SelectionChangedCause.toolbar);
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

  /// Any key at all dismisses the link panel first. Escape is the one people
  /// reach for, but a panel that outlives the caret it was raised next to is
  /// wrong whichever key moved it.
  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
    if (_slashCommandMenu.handleKeyEvent(event)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      LinkPopover.hide();
      _clearKeywordTooltip();
      _recordKapyPeekActivity();
    }
    return _handleTabIndent(node, event);
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
    if (!_focusNode.hasFocus || !_showIndentControls) {
      return KeyEventResult.ignored;
    }
    final pressed = keyboard.logicalKeysPressed;
    final outdent =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    // Claim the key even at the ends of the range, or Tab would silently fall
    // through to focus traversal exactly when the list stops moving.
    if (_canIndent(outdent: outdent)) {
      _indentList(outdent: outdent);
    }
    return KeyEventResult.handled;
  }

  void _handlePointerDown(PointerDownEvent event) {
    _clearKeywordTooltip();
    _recordKapyPeekActivity();
    if (event.buttons & kSecondaryButton != 0) {
      final editable = _fieldEditable();
      if (editable != null) {
        final offset = editable.getPositionForPoint(event.position).offset;
        if (_openTableCellAt(editable, event.position, offset)) return;
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

  /// Puts the caret on the ruled row a click landed on, below everything the
  /// note has been written into.
  ///
  /// Left to itself the field answers such a click with the end of the text,
  /// so the caret appears on the last written line rather than under the
  /// pointer and the page reads as though it ignored the click. A caret can
  /// only sit on a row that exists, so the rows in between are written — the
  /// same lines a run of Returns would have made, and undone by one press of
  /// undo.
  ///
  /// Returns whether the click was in that empty region, in which case there
  /// is nothing below it to be a checkbox, a link or a calculator word.
  bool _caretToBlankRow(RenderEditable editable, Offset globalPosition) {
    if (widget.readOnly) return false;
    final lineHeight = editable.preferredLineHeight;
    if (lineHeight <= 0) return false;

    // Where the writing actually ends. Measured rather than counted in rows:
    // a note holding a picture has one row as tall as the picture, and only
    // the empty page below the text is ruled at a fixed height.
    final textBottom =
        editable.localToGlobal(Offset.zero).dy + editable.size.height;
    if (globalPosition.dy <= textBottom) return false;

    // Below that the ruling is uniform — the field forces its strut and the
    // paper is drawn from the same number — so which line the pointer is over
    // is arithmetic rather than a hit test.
    final missing = ((globalPosition.dy - textBottom) / lineHeight).floor() + 1;

    final text = _controller.text + '\n' * missing;
    final caret = TextSelection.collapsed(offset: text.length);
    _controller.value = TextEditingValue(text: text, selection: caret);
    _focusNode.requestFocus();
    // The field's own tap handler runs after this one, and answers the click
    // with the position it finds in the layout it already has — the layout
    // from before these rows existed, which puts the caret straight back on
    // the last written line. A microtask lands after that handler and before
    // the frame it would be drawn in, so the caret is only ever painted where
    // the click was aimed.
    scheduleMicrotask(() {
      if (!mounted || _controller.text != text) return;
      _controller.selection = caret;
    });
    return true;
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
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    if (editable == null) return;

    final offset = editable.getPositionForPoint(position).offset;
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
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    if (editable == null) return;
    final offset = editable.getPositionForPoint(position).offset;
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
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    if (editable == null) return;

    if (_caretToBlankRow(editable, event.position)) {
      _offerPasteAfterTap(down);
      return;
    }

    final offset = editable.getPositionForPoint(event.position).offset;
    final task = _markdownTaskAt(editable, event.position, offset);
    if (!widget.readOnly && task != null) {
      _nextInsertedFormats = const {};
      _controller.value = toggleMarkdownTask(_controller.value, task.box);
      _focusNode.requestFocus();
      if (!task.checked) _celebrateCheck(editable, event.position);
      return;
    }
    final checkboxStart = _checkboxAt(editable, event.position, offset);
    if (!widget.readOnly && checkboxStart >= 0) {
      _nextInsertedFormats = const {};
      final wasUnchecked = _controller.text.startsWith(
        uncheckedPrefix,
        checkboxStart,
      );
      _controller.value = toggleCheckboxAt(_controller.value, checkboxStart);
      _focusNode.requestFocus();
      // Only on the way in. Unticking something is a correction, and a
      // correction that throws confetti is mocking you.
      if (wasUnchecked) _celebrateCheck(editable, event.position);
      return;
    }

    // Before links: a link inside a cell is reached by editing the cell, not
    // instead of it.
    if (_openTableCellAt(editable, event.position, offset)) return;

    final hit = _linkAtPoint(editable, event.position, offset);
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
    final keyword = _keywordAtPoint(editable, event.position, offset);
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
    final editable = _editableTextState();
    final caret = _controller.selection;
    if (!mounted ||
        editable == null ||
        !_focusNode.hasFocus ||
        !caret.isValid ||
        !caret.isCollapsed ||
        (putAwayAt != null && caret.baseOffset == putAwayAt.baseOffset)) {
      return;
    }
    final text = _controller.text;
    await editable.clipboardStatus.update();
    if (!mounted ||
        !_focusNode.hasFocus ||
        _controller.text != text ||
        _controller.selection != caret ||
        editable.clipboardStatus.value != ClipboardStatus.pasteable) {
      return;
    }
    // Does nothing when the menu is already up, as it is when iOS opened its
    // own for a tap on the caret.
    editable.showToolbar();
  }

  /// Confetti over the box just ticked, with a fuller burst for the last one.
  ///
  /// The finale is deliberately rare: a note has to have had at least two
  /// boxes and none of them can be left, so it marks finishing a list rather
  /// than ticking a single stray item.
  void _celebrateCheck(RenderEditable editable, Offset tapPosition) {
    if (!mounted) return;
    final text = _controller.text;
    // Markdown tasks count alongside the app's own boxes: a list is finished
    // when neither kind has anything left open.
    // With markdown off this is empty, the way the old null was: a table is all
    // that view holds. See HighlightingController.markdownFor.
    final tasks = _controller.markdownFor(text).tasks;
    final open =
        uncheckedPrefix.allMatches(text).length +
        tasks.where((task) => !task.checked).length;
    final total =
        open +
        checkedPrefix.allMatches(text).length +
        tasks.where((task) => task.checked).length;
    final finale = open == 0 && total >= 2;
    Celebrate.at(context, tapPosition);
    if (!finale) return;

    final caret = _caretGlobalCenter(editable);
    if (caret != null) Celebrate.at(context, caret, finale: true);
  }

  /// Where the caret is on screen, or null if it has nowhere to be.
  Offset? _caretGlobalCenter(RenderEditable editable) {
    final selection = _controller.selection;
    if (!selection.isValid) return null;
    final rect = editable.getLocalRectForCaret(
      TextPosition(
        offset: selection.extentOffset.clamp(0, _controller.text.length),
      ),
    );
    return editable.localToGlobal(rect.topCenter);
  }

  void _handleFocusChanged() {
    // A markdown note shows its syntax only while it is being edited, so
    // what is drawn changes with focus.
    if (widget.markdownEnabled && mounted) {
      _markdownTyping.clear();
      setState(() => _markdownQuiet = true);
    }
    if (_focusNode.hasFocus) {
      widget.onFocus?.call();
      _recordKapyPeekActivity();
      _reportActivity(edited: false);
      _scheduleSlashCommandMenuSync();
      return;
    }
    // Nothing left to raise a keyboard for. A retry still in flight would
    // otherwise put one up over a note nobody is writing in.
    _keyboardRetryTimer?.cancel();
    _slashCommandMenu.hide();
    _kapyPeekIdleTimer?.cancel();
    _clearKeywordTooltip();
    _kapyPeekIdleTimer = null;
    _dismissKapyPeek();
  }

  /// Gives the footer a deliberate way out of editing on a phone. Cancelling
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
    final wasUp = _keyboardWasUp;
    final inset = _keyboardInset;
    final isUp = inset > 0;
    _keyboardWasUp = isUp;
    if (mounted && AppPlatform.isMobile && isUp != wasUp) setState(() {});
    if (isUp || !wasUp) return;
    if (widget.readOnly || !_editingNote) return;
    // Backgrounding the app also takes the keyboard down, and focus should
    // survive that: it is the same note, still open, when the app comes back.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _keyboardRetryTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
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
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    if (editable == null) return;
    final caret = _caretGlobalCenter(editable);
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
  int _checkboxAt(
    RenderEditable editable,
    Offset globalPosition,
    int textOffset,
  ) {
    final start = checkboxLineStartAt(_controller.text, textOffset);
    if (start < 0) return -1;
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    if (boxes.isEmpty) return -1;
    final box = boxes.first;
    final origin = editable.localToGlobal(Offset(box.left, box.top));
    final rect = origin & Size(box.right - box.left, box.bottom - box.top);
    // A forgiving margin: the glyph is small, and a pointer a few pixels off
    // is still aiming at it.
    return rect.inflate(6).contains(globalPosition) ? start : -1;
  }

  /// The markdown task whose `[ ]` is under [globalPosition], if any.
  ///
  /// The same question [_checkboxAt] answers for the app's own boxes, with
  /// the same forgiving margin, for the same reason: the hover cursor and the
  /// click ask it alike, so anything that shows a hand is something a click
  /// will tick.
  MarkdownTask? _markdownTaskAt(
    RenderEditable editable,
    Offset globalPosition,
    int textOffset,
  ) {
    final markdown = _controller.markdownFor(_controller.text);
    for (final task in markdown.tasks) {
      if (task.box > textOffset + 1) break;
      if (textOffset > task.box + 4) continue;
      final boxes = editable.getBoxesForSelection(
        TextSelection(baseOffset: task.box, extentOffset: task.box + 3),
      );
      for (final box in boxes) {
        final origin = editable.localToGlobal(Offset(box.left, box.top));
        final rect = origin & Size(box.right - box.left, box.bottom - box.top);
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
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    var wanted = _textCursor;
    _KeywordHit? keyword;

    if (editable != null) {
      final offset = editable.getPositionForPoint(event.position).offset;
      // Link scanning is cached against the text, so hovering re-uses the
      // spans the highlighter already built rather than re-scanning the note.
      if ((!widget.readOnly &&
              (_checkboxAt(editable, event.position, offset) >= 0 ||
                  _markdownTaskAt(editable, event.position, offset) != null)) ||
          _linkAtPoint(editable, event.position, offset) != null) {
        wanted = SystemMouseCursors.click;
      } else {
        keyword = _keywordAtPoint(editable, event.position, offset);
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
    RenderEditable editable,
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
      final boxes = editable.getBoxesForSelection(
        TextSelection(baseOffset: span.start, extentOffset: span.end),
      );
      for (final box in boxes) {
        final origin = editable.localToGlobal(Offset(box.left, box.top));
        final rect = origin & Size(box.right - box.left, box.bottom - box.top);
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
    RenderEditable editable,
    Offset globalPosition,
    int textOffset,
  ) {
    final links = _controller.linksFor(_controller.text);
    for (final link in links) {
      if (textOffset < link.start || textOffset > link.end) continue;
      final boxes = editable.getBoxesForSelection(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      );
      for (final box in boxes) {
        final origin = editable.localToGlobal(Offset(box.left, box.top));
        final rect = origin & Size(box.right - box.left, box.bottom - box.top);
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
  Widget _contextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final selection = editableTextState.textEditingValue.selection;
    final touch = !AppPlatform.hasPointer;
    final link = _linkForSelection(selection);
    final linkItems = _linkContextMenuItems(link);
    if (widget.readOnly) {
      final editItems = _withRichCopy(_editItems(editableTextState), selection);
      return NoteEditorContextMenu(
        anchors: editableTextState.contextMenuAnchors,
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
      final editItems = _withImagePaste(_editItems(editableTextState));
      return NoteEditorContextMenu(
        anchors: editableTextState.contextMenuAnchors,
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
    if (touch) {
      return NoteEditorContextMenu(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: _touchSelectionItems(
          editableTextState,
          selection,
          linkItems,
        ),
      );
    }
    return NoteSelectionFormattingToolbar(
      editableTextState: editableTextState,
      corrections: _spellingContextMenuItems(selection),
      paragraphStyle: _activeParagraphStyle,
      markdownHeadingLevel: widget.markdownEnabled
          ? _markdownHeadingLevel
          : null,
      markdown: widget.markdownEnabled,
      boldActive: _formatActive(NoteFormat.bold),
      italicActive: _formatActive(NoteFormat.italic),
      bulletsActive: _lineStyleActive(NoteLineStyle.bullet),
      checklistActive: _lineStyleActive(NoteLineStyle.checklist),
      onParagraphStylePressed: _cycleParagraphStyle,
      onBoldPressed: () => _toggleInlineFormat(NoteFormat.bold),
      onItalicPressed: () => _toggleInlineFormat(NoteFormat.italic),
      onBulletsPressed: _toggleBullets,
      onChecklistPressed: _toggleChecklist,
      onOpenLink: link == null ? null : () => unawaited(_openLink(link)),
      onCopyLink: link == null ? null : () => unawaited(_copyLink(link)),
      onCopy: _selectionContainsImage(selection)
          ? () => unawaited(_copyRichSelection(selection))
          : null,
      // The same rule as the menu's Paste: through the editor wherever a
      // picture could be on the clipboard, and the field's own paste where
      // one could not.
      onPaste: widget.images == null
          ? null
          : () => unawaited(handlePaste(SelectionChangedCause.toolbar)),
      onPastePlainText: () =>
          unawaited(_pastePlainText(SelectionChangedCause.toolbar)),
      onCopyPlainText: () => unawaited(_copyPlainText(selection)),
    );
  }

  bool _isPasteAction(ContextMenuButtonItem item) =>
      item.type == ContextMenuButtonType.paste ||
      item.label == _pasteAsPlainTextLabel;

  /// The field's Cut, Copy, Paste and Select All, asked of the field itself,
  /// followed by whatever else the platform adds.
  ///
  /// `contextMenuButtonItems` withholds every one of the four until the
  /// clipboard has been checked, and goes on withholding them if that check
  /// fails, which left a phone's menu without Copy for as long as the check
  /// took, or for good. Only Paste needs the answer; the builder rebuilds the
  /// menu when it comes.
  List<ContextMenuButtonItem> _editItems(EditableTextState editable) {
    const ownTypes = {
      ContextMenuButtonType.cut,
      ContextMenuButtonType.copy,
      ContextMenuButtonType.paste,
      ContextMenuButtonType.selectAll,
    };
    return [
      if (editable.cutEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () => editable.cutSelection(SelectionChangedCause.toolbar),
        ),
      if (editable.copyEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () =>
              editable.copySelection(SelectionChangedCause.toolbar),
        ),
      if (editable.pasteEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () =>
              unawaited(editable.pasteText(SelectionChangedCause.toolbar)),
        ),
      if (editable.pasteEnabled)
        ContextMenuButtonItem(
          label: _pasteAsPlainTextLabel,
          onPressed: () {
            ContextMenuController.removeAny();
            unawaited(_pastePlainText(SelectionChangedCause.toolbar));
          },
        ),
      if (editable.selectAllEnabled)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () => editable.selectAll(SelectionChangedCause.toolbar),
        ),
      for (final item in editable.contextMenuButtonItems)
        if (!ownTypes.contains(item.type)) item,
    ];
  }

  /// A phone's toolbar for selected text.
  ///
  /// Copy leads, followed by the platform's Cut and paste actions, because
  /// copying is what a selection on a phone is usually for. The formatting
  /// row a pointer gets had put Copy behind a More button. The rest follows in
  /// the order the toolbar tucks it away: corrections, the platform's other
  /// actions, the link, and the note's own formatting, which the footer's
  /// writing tools also carry.
  List<ContextMenuButtonItem> _touchSelectionItems(
    EditableTextState editableTextState,
    TextSelection selection,
    List<ContextMenuButtonItem> linkItems,
  ) {
    final nativeItems = _withImagePaste(
      _withRichCopy(_editItems(editableTextState), selection),
    );
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
    final editable = _editableTextState();
    if (editable == null) return;
    final value = editable.textEditingValue;
    final range = misspelling.range;
    if (range.start < 0 ||
        range.end <= range.start ||
        range.end > value.text.length) {
      return;
    }

    editable.userUpdateTextEditingValue(
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

  bool _selectionContainsImage(TextSelection selection) =>
      selection.isValid &&
      !selection.isCollapsed &&
      _attachments.any(
        (ref) =>
            ref is NoteImageRef &&
            ref.offset >= selection.start &&
            ref.offset < selection.end,
      );

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
    _selectImage(ref);
    unawaited(_copyRichSelection(_controller.selection));
  }

  Future<Uint8List?> _clipboardBytes(NoteImageRef ref) async {
    final store = widget.images;
    if (store == null) return null;
    var bytes = await store.read(ref.hash);
    if (bytes != null) return bytes;
    final fetch = widget.imageFetch;
    if (fetch == null) return null;
    bytes = await fetch(ref.hash);
    if (bytes == null || BlobStore.hashOf(bytes) != ref.hash) return null;
    await store.put(bytes);
    return bytes;
  }

  /// Materialises only the images inside [selection], preserving their exact
  /// positions among the selected text. Non-image attachments become readable
  /// labels because this clipboard contract is intentionally image-specific.
  Future<NoteClipboardFragment?> _clipboardFragment(
    TextSelection selection,
  ) async {
    if (!selection.isValid || selection.isCollapsed) return null;
    final text = _controller.text;
    if (selection.start < 0 || selection.end > text.length) return null;

    final selected = [
      for (final ref in _attachments)
        if (ref.offset >= selection.start && ref.offset < selection.end) ref,
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    final selectedImages = selected.whereType<NoteImageRef>().toList();
    if (selectedImages.isEmpty ||
        selectedImages.length > maxClipboardFragmentImages ||
        selectedImages.fold<int>(0, (sum, ref) => sum + ref.bytes) >
            maxClipboardFragmentBytes) {
      return null;
    }

    final body = StringBuffer();
    final images = <ClipboardFragmentImage>[];
    var cursor = selection.start;
    for (final ref in selected) {
      body.write(
        text
            .substring(cursor, ref.offset)
            .replaceAll(NoteAttachmentRef.placeholder, '[Attachment]'),
      );
      if (ref is NoteImageRef) {
        final bytes = await _clipboardBytes(ref);
        if (bytes == null) return null;
        final relativeOffset = body.length;
        body.write(NoteAttachmentRef.placeholder);
        images.add(
          ClipboardFragmentImage(
            offset: relativeOffset,
            bytes: bytes,
            mime: ref.mime,
            width: ref.width,
            height: ref.height,
            widthFactor: ref.widthFactor,
          ),
        );
      } else if (ref is NoteVoiceRef) {
        body.write('[Voice note]');
      } else {
        body.write('[Attachment]');
      }
      cursor = ref.offset + 1;
    }
    body.write(
      text
          .substring(cursor, selection.end)
          .replaceAll(NoteAttachmentRef.placeholder, '[Attachment]'),
    );
    return NoteClipboardFragment(body: body.toString(), images: images);
  }

  Future<bool> _copyRichSelection(TextSelection selection) async {
    ContextMenuController.removeAny();
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.start < 0 ||
        selection.end > _controller.text.length) {
      return false;
    }
    final selectedImages = [
      for (final ref in _attachments)
        if (ref is NoteImageRef &&
            ref.offset >= selection.start &&
            ref.offset < selection.end)
          ref,
    ];
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
    if (_copyingRichSelection) return false;
    _copyingRichSelection = true;
    try {
      final fragment = await _clipboardFragment(selection);
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
      Toast.show(context, imageOnly ? 'Image copied' : 'Copied with images');
      return true;
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes editor',
          context: ErrorDescription('while copying images from a note'),
        ),
      );
      if (mounted) {
        Toast.show(
          context,
          'Could not copy that image',
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
    _editableTextState()?.userUpdateTextEditingValue(
      before.replaced(selection, ''),
      cause,
    );
    _focusNode.requestFocus();
  }

  void _handleCopyIntent(CopySelectionTextIntent intent) {
    if (intent.collapseSelection && widget.readOnly) return;
    final editable = _editableTextState();
    if (editable == null) return;
    final selection = editable.textEditingValue.selection;
    if (!_selectionContainsImage(selection)) {
      if (intent.collapseSelection) {
        editable.cutSelection(intent.cause);
      } else {
        editable.copySelection(intent.cause);
      }
      return;
    }
    if (intent.collapseSelection) {
      unawaited(_copyAndCutRichSelection(selection, intent.cause));
    } else {
      unawaited(_copyRichSelection(selection));
    }
  }

  List<ContextMenuButtonItem> _withRichCopy(
    List<ContextMenuButtonItem> items,
    TextSelection selection,
  ) {
    if (!_selectionContainsImage(selection)) return items;
    return [
      for (final item in items)
        if (item.type == ContextMenuButtonType.copy)
          ContextMenuButtonItem(
            type: item.type,
            label: item.label,
            onPressed: () => unawaited(_copyRichSelection(selection)),
          )
        else
          item,
    ];
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

  void _scheduleSelectionToolbar(TextSelection selection) {
    _selectionToolbarTimer?.cancel();
    if (!selection.isValid || selection.isCollapsed || !_focusNode.hasFocus) {
      return;
    }
    _selectionToolbarTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted ||
          !_focusNode.hasFocus ||
          _controller.selection != selection) {
        return;
      }
      _editableTextState()?.showToolbar();
    });
  }

  EditableTextState? _editableTextState() {
    final root = _textFieldKey.currentContext;
    if (root is! Element) return null;
    EditableTextState? result;
    void visit(Element element) {
      if (result != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        result = element.state as EditableTextState;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return result;
  }

  static RenderEditable? _findRenderEditable(RenderObject root) {
    if (root is RenderEditable) return root;
    RenderEditable? result;
    root.visitChildren((child) {
      result ??= _findRenderEditable(child);
    });
    return result;
  }

  void _evaluate() {
    // In markdown, the calculator reads the note with its code blanked and
    // its list markers made bullets; see MarkdownAnalysis.calculatorText.
    final evaluation = widget.engine.evaluateDocumentWithSummary(
      _controller.calculatorTextFor(_controller.text),
    );
    _results = evaluation.results;
    _totalText = evaluation.totalText;
  }

  void _dragGutter(double width) => widget.onGutterWidthChanged(width);

  void _restoreGutter(double? width) {
    if (width != null) widget.onGutterWidthChanged(width);
    widget.onResultsVisibilityChanged(true);
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
  /// `WidgetSpan` counts as exactly one character, and `EditableText` requires
  /// the span it paints to hold precisely the text the controller does — so
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
    RenderEditable editable,
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
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: row.start, extentOffset: row.start + 1),
    );
    if (boxes.isEmpty) return false;
    final box = boxes.first;
    final origin = editable.localToGlobal(Offset(0, box.top));
    final column = geometry.columnAt(globalPosition.dx - origin.dx);
    if (column == null) return false;

    final rect = _cellRect(editable, table, where.row, column);
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
    RenderEditable editable,
    MarkdownTable table,
    int row,
    int column,
  ) {
    final geometry = _tableGrids[table];
    if (geometry == null || column >= geometry.columns.length) return null;
    final band = _tableRowBand(editable, table, row);
    if (band == null) return null;
    final left = editable.localToGlobal(Offset.zero).dx;
    return Rect.fromLTRB(
      left + geometry.columnLeft(column),
      band.top,
      left + geometry.columnLeft(column) + geometry.columns[column],
      band.bottom,
    );
  }

  /// The band one row of a table is painted in, in global coordinates.
  ///
  /// Worked out exactly as [MarkdownBackdrop] works it out — from the top of the
  /// row's line to the top of the line after it — so that the field opened over
  /// a cell covers the painted cell to the pixel. The header's band takes in the
  /// `|---|` line under it as well, which is how the grid draws it.
  ({double top, double bottom})? _tableRowBand(
    RenderEditable editable,
    MarkdownTable table,
    int row,
  ) {
    final offsets = _lineOffsets;
    if (offsets == null || row < 0 || row >= table.rows.length) return null;
    final tops = offsets.tops;
    final line = table.rows[row];
    final end = line.header ? table.delimiterEnd : line.end;
    final first = _lineIndexOf(line.start);
    final last = _lineIndexOf(math.max(line.start, end - 1));
    if (first >= tops.length) return null;
    final top = tops[first];
    final bottom = last + 1 < tops.length
        ? tops[last + 1]
        : offsets.totalHeight;
    if (bottom <= top) return null;
    final scrolled = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final origin = editable.localToGlobal(Offset.zero).dy - scrolled;
    return (top: origin + top, bottom: origin + bottom);
  }

  int _lineIndexOf(int offset) {
    final text = _controller.text;
    if (!identical(text, _lineStartsText)) {
      _lineStartsText = text;
      _lineStarts = [
        0,
        for (var i = 0; i < text.length; i++)
          if (text.codeUnitAt(i) == 0x0A) i + 1,
      ];
    }
    final starts = _lineStarts!;
    var low = 0;
    var high = starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  /// Where a collaborator's caret sits inside the painted grid.
  ///
  /// The source characters under a table are deliberately hidden and occupy
  /// almost no width, so RenderEditable cannot place a useful caret there.
  /// Resolve the source offset to its cell and ask the same geometry that drew
  /// the grid where the visible words are instead.
  Rect? _remoteTableCaretRect(int offset) {
    final editable = _fieldEditable();
    if (editable == null) return null;
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
    final cellRect = _cellRect(editable, table, where.row, where.column);
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
    final editable = _fieldEditable();
    if (editable == null) return;
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
          final rect = _cellRect(editable, table, row, column);
          if (rect != null) yield rect;
        }
      }
    }
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
    final editable = _fieldEditable();
    if (active == null || editable == null) {
      _closeCellEditor();
      return;
    }
    final rect = _cellRect(editable, active.table, active.row, active.column);
    if (rect == null) {
      _closeCellEditor();
      return;
    }
    _showCellEditor(active.table, active.row, active.column, rect);
  }

  void _syncTableCellEditorPosition() {
    if (!_cellEditor.isVisible) return;
    final active = _activeTableCell();
    final editable = _fieldEditable();
    if (active == null || editable == null) return;
    final rect = _cellRect(editable, active.table, active.row, active.column);
    if (rect == null) return;
    final geometry = _tableGrids[active.table];
    _cellEditor.moveTo(
      rect,
      bounds: editable.localToGlobal(Offset.zero) & editable.size,
      tableLeft: geometry == null
          ? null
          : rect.left - geometry.columnLeft(active.column),
      tableTop: _tableRowBand(editable, active.table, 0)?.top,
    );
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
      final editable = _fieldEditable();
      final rect = editable == null
          ? null
          : _cellRect(editable, table, next.row, next.column);
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
      final editable = _fieldEditable();
      final rect = editable == null
          ? null
          : _cellRect(editable, active.table, nextRow, active.column);
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
    final editable = _fieldEditable();
    if (active == null || editable == null) return;
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
    final rect = _cellRect(editable, table, target.row, target.column);
    if (rect == null) return;
    _showCellEditor(
      table,
      target.row,
      target.column,
      rect,
      caretAtStart: direction == AxisDirection.right,
    );
  }

  void _addTableRow({bool above = false}) {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    // Nothing goes above the header: the row under it would become the header.
    if (above && active.row == 0) return;
    final targetRow = above ? active.row : active.row + 1;
    _applyTableEdit(
      insertMarkdownTableRow(
        _controller.value,
        active.table,
        after: above ? active.row - 1 : active.row,
      ),
    );
    _scheduleTableCell(active.table.start, targetRow, active.column);
  }

  void _removeTableRow() {
    final active = _activeTableCell();
    if (active == null || active.row == 0 || widget.readOnly) return;
    _applyTableEdit(
      removeMarkdownTableRow(_controller.value, active.table, row: active.row),
    );
    final targetRow = math.min(active.row, active.table.rows.length - 2);
    _scheduleTableCell(active.table.start, targetRow, active.column);
  }

  void _addTableColumn({bool before = false}) {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    _applyTableEdit(
      insertMarkdownTableColumn(
        _controller.value,
        active.table,
        after: before ? active.column - 1 : active.column,
      ),
    );
    _scheduleTableCell(
      active.table.start,
      active.row,
      before ? active.column : active.column + 1,
    );
  }

  void _removeTableColumn() {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    final columns = markdownTableColumnCount(active.table);
    if (columns <= 1) return;
    _applyTableEdit(
      removeMarkdownTableColumn(
        _controller.value,
        active.table,
        column: active.column,
      ),
    );
    _scheduleTableCell(
      active.table.start,
      active.row,
      math.min(active.column, columns - 2),
    );
  }

  MarkdownCellAlign _tableColumnAlignment(MarkdownTable table, int column) =>
      table.aligns.elementAtOrNull(column) ?? MarkdownCellAlign.start;

  void _cycleTableColumnAlignment() {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    final current = _tableColumnAlignment(active.table, active.column);
    _setTableColumnAlignment(switch (current) {
      MarkdownCellAlign.start => MarkdownCellAlign.center,
      MarkdownCellAlign.center => MarkdownCellAlign.end,
      MarkdownCellAlign.end => MarkdownCellAlign.start,
    });
  }

  void _setTableColumnAlignment(MarkdownCellAlign next) {
    final active = _activeTableCell();
    if (active == null || widget.readOnly) return;
    if (_tableColumnAlignment(active.table, active.column) == next) return;
    _applyTableEdit(
      setMarkdownTableColumnAlign(
        _controller.value,
        active.table,
        column: active.column,
        align: next,
      ),
    );
    _scheduleTableCell(active.table.start, active.row, active.column);
  }

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
    final columns = markdownTableColumnCount(table);
    final alignment = _tableColumnAlignment(table, column);
    final header = table.rows[row].header;
    final base = EditorMetrics.textStyle(
      palette.textPrimary,
      widget.writingFont,
      editorScale: widget.editorTextScale,
    );
    final editable = _fieldEditable();
    final origin = editable?.localToGlobal(Offset.zero);
    final geometry = _tableGrids[table];
    _cellEditor.show(
      context,
      anchor: rect,
      bounds: editable == null || origin == null
          ? null
          : origin & editable.size,
      tableLeft: geometry == null
          ? rect.left
          : rect.left - geometry.columnLeft(column),
      tableTop: editable == null
          ? rect.top
          : _tableRowBand(editable, table, 0)?.top ?? rect.top,
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
      showToolbar: !AppPlatform.isMobile,
      cursorColor: accent,
      background: header ? palette.controlBackground : palette.paperColor,
      border: accent,
      toolbarBackground: palette.paperColor,
      onChanged: _commitCellText,
      onDone: _closeCellEditor,
      onTapOutside: _cellTappedOutside,
      onTab: (backwards) => _moveToCell(backwards: backwards),
      onEnter: _moveDownTable,
      onArrow: _moveByArrow,
      onAddRowAbove: row == 0 ? null : () => _addTableRow(above: true),
      onAddRow: _addTableRow,
      onRemoveRow: row == 0 ? null : _removeTableRow,
      onAddColumnBefore: () => _addTableColumn(before: true),
      onAddColumn: _addTableColumn,
      onRemoveColumn: columns <= 1 ? null : _removeTableColumn,
      onAlign: _setTableColumnAlignment,
      onUndo: () => _undoTableEdit(redo: false),
      onRedo: () => _undoTableEdit(redo: true),
      alignment: alignment,
    );
    if (moved) _ensureCellVisible();
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
      final editable = _fieldEditable();
      if (active == null || editable == null || !editable.hasSize) return;
      final rect = _cellRect(editable, active.table, active.row, active.column);
      if (rect == null) return;
      final view = editable.localToGlobal(Offset.zero) & editable.size;
      final window = View.of(context);
      final keyboardTop =
          (window.physicalSize.height - window.viewInsets.bottom) /
          window.devicePixelRatio;
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
  /// undo all behave as they always have.
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
    if (edit.changesText) _applyTableEdit(edit);
  }

  /// A press outside the open cell finishes it — unless it is on the same
  /// table, where it is choosing another cell. Closing first would hand the
  /// note the keyboard only for the next cell to take it back, and on a phone
  /// the keyboard went down in that exchange and stayed down.
  void _cellTappedOutside(Offset position) {
    final active = _activeTableCell();
    final editable = _fieldEditable();
    if (active != null && editable != null && !widget.readOnly) {
      final table = active.table;
      final geometry = _tableGrids[table];
      final first = _tableRowBand(editable, table, 0);
      final last = _tableRowBand(editable, table, table.rows.length - 1);
      if (geometry != null && first != null && last != null) {
        final left = editable.localToGlobal(Offset.zero).dx;
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
    final editable = _editableTextState();
    if (editable == null) {
      _controller.value = parked;
    } else {
      // A keyboard cause, never the toolbar's. For any other cause the field
      // asks for the keyboard, which takes focus from the open cell — and the
      // next key typed lands in the table's hidden pipes instead.
      editable.userUpdateTextEditingValue(
        parked,
        SelectionChangedCause.keyboard,
      );
    }
  }

  Map<int, NoteImageSpan> _tableRowSpacers({
    required MarkdownAnalysis? markdown,
    required double rowHeight,
    required double overhead,
  }) {
    if (markdown == null || _tableGrids.isEmpty) return const {};
    final spacers = <int, NoteImageSpan>{};
    for (final table in markdown.tables) {
      final geometry = _tableGrids[table];
      if (geometry == null) continue;
      for (final row in table.rows) {
        final wanted =
            geometry.rowHeight(row) - (row.header ? rowHeight : 0) - overhead;
        // A row needing no more than the line it already has takes no spacer:
        // the strut floor gives it that much for nothing.
        if (wanted <= 0) continue;
        // The child has to carry the height itself. `RenderEditable` lays a
        // placeholder out by asking its widget, not from the dimensions handed
        // to a `TextPainter` — those only answer for a painter measuring on its
        // own, which is why a `SizedBox.shrink()` here reserved nothing at all.
        spacers[row.start] = (
          width: 0,
          height: wanted,
          child: SizedBox(width: 0, height: wanted),
        );
      }
    }
    return spacers;
  }

  Map<int, NoteImageSpan> _buildAttachmentSpans(
    double columnWidth,
    double viewportHeight,
  ) {
    final store = widget.images;
    if (_attachments.isEmpty || store == null) return const {};

    // Tall images are capped rather than allowed to fill the screen: a note is
    // writing with pictures in it, not a gallery with captions.
    final maxHeight = viewportHeight.isFinite && viewportHeight > 0
        ? viewportHeight * 0.6
        : 420.0;
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
        spans[ref.offset] = (
          width: columnWidth,
          height: noteVoiceChipHeight + noteImageGap,
          child: SizedBox(width: columnWidth, child: _voiceChip(ref)),
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
            onOpen: () => NoteVideoViewer.open(
              context,
              ref: ref,
              store: store,
              fetch: widget.imageFetch,
            ),
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
        ),
      );
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // No home indicator inset here: the footer below runs under it and keeps
    // its own controls clear of it, so an inset on the text would only open a
    // second gap above a bar that already covers that strip.
    final padding = AppPlatform.isMobile
        ? EditorMetrics.mobilePadding
        : EditorMetrics.padding;
    final textStyle = EditorMetrics.textStyle(
      palette.textPrimary,
      widget.writingFont,
      editorScale: widget.editorTextScale,
    );
    // Only a note that needs a row taller than one line gives up the forced
    // one: a picture, or a table whose cells wrap onto more lines than that.
    final holdsTable = _controller
        .markdownFor(_controller.text)
        .tables
        .isNotEmpty;
    final strut = EditorMetrics.strut(
      widget.writingFont,
      allowTallRows:
          (_attachments.isNotEmpty && widget.images != null) || holdsTable,
      editorScale: widget.editorTextScale,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final mobileTableCell = AppPlatform.isMobile ? _activeTableCell() : null;

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
                // Compact and touch layouts reserve the results rail only when
                // a line calculates, so prose, checklists, and journals keep
                // the full writing width. Desktop preserves its saved panel.
                final hasResults = _results.isNotEmpty;
                final emptyResultsSuppressed =
                    !hasResults &&
                    (!widget.showDivider || widget.hideEmptyResults);
                final resultsVisible =
                    !emptyResultsSuppressed &&
                    (!widget.showDivider || widget.resultsVisible);
                final dividerWidth = widget.showDivider && resultsVisible
                    ? GutterDivider.width
                    : 0.0;
                final gutterWidth = resultsVisible
                    ? widget.gutterWidth.clamp(
                        0.0,
                        (constraints.maxWidth - 160).clamp(0.0, 480.0),
                      )
                    : 0.0;
                final textPaneWidth =
                    constraints.maxWidth - gutterWidth - dividerWidth;

                // Must match the text field's own content box exactly, right
                // down to the sliver it holds back for the caret.
                const trailingGap = 16.0;
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

                // Every table's grid, fitted to the writing column so that a
                // wide one shrinks and wraps rather than running off the side of
                // a phone. Worked out here for the same reason images are sized
                // here: it is the first point at which the width is known.
                final rowHeight = textScaler.scale(
                  EditorMetrics.lineHeight * widget.editorTextScale,
                );
                _tableGrids = {
                  for (final table in markdown.tables)
                    table: _tableGeometry.of(
                      table: table,
                      analysis: markdown,
                      base: textStyle,
                      scaler: textScaler,
                      fitToWidth: attachmentWidth,
                      minRowHeight: rowHeight,
                      runStyle: (base, styles) {
                        final drawn = _controller.markdownRunStyle(
                          base,
                          styles,
                          Theme.of(context).colorScheme.primary,
                        );
                        // The pill inline code has in the text can be a plain
                        // background in a grid painted behind it: there is no
                        // selection to show over it there.
                        return styles.contains(MarkdownStyle.code)
                            ? drawn.copyWith(
                                backgroundColor: palette.controlBackground,
                              )
                            : drawn;
                      },
                    ),
                };

                // A table's rows reserve their room the same way a picture
                // does, through a placeholder apiece. A real attachment wins any
                // offset they might share.
                _controller.setImageSpansDuringLayout({
                  ..._tableRowSpacers(
                    markdown: markdown,
                    rowHeight: rowHeight,
                    overhead: placeholderLineOverhead(
                      style: textStyle,
                      strut: strut,
                      scaler: textScaler,
                    ),
                  ),
                  ..._buildAttachmentSpans(
                    attachmentWidth,
                    constraints.maxHeight,
                  ),
                });
                if (_editingCell != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _syncTableCellEditorPosition();
                  });
                }
                final offsets = _measurer.measure(
                  span: _controller.buildTextSpan(
                    context: context,
                    style: textStyle,
                    withComposing: false,
                  ),
                  text: _controller.text,
                  maxWidth: contentWidth,
                  strut: strut,
                  textScaler: textScaler,
                  // What is hidden changes where lines wrap, so it is part of
                  // what the measurement depends on.
                  layoutKey: (
                    widget.writingFont,
                    widget.editorTextScale,
                    _formats,
                    widget.markdownEnabled,
                    concealment.key,
                  ),
                  placeholders: _controller.placeholderDimensions(),
                );
                _lineOffsets = offsets;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: textPaneWidth,
                            child: NotebookPaper(
                              style: widget.paperStyle,
                              lineHeight: offsets.lineHeight,
                              topInset: padding.top,
                              scroll: _scrollController,
                              child: Stack(
                                children: [
                                  if (_isEmpty)
                                    _Placeholder(
                                      padding: padding,
                                      style: textStyle,
                                      strut: strut,
                                      writingFont: widget.writingFont,
                                    ),
                                  // A note with a table always needs it, even on
                                  // a device with markdown switched off. A plain
                                  // note gains no layer it did not have before.
                                  if (widget.markdownEnabled ||
                                      markdown.tables.isNotEmpty)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: MarkdownBackdrop(
                                          analysis: markdown,
                                          concealment: concealment,
                                          grids: _tableGrids,
                                          offsets: offsets,
                                          scroll: _scrollController,
                                          editable: _fieldEditable,
                                          colors: MarkdownBackdropColors(
                                            quiet: palette.textSecondary,
                                            faint: palette.textTertiary
                                                .withValues(alpha: 0.35),
                                            panel: palette.controlBackground,
                                            panelBorder: palette.controlBorder,
                                            accent: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            onAccent: Theme.of(
                                              context,
                                            ).colorScheme.onPrimary,
                                          ),
                                          markerRoom: _controller
                                              .markdownMarkerRoom(
                                                textStyle,
                                                textScaler,
                                              ),
                                        ),
                                      ),
                                    ),
                                  // Under the field, as its own highlight is.
                                  Positioned.fill(
                                    child: BlankLineHighlight(
                                      editable: () =>
                                          _editableTextState()?.renderEditable,
                                      repaint: _selectionRepaint,
                                    ),
                                  ),
                                  _buildField(
                                    padding,
                                    textStyle,
                                    strut,
                                    trailingGap,
                                  ),
                                  if (widget.remoteCarets case final source?)
                                    Positioned.fill(
                                      child: RemoteCaretLayer(
                                        noteId: widget.noteId,
                                        source: source,
                                        controller: _controller,
                                        scroll: _scrollController,
                                        editable: _fieldEditable,
                                        hover: _remoteHover,
                                        tableCaretRect: _remoteTableCaretRect,
                                        tableSelectionRects:
                                            _remoteTableSelectionRects,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (widget.showDivider && resultsVisible)
                            GutterDivider(
                              gutterWidth: gutterWidth,
                              onDrag: _dragGutter,
                              onHide: () =>
                                  widget.onResultsVisibilityChanged(false),
                              onReset: widget.onGutterWidthReset,
                            ),
                          if (resultsVisible)
                            SizedBox(
                              width: gutterWidth,
                              // The gutter has no scrollable of its own, so a
                              // drag over it is handed to the field's.
                              child: ScrollPassthrough(
                                controller: _scrollController,
                                child: ListenableBuilder(
                                  listenable: _scrollController,
                                  builder: (context, _) => ResultsGutter(
                                    results: _results,
                                    offsets: offsets,
                                    scrollOffset: _scrollController.hasClients
                                        ? _scrollController.offset
                                        : 0,
                                    viewportHeight: constraints.maxHeight,
                                    padding: padding,
                                    width: gutterWidth,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.showDivider &&
                        !resultsVisible &&
                        !emptyResultsSuppressed)
                      Positioned(
                        top: 0,
                        right: 0,
                        bottom: 0,
                        child: ResultsRestoreHandle(onRestore: _restoreGutter),
                      ),
                  ],
                );
              },
            ),
          ),
          if (!widget.readOnly && _liveSession != null)
            VoiceRecordingBar(
              session: _liveSession!,
              onPause: widget.recording?.pause,
              onResume: widget.recording?.resume,
              onStop: widget.onRecordVoice,
              onCancel: () => unawaited(widget.recording!.cancel()),
            )
          else
            NoteFooter(
              total: AppPlatform.isMobile ? null : _totalText,
              typing: widget.typing,
              readOnly: widget.readOnly,
              readOnlyLabel: widget.readOnlyLabel,
              readOnlyIcon: widget.readOnlyIcon,
              onReadOnlyPressed: widget.onReadOnlyPressed,
              paragraphStyleShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.cycleTextStyle,
              ),
              boldShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.formatBold,
              ),
              italicShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.formatItalic,
              ),
              bulletsShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.formatBullets,
              ),
              checklistShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.formatChecklist,
              ),
              imageShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.insertImage,
              ),
              voiceShortcut: widget.shortcuts.bindingFor(
                ShortcutAction.recordVoiceNote,
              ),
              onParagraphStylePressed: _cycleParagraphStyle,
              onBoldPressed: () => _toggleInlineFormat(NoteFormat.bold),
              onItalicPressed: () => _toggleInlineFormat(NoteFormat.italic),
              onBulletsPressed: _toggleBullets,
              onInsertImagePressed: widget.readOnly || widget.images == null
                  ? null
                  : () => unawaited(pickAndInsertImages()),
              imageBusy: _imageActionBusy,
              onInsertVideoPressed: widget.readOnly || widget.images == null
                  ? null
                  : () => unawaited(pickAndInsertVideos()),
              videoBusy: _videoActionBusy,
              onRecordVoicePressed: widget.readOnly
                  ? null
                  : widget.onRecordVoice,
              voiceBusy: widget.voiceActionBusy,
              onChecklistPressed: _toggleChecklist,
              onInsertMenuPressed: _showInsertMenu,
              onIndentPressed: () => _indentList(outdent: false),
              onOutdentPressed: () => _indentList(outdent: true),
              showIndentControls: _showIndentControls,
              canIndent: _canIndent(outdent: false),
              canOutdent: _canIndent(outdent: true),
              onAddTableRowPressed: mobileTableCell == null
                  ? null
                  : _addTableRow,
              onRemoveTableRowPressed:
                  mobileTableCell == null || mobileTableCell.row == 0
                  ? null
                  : _removeTableRow,
              onAddTableColumnPressed: mobileTableCell == null
                  ? null
                  : _addTableColumn,
              onRemoveTableColumnPressed:
                  mobileTableCell == null ||
                      markdownTableColumnCount(mobileTableCell.table) <= 1
                  ? null
                  : _removeTableColumn,
              onCycleTableAlignmentPressed: mobileTableCell == null
                  ? null
                  : _cycleTableColumnAlignment,
              tableTapGroup: _cellEditor,
              tableAlignment: mobileTableCell == null
                  ? null
                  : _tableColumnAlignment(
                      mobileTableCell.table,
                      mobileTableCell.column,
                    ),
              boldActive: _formatActive(NoteFormat.bold),
              italicActive: _formatActive(NoteFormat.italic),
              bulletsActive: _lineStyleActive(NoteLineStyle.bullet),
              checklistActive: _lineStyleActive(NoteLineStyle.checklist),
              paragraphStyle: _activeParagraphStyle,
              markdownHeadingLevel: widget.markdownEnabled
                  ? _markdownHeadingLevel
                  : null,
              markdown: widget.markdownEnabled,
              onDismissKeyboardPressed:
                  AppPlatform.isMobile && _keyboardInset > 0
                  ? _dismissKeyboard
                  : null,
            ),
        ],
      ),
    );

    return ImageDropTarget(
      enabled: !widget.readOnly && widget.images != null,
      onFiles: (files) => unawaited(insertDroppedMedia(files)),
      child: page,
    );
  }

  Widget _buildField(
    EdgeInsets padding,
    TextStyle textStyle,
    StrutStyle strut,
    double trailingGap,
  ) {
    return Padding(
      padding: EdgeInsets.only(
        left: padding.left,
        right: trailingGap,
        top: padding.top,
        bottom: padding.bottom,
      ),
      child: Focus(
        // Not a focus stop of its own; it only watches the field below for Tab
        // before the app's traversal shortcuts can claim it.
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleEditorKey,
        child: _textField(textStyle, strut),
      ),
    );
  }

  Widget _textField(TextStyle textStyle, StrutStyle strut) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleEditorScrollNotification,
      child: MouseRegion(
        // Hover only. The cursor itself goes to the TextField below: it builds
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
          // `EditableText` builds its paste action with `Action.overridable`,
          // which looks an override up in the ancestor context — so this is the
          // supported way in, rather than a shortcut racing the built-in one.
          child: Actions(
            actions: {
              CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
                onInvoke: (intent) {
                  _handleCopyIntent(intent);
                  return null;
                },
              ),
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (intent) {
                  unawaited(handlePaste(intent.cause));
                  return null;
                },
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
                if (!widget.readOnly && widget.images != null)
                  ?widget.shortcuts
                      .bindingFor(ShortcutAction.insertImage)
                      ?.activator: () =>
                      unawaited(pickAndInsertImages()),
                ?widget.shortcuts
                        .bindingFor(ShortcutAction.openSettings)
                        ?.activator:
                    widget.onSettingsPressed,
              },
              child: TextField(
                key: _textFieldKey,
                mouseCursor: _hoverCursor,
                controller: _controller,
                focusNode: _focusNode,
                scrollController: _scrollController,
                autofocus: !widget.readOnly && widget.autofocus,
                readOnly: widget.readOnly,
                expands: true,
                maxLines: null,
                minLines: null,
                style: textStyle,
                strutStyle: strut,
                cursorWidth: EditorMetrics.cursorWidth,
                cursorHeight: EditorMetrics.cursorHeight(
                  widget.writingFont,
                  editorScale: widget.editorTextScale,
                  textScaler: MediaQuery.textScalerOf(context),
                ),
                cursorRadius: const Radius.circular(1),
                cursorColor: Theme.of(context).colorScheme.primary,
                // Uniform selection rectangles: without this, a line whose glyphs
                // come from a fallback font gets a differently sized highlight.
                selectionHeightStyle: BoxHeightStyle.strut,
                // A highlight stops at the end of its own line. Flutter defaults
                // this to `max` off the web, which pads every selected line that
                // carries a line break out to the width of the longest line in
                // the whole note — so selecting two short lines under a long one
                // paints a block of empty space that is not selected at all.
                selectionWidthStyle: BoxWidthStyle.tight,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                // Flutter's stock spelling renderer replaces a custom
                // controller's TextSpan tree after it finds a misspelling.
                // KapyNotes merges the native results into its own tree so
                // calculator colours and attachment WidgetSpans stay intact.
                spellCheckConfiguration:
                    const SpellCheckConfiguration.disabled(),
                inputFormatters: [
                  _dailySeparatorFormatter,
                  // Whatever the markdown setting: tables draw either way.
                  _TableEdgeFormatter(_controller.markdownFor),
                  if (widget.markdownEnabled) ...[
                    _MarkdownTypingFormatter(
                      _controller.markdownFor,
                      _markdownTyping,
                    ),
                    _MarkdownStructureFormatter(_controller.markdownFor),
                  ],
                  _ListContinuationFormatter(
                    markdown: widget.markdownEnabled
                        ? _controller.markdownFor
                        : null,
                  ),
                  // In markdown `- ` already is a list item, and turning it
                  // into a bullet glyph would take the markdown away.
                  if (!widget.markdownEnabled) const _ListShorthandFormatter(),
                  // Last, so it sees whatever the others made of the edit: a
                  // continuation or a shorthand landing on a picture's line
                  // has to be moved off it too.
                  const _ImageLineFormatter(),
                ],
                contextMenuBuilder: (context, editableTextState) =>
                    _EditMenuPresence(
                      // Counted, not read off the field: a tap on a phone
                      // needs to know whether it is putting a menu away.
                      onPresence: (shown) => _editMenus += shown ? 1 : -1,
                      child: ListenableBuilder(
                        // Rebuilds the menu when a word's corrections arrive
                        // after it opened, and when the clipboard answers:
                        // until it has, the field offers no Paste at all.
                        // Either way the menu is not left half-answered.
                        listenable: Listenable.merge([
                          _correctionsArrived,
                          editableTextState.clipboardStatus,
                        ]),
                        builder: (context, _) =>
                            _contextMenu(context, editableTextState),
                      ),
                    ),
                textAlignVertical: TextAlignVertical.top,
                // Spelling may point something out, but the calculator must
                // never rewrite a value, operator, name or unit on its own.
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                scrollPadding: const EdgeInsets.all(80),
                // No decoration padding: an InputDecorator positions its child by
                // rules of its own, and the gutter needs the text origin to be
                // exactly the padding it was told about.
                decoration: const InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  filled: false,
                  hoverColor: Colors.transparent,
                  contentPadding: EdgeInsets.zero,
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
  });

  final EdgeInsets padding;
  final TextStyle style;
  final StrutStyle strut;
  final WritingFont writingFont;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Positioned.fill(
      child: IgnorePointer(
        child: Padding(
          padding: padding,
          child: Align(
            alignment: Alignment.topLeft,
            child: Text.rich(
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
/// happen *before* the value is applied: `EditableText` runs these on typing,
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

/// Markdown that behaves like formatting rather than like characters: Bold
/// switched on with nothing selected wraps what is typed next, a space or
/// Return at the end of a styled word steps out of the style, and emptying a
/// styled word takes its hidden markers with it.
/// See [separateTypingFromTables].
class _TableEdgeFormatter extends TextInputFormatter {
  const _TableEdgeFormatter(this.markdown);

  final MarkdownAnalysis Function(String text) markdown;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      separateTypingFromTables(oldValue, newValue, markdown(oldValue.text)) ??
      newValue;
}

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

/// Keystrokes that act on a line's hidden markdown as one piece: Backspace
/// at the start of a heading or list item takes the whole `## ` or `- [ ] `
/// away, and `[] ` at the start of a line becomes a checkbox.
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
          borderRadius: BorderRadius.circular(6),
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
