import 'dart:async';
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../calc/engine.dart';
import '../../calc/highlight.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/daily_separator.dart';
import 'highlighting_controller.dart';
import 'line_metrics.dart';
import 'note_footer.dart';
import 'results_gutter.dart';

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
    required this.engine,
    required this.highlighter,
    required this.gutterWidth,
    required this.onBodyChanged,
    required this.onGutterWidthChanged,
    required this.onGutterWidthReset,
    required this.onSettingsPressed,
    this.showDivider = true,
    this.showSettingsButton = true,
    this.autofocus = false,
    this.startAtEnd = false,
    this.ensureKeyboardVisible = false,
    this.lastUpdatedAt,
    this.dailySeparatorsEnabled = false,
    this.now,
  });

  final String noteId;
  final String initialBody;
  final CalcEngine engine;
  final Highlighter highlighter;
  final double gutterWidth;
  final ValueChanged<String> onBodyChanged;
  final ValueChanged<double> onGutterWidthChanged;
  final VoidCallback onGutterWidthReset;
  final VoidCallback onSettingsPressed;
  final bool showDivider;
  final bool showSettingsButton;
  final bool autofocus;
  final bool startAtEnd;
  final bool ensureKeyboardVisible;
  final DateTime? lastUpdatedAt;
  final bool dailySeparatorsEnabled;
  final DateTime Function()? now;

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

  static const List<String> _placeholderLines = [
    'Start typing…',
    '',
    'Try:  20% of 80',
    '      1,250 + 8%',
    '      10rs to usd',
    '      subtotal = 42',
    '      subtotal * 3',
    '',
    'Start with // to add a comment',
  ];

  late HighlightingController _controller;
  final ScrollController _scrollController = ScrollController();
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'note-editor:${widget.noteId}',
  );
  final LineMeasurer _measurer = LineMeasurer();
  late final _DailySeparatorFormatter _dailySeparatorFormatter;
  Timer? _keyboardRetryTimer;

  Map<int, LineResult> _results = const {};
  String _totalText = '0';
  late String _lastText;
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
    _controller = HighlightingController(
      highlighter: widget.highlighter,
      palette: KapyTheme.darkPalette,
      text: initialText,
    );
    _dailySeparatorFormatter = _DailySeparatorFormatter(
      enabled: widget.dailySeparatorsEnabled,
      lastUpdatedAt: widget.lastUpdatedAt ?? (widget.now ?? DateTime.now)(),
      now: widget.now ?? DateTime.now,
      pendingSeparatorLine: pendingSeparatorLine,
    );
    if (widget.startAtEnd) {
      _controller.selection = TextSelection.collapsed(
        offset: initialText.length,
      );
    }
    _lastText = initialText;
    _controller.addListener(_onTextChanged);
    _isEmpty = initialText.isEmpty;
    _evaluate();
    if (widget.autofocus && widget.startAtEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => focusAtEnd());
    }
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new engine arrives when exchange rates land; re-evaluate so currency
    // lines light up without the user touching anything.
    if (!identical(oldWidget.engine, widget.engine)) {
      _controller.highlighter = widget.highlighter;
      _evaluate();
    }
    _dailySeparatorFormatter
      ..enabled = widget.dailySeparatorsEnabled
      ..syncLastUpdatedAt(widget.lastUpdatedAt);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.palette = context.palette;
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _keyboardRetryTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void focus() {
    _focusNode.requestFocus();
    _scheduleKeyboardRetry();
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

  void _onTextChanged() {
    final text = _controller.text;
    // TextEditingController also notifies for selection, composing, palette,
    // and highlighter changes. Only user-visible text changes belong in the
    // note store, especially because the launch append position is transient.
    if (text == _lastText) return;
    _lastText = text;
    setState(() {
      _isEmpty = text.isEmpty;
      _evaluate();
    });
    widget.onBodyChanged(text);
  }

  void _evaluate() {
    final evaluation = widget.engine.evaluateDocumentWithSummary(
      _controller.text,
    );
    _results = evaluation.results;
    _totalText = evaluation.totalText;
  }

  void _dragGutter(double delta) =>
      widget.onGutterWidthChanged(widget.gutterWidth - delta);

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
    final textStyle = EditorMetrics.textStyle(palette.textPrimary);
    final textScaler = MediaQuery.textScalerOf(context);

    return Container(
      color: palette.editorBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dividerWidth = widget.showDivider
                    ? GutterDivider.width
                    : 0.0;
                final gutterWidth = widget.gutterWidth.clamp(
                  0.0,
                  (constraints.maxWidth - 160).clamp(0.0, 480.0),
                );
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
                  strut: EditorMetrics.strut,
                  textScaler: textScaler,
                );

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: textPaneWidth,
                      child: Stack(
                        children: [
                          if (_isEmpty)
                            _Placeholder(padding: padding, style: textStyle),
                          _buildField(padding, textStyle, trailingGap),
                        ],
                      ),
                    ),
                    if (widget.showDivider)
                      GutterDivider(
                        onDrag: _dragGutter,
                        onReset: widget.onGutterWidthReset,
                      ),
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
                );
              },
            ),
          ),
          NoteFooter(
            total: _totalText,
            onSettingsPressed: widget.onSettingsPressed,
            showSettingsButton: widget.showSettingsButton,
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    EdgeInsets padding,
    TextStyle textStyle,
    double trailingGap,
  ) {
    return Padding(
      padding: EdgeInsets.only(
        left: padding.left,
        right: trailingGap,
        top: padding.top,
        bottom: padding.bottom,
      ),
      child: _textField(textStyle),
    );
  }

  Widget _textField(TextStyle textStyle) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      scrollController: _scrollController,
      autofocus: widget.autofocus,
      expands: true,
      maxLines: null,
      minLines: null,
      style: textStyle,
      strutStyle: EditorMetrics.strut,
      cursorWidth: EditorMetrics.cursorWidth,
      cursorRadius: const Radius.circular(1),
      cursorColor: Theme.of(context).colorScheme.primary,
      // Uniform selection rectangles: without this, a line whose glyphs come
      // from a fallback font gets a differently sized highlight.
      selectionHeightStyle: BoxHeightStyle.strut,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      inputFormatters: [_dailySeparatorFormatter],
      textAlignVertical: TextAlignVertical.top,
      // This is a calculator surface, not prose: every helpful-guess input
      // feature would fight the user.
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      scrollPadding: const EdgeInsets.all(80),
      // No decoration padding: an InputDecorator positions its child by rules
      // of its own, and the gutter needs the text origin to be exactly the
      // padding it was told about.
      decoration: const InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        filled: false,
        hoverColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.padding, required this.style});

  final EdgeInsets padding;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Positioned.fill(
      child: IgnorePointer(
        child: Padding(
          padding: padding,
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              NoteEditorState._placeholderLines.join('\n'),
              style: style.copyWith(color: palette.textTertiary),
              strutStyle: EditorMetrics.strut,
            ),
          ),
        ),
      ),
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
    String? pendingSeparatorLine,
  }) : _lastUpdatedAt = lastUpdatedAt,
       _pendingSeparatorLine = pendingSeparatorLine;

  bool enabled;
  DateTime _lastUpdatedAt;
  String? _pendingSeparatorLine;
  final DateTime Function() now;

  void syncLastUpdatedAt(DateTime? value) {
    if (value != null && value.isAfter(_lastUpdatedAt)) {
      _lastUpdatedAt = value;
    }
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
        DailySeparator.isSameDay(previousEdit, editedAt)) {
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
        ? DailySeparator.append(oldValue.text, previousEdit)
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
