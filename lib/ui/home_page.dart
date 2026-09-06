import 'dart:async';

import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../core/desktop_integration.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/engine_provider.dart';
import '../data/layout_prefs.dart';
import '../data/local_store.dart';
import '../data/note.dart';
import '../data/note_format.dart';
import '../data/notes_store.dart';
import '../data/onboarding.dart';
import '../sync/account.dart';
import '../data/rates.dart';
import 'share_dialog.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import 'editor/note_editor.dart';
import 'empty_state.dart';
import 'kapy_header_mascot.dart';
import 'sidebar.dart';
import 'settings_dialog.dart';
import 'sidebar_swipe.dart';
import 'split_view.dart';
import 'toolbar.dart';

/// Width at which the two-pane desktop layout gives way to the compact editor
/// with a notes drawer. Mobile platforms always use the compact layout.
const double kTwoPaneBreakpoint = 720;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.notes,
    required this.engines,
    required this.rates,
    required this.prefs,
    required this.shortcuts,
    this.updates,
    this.desktopIntegration,
    this.account,
    required this.store,
    this.welcomeNoteId,
  });

  /// Kapy settles into sleep after a full minute without local interaction.
  static const kapyIdleDelay = Duration(minutes: 1);

  final NotesStore notes;
  final EngineProvider engines;
  final RatesRepository rates;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;
  final Account? account;
  final LocalStore store;

  /// The welcome note seeded by this launch, if this launch seeded one.
  final String? welcomeNoteId;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _selectionKey = 'selectedNote.v1';
  static final _totalCue = RegExp(r'\btotal\b', caseSensitive: false);

  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  final KapyHeaderController _kapyHeader = KapyHeaderController();
  final Set<String> _totalAnimatedFor = {};
  GlobalKey<NoteEditorState> _compactEditorKey = GlobalKey<NoteEditorState>();
  GlobalKey<NoteEditorState> _wideEditorKey = GlobalKey<NoteEditorState>();

  String? _selectedId;
  String _query = '';
  bool _initialNoteScheduled = false;
  bool _openSessionScheduled = false;
  bool _drawerContentReady = false;
  bool _drawerOpen = false;
  Timer? _kapyIdleTimer;

  /// Lets the compact layout close its own drawer, which is otherwise only
  /// reachable from a context below the Scaffold.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Everything the toolbar draws itself from: the pin's state comes from
  /// [LayoutPrefs], and the chord its tooltip names from [ShortcutPrefs].
  /// Listening to only the first left the tooltip quoting a shortcut the user
  /// had already changed.
  ///
  /// Merged once rather than per build, so the subscription is not torn down
  /// and rebuilt on every frame. Both outlive this page — the app root makes
  /// them before it makes a window — so neither is ever swapped underneath it.
  late final Listenable _toolbarSources = Listenable.merge([
    widget.prefs,
    widget.shortcuts,
    // The sidebar groups shared notes by space once the account is unlocked,
    // and that is a fact of the account, not of the notes.
    ?widget.account,
  ]);

  /// The welcome note while it is still exactly as it was written.
  ///
  /// Not persisted, and cleared the moment the reader types into it: from then
  /// on it is one of their notes and behaves like one.
  String? _untouchedWelcomeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _untouchedWelcomeId = widget.welcomeNoteId;
    _selectedId = widget.notes.lastEditedNote?.id;
    widget.notes.addListener(_onNotesChanged);
    // The system-wide new-note shortcut has already raised the window by the
    // time this runs; the note itself is this page's to make.
    widget.desktopIntegration?.onNewNoteRequested = _createNote;
    widget.desktopIntegration?.onOpenRequested = _beginOpenSession;
    _reconcileSelection();
    // Keep timers and mascot work behind the first editable frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _armKapyIdleTimer();
      _reactToSelectedTotal();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    widget.desktopIntegration?.onNewNoteRequested = null;
    widget.desktopIntegration?.onOpenRequested = null;
    _kapyIdleTimer?.cancel();
    _kapyHeader.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recordKapyActivity();
      _beginOpenSession();
    } else {
      _kapyIdleTimer?.cancel();
    }
  }

  void _beginOpenSession() {
    // A welcome note nobody has typed into yet is there to be read. Appending
    // a dated line to it and dropping the cursor underneath is the opposite of
    // that, and on a phone it would raise a keyboard over the half that
    // explains itself.
    if (_selectedId != null && _selectedId == _untouchedWelcomeId) return;
    if (!widget.prefs.readyToTypeOnOpen ||
        _drawerOpen ||
        _openSessionScheduled) {
      return;
    }
    _openSessionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openSessionScheduled = false;
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final editor = _usesCompactLayout
          ? _compactEditorKey.currentState
          : _wideEditorKey.currentState;
      editor?.beginAppendSession();
    });
  }

  void _onNotesChanged() {
    _reconcileSelection();
    _reactToSelectedTotal();
    if (mounted) setState(() {});
  }

  /// Keeps the selection pointing at a note that still exists.
  void _reconcileSelection() {
    if (widget.notes.isEmpty) {
      _setSelectedId(null);
      if (_usesCompactLayout) _scheduleInitialNote();
      return;
    }
    if (widget.notes.byId(_selectedId) != null) return;
    _setSelectedId(
      _usesCompactLayout
          ? widget.notes.lastEditedNote!.id
          : widget.notes.notes.first.id,
    );
  }

  /// Read from the window because selection is also reconciled outside build.
  bool get _usesCompactLayout {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio < kTwoPaneBreakpoint;
  }

  void _setSelectedId(String? id) {
    if (_selectedId != id) {
      _compactEditorKey = GlobalKey<NoteEditorState>();
      _wideEditorKey = GlobalKey<NoteEditorState>();
    }
    _selectedId = id;
  }

  void _scheduleInitialNote() {
    if (_initialNoteScheduled) return;
    _initialNoteScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialNoteScheduled = false;
      if (!mounted || !_usesCompactLayout || !widget.notes.isEmpty) return;
      _createNote();
    });
  }

  void _select(String id) {
    setState(() => _setSelectedId(id));
    widget.store.put(_selectionKey, id);
    _recordKapyActivity();
    _reactToSelectedTotal();
  }

  /// Walks the selection [delta] notes along the list the sidebar is showing,
  /// wrapping round at both ends.
  ///
  /// The visible list rather than every note, so a walk under an active search
  /// stays inside the results the reader is looking at. Selecting does not
  /// reorder anything — only editing moves a note to the top — so holding the
  /// key down passes each note exactly once.
  void _cycleNote(int delta) {
    final visible = _visibleNotes;
    if (visible.length < 2) return;
    final current = visible.indexWhere((note) => note.id == _selectedId);
    // Nothing selected, or a selection the search has filtered out: start at
    // whichever end the direction is coming from.
    final next = current < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : (current + delta) % visible.length;
    _select(visible[next].id);
    _focusSelectedEditorAtEnd();
  }

  void _createNote() {
    _recordKapyActivity();
    final note = widget.notes.create();
    setState(() {
      _query = '';
      _setSelectedId(note.id);
    });
    widget.store.put(_selectionKey, note.id);
    _focusSelectedEditorAtEnd();
  }

  void _deleteNote(String id) {
    _recordKapyActivity();
    _totalAnimatedFor.remove(id);
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    final index = widget.notes.indexOf(id);
    final deletingSelected = id == _selectedId;
    widget.notes.delete(id);
    if (!deletingSelected) return;

    final next = widget.notes.successorTo(index);
    setState(() => _setSelectedId(next));
    widget.store.put(_selectionKey, next);
    if (_usesCompactLayout && next == null) _scheduleInitialNote();
    _focusSelectedEditorAtEnd();
  }

  /// Whether opening [note] should place the cursor at its end and raise the
  /// keyboard.
  ///
  /// True of every note but an untouched welcome note, which is there to be
  /// read: jumping to the bottom of it and covering the rest with a keyboard
  /// would show a first-time reader the one part that says nothing.
  bool _readyToTypeIn(Note note) =>
      widget.prefs.readyToTypeOnOpen && note.id != _untouchedWelcomeId;

  /// Opens the welcome note again, from settings.
  ///
  /// Selected rather than focused, and shown from the top, exactly as a first
  /// launch shows it.
  void _openWelcomeNote() {
    _recordKapyActivity();
    final note = Onboarding(widget.store).openWelcomeNote(widget.notes);
    setState(() {
      _query = '';
      _setSelectedId(note.id);
      _untouchedWelcomeId = note.id;
    });
    widget.store.put(_selectionKey, note.id);
    // On a phone the settings sheet was opened from inside the notes drawer,
    // which would otherwise stay over the note it just opened.
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _updateDocument(String id, String body, List<NoteFormatRange> formats) {
    _recordKapyActivity();
    // Typed in, so it is theirs now. Assigned rather than set: the editor
    // holding the cursor is already mounted, and nothing on screen changes
    // until it is next built.
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    widget.notes.updateDocument(id, body, formats);
  }

  /// The pin's toggle, or null where there is no window to float.
  ///
  /// Desktop always, mobile never — and deliberately not conditioned on
  /// window width. A narrow desktop window still has a window; hiding the
  /// control there was the bug this replaced, and a rule stated once cannot
  /// drift between the two toolbars that read it.
  VoidCallback? get _pinToggle =>
      AppPlatform.isDesktop ? widget.prefs.toggleAlwaysOnTop : null;

  /// Null once the pin's shortcut is cleared, which drops the chord from the
  /// tooltip rather than leaving it promising a key that does nothing.
  String? get _pinShortcut => widget.shortcuts
      .bindingFor(ShortcutAction.toggleAlwaysOnTop)
      ?.displayLabel;

  void _recordKapyActivity() {
    if (_kapyHeader.needsWake) _kapyHeader.wake(hideAfter: true);
    _armKapyIdleTimer();
  }

  void _armKapyIdleTimer() {
    _kapyIdleTimer?.cancel();
    _kapyIdleTimer = Timer(HomePage.kapyIdleDelay, _kapyHeader.sleep);
  }

  void _reactToSelectedTotal() {
    final id = _selectedId;
    final note = widget.notes.byId(id);
    if (id == null || note == null) return;
    if (!_totalCue.hasMatch(note.body)) {
      _totalAnimatedFor.remove(id);
      return;
    }
    if (_totalAnimatedFor.add(id)) _kapyHeader.think();
  }

  /// Opens the share sheet for a note. Before the account is unlocked there
  /// is no key to share with, so settings opens instead, on the pane that
  /// explains what is missing.
  void _shareNote(String id) {
    _recordKapyActivity();
    final note = widget.notes.byId(id);
    final sharing = widget.account?.sharing;
    if (note == null) return;
    if (sharing == null) {
      _showSettings();
      return;
    }
    unawaited(showShareDialog(context, note: note, sharing: sharing));
  }

  void _showSettings() {
    unawaited(
      showSettings(
        context,
        account: widget.account,
        notes: widget.notes,
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        rates: widget.rates,
        updates: widget.updates,
        desktopIntegration: widget.desktopIntegration,
        onOpenWelcomeNote: _openWelcomeNote,
      ),
    );
  }

  void _focusSelectedEditorAtEnd() {
    // Not into a welcome note nobody has typed into — including on the way
    // out of the notes drawer, which is how settings is reached on a phone
    // and would otherwise answer "open the welcome note" with a keyboard over
    // the bottom half of it.
    if (_selectedId != null && _selectedId == _untouchedWelcomeId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final editor = _usesCompactLayout
          ? _compactEditorKey.currentState
          : _wideEditorKey.currentState;
      editor?.focusAtEnd();
    });
  }

  List<Note> get _visibleNotes => widget.notes.search(_query);

  @override
  Widget build(BuildContext context) {
    // Keep LayoutBuilder as the first render object: the app's whole-window
    // golden harness captures this boundary directly.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < kTwoPaneBreakpoint;
        final page = compact ? _buildCompact(context) : _buildWide(context);
        final content = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _recordKapyActivity(),
          child: page,
        );

        if (!AppPlatform.isDesktop) return content;
        return ListenableBuilder(
          listenable: widget.shortcuts,
          builder: (context, _) => _DesktopShortcuts(
            shortcuts: widget.shortcuts,
            onNewNote: _createNote,
            onFindNotes: () {
              if (!widget.prefs.sidebarVisible) widget.prefs.toggleSidebar();
              _searchFocus.requestFocus();
            },
            onNextNote: () => _cycleNote(1),
            onPreviousNote: () => _cycleNote(-1),
            onToggleSidebar: widget.prefs.toggleSidebar,
            onToggleResults: widget.prefs.toggleResults,
            onToggleAlwaysOnTop: AppPlatform.isDesktop
                ? widget.prefs.toggleAlwaysOnTop
                : null,
            onDeleteNote: _selectedId == null
                ? null
                : () => _deleteNote(_selectedId!),
            autofocus: _selectedId == null || !widget.prefs.readyToTypeOnOpen,
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final selected = widget.notes.byId(_selectedId);
    // A tablet reaches this layout too, and it has no Scaffold to resize
    // around the software keyboard. Desktop reports zero here.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    // The desktop layout is its own chrome rather than a Scaffold, but text
    // fields, menus and ink still need a Material ancestor.
    return Material(
      color: AppPlatform.isMacOS && !AppPlatform.isFlutterTest
          ? Colors.transparent
          : context.palette.editorBackground,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: ListenableBuilder(
          listenable: _toolbarSources,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoteToolbar(
                mascotController: _kapyHeader,
                sidebarVisible: widget.prefs.sidebarVisible,
                onToggleSidebar: widget.prefs.toggleSidebar,
                onCreate: _createNote,
                alwaysOnTop: widget.prefs.alwaysOnTop,
                onToggleAlwaysOnTop: _pinToggle,
                alwaysOnTopShortcut: _pinShortcut,
              ),
              Expanded(
                child: SidebarSwipe(
                  sidebarVisible: widget.prefs.sidebarVisible,
                  onToggle: widget.prefs.toggleSidebar,
                  child: SplitView(
                    sidebarVisible: widget.prefs.sidebarVisible,
                    sidebarWidth: widget.prefs.sidebarWidth,
                    minSidebarWidth: LayoutPrefs.minSidebarWidth,
                    maxSidebarWidth: LayoutPrefs.maxSidebarWidth,
                    onWidthChanged: (value) =>
                        widget.prefs.sidebarWidth = value,
                    onHide: widget.prefs.toggleSidebar,
                    sidebar: Sidebar(
                      notes: _visibleNotes,
                      selectedId: _selectedId,
                      query: _query,
                      displayTime: widget.prefs.displayTime,
                      searchFocusNode: _searchFocus,
                      onQueryChanged: (value) => setState(() => _query = value),
                      onSelect: _select,
                      onCreate: _createNote,
                      onDelete: _deleteNote,
                      onShare: widget.account == null ? null : _shareNote,
                      sharing: widget.account?.sharing,
                      onSettingsPressed: _showSettings,
                      updates: widget.updates,
                      showHeader: false,
                    ),
                    body: SafeArea(
                      top: false,
                      left: false,
                      right: false,
                      child: selected == null
                          ? EmptyState(onCreate: _createNote)
                          : _buildEditor(selected),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context) {
    final palette = context.palette;
    final selected = widget.notes.byId(_selectedId);
    final drawerWidth = (MediaQuery.sizeOf(context).width * 0.88).clamp(
      0.0,
      360.0,
    );
    // A third of the window, so "show me my notes" does not need aiming.
    final drawerEdgeDragWidth = MediaQuery.sizeOf(context).width / 3;
    final overlayStyle = Theme.of(context).brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: palette.editorBackground,
        // A drag rather than a free swipe, and only one that starts near the
        // left edge: anywhere else in a note, sideways dragging is how a
        // touchscreen selects text. Flutter's default strip is about twenty
        // pixels, which is a lot of precision to ask for.
        drawerEdgeDragWidth: drawerEdgeDragWidth,
        onDrawerChanged: (isOpen) {
          setState(() {
            _drawerOpen = isOpen;
            if (isOpen) _drawerContentReady = true;
          });
          if (!isOpen) _focusSelectedEditorAtEnd();
        },
        drawer: Drawer(
          width: drawerWidth,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(22),
              bottomRight: Radius.circular(22),
            ),
            side: BorderSide(color: palette.separator, width: 0.5),
          ),
          child: _drawerContentReady
              ? Builder(
                  builder: (drawerContext) => ListenableBuilder(
                    listenable: _toolbarSources,
                    builder: (context, _) => Sidebar(
                      notes: _visibleNotes,
                      selectedId: _selectedId,
                      query: _query,
                      displayTime: widget.prefs.displayTime,
                      searchFocusNode: _searchFocus,
                      onQueryChanged: (value) => setState(() => _query = value),
                      onSelect: (id) {
                        _select(id);
                        Navigator.of(drawerContext).pop();
                      },
                      onCreate: () {
                        _createNote();
                        Navigator.of(drawerContext).pop();
                      },
                      onDelete: _deleteNote,
                      onShare: widget.account == null ? null : _shareNote,
                      sharing: widget.account?.sharing,
                      onSettingsPressed: _showSettings,
                      updates: widget.updates,
                    ),
                  ),
                )
              : ColoredBox(color: palette.sidebarBackground),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Listening, because the pin it carries draws itself from the
            // preference: without this the icon kept the old state until
            // something unrelated happened to rebuild the page, while the
            // window itself had already gone on top. The wide layout has
            // covered its own toolbar this way all along.
            //
            // The builder's context is below the Scaffold, which is the other
            // thing this has to be — [Scaffold.of] cannot see it from the
            // context that built the Scaffold.
            ListenableBuilder(
              listenable: _toolbarSources,
              builder: (scaffoldContext, _) => NoteToolbar(
                mascotController: _kapyHeader,
                sidebarVisible: false,
                showActions: !_drawerOpen,
                onToggleSidebar: () {
                  FocusScope.of(scaffoldContext).unfocus();
                  Scaffold.of(scaffoldContext).openDrawer();
                },
                onCreate: _createNote,
                alwaysOnTop: widget.prefs.alwaysOnTop,
                onToggleAlwaysOnTop: _pinToggle,
                alwaysOnTopShortcut: _pinShortcut,
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: selected == null
                    ? EmptyState(onCreate: _createNote)
                    : _buildCompactEditor(selected),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactEditor(Note note) {
    // Narrow desktop windows still have a precise pointer and enough room for
    // the results column to be resized. Phone-sized test surfaces preserve the
    // fixed mobile gutter, matching real iOS and Android builds. Wide phones
    // get enough room for a grouped currency plus its three-letter code.
    final compactWidth = MediaQuery.sizeOf(context).width;
    final desktopResultsDivider =
        AppPlatform.isDesktop &&
        compactWidth >= LayoutPrefs.minimumWindowSize.width;
    final mobileGutterWidth = compactWidth >= 400 ? 152.0 : 132.0;
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.prefs,
        builder: (context, _) => NoteEditor(
          key: _compactEditorKey,
          noteId: note.id,
          initialBody: note.body,
          initialFormats: note.formats,
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          gutterWidth: desktopResultsDivider
              ? widget.prefs.gutterWidth
              : mobileGutterWidth,
          resultsVisible: desktopResultsDivider
              ? widget.prefs.resultsVisible
              : true,
          showDivider: desktopResultsDivider,
          autofocus: _readyToTypeIn(note),
          startAtEnd: _readyToTypeIn(note),
          ensureKeyboardVisible:
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          shortcuts: widget.shortcuts,
          onDocumentChanged: (body, formats) =>
              _updateDocument(note.id, body, formats),
          onGutterWidthChanged: desktopResultsDivider
              ? (value) => widget.prefs.gutterWidth = value
              : (_) {},
          onResultsVisibilityChanged: desktopResultsDivider
              ? (value) => widget.prefs.resultsVisible = value
              : (_) {},
          onGutterWidthReset: desktopResultsDivider
              ? widget.prefs.resetGutterWidth
              : () {},
          onSettingsPressed: _showSettings,
        ),
      ),
    );
  }

  Widget _buildEditor(Note note) {
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.prefs,
        builder: (context, _) => NoteEditor(
          // Remounting on note change keeps one note's editing state from
          // leaking into the next.
          key: _wideEditorKey,
          noteId: note.id,
          initialBody: note.body,
          initialFormats: note.formats,
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          gutterWidth: widget.prefs.gutterWidth,
          resultsVisible: widget.prefs.resultsVisible,
          autofocus: _readyToTypeIn(note),
          startAtEnd: _readyToTypeIn(note),
          ensureKeyboardVisible:
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          shortcuts: widget.shortcuts,
          onDocumentChanged: (body, formats) =>
              _updateDocument(note.id, body, formats),
          onGutterWidthChanged: (value) => widget.prefs.gutterWidth = value,
          onResultsVisibilityChanged: (value) =>
              widget.prefs.resultsVisible = value,
          onGutterWidthReset: widget.prefs.resetGutterWidth,
          onSettingsPressed: _showSettings,
          hideEmptyResults: AppPlatform.isMobile,
          showSettingsButton: !widget.prefs.sidebarVisible,
        ),
      ),
    );
  }
}

/// Keyboard shortcuts that a desktop user expects to just work.
class _DesktopShortcuts extends StatelessWidget {
  const _DesktopShortcuts({
    required this.child,
    required this.onNewNote,
    required this.onFindNotes,
    required this.onNextNote,
    required this.onPreviousNote,
    required this.onToggleSidebar,
    required this.onToggleResults,
    required this.onToggleAlwaysOnTop,
    required this.onDeleteNote,
    required this.shortcuts,
    required this.autofocus,
  });

  final Widget child;
  final VoidCallback onNewNote;
  final VoidCallback onFindNotes;
  final VoidCallback onNextNote;
  final VoidCallback onPreviousNote;
  final VoidCallback onToggleSidebar;
  final VoidCallback onToggleResults;
  final VoidCallback? onToggleAlwaysOnTop;
  final VoidCallback? onDeleteNote;
  final ShortcutPrefs shortcuts;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    // A cleared shortcut leaves no entry behind: the action keeps whatever
    // button it has, and the keyboard simply says nothing about it.
    return CallbackShortcuts(
      bindings: {
        ?shortcuts.bindingFor(ShortcutAction.newNote)?.activator: onNewNote,
        ?shortcuts.bindingFor(ShortcutAction.findNotes)?.activator: onFindNotes,
        ?shortcuts.bindingFor(ShortcutAction.nextNote)?.activator: onNextNote,
        ?shortcuts.bindingFor(ShortcutAction.previousNote)?.activator:
            onPreviousNote,
        ?shortcuts.bindingFor(ShortcutAction.toggleSidebar)?.activator:
            onToggleSidebar,
        ?shortcuts.bindingFor(ShortcutAction.toggleResults)?.activator:
            onToggleResults,
        ?shortcuts.bindingFor(ShortcutAction.toggleAlwaysOnTop)?.activator:
            ?onToggleAlwaysOnTop,
        ?shortcuts.bindingFor(ShortcutAction.deleteNote)?.activator:
            ?onDeleteNote,
      },
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}
