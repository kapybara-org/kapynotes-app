import 'dart:async';
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kLongPressTimeout, kPrimaryButton, kTouchSlop;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../calc/engine.dart';
import '../../calc/highlight.dart';
import '../../core/editor_font.dart';
import '../../core/note_link.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/daily_separator.dart';
import '../../data/note_format.dart';
import '../../data/shortcut_prefs.dart';
import '../notebook_paper.dart';
import 'editor_formatting.dart';
import 'highlighting_controller.dart';
import 'line_metrics.dart';
import 'link_popover.dart';
import 'note_footer.dart';
import 'results_gutter.dart';
import 'selection_formatting_toolbar.dart';

typedef NoteDocumentChanged =
    void Function(String body, List<NoteFormatRange> formats);

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
    this.showDivider = true,
    this.hideEmptyResults = false,
    this.showSettingsButton = true,
    this.autofocus = false,
    this.startAtEnd = false,
    this.ensureKeyboardVisible = false,
    this.lastUpdatedAt,
    this.dailySeparatorsEnabled = false,
    this.now,
    this.displayTime,
  });

  final String noteId;
  final String initialBody;
  final List<NoteFormatRange> initialFormats;
  final CalcEngine engine;
  final Highlighter highlighter;
  final double gutterWidth;
  final bool resultsVisible;
  final NoteDocumentChanged onDocumentChanged;
  final ValueChanged<double> onGutterWidthChanged;
  final ValueChanged<bool> onResultsVisibilityChanged;
  final VoidCallback onGutterWidthReset;
  final VoidCallback onSettingsPressed;
  final WritingFont writingFont;
  final ShortcutPrefs shortcuts;
  final bool showDivider;
  final bool hideEmptyResults;
  final bool showSettingsButton;
  final bool autofocus;
  final bool startAtEnd;
  final bool ensureKeyboardVisible;
  final DateTime? lastUpdatedAt;
  final bool dailySeparatorsEnabled;
  final DateTime Function()? now;
  final DateTime Function(DateTime)? displayTime;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
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

  Map<int, LineResult> _results = const {};
  String? _totalText;
  late TextEditingValue _lastValue;
  late List<NoteFormatRange> _formats;
  final Map<NoteFormat, bool> _typingOverrides = {};
  NoteParagraphStyle? _paragraphOverride;
  final Map<int, _PointerDownDetails> _pointerDownDetails = {};
  Set<NoteFormat>? _nextInsertedFormats;
  bool _isEmpty = true;

  @override
  void initState() {
    super.initState();
    final initialText = widget.startAtEnd
        ? DailySeparator.prepareForAppend(widget.initialBody)
        : widget.initialBody;
    final pendingSeparatorLine = widget.startAtEnd
        ? DailySeparator.trailingEmptySectionLine(widget.initialBody)
        : null;
    _formats = normalizeNoteFormats(widget.initialFormats, initialText.length);
    _controller = HighlightingController(
      highlighter: widget.highlighter,
      palette: KapyTheme.darkPalette,
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
    if (widget.startAtEnd) {
      _controller.selection = TextSelection.collapsed(
        offset: initialText.length,
      );
    }
    _lastValue = _controller.value;
    _controller.addListener(_onControllerChanged);
    // Anchored to a rect that scrolling invalidates, so it goes rather than
    // drifts away from the link it points at.
    _scrollController.addListener(LinkPopover.hide);
    widget.shortcuts.addListener(_onShortcutsChanged);
    _isEmpty = initialText.isEmpty;
    _evaluate();
    if (widget.autofocus && widget.startAtEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => focusAtEnd());
    }
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.shortcuts, widget.shortcuts)) {
      oldWidget.shortcuts.removeListener(_onShortcutsChanged);
      widget.shortcuts.addListener(_onShortcutsChanged);
    }
    // A new engine arrives when exchange rates land; re-evaluate so currency
    // lines light up without the user touching anything.
    if (!identical(oldWidget.engine, widget.engine)) {
      _controller.highlighter = widget.highlighter;
      _evaluate();
    }
    if (widget.initialBody == _controller.text &&
        !listEquals(widget.initialFormats, _formats)) {
      _formats = normalizeNoteFormats(
        widget.initialFormats,
        _controller.text.length,
      );
      _controller.formats = _formats;
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
  }

  @override
  void dispose() {
    LinkPopover.hide();
    _controller.removeListener(_onControllerChanged);
    _scrollController.removeListener(LinkPopover.hide);
    widget.shortcuts.removeListener(_onShortcutsChanged);
    _keyboardRetryTimer?.cancel();
    _selectionToolbarTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onShortcutsChanged() {
    if (mounted) setState(() {});
  }

  void focus() {
    _focusNode.requestFocus();
    _scheduleKeyboardRetry();
  }

  /// Opens a fresh append position without writing empty lines to the note.
  /// The prepared spacing becomes durable only if the user actually types.
  void beginAppendSession() {
    if (!mounted) return;
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

  /// Places the caret after the note's final character and brings it on screen.
  void focusAtEnd() {
    if (!mounted) return;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _focusNode.requestFocus();
    _scheduleKeyboardRetry();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _scheduleKeyboardRetry() {
    _keyboardRetryTimer?.cancel();
    if (!widget.ensureKeyboardVisible) return;
    // Try as soon as the editable connection exists, then probe quickly while
    // Android is still promoting FlutterView to the served input view.
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    _scheduleKeyboardRetryAt(0);
  }

  void _scheduleKeyboardRetryAt(int index) {
    if (index >= _keyboardRetryDelays.length) return;
    _keyboardRetryTimer = Timer(_keyboardRetryDelays[index], () {
      if (!mounted ||
          !_focusNode.hasFocus ||
          MediaQuery.viewInsetsOf(context).bottom > 0) {
        return;
      }
      // A rejected Android request has no Dart acknowledgement. Backoff keeps
      // the recovery window broad without repeatedly waking an IME that has
      // already started its animation.
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
      _scheduleKeyboardRetryAt(index + 1);
    });
  }

  void _onControllerChanged() {
    final value = _controller.value;
    final previous = _lastValue;
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

    final insertedText = insertedTextForChange(previous.text, value.text);
    final forcedInsertedFormats = _nextInsertedFormats;
    _nextInsertedFormats = null;
    final insertedFormats = forcedInsertedFormats ?? <NoteFormat>{};
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
    _controller.formats = updatedFormats;
    setState(() {
      _isEmpty = value.text.isEmpty;
      _evaluate();
    });
    widget.onDocumentChanged(value.text, updatedFormats);
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
    _applyParagraphStyle(nextParagraphStyle(_activeParagraphStyle));
  }

  void _applyParagraphStyle(NoteParagraphStyle style) {
    final selection = _controller.selection;
    if (!selection.isValid) return;
    _paragraphOverride = selection.isCollapsed ? style : null;
    _commitFormats(
      applyParagraphStyle(_formats, _controller.text, selection, style),
    );
    _focusNode.requestFocus();
  }

  void _toggleInlineFormat(NoteFormat format) {
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

  void _commitFormats(List<NoteFormatRange> formats) {
    _formats = formats;
    _controller.formats = formats;
    setState(() {});
    widget.onDocumentChanged(_controller.text, formats);
  }

  void _toggleBullets() {
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
    ContextMenuController.removeAny();
    _nextInsertedFormats = const {};
    _controller.value = indentSelection(_controller.value, outdent: outdent);
    _focusNode.requestFocus();
  }

  /// Any key at all dismisses the link panel first. Escape is the one people
  /// reach for, but a panel that outlives the caret it was raised next to is
  /// wrong whichever key moved it.
  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) LinkPopover.hide();
    return _handleTabIndent(node, event);
  }

  /// Tab nests the current item, Shift+Tab lifts it out.
  ///
  /// Only claimed when the caret is actually on a list line. Everywhere else
  /// Tab is left to move focus, which is the only way to leave the editor from
  /// the keyboard.
  KeyEventResult _handleTabIndent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (!_focusNode.hasFocus || !selectionHasListLine(_controller.value)) {
      return KeyEventResult.ignored;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
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
    _pointerDownDetails[event.pointer] = _PointerDownDetails(
      position: event.position,
      timeStamp: event.timeStamp,
      wasPrimary: event.buttons & kPrimaryButton != 0,
    );
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _pointerDownDetails.remove(event.pointer);
  }

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

    final offset = editable.getPositionForPoint(event.position).offset;
    final checkboxStart = checkboxLineStartAt(_controller.text, offset);
    if (checkboxStart >= 0) {
      final boxes = editable.getBoxesForSelection(
        TextSelection(
          baseOffset: checkboxStart,
          extentOffset: checkboxStart + 1,
        ),
      );
      if (boxes.isNotEmpty) {
        final box = boxes.first;
        final origin = editable.localToGlobal(Offset(box.left, box.top));
        final checkboxRect =
            origin & Size(box.right - box.left, box.bottom - box.top);
        if (checkboxRect.inflate(6).contains(event.position)) {
          _nextInsertedFormats = const {};
          _controller.value = toggleCheckboxAt(
            _controller.value,
            checkboxStart,
          );
          _focusNode.requestFocus();
          return;
        }
      }
    }

    final hit = _linkAtPoint(editable, event.position, offset);
    if (hit == null) return;
    // The shortcut stays: someone who already knows it should not be made to
    // read a panel first.
    if (_isDirectOpenShortcut()) {
      unawaited(_openLink(hit.link));
      return;
    }
    _showLinkPopover(hit);
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final base = AppPlatform.isMobile
        ? EditorMetrics.mobilePadding
        : EditorMetrics.padding;
    // Keep the last line clear of the home indicator. Folding the inset into
    // the shared padding keeps the text and its results in step; insetting
    // only one of them would pull them apart.
    final padding = base.copyWith(
      bottom: base.bottom + MediaQuery.paddingOf(context).bottom,
    );
    final textStyle = EditorMetrics.textStyle(
      palette.textPrimary,
      widget.writingFont,
    );
    final strut = EditorMetrics.strut(widget.writingFont);
    final textScaler = MediaQuery.textScalerOf(context);

    return Container(
      color: palette.editorBackground,
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
                              child: Stack(
                                children: [
                                  if (_isEmpty)
                                    _Placeholder(
                                      padding: padding,
                                      style: textStyle,
                                      strut: strut,
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
          NoteFooter(
            total: _totalText,
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
            onSettingsPressed: widget.onSettingsPressed,
            onParagraphStylePressed: _cycleParagraphStyle,
            onBoldPressed: () => _toggleInlineFormat(NoteFormat.bold),
            onItalicPressed: () => _toggleInlineFormat(NoteFormat.italic),
            onBulletsPressed: _toggleBullets,
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
            showSettingsButton: widget.showSettingsButton,
          ),
        ],
      ),
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
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: CallbackShortcuts(
        bindings: {
          widget.shortcuts.bindingFor(ShortcutAction.cycleTextStyle).activator:
              _cycleParagraphStyle,
          widget.shortcuts
              .bindingFor(ShortcutAction.formatBold)
              .activator: () =>
              _toggleInlineFormat(NoteFormat.bold),
          widget.shortcuts
              .bindingFor(ShortcutAction.formatItalic)
              .activator: () =>
              _toggleInlineFormat(NoteFormat.italic),
          widget.shortcuts.bindingFor(ShortcutAction.formatBullets).activator:
              _toggleBullets,
          widget.shortcuts.bindingFor(ShortcutAction.formatChecklist).activator:
              _toggleChecklist,
        },
        child: TextField(
          key: _textFieldKey,
          controller: _controller,
          focusNode: _focusNode,
          scrollController: _scrollController,
          autofocus: widget.autofocus,
          expands: true,
          maxLines: null,
          minLines: null,
          style: textStyle,
          strutStyle: strut,
          cursorWidth: EditorMetrics.cursorWidth,
          cursorRadius: const Radius.circular(1),
          cursorColor: Theme.of(context).colorScheme.primary,
          // Uniform selection rectangles: without this, a line whose glyphs
          // come from a fallback font gets a differently sized highlight.
          selectionHeightStyle: BoxHeightStyle.strut,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          inputFormatters: [
            _dailySeparatorFormatter,
            const _ListContinuationFormatter(),
          ],
          contextMenuBuilder: (context, editableTextState) {
            final selection = editableTextState.textEditingValue.selection;
            final link = _linkForSelection(selection);
            final linkItems = _linkContextMenuItems(link);
            if (selection.isCollapsed) {
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: [
                  ...linkItems,
                  ...editableTextState.contextMenuButtonItems,
                ],
              );
            }
            return NoteSelectionFormattingToolbar(
              editableTextState: editableTextState,
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
              onOpenLink: link == null
                  ? null
                  : () => unawaited(_openLink(link)),
              onCopyLink: link == null
                  ? null
                  : () => unawaited(_copyLink(link)),
            );
          },
          textAlignVertical: TextAlignVertical.top,
          // This is a calculator surface, not prose: every helpful-guess input
          // feature would fight the user.
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
    );
  }
}

/// A link and where it was drawn, paired so the panel can be put against it.
class _LinkHit {
  const _LinkHit({required this.link, required this.rect});

  final NoteLink link;
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
  });

  final EdgeInsets padding;
  final TextStyle style;
  final StrutStyle strut;

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
                      primaryColor: palette.textTertiary,
                    ),
                  ),
                  TextSpan(
                    text: 'Notes and quick calculations\n\n',
                    style: paragraphTextStyle(
                      style,
                      NoteParagraphStyle.subtitle,
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
    for (final candidate in [bulletPrefix, uncheckedPrefix, checkedPrefix]) {
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
        return TextEditingValue(
          text: oldValue.text.replaceRange(
            prefixStart - removed,
            prefixStart,
            '',
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
    // nested list would jump back to the margin on every Enter.
    final continuation =
        indent + (prefix == bulletPrefix ? bulletPrefix : uncheckedPrefix);
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
