import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle, Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kLongPressTimeout, kPrimaryButton, kSecondaryButton, kTouchSlop;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../calc/engine.dart';
import '../../calc/highlight.dart';
import '../../calc/keyword_help.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/platform.dart';
import '../../core/platform_spell_check.dart';
import '../../core/appearance.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/daily_separator.dart';
import '../../data/note_format.dart';
import '../../data/shortcut_prefs.dart';
import '../notebook_paper.dart';
import '../celebrate.dart';
import '../kapy_cursor_peek.dart';
import 'editor_formatting.dart';
import 'highlighting_controller.dart';
import 'line_metrics.dart';
import 'link_popover.dart';
import 'keyword_tooltip.dart';
import 'note_footer.dart';
import '../../data/note_attachment.dart';
import 'package:file_selector/file_selector.dart';

import '../../images/image_clipboard.dart';
import '../../images/image_ingest.dart';
import '../../images/image_picker.dart';
import '../../audio/voice_player.dart';
import '../../data/blob_store.dart';
import '../../images/note_image_provider.dart';
import 'image_drop_target.dart';
import 'image_insertion.dart';
import 'note_image_layout.dart';
import '../../audio/voice_recording_controller.dart';
import 'voice_chip.dart';
import 'voice_recording_bar.dart';
import 'voice_insertion.dart';
import 'note_image_view.dart';
import 'results_gutter.dart';
import 'scroll_passthrough.dart';
import 'selection_formatting_toolbar.dart';

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
    this.onImagesRejected,
    this.typingNames = const [],
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
    required this.shortcuts,
    this.spellCheckEnabled = true,
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

  /// Called when at least one file in a batch could not be added.
  final ValueChanged<ImageBatch>? onImagesRejected;

  /// Other members actively editing this shared note.
  final List<String> typingNames;

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
  final ShortcutPrefs shortcuts;
  final bool spellCheckEnabled;
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
  late final _DailySeparatorFormatter _dailySeparatorFormatter;
  Timer? _keyboardRetryTimer;
  Timer? _selectionToolbarTimer;
  Timer? _keywordHoverTimer;
  Timer? _kapyPeekIdleTimer;
  VoidCallback? _kapyPeekDismiss;

  Map<int, LineResult> _results = const {};
  String? _totalText;
  String? _hoveredKeywordId;
  late TextEditingValue _lastValue;
  late List<NoteFormatRange> _formats;
  late List<NoteAttachmentRef> _attachments;
  final Map<NoteFormat, bool> _typingOverrides = {};
  NoteParagraphStyle? _paragraphOverride;
  final Map<int, _PointerDownDetails> _pointerDownDetails = {};
  Set<NoteFormat>? _nextInsertedFormats;
  bool _imageActionBusy = false;
  bool _copyingRichSelection = false;

  /// The attachment list a programmatic edit has already worked out.
  ///
  /// Mirrors [_nextInsertedFormats]: an insert knows exactly where its images
  /// land, so it says so rather than leaving the change handler to infer it
  /// from a diff that cannot tell one placeholder from another.
  List<NoteAttachmentRef>? _nextAttachments;

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
    _controller.removeListener(_onControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _scrollController.removeListener(_handleEditorScroll);
    widget.shortcuts.removeListener(_onShortcutsChanged);
    widget.player?.removeListener(_onPlaybackChanged);
    _spellCheckService.dispose();
    _correctionsArrived.dispose();
    _keyboardRetryTimer?.cancel();
    _selectionToolbarTimer?.cancel();
    _keywordHoverTimer?.cancel();
    _kapyPeekIdleTimer?.cancel();
    _dismissKapyPeek();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  void _handleEditorScroll() {
    LinkPopover.hide();
    _clearKeywordTooltip();
    _recordKapyPeekActivity();
  }

  bool _handleEditorScrollNotification(ScrollNotification notification) {
    if (!AppPlatform.isMobile ||
        notification.metrics.axis != Axis.vertical ||
        !_focusNode.hasFocus) {
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
      _focusNode.unfocus();
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
    _dailySeparatorFormatter.syncLastUpdatedAt(widget.lastUpdatedAt);
    setState(() {
      _isEmpty = newText.isEmpty;
      _evaluate();
    });
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
    if (value.text == previous.text) {
      final selectionChanged = value.selection != previous.selection;
      _lastValue = value;
      if (!selectionChanged) return;
      if (_collapseLineTerminatorSelection(value.selection)) return;
      _typingOverrides.clear();
      _paragraphOverride = null;
      _scheduleSelectionToolbar(value.selection);
      setState(() {});
      return;
    }

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
    var updatedFormats = rebaseNoteFormats(
      oldText: previous.text,
      newText: value.text,
      formats: _formats,
      insertedFormats: insertedFormats,
    );
    if (insertedText.contains('\n') && value.selection.isValid) {
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

    final links = _controller.linksFor(text);
    final filtered = suggestions
        .where((suggestion) {
          final range = suggestion.range;
          final overlapsLink = links.any(
            (link) => range.start < link.end && range.end > link.start,
          );
          final overlapsAttachment = _attachments.any(
            (attachment) =>
                range.start <= attachment.offset &&
                range.end > attachment.offset,
          );
          return !overlapsLink && !overlapsAttachment;
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
    final store = widget.images;
    if (player == null || store == null) return;
    if (player.isPlaying(ref.hash)) {
      await player.pause();
      return;
    }
    final file = await store.fileFor(ref.hash);
    // Not on this device yet: it arrived by sync and the bytes have not come
    // down. Silence is the honest outcome; the chip already says so.
    if (file == null) return;
    await player.play(ref.hash, file);
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
    final store = widget.images;
    if (store == null) return;
    final file = await store.fileFor(ref.hash);
    if (file == null) return;
    await player.play(ref.hash, file, from: ref.duration * fraction);
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

  bool _formatActive(NoteFormat format) =>
      _typingOverrides[format] ??
      selectionHasFormat(_formats, _controller.selection, format);

  NoteParagraphStyle? get _activeParagraphStyle =>
      _paragraphOverride ??
      paragraphStyleForSelection(
        _controller.text,
        _formats,
        _controller.selection,
      );

  void _cycleParagraphStyle() {
    if (widget.readOnly) return;
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
        final progress = Toast.showProgress(context, 'Adding image…');
        try {
          final result = await ingestImage(
            source: pasted.bytes,
            sourceMime: mimeForFilename(pasted.name),
            store: store,
          );
          if (!mounted) {
            progress.dismiss();
            return;
          }
          if (result.isOk) {
            insertImages([result.image!.ref]);
            progress.success('Image added');
            return;
          }
          progress.error(
            '${pasted.name} ${describeRejection(result.rejection!)}',
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
          progress.error('Could not add that image');
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

  bool _beginImageAction() {
    if (widget.readOnly) return false;
    if (_imageActionBusy) {
      Toast.show(
        context,
        'Another image is still being added',
        icon: Icons.hourglass_top_rounded,
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

  Future<void> _ingestAndInsertFiles(List<XFile> files, BlobStore store) async {
    final count = files.length;
    final progress = Toast.showProgress(
      context,
      count == 1 ? 'Adding image…' : 'Adding $count images…',
    );
    try {
      final batch = await (widget.imageIngestor ?? _ingestImageFiles)(
        files,
        store,
      );
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
          icon: Icons.warning_amber_rounded,
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

  void _commitFormats(List<NoteFormatRange> formats) {
    if (widget.readOnly) return;
    _formats = formats;
    _controller.formats = formats;
    setState(() {});
    widget.onDocumentChanged(_controller.text, formats, _attachments);
  }

  void _toggleBullets() {
    if (widget.readOnly) return;
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
    ContextMenuController.removeAny();
    _nextInsertedFormats = const {};
    _controller.value = indentSelection(_controller.value, outdent: outdent);
    _focusNode.requestFocus();
  }

  /// Any key at all dismisses the link panel first. Escape is the one people
  /// reach for, but a panel that outlives the caret it was raised next to is
  /// wrong whichever key moved it.
  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
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
    if (!_focusNode.hasFocus || !selectionHasListLine(_controller.value)) {
      return KeyEventResult.ignored;
    }
    final pressed = keyboard.logicalKeysPressed;
    final outdent =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    // Claim the key even at the ends of the range, or Tab would silently fall
    // through to focus traversal exactly when the list stops moving.
    if (canIndentSelection(_controller.value, outdent: outdent)) {
      _indentList(outdent: outdent);
    }
    return KeyEventResult.handled;
  }

  void _handlePointerDown(PointerDownEvent event) {
    _clearKeywordTooltip();
    _recordKapyPeekActivity();
    if (event.buttons & kSecondaryButton != 0) {
      _caretForSecondaryTapOnMisspelling(event.position);
    }
    _prefetchCorrectionsAt(event.position);
    _pointerDownDetails[event.pointer] = _PointerDownDetails(
      position: event.position,
      timeStamp: event.timeStamp,
      wasPrimary: event.buttons & kPrimaryButton != 0,
    );
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
  }

  /// What the editor claims about itself under the pointer. An I-beam over
  /// text, a hand over a checkbox or a link.
  static const MouseCursor _textCursor = SystemMouseCursors.text;
  MouseCursor _hoverCursor = _textCursor;

  void _handlePointerUp(PointerUpEvent event) {
    final down = _pointerDownDetails.remove(event.pointer);
    if (down == null ||
        !down.wasPrimary ||
        event.timeStamp - down.timeStamp >= kLongPressTimeout ||
        (event.position - down.position).distance > kTouchSlop) {
      return;
    }
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    if (editable == null) return;

    if (_caretToBlankRow(editable, event.position)) return;

    final offset = editable.getPositionForPoint(event.position).offset;
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
    if (keyword != null) _showKeywordTooltip(keyword);
  }

  /// Confetti over the box just ticked, with a fuller burst for the last one.
  ///
  /// The finale is deliberately rare: a note has to have had at least two
  /// boxes and none of them can be left, so it marks finishing a list rather
  /// than ticking a single stray item.
  void _celebrateCheck(RenderEditable editable, Offset tapPosition) {
    if (!mounted) return;
    final text = _controller.text;
    final done = !text.contains(uncheckedPrefix);
    final total =
        uncheckedPrefix.allMatches(text).length +
        checkedPrefix.allMatches(text).length;
    final finale = done && total >= 2;
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
    if (_focusNode.hasFocus) {
      _recordKapyPeekActivity();
      return;
    }
    // Nothing left to raise a keyboard for. A retry still in flight would
    // otherwise put one up over a note nobody is writing in.
    _keyboardRetryTimer?.cancel();
    _kapyPeekIdleTimer?.cancel();
    _clearKeywordTooltip();
    _kapyPeekIdleTimer = null;
    _dismissKapyPeek();
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
    _keyboardWasUp = inset > 0;
    if (inset > 0 || !wasUp) return;
    if (widget.readOnly || !_focusNode.hasFocus) return;
    // Backgrounding the app also takes the keyboard down, and focus should
    // survive that: it is the same note, still open, when the app comes back.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _keyboardRetryTimer?.cancel();
    _focusNode.unfocus();
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

  /// Turns the pointer into a hand over things a click acts on, a help cursor
  /// over explained calculator words, and leaves an I-beam everywhere else.
  ///
  /// Checkboxes and links are characters inside an editable field rather than
  /// widgets, so nothing gives them a cursor for free — without this the
  /// editor claims the whole surface is text and offers no hint that any of
  /// it can be clicked.
  void _handleHover(PointerHoverEvent event) {
    final root = _textFieldKey.currentContext?.findRenderObject();
    final editable = root == null ? null : _findRenderEditable(root);
    var wanted = _textCursor;
    _KeywordHit? keyword;

    if (editable != null) {
      final offset = editable.getPositionForPoint(event.position).offset;
      // Link scanning is cached against the text, so hovering re-uses the
      // spans the highlighter already built rather than re-scanning the note.
      if ((!widget.readOnly &&
              _checkboxAt(editable, event.position, offset) >= 0) ||
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
      icon: Icons.error_outline_rounded,
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
        label: 'Open Link',
        onPressed: () => unawaited(_openLink(link)),
      ),
      ContextMenuButtonItem(
        label: 'Copy Link',
        onPressed: () => unawaited(_copyLink(link)),
      ),
    ];
  }

  /// The menu behind a right-click, a press-and-hold, or the keyboard.
  Widget _contextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final selection = editableTextState.textEditingValue.selection;
    final link = _linkForSelection(selection);
    final linkItems = _linkContextMenuItems(link);
    if (widget.readOnly) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: [
          ...linkItems,
          ..._withRichCopy(editableTextState.contextMenuButtonItems, selection),
          if (_controller.text.isNotEmpty)
            ContextMenuButtonItem(
              label: 'Copy Plain Text',
              onPressed: () => unawaited(_copyPlainText(selection)),
            ),
        ],
      );
    }
    if (selection.isCollapsed) {
      final spellingItems = _spellingContextMenuItems(selection);
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableTextState.contextMenuAnchors,
        buttonItems: [
          ...spellingItems,
          ...linkItems,
          if (widget.images != null && !AppPlatform.hasPointer)
            ContextMenuButtonItem(
              label: 'Add Image',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(pickAndInsertImages());
              },
            ),
          // Touch only, beside Add Image: on a phone the footer
          // row has no space left, so the press-and-hold menu is
          // where every insert action already lives.
          if (widget.onRecordVoice != null && !AppPlatform.hasPointer)
            ContextMenuButtonItem(
              label: 'Record Voice Note',
              onPressed: () {
                ContextMenuController.removeAny();
                widget.onRecordVoice!();
              },
            ),
          if (_controller.text.isNotEmpty)
            ContextMenuButtonItem(
              label: 'Copy Plain Text',
              onPressed: () => unawaited(_copyPlainText(selection)),
            ),
          ..._withImagePaste(editableTextState.contextMenuButtonItems),
        ],
      );
    }
    return NoteSelectionFormattingToolbar(
      editableTextState: editableTextState,
      corrections: _spellingContextMenuItems(selection),
      paragraphStyle: _activeParagraphStyle,
      boldActive: _formatActive(NoteFormat.bold),
      italicActive: _formatActive(NoteFormat.italic),
      bulletsActive: selectionHasLineStyle(
        _controller.value,
        NoteLineStyle.bullet,
      ),
      checklistActive: selectionHasLineStyle(
        _controller.value,
        NoteLineStyle.checklist,
      ),
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
      onCopyPlainText: () => unawaited(_copyPlainText(selection)),
    );
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
          icon: Icons.error_outline_rounded,
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
          icon: Icons.error_outline_rounded,
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
          icon: Icons.error_outline_rounded,
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
  /// selects the line terminator instead. Nothing can be done with such a
  /// selection — it holds no text to copy, format or replace — but it paints a
  /// full-width highlight across the empty line and opens the formatting
  /// toolbar over it.
  ///
  /// Collapsing to a caret is what every other editor leaves you with there.
  /// Only a selection that is *entirely* newlines is caught, so dragging
  /// across blank lines on the way to real text is untouched.
  ///
  /// Returns true when it took over, so the caller can leave the follow-up
  /// work to the change this triggers.
  bool _collapseLineTerminatorSelection(TextSelection selection) {
    if (!selection.isValid || selection.isCollapsed) return false;
    final text = _controller.text;
    if (selection.start < 0 || selection.end > text.length) return false;
    final selected = text.substring(selection.start, selection.end);
    if (selected.isEmpty || selected.replaceAll('\n', '').isNotEmpty) {
      return false;
    }
    // Re-enters this listener, where the now-collapsed selection falls
    // straight through the check above.
    _controller.selection = TextSelection.collapsed(offset: selection.start);
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
    final evaluation = widget.engine.evaluateDocumentWithSummary(
      _controller.text,
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
    );
    // Only a note that actually holds a picture gives up the forced row.
    final strut = EditorMetrics.strut(
      widget.writingFont,
      allowTallRows: _attachments.isNotEmpty && widget.images != null,
    );
    final textScaler = MediaQuery.textScalerOf(context);

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
                _controller.setImageSpansDuringLayout(
                  _buildAttachmentSpans(
                    math.max(1, contentWidth - noteAttachmentColumnSlack),
                    constraints.maxHeight,
                  ),
                );

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
                  layoutKey: (widget.writingFont, _formats),
                  placeholders: _controller.placeholderDimensions(),
                );

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
                                  _buildField(
                                    padding,
                                    textStyle,
                                    strut,
                                    trailingGap,
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
              typingNames: widget.typingNames,
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
              onRecordVoicePressed: widget.readOnly
                  ? null
                  : widget.onRecordVoice,
              voiceBusy: widget.voiceActionBusy,
              onChecklistPressed: _toggleChecklist,
              onIndentPressed: () => _indentList(outdent: false),
              onOutdentPressed: () => _indentList(outdent: true),
              showIndentControls: selectionHasListLine(_controller.value),
              canIndent: canIndentSelection(_controller.value, outdent: false),
              canOutdent: canIndentSelection(_controller.value, outdent: true),
              boldActive: _formatActive(NoteFormat.bold),
              italicActive: _formatActive(NoteFormat.italic),
              bulletsActive: selectionHasLineStyle(
                _controller.value,
                NoteLineStyle.bullet,
              ),
              checklistActive: selectionHasLineStyle(
                _controller.value,
                NoteLineStyle.checklist,
              ),
              paragraphStyle: _activeParagraphStyle,
            ),
        ],
      ),
    );

    return ImageDropTarget(
      enabled: !widget.readOnly && widget.images != null,
      onFiles: (files) => unawaited(insertFiles(files)),
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
                cursorHeight: EditorMetrics.cursorHeight(widget.writingFont),
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
                  const _ListContinuationFormatter(),
                  const _ListShorthandFormatter(),
                  // Last, so it sees whatever the others made of the edit: a
                  // continuation or a shorthand landing on a picture's line
                  // has to be moved off it too.
                  const _ImageLineFormatter(),
                ],
                contextMenuBuilder: (context, editableTextState) =>
                    ValueListenableBuilder<int>(
                      // Rebuilds the menu if a word's corrections arrive after
                      // it opened, rather than leaving it half-answered.
                      valueListenable: _correctionsArrived,
                      builder: (context, _, _) =>
                          _contextMenu(context, editableTextState),
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

Future<ImageBatch> _ingestImageFiles(List<XFile> files, BlobStore store) =>
    ingestFiles(files, store: store);

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
  });

  final Offset position;
  final Duration timeStamp;
  final bool wasPrimary;
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

class _ListContinuationFormatter extends TextInputFormatter {
  const _ListContinuationFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
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
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
      ),
    );
  }
}
