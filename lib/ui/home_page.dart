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
import '../sync/account.dart';
import '../data/rates.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import 'editor/note_editor.dart';
import 'empty_state.dart';
import 'sidebar.dart';
import 'settings_dialog.dart';
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
  });

  final NotesStore notes;
  final EngineProvider engines;
  final RatesRepository rates;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;
  final Account? account;
  final LocalStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _selectionKey = 'selectedNote.v1';

  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  GlobalKey<NoteEditorState> _compactEditorKey = GlobalKey<NoteEditorState>();
  GlobalKey<NoteEditorState> _wideEditorKey = GlobalKey<NoteEditorState>();

  String? _selectedId;
  String _query = '';
  bool _initialNoteScheduled = false;
  bool _openSessionScheduled = false;
  bool _drawerContentReady = false;
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedId = widget.notes.lastEditedNote?.id;
    widget.notes.addListener(_onNotesChanged);
    // The system-wide new-note shortcut has already raised the window by the
    // time this runs; the note itself is this page's to make.
    widget.desktopIntegration?.onNewNoteRequested = _createNote;
    widget.desktopIntegration?.onOpenRequested = _beginOpenSession;
    _reconcileSelection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    widget.desktopIntegration?.onNewNoteRequested = null;
    widget.desktopIntegration?.onOpenRequested = null;
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _beginOpenSession();
  }

  void _beginOpenSession() {
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
  }

  void _createNote() {
    final note = widget.notes.create();
    setState(() {
      _query = '';
      _setSelectedId(note.id);
    });
    widget.store.put(_selectionKey, note.id);
    _focusSelectedEditorAtEnd();
  }

  void _deleteNote(String id) {
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

  void _updateDocument(String id, String body, List<NoteFormatRange> formats) =>
      widget.notes.updateDocument(id, body, formats);

  void _showSettings() {
    showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        account: widget.account,
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        rates: widget.rates,
        updates: widget.updates,
        desktopIntegration: widget.desktopIntegration,
      ),
    );
  }

  void _focusSelectedEditorAtEnd() {
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < kTwoPaneBreakpoint;
        final content = compact ? _buildCompact(context) : _buildWide(context);

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
            onToggleSidebar: widget.prefs.toggleSidebar,
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
          listenable: widget.prefs,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoteToolbar(
                sidebarVisible: widget.prefs.sidebarVisible,
                onToggleSidebar: widget.prefs.toggleSidebar,
                onCreate: _createNote,
                alwaysOnTop: widget.prefs.alwaysOnTop,
                // Null on anything without a window to float, which keeps the
                // pin off the toolbar rather than showing a dead control.
                onToggleAlwaysOnTop: AppPlatform.isDesktop
                    ? widget.prefs.toggleAlwaysOnTop
                    : null,
                alwaysOnTopShortcut: widget.shortcuts
                    .bindingFor(ShortcutAction.toggleAlwaysOnTop)
                    .displayLabel,
              ),
              Expanded(
                child: SplitView(
                  sidebarVisible: widget.prefs.sidebarVisible,
                  sidebarWidth: widget.prefs.sidebarWidth,
                  minSidebarWidth: LayoutPrefs.minSidebarWidth,
                  maxSidebarWidth: LayoutPrefs.maxSidebarWidth,
                  onWidthChanged: (value) => widget.prefs.sidebarWidth = value,
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
    final overlayStyle = Theme.of(context).brightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: palette.editorBackground,
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
                    listenable: widget.prefs,
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
            Builder(
              builder: (scaffoldContext) => NoteToolbar(
                sidebarVisible: false,
                showActions: !_drawerOpen,
                onToggleSidebar: () {
                  FocusScope.of(scaffoldContext).unfocus();
                  Scaffold.of(scaffoldContext).openDrawer();
                },
                onCreate: _createNote,
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
          autofocus: widget.prefs.readyToTypeOnOpen,
          startAtEnd: widget.prefs.readyToTypeOnOpen,
          ensureKeyboardVisible:
              widget.prefs.readyToTypeOnOpen &&
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
          autofocus: widget.prefs.readyToTypeOnOpen,
          startAtEnd: widget.prefs.readyToTypeOnOpen,
          ensureKeyboardVisible:
              widget.prefs.readyToTypeOnOpen &&
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
    required this.onToggleSidebar,
    required this.onToggleAlwaysOnTop,
    required this.onDeleteNote,
    required this.shortcuts,
    required this.autofocus,
  });

  final Widget child;
  final VoidCallback onNewNote;
  final VoidCallback onFindNotes;
  final VoidCallback onToggleSidebar;
  final VoidCallback? onToggleAlwaysOnTop;
  final VoidCallback? onDeleteNote;
  final ShortcutPrefs shortcuts;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        shortcuts.bindingFor(ShortcutAction.newNote).activator: onNewNote,
        shortcuts.bindingFor(ShortcutAction.findNotes).activator: onFindNotes,
        shortcuts.bindingFor(ShortcutAction.toggleSidebar).activator:
            onToggleSidebar,
        shortcuts.bindingFor(ShortcutAction.toggleAlwaysOnTop).activator:
            ?onToggleAlwaysOnTop,
        shortcuts.bindingFor(ShortcutAction.deleteNote).activator:
            ?onDeleteNote,
      },
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}
