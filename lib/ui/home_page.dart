import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/desktop_integration.dart';
import '../core/theme.dart';
import '../core/window_chrome.dart';
import '../data/engine_provider.dart';
import '../data/layout_prefs.dart';
import '../data/local_store.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/shortcut_prefs.dart';
import 'app_logo.dart';
import 'editor/note_editor.dart';
import 'empty_state.dart';
import 'glass_surface.dart';
import 'sidebar.dart';
import 'settings_dialog.dart';
import 'split_view.dart';
import 'toolbar.dart';
import 'window_drag_area.dart';

/// Width at which the two-pane desktop layout gives way to the compact editor
/// with a notes drawer. Mobile platforms always use the compact layout.
const double kTwoPaneBreakpoint = 720;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.notes,
    required this.engines,
    required this.prefs,
    required this.shortcuts,
    this.desktopIntegration,
    required this.store,
  });

  final NotesStore notes;
  final EngineProvider engines;
  final LayoutPrefs prefs;
  final ShortcutPrefs shortcuts;
  final DesktopIntegration? desktopIntegration;
  final LocalStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _selectionKey = 'selectedNote.v1';

  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  GlobalKey<NoteEditorState> _compactEditorKey = GlobalKey<NoteEditorState>();

  String? _selectedId;
  String _query = '';
  bool _initialNoteScheduled = false;
  bool _drawerContentReady = false;
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedId = widget.notes.lastEditedNote?.id;
    widget.notes.addListener(_onNotesChanged);
    _reconcileSelection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed ||
        !_usesCompactLayout ||
        _drawerOpen) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      _compactEditorKey.currentState?.focus();
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
    if (AppPlatform.isMobile) return true;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio < kTwoPaneBreakpoint;
  }

  void _setSelectedId(String? id) {
    if (_selectedId != id) {
      _compactEditorKey = GlobalKey<NoteEditorState>();
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
    if (_usesCompactLayout) _focusCompactEditorAtEnd();
  }

  void _deleteNote(String id) {
    final index = widget.notes.indexOf(id);
    final deletingSelected = id == _selectedId;
    widget.notes.delete(id);
    if (!deletingSelected) return;

    final next = widget.notes.successorTo(index);
    setState(() => _setSelectedId(next));
    widget.store.put(_selectionKey, next);
    if (_usesCompactLayout) {
      if (next == null) _scheduleInitialNote();
      _focusCompactEditorAtEnd();
    }
  }

  void _updateBody(String id, String body) => widget.notes.updateBody(id, body);

  void _showSettings() {
    showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        desktopIntegration: widget.desktopIntegration,
      ),
    );
  }

  void _focusCompactEditorAtEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _compactEditorKey.currentState?.focusAtEnd();
    });
  }

  List<Note> get _visibleNotes => widget.notes.search(_query);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            AppPlatform.isMobile || constraints.maxWidth < kTwoPaneBreakpoint;
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
            onDeleteNote: _selectedId == null
                ? null
                : () => _deleteNote(_selectedId!),
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final selected = widget.notes.byId(_selectedId);

    // The desktop layout is its own chrome rather than a Scaffold, but text
    // fields, menus and ink still need a Material ancestor.
    return Material(
      color: AppPlatform.isMacOS && !AppPlatform.isFlutterTest
          ? Colors.transparent
          : context.palette.editorBackground,
      child: ListenableBuilder(
        listenable: widget.prefs,
        builder: (context, _) => SplitView(
          sidebarVisible: widget.prefs.sidebarVisible,
          sidebarWidth: widget.prefs.sidebarWidth,
          minSidebarWidth: LayoutPrefs.minSidebarWidth,
          maxSidebarWidth: LayoutPrefs.maxSidebarWidth,
          onWidthChanged: (value) => widget.prefs.sidebarWidth = value,
          sidebar: Sidebar(
            notes: _visibleNotes,
            selectedId: _selectedId,
            query: _query,
            searchFocusNode: _searchFocus,
            onQueryChanged: (value) => setState(() => _query = value),
            onSelect: _select,
            onCreate: _createNote,
            onDelete: _deleteNote,
            onSettingsPressed: _showSettings,
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NoteToolbar(
                title: selected?.title ?? AppWordmark.name,
                sidebarVisible: widget.prefs.sidebarVisible,
                onToggleSidebar: widget.prefs.toggleSidebar,
                onCreate: _createNote,
                onDelete: selected == null
                    ? null
                    : () => _deleteNote(selected.id),
                // With the sidebar collapsed the toolbar runs to the window's
                // left edge, straight under the macOS traffic lights.
                leadingInset: WindowChrome.leadingInset(
                  atWindowLeftEdge: !widget.prefs.sidebarVisible,
                ),
              ),
              Expanded(
                child: selected == null
                    ? EmptyState(onCreate: _createNote)
                    : _buildEditor(selected),
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
    final leadingInset = WindowChrome.leadingInset(
      atWindowLeftEdge: AppPlatform.isDesktop,
    );

    return Scaffold(
      backgroundColor: palette.editorBackground,
      onDrawerChanged: (isOpen) {
        _drawerOpen = isOpen;
        if (isOpen && !_drawerContentReady) {
          setState(() => _drawerContentReady = true);
        }
        if (!isOpen) _focusCompactEditorAtEnd();
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
                builder: (drawerContext) => Sidebar(
                  notes: _visibleNotes,
                  selectedId: _selectedId,
                  query: _query,
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
                ),
              )
            : ColoredBox(color: palette.sidebarBackground),
      ),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: GlassSurface(
          color: palette.surfaceBackground.withValues(alpha: 0.74),
          blur: 28,
          child: const SizedBox.expand(),
        ),
        titleSpacing: 0,
        leadingWidth: 48 + leadingInset,
        leading: Builder(
          builder: (scaffoldContext) => Padding(
            padding: EdgeInsets.only(left: leadingInset),
            child: IconButton(
              onPressed: () {
                FocusScope.of(scaffoldContext).unfocus();
                Scaffold.of(scaffoldContext).openDrawer();
              },
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Show notes',
            ),
          ),
        ),
        title: WindowDragArea(
          child: SizedBox(
            height: kToolbarHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                selected?.title ?? AppWordmark.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _createNote,
            icon: const Icon(Icons.add_rounded, size: 19),
            tooltip: 'New note',
          ),
          if (selected != null)
            NoteActionsMenu(onDelete: () => _deleteNote(selected.id)),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(height: 0.5, color: palette.separator),
        ),
      ),
      body: SafeArea(
        top: false,
        child: selected == null
            ? EmptyState(onCreate: _createNote)
            : _buildCompactEditor(selected),
      ),
    );
  }

  Widget _buildCompactEditor(Note note) {
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.prefs,
        builder: (context, _) => NoteEditor(
          key: _compactEditorKey,
          noteId: note.id,
          initialBody: note.body,
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          // A phone has no room for a draggable column; a fixed, narrow gutter
          // keeps results visible without crowding the text.
          gutterWidth: 132,
          showDivider: false,
          autofocus: true,
          startAtEnd: true,
          ensureKeyboardVisible:
              AppPlatform.isMobile || AppPlatform.isFlutterTest,
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          onBodyChanged: (body) => _updateBody(note.id, body),
          onGutterWidthChanged: (_) {},
          onGutterWidthReset: () {},
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
          key: ValueKey(note.id),
          noteId: note.id,
          initialBody: note.body,
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          gutterWidth: widget.prefs.gutterWidth,
          autofocus: AppPlatform.isDesktop,
          startAtEnd: true,
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          onBodyChanged: (body) => _updateBody(note.id, body),
          onGutterWidthChanged: (value) => widget.prefs.gutterWidth = value,
          onGutterWidthReset: widget.prefs.resetGutterWidth,
          onSettingsPressed: _showSettings,
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
    required this.onDeleteNote,
    required this.shortcuts,
  });

  final Widget child;
  final VoidCallback onNewNote;
  final VoidCallback onFindNotes;
  final VoidCallback onToggleSidebar;
  final VoidCallback? onDeleteNote;
  final ShortcutPrefs shortcuts;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        shortcuts.bindingFor(ShortcutAction.newNote).activator: onNewNote,
        shortcuts.bindingFor(ShortcutAction.findNotes).activator: onFindNotes,
        shortcuts.bindingFor(ShortcutAction.toggleSidebar).activator:
            onToggleSidebar,
        if (onDeleteNote != null)
          shortcuts.bindingFor(ShortcutAction.deleteNote).activator:
              onDeleteNote!,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
