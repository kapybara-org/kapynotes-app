import 'dart:async';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        PhysicalKeyboardKey,
        SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../audio/voice_player.dart';
import '../audio/voice_recording_controller.dart';
import '../billing/note_limit.dart';
import '../crdt/text_diff.dart';
import '../data/voice_prefs.dart';
import '../speech/cloud_access.dart';
import '../speech/local_model_store.dart';
import '../speech/summarizer.dart';
import '../speech/transcriber.dart';
import '../speech/transcription_queue.dart';
import '../core/desktop_integration.dart';
import '../core/platform.dart';
import '../core/quick_capture.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/engine_provider.dart';
import '../data/attachment_limits.dart';
import '../data/auto_titles.dart';
import '../data/daily_separator.dart';
import '../data/editor_workspace.dart';
import '../data/layout_prefs.dart';
import '../data/local_store.dart';
import '../data/tags.dart';
import '../data/task_library.dart';
import '../data/note.dart';
import '../data/note_drawing.dart';
import '../files/file_picker.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';
import '../data/note_switcher.dart';
import '../data/notes_store.dart';
import 'editor/voice_chip.dart';
import 'editor/voice_insertion.dart';
import 'voice_note_dialog.dart';
import '../speech/speech_api.dart';
import '../speech/speech_errors.dart';
import 'voice_consent_sheet.dart';
import '../ai/kapy_ai.dart';
import '../sync/aead.dart';
import '../sync/sync_api.dart';
import '../sync/account.dart';
import '../sync/key_bundle.dart';
import 'account/encryption_pane.dart';
import '../sync/presence.dart';
import '../sync/spaces.dart';
import '../data/rates.dart';
import 'share_dialog.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../images/image_picker.dart';
import '../video/video_picker.dart';
import 'editor/note_editor.dart';
import 'editor/image_insertion.dart';
import 'editor/slash_commands.dart';
import 'editor_panes.dart';
import 'billing/note_limit_dialog.dart';
import 'billing/pro_sheet.dart';
import 'command_menu.dart';
import 'empty_state.dart';
import 'context_menu.dart';
import 'hidden_notes_gate.dart';
import 'kapy_ai/kapy_ai_panel.dart';
import 'kapy_ai/kapy_ai_settings.dart';
import 'kapy_header_mascot.dart';
import 'mobile_page_swipe.dart';
import 'notes_list.dart';
import 'page_card.dart';
import 'page_toolbar.dart';
import 'tasks/task_marks.dart';
import 'tasks/tasks_controller.dart';
import 'tasks/tasks_screen.dart';
import 'tasks/tasks_sidebar.dart';
import 'sidebar.dart';
import 'sidebar_timestamp.dart';
import 'settings_dialog.dart';
import 'tag_colours.dart';
import 'tag_ui.dart';
import 'sidebar_swipe.dart';
import 'spaces_rail.dart';
import 'split_view.dart';
import 'toolbar.dart';
import 'window_drag_area.dart';
import 'draw/drawing_canvas.dart';
import 'draw/note_mode_switch.dart';

/// The narrowest window that holds the notes list beside the page. Below it a
/// phone switches to the compact editor with a notes drawer, while a desktop
/// window keeps the rail and the page and opens the list over the page.
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
    this.tasks,
    this.tags,
    required this.store,
    this.welcomeNoteId,
    this.launchIntent = LaunchIntent.open,
    this.recording,
    this.player,
    this.transcriptions,
    this.voicePrefs,
    this.cloudAccess,
    this.localModels,
    this.deviceSummarizer,
    this.summarizer,
    this.deviceTranscriber,
    this.transcriber,
    this.imageAcquirer,
    this.lostImageRetriever,
    required this.hiddenNotesGate,
    this.kapyAi,
    this.titleModel,
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

  /// Every checklist line as a task, for Tasks. Null leaves Tasks out.
  final TaskLibrary? tasks;

  /// The person's tags and which notes carry them.
  final TagStore? tags;
  final LocalStore store;

  /// The welcome note seeded by this launch, if this launch seeded one.
  final String? welcomeNoteId;

  /// Which widget this launch came through, if it came through one.
  ///
  /// The note it opens onto has already been chosen by the time this page is
  /// built — see [QuickCapture.file]. What is left is the rest of the action:
  /// Capture opens the camera, Dictate starts recording, Write is already
  /// done by being here.
  final LaunchIntent launchIntent;

  /// Owns the microphone. Created above this page so a recording survives the
  /// page being rebuilt, and so the app's lifecycle hooks can end one.
  final VoiceRecordingController? recording;

  /// Plays recordings back. One for the whole app.
  final VoicePlayer? player;

  /// What is still to be transcribed, and what each chip should say.
  final TranscriptionQueue? transcriptions;

  final VoicePrefs? voicePrefs;
  final CloudAccess? cloudAccess;

  /// The speech models this device has downloaded, for the voice pane of
  /// settings to show and add to.
  final LocalModelStore? localModels;

  /// The device half of summarising, for the voice pane to offer and to
  /// explain when this machine cannot do it.
  final Summarizer? deviceSummarizer;

  /// Where a summary or a rewrite actually goes, cloud or device, following
  /// the preference at the moment it is asked for. The settings pane wants
  /// [deviceSummarizer] instead, because it asks a different question: what
  /// this machine *could* do.
  final Summarizer? summarizer;

  /// The device half of transcribing, for the voice pane to offer and to
  /// explain when this machine cannot do it.
  final Transcriber? deviceTranscriber;

  /// Where a recording actually goes to become words. The twin of
  /// [summarizer], and it is the queue rather than this page that uses it —
  /// held here only to hand on to settings.
  final Transcriber? transcriber;

  /// Injectable media boundaries keep launch tests independent of a physical
  /// camera and let the real page remember which note owns an interrupted
  /// Android photo-library result.
  final ImageFileAcquirer? imageAcquirer;
  final LostImageRetriever? lostImageRetriever;
  final HiddenNotesGate hiddenNotesGate;

  /// Kapy AI: its panel, its button beside the pin, and ⌘J. Null, or the
  /// feature not built in, leaves all three out.
  final KapyAi? kapyAi;

  /// The model on this device that names new notes. Null names none.
  final TitleModel? titleModel;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _pendingImageNoteKey = 'pendingImageNote.v1';
  static final _totalCue = RegExp(r'\btotal\b', caseSensitive: false);

  final FocusNode _desktopShortcutFocus = FocusNode(
    debugLabel: 'desktop-shortcuts',
  );
  final KapyHeaderController _kapyHeader = KapyHeaderController();
  final Set<String> _totalAnimatedFor = {};
  final NoteSwitcher _noteSwitcher = NoteSwitcher();
  GlobalKey<NoteEditorState> _compactEditorKey = GlobalKey<NoteEditorState>();
  GlobalKey<NoteEditorState> _archiveEditorKey = GlobalKey<NoteEditorState>();

  /// One key per note on screen in the panes, rather than one per pane, so a
  /// note keeps its caret, scroll and undo while its pane moves or swaps. A
  /// note that leaves the screen loses its key, and comes back fresh.
  final Map<String, GlobalKey<NoteEditorState>> _paneEditorKeys = {};
  late final EditorWorkspace _workspace;

  String? _selectedId;

  /// The search the ⌘K menu carries into Archive. Only Archive is narrowed by
  /// it, and leaving Archive drops it.
  String _archiveQuery = '';

  /// Which half of the library the sidebar lists. Not remembered across
  /// launches: the app opens on the tab of the note it opens on, and on the
  /// person's own notes when there is none.
  SidebarTab _sidebarTab = SidebarTab.mine;

  /// Whether the list beside the rail shows only drawings. Like a tab, a way
  /// of looking at the list rather than a choice of note, and only in the
  /// wide window: the compact list has no rail to leave it by.
  bool _drawingsOnly = false;

  /// The kinds of media the list beside the rail is narrowed to. Not kept
  /// across launches, so a filter left on cannot pass for missing notes.
  Set<NoteMedia> _mediaFilter = NoteMedia.values.toSet();

  /// The tags that list is narrowed to, kept the same way.
  TagFilter _tagFilter = const TagFilter();

  /// Whether that list shows every pinned note, after See all.
  bool _pinnedOnly = false;

  bool get _showingPinnedOnly =>
      _pinnedOnly && !_specialMode && widget.notes.pinnedNoteIds.isNotEmpty;

  bool _initialNoteScheduled = false;
  bool _openSessionScheduled = false;
  bool _drawerContentReady = false;
  bool _drawerOpen = false;

  /// Whether the notes list is open over the page, in a desktop window too
  /// narrow to hold it beside the page. See [_setListShown].
  bool _listOverlaid = false;

  bool _settingsOpen = false;
  bool _archiveMode = false;
  bool _hiddenMode = false;
  bool _hiddenAuthBusy = false;
  int _hiddenSystemUiDepth = 0;
  bool _voiceActionBusy = false;
  int _selectionRequest = 0;
  _NoteSwitchModifier? _noteSwitchModifier;
  EditorWorkspacePreviewSession? _noteSwitchWorkspace;
  ({String id, bool focusEditor})? _committedSwitchAwaitingSelection;

  /// True for a selection frame that only previews a note. The new editor is
  /// prepared at its normal caret but cannot steal focus from either sidebar
  /// scrubbing or an active Ctrl/Cmd switch session.
  bool _selectionAutofocusSuppressed = false;

  /// Whether the archive is picking notes rather than opening them, and which
  /// ones have been picked. Both are cleared on the way out of the archive:
  /// a selection is about the list you made it in.
  bool _selectingArchived = false;
  final Set<String> _checkedArchived = {};
  Timer? _kapyIdleTimer;

  /// Lets the compact layout close its own drawer, which is otherwise only
  /// reachable from a context below the Scaffold.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool get _specialMode => _archiveMode || _hiddenMode;

  /// A mobile overlay owns the screen while it is open. Editors can rebuild
  /// underneath one when a folder changes, but must not reclaim focus and
  /// raise the software keyboard behind it.
  bool get _editorFocusSuppressed =>
      AppPlatform.isMobile && (_drawerOpen || _settingsOpen);

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
    ?widget.voicePrefs,
    // The sidebar groups shared notes by space once the account is unlocked,
    // and that is a fact of the account, not of the notes.
    ?widget.account,
    ?widget.tasks,
  ]);

  /// Tasks, while the rail has it open.
  bool _tasksMode = false;

  /// The note that was open when a space it is not in was chosen, and the
  /// item that space opened in its place. Choosing a space that holds the
  /// note again, with that item still the one open, puts the note back.
  String? _noteBeforeSpace;
  String? _openedBySpace;
  TaskFilter _taskFilter = const TaskFilter.all();
  final FocusNode _taskAddFocus = FocusNode(debugLabel: 'Add a task');
  final GlobalKey<TasksScreenState> _tasksPage = GlobalKey();
  late final TasksController? _taskController = switch (widget.tasks) {
    final tasks? => TasksController(
      notes: widget.notes,
      library: tasks,
      canEdit: _canEditNote,
      now: widget.notes.now,
    ),
    null => null,
  };

  /// The welcome note while it is still exactly as it was written.
  ///
  /// Not persisted, and cleared the moment the reader types into it: from then
  /// on it is one of their notes and behaves like one.
  String? _untouchedWelcomeId;

  /// Notes made by "new note" on this device since the app started.
  ///
  /// One still blank when the reader moves on was never written, so it is
  /// deleted rather than left in the list — see [_discardAbandonedBlanks].
  /// Only these: a blank note that came from another device, or one the
  /// reader emptied by hand, may be somebody's on purpose.
  final Set<String> _freshNoteIds = {};
  bool _discardScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _kapyAiWasOn = _kapyAiOn;
    _kapyAi?.addListener(_onKapyAi);
    if (widget.titleModel case final model?) {
      _namer = NoteNamer(
        notes: widget.notes,
        prefs: widget.prefs,
        model: model,
        mayName: _mayNameNote,
      );
    }
    _untouchedWelcomeId = widget.welcomeNoteId;
    final openingId =
        widget.prefs.resolveOpeningNoteId(
          widget.notes.notes.map((note) => note.id),
        ) ??
        widget.notes.lastEditedNote?.id;
    _workspace = EditorWorkspace(widget.store)
      ..load(
        availableNoteIds: widget.notes.notes.map((note) => note.id),
        openingNoteId: openingId,
      );
    _selectedId = _workspace.selectedNoteId;
    // Opens on the tab that lists the note it opens on.
    _showTabOf(_selectedId);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    widget.notes.addListener(_onNotesChanged);
    widget.account?.noteLimit?.addListener(_onNoteLimitChanged);
    widget.account?.addListener(_offerRecoveryKey);
    // The system-wide new-note shortcut has already raised the window by the
    // time this runs; the note itself is this page's to make.
    widget.desktopIntegration?.onNewNoteRequested = _createNote;
    widget.desktopIntegration?.onOpenRequested = _beginOpenSession;
    widget.desktopIntegration?.window = (
      openNote: _openTaskNote,
      openTasks: () => _showSpace(LibrarySpace.tasks),
      find: () => unawaited(_openCommandMenu()),
      newTask: _newTask,
      openSettings: _showSettings,
      explainNoteLimit: () => unawaited(_explainNoteLimit(creating: true)),
    );
    // The controller owns the microphone but knows nothing about notes or
    // editors; this is where a finished recording becomes a ref in one.
    widget.recording?.onFinished = _deliverRecording;
    widget.recording?.addListener(_onRecordingChanged);
    _reconcileSelection();
    // Keep timers and mascot work behind the first editable frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = _selectedId;
      if (selected != null) widget.prefs.lastOpenedNoteId = selected;
      _armKapyIdleTimer();
      _reactToSelectedTotal();
      // After the frame, because both paths act on the editor that frame just
      // built. A recovered Android library result wins over replaying the
      // widget's Capture intent, so process recreation cannot open a second
      // camera over the picture the user just chose.
      unawaited(_runInitialImageAndWidgetActions());
    });
  }

  @override
  void dispose() {
    widget.account?.sync?.leaveNote(_selectedId);
    _namer?.dispose();
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    widget.account?.noteLimit?.removeListener(_onNoteLimitChanged);
    widget.account?.removeListener(_offerRecoveryKey);
    widget.desktopIntegration?.onNewNoteRequested = null;
    widget.desktopIntegration?.onOpenRequested = null;
    widget.desktopIntegration?.window = null;
    _kapyIdleTimer?.cancel();
    _kapyHeader.dispose();
    _desktopShortcutFocus.dispose();
    _kapyAi?.removeListener(_onKapyAi);
    _kapyPanel.dispose();
    _taskAddFocus.dispose();
    _taskController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_hiddenMode &&
        _hiddenSystemUiDepth == 0 &&
        state != AppLifecycleState.resumed) {
      _leaveHiddenNotes();
    }
    if (state == AppLifecycleState.resumed) {
      _recordKapyActivity();
      _beginOpenSession();
      // A widget tapped while the app was already running. The platform has
      // been holding that fact since the intent or the URL arrived, and gives
      // it up once, to whoever asks first — so asking on every resume costs
      // an ordinary resume one unanswered question and nothing else.
      unawaited(QuickCapture.launchIntent().then(_runWidgetAction));
    } else {
      // A window can lose the matching modifier-up event while focus moves to
      // the operating system. Commit the last preview so the switcher cannot
      // remain half-open when the app returns.
      _commitNoteSwitch(focusEditor: false);
      _kapyIdleTimer?.cancel();
      _namer?.left(_selectedId);
    }
  }

  @override
  void didChangeMetrics() {
    if (mounted && _drawingsOnly && _usesCompactLayout) {
      setState(() => _drawingsOnly = false);
    }
    // An open compact drawer is disposed when a phone turns or a tablet's
    // window widens into the two-pane layout. Scaffold cannot report a closing
    // transition after that disposal, so clear the transient flag here.
    // Otherwise returning to a compact width builds a closed drawer whose
    // toolbar still hides every edge action.
    if (mounted && _drawerOpen && !_usesCompactLayout) {
      setState(() => _drawerOpen = false);
    }
    // A list opened over the page stays open as the window widens, beside the
    // page now that there is room for it.
    if (mounted && _listOverlaid && _listFits) {
      setState(() => _listOverlaid = false);
      if (!widget.prefs.sidebarVisible) widget.prefs.toggleSidebar();
    }
    // A phone shows only the focused pane's note. An empty pane has none, so
    // focus a pane that does rather than show nothing at all.
    if (mounted &&
        !_specialMode &&
        _usesCompactLayout &&
        _workspace.selectedNoteId == null) {
      final filled = _workspace.panes.indexWhere((pane) => pane.noteId != null);
      final previous = _selectedId;
      if (filled >= 0 && _workspace.activate(filled)) {
        setState(() => _adoptWorkspaceSelection(previous));
      }
    }
  }

  void _beginOpenSession() {
    // A welcome note nobody has typed into yet is there to be read. Appending
    // a dated line to it and dropping the cursor underneath is the opposite of
    // that, and on a phone it would raise a keyboard over the half that
    // explains itself.
    if (_selectedId != null && _selectedId == _untouchedWelcomeId) return;
    if (!widget.prefs.readyToTypeOnOpen ||
        _editorFocusSuppressed ||
        _openSessionScheduled) {
      return;
    }
    _openSessionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openSessionScheduled = false;
      if (!mounted ||
          _editorFocusSuppressed ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      // Coming back to the app on the same day is coming back to the middle
      // of something. Take the focus, and leave the caret where it is.
      final id = _selectedId;
      if (id != null && widget.prefs.caretIn(id) != null) {
        _selectedEditor?.focusHere();
        return;
      }
      _selectedEditor?.beginAppendSession();
    });
    // An idle app draws no frame of its own to run that in.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// The half of a widget tap that is not the note it opened.
  ///
  /// The note is already chosen and on screen: Write wanted nothing more than
  /// that. Capture and Dictate are each one thing done *in* that note, and on
  /// a tap that arrives while the app is already open that note is simply the
  /// one being read — the same note the widget would have opened.
  Future<void> _runWidgetAction(LaunchIntent intent) async {
    if (!mounted) return;
    switch (intent) {
      case LaunchIntent.open:
      case LaunchIntent.continueWriting:
        return;
      case LaunchIntent.capture:
        await _selectedEditor?.pickAndInsertImages();
      case LaunchIntent.dictate:
        await _startVoiceRecording();
    }
  }

  Future<void> _runInitialImageAndWidgetActions() async {
    final interruptedSelection = await _recoverInterruptedImageSelection();
    if (!mounted || interruptedSelection) return;
    await _runWidgetAction(widget.launchIntent);
  }

  Future<List<XFile>> _acquireImages(
    BuildContext context,
    String noteId,
  ) async {
    final protectsHiddenSession =
        _hiddenMode && (widget.notes.byId(noteId)?.isHidden ?? false);
    if (protectsHiddenSession) _hiddenSystemUiDepth++;
    try {
      final override = widget.imageAcquirer;
      if (override != null) return await override(context);
      if (!AppPlatform.isAndroid) return await acquireNoteImages(context);
      return await acquireNoteImages(
        context,
        chooseFromLibrary: () => _pickImagesFromAndroidLibrary(noteId),
      );
    } finally {
      if (protectsHiddenSession) _hiddenSystemUiDepth--;
    }
  }

  Future<List<XFile>> _acquireVideos(String noteId) async {
    final protectsHiddenSession =
        _hiddenMode && (widget.notes.byId(noteId)?.isHidden ?? false);
    if (protectsHiddenSession) _hiddenSystemUiDepth++;
    try {
      return await acquireNoteVideos();
    } finally {
      if (protectsHiddenSession) _hiddenSystemUiDepth--;
    }
  }

  /// The file picker, which leaves the app as the photo pickers do: a hidden
  /// note's session outlasts it, or the picked files would land nowhere.
  Future<List<XFile>> _acquireFiles(String noteId) async {
    final protectsHiddenSession =
        _hiddenMode && (widget.notes.byId(noteId)?.isHidden ?? false);
    if (protectsHiddenSession) _hiddenSystemUiDepth++;
    try {
      return await acquireAttachmentFiles();
    } finally {
      if (protectsHiddenSession) _hiddenSystemUiDepth--;
    }
  }

  /// Remembers the target note only for the moment Android leaves Flutter for
  /// its system photo picker. This durable marker is needed where the operating
  /// system may reclaim the Activity while another one is choosing photos.
  Future<List<XFile>> _pickImagesFromAndroidLibrary(String noteId) async {
    widget.store.put(_pendingImageNoteKey, noteId);
    await widget.store.flush();
    try {
      return await pickExistingImageFiles();
    } finally {
      widget.store.put(_pendingImageNoteKey, null);
      unawaited(widget.store.flush());
    }
  }

  /// Returns true when a prior image flow was found, even if it ended without
  /// a usable file. The caller uses that to avoid replaying an old Capture
  /// launch intent after Android reconstructed the activity.
  Future<bool> _recoverInterruptedImageSelection() async {
    if (!AppPlatform.isAndroid) return false;
    final targetId = widget.store.read<String>(_pendingImageNoteKey);
    if (targetId == null) return false;

    final recovery =
        await (widget.lostImageRetriever ?? recoverLostImageFiles)();
    widget.store.put(_pendingImageNoteKey, null);
    unawaited(widget.store.flush());
    if (!mounted) return true;

    if (recovery.files.isEmpty) {
      if (recovery.error != null) {
        Toast.show(
          context,
          'Could not recover the selected photo',
          icon: KapyIcons.errorOutlined,
        );
      }
      return true;
    }

    final note = widget.notes.byId(targetId);
    if (!_canWriteNote(note)) {
      Toast.show(
        context,
        'The note for that photo is no longer available',
        icon: KapyIcons.errorOutlined,
      );
      return true;
    }

    final progress = Toast.showProgress(
      context,
      recovery.files.length == 1
          ? 'Recovering photo…'
          : 'Recovering ${recovery.files.length} photos…',
    );
    try {
      final batch = await ingestFiles(
        recovery.files,
        store: widget.notes.blobs,
      );
      if (!mounted) {
        progress.dismiss();
        return true;
      }
      if (batch.images.isEmpty) {
        final first = batch.rejections.firstOrNull;
        progress.error(
          first == null
              ? 'Could not recover that photo'
              : '${first.name} ${describeRejection(first.reason)}',
        );
        return true;
      }

      final current = widget.notes.byId(targetId);
      if (!_canWriteNote(current)) {
        progress.error('The note for that photo is no longer available');
        return true;
      }
      final body = _bodyForEndAttachment(current!);
      final insertion = insertImagesIntoBody(
        body: body,
        existing: current.attachments,
        caret: body.length,
        incoming: batch.images,
      );
      final mayReveal = _mayRevealInCurrentCollection(current);
      if (_selectedId != targetId && mayReveal) {
        setState(() => _setSelectedId(targetId));
        widget.prefs.lastOpenedNoteId = targetId;
      }
      widget.notes.updateDocument(
        targetId,
        insertion.body,
        current.formats,
        insertion.attachments,
      );
      final added = batch.images.length;
      final rejected = batch.rejections.length;
      if (rejected > 0) {
        progress.success(
          'Recovered $added ${added == 1 ? 'photo' : 'photos'}; '
          '$rejected could not be added',
          icon: KapyIcons.warningRounded,
        );
      } else {
        progress.success(
          current.isHidden && !mayReveal
              ? added == 1
                    ? 'Photo added to Hidden Notes'
                    : '$added photos added to Hidden Notes'
              : added == 1
              ? 'Photo added'
              : '$added photos added',
        );
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Kapy Notes image recovery',
        ),
      );
      if (mounted) {
        progress.error('Could not recover the selected photo');
      } else {
        progress.dismiss();
      }
    }
    return true;
  }

  /// Starts recording into the selected note, or stops one already running.
  ///
  /// The single place every entry point lands: the widget's Dictate tap, the
  /// toolbar mic, the footer button, the shortcut and the context menu.
  Future<void> _startVoiceRecording({String? noteId}) async {
    if (_voiceActionBusy) return;
    final recording = widget.recording;
    final id = noteId ?? _selectedId;
    if (recording == null || id == null) return;

    final stopping = recording.isRecording;
    if (!stopping && !_canWriteNote(widget.notes.byId(id))) return;
    // A drawing has nowhere to show a recording, or play it, or let it go:
    // one delivered into it would only become part of its title.
    if (!stopping && (widget.notes.byId(id)?.isDrawing ?? false)) {
      Toast.show(
        context,
        'Voice notes go in a written note, not a drawing',
        isError: true,
      );
      return;
    }
    setState(() => _voiceActionBusy = true);
    final progress = Toast.showProgress(
      context,
      stopping ? 'Saving voice note…' : 'Starting recording…',
    );
    try {
      if (stopping) {
        await recording.finishRecordingAndFlush();
        if (mounted) {
          progress.success('Recording stopped');
        } else {
          progress.dismiss();
        }
        return;
      }
      final started = await recording.start(noteId: id);
      if (!mounted) {
        progress.dismiss();
        return;
      }
      if (started) {
        progress.success('Recording started');
      } else {
        // Linux asks no permission, so there a refusal is a capture that
        // never started: no sound server, or nothing to record from.
        progress.error(
          AppPlatform.isLinux
              ? 'Could not open a microphone'
              : 'Kapy Notes needs microphone access to record',
        );
      }
    } catch (error) {
      if (mounted) {
        progress.error(
          stopping
              ? 'Could not save the voice note'
              : 'Could not start recording',
        );
      } else {
        progress.dismiss();
      }
    } finally {
      if (mounted) setState(() => _voiceActionBusy = false);
    }
  }

  /// Delivers a finished recording into the note it was started in.
  ///
  /// Two paths, because the note may no longer be the one on screen: if its
  /// editor is mounted the ref goes in at the caret, and if it is not it is
  /// appended to the stored note directly. Both end with the same ref in the
  /// same note; only the caret differs.
  Future<void> _deliverRecording(
    VoiceRecordingResult result,
    String noteId,
  ) async {
    if (!_canWriteNote(widget.notes.byId(noteId))) return;
    // Switched to a drawing while recording, or taken for one elsewhere: the
    // recording goes into a note of its own rather than into a title.
    if (widget.notes.byId(noteId)?.isDrawing ?? false) {
      noteId = widget.notes.create(body: Note.blankBody, authored: false).id;
    }
    final blobs = widget.notes.blobs;
    final hash = await blobs.adoptFile(
      result.file,
      extension: NoteVoiceRef.voiceExtension,
    );
    final bytes = await result.file.exists()
        ? await result.file.length()
        : (await blobs.fileFor(hash))?.lengthSync() ?? 0;

    final ref = NoteVoiceRef(
      offset: 0,
      hash: hash,
      key: randomKey(),
      bytes: bytes,
      durationMs: result.duration.inMilliseconds,
      peaks: result.peaks,
    );

    // Any pane showing the note takes it at its caret, focused or not. Only a
    // note that is off the screen is appended to directly.
    final editor = _mountedEditorFor(noteId);
    if (editor != null) {
      editor.insertVoice(ref);
    } else {
      final note = widget.notes.byId(noteId);
      if (note == null) return;
      final placed = appendVoiceToBody(
        body: _bodyForEndAttachment(note),
        existing: note.attachments,
        incoming: ref,
      );
      widget.notes.updateDocument(
        noteId,
        placed.body,
        note.formats,
        placed.attachments,
      );
    }

    // Queued whatever happens next. A signed-out user, one who has not agreed,
    // and one with no connection all end up with the same entry, and the queue
    // works out which of those it is when it next drains.
    widget.transcriptions?.enqueue(noteId, hash);
    unawaited(_drainTranscriptions());
  }

  String _bodyForEndAttachment(Note note) {
    final now = DateTime.now();
    if (!widget.prefs.dailySeparatorsEnabled ||
        DailySeparator.isSameDay(
          note.updatedAt,
          now,
          displayTime: widget.prefs.displayTime,
        )) {
      return note.body;
    }
    return DailySeparator.append(
      note.body,
      note.updatedAt,
      displayTime: widget.prefs.displayTime,
    );
  }

  bool _mayRevealInCurrentCollection(Note note) {
    if (note.isHidden) return _hiddenMode;
    if (note.isArchived) return _archiveMode;
    return !_specialMode;
  }

  /// Drains the queue, offering the consent sheet the first time the server
  /// asks for it.
  Future<void> _drainTranscriptions() async {
    final queue = widget.transcriptions;
    if (queue == null) return;
    await queue.drain();
    if (!mounted || !queue.needsConsent) return;

    final prefs = widget.voicePrefs;
    // Asked once per version. Someone who said no is not asked again until the
    // wording changes, because then it is a different question.
    if (prefs != null && !prefs.shouldOfferConsent(speechConsentVersion)) {
      return;
    }

    final accepted = await showSpeechConsentSheet(context);
    if (!accepted) {
      prefs?.transcriptionDeclinedVersion = speechConsentVersion;
      return;
    }
    try {
      await widget.account?.speech?.acceptConsent(speechConsentVersion);
      prefs?.transcriptionDeclinedVersion = null;
      queue.needsConsent = false;
      for (final entry in queue.entries) {
        queue.retry(entry.noteId, entry.hash);
      }
      await queue.drain();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(describeSpeechError(error))));
    }
  }

  VoiceChipState _voiceStateFor(NoteVoiceRef ref) =>
      widget.transcriptions?.stateFor(ref) ?? VoiceChipState.idle;

  /// Retries the recording that led into Voice Settings once an engine is
  /// selected. This bypasses the consent prompt in [_drainTranscriptions]:
  /// the cloud row has just collected it, and local transcription needs none.
  void _resumeTranscriptionsFromSettings() {
    final queue = widget.transcriptions;
    if (queue == null) return;
    queue.needsConsent = false;
    for (final entry in queue.entries) {
      queue.retry(entry.noteId, entry.hash);
    }
    unawaited(queue.drain());
  }

  Future<void> _openVoiceNote(NoteVoiceRef ref) async {
    final state = _voiceStateFor(ref);
    // Two states are not about this recording at all: they are about the
    // account and the consent behind every recording. A dialog explaining
    // that, with a button that opens settings, is one screen too many.
    if (ref.transcript == null &&
        (state == VoiceChipState.needsAccount ||
            state == VoiceChipState.needsConsent)) {
      _showSettings(section: SettingsSection.voice);
      return;
    }
    final noteId = _selectedId;
    final note = widget.notes.byId(noteId ?? '');
    final canEdit = _canWriteNote(note);
    await openVoiceNoteDialog(
      context,
      ref: ref,
      state: state,
      player: widget.player,
      recordedAt: note?.createdAt,
      actions: VoiceNoteActions(
        onInsert: canEdit
            ? (text) => _selectedEditor?.insertPlainLines(
                text,
                afterOffset: ref.offset,
              )
            : null,
        onDelete: canEdit
            ? () => _selectedEditor?.removeAttachment(ref.offset)
            : null,
        onRetry: noteId == null
            ? null
            : () {
                widget.transcriptions?.retry(noteId, ref.hash);
                unawaited(_drainTranscriptions());
              },
        onTranscribeAgain: noteId == null
            ? null
            : () {
                // A deliberate second transcription: a new intent, which the
                // server bills for, rather than a free retry of the first.
                widget.transcriptions?.enqueue(noteId, ref.hash, fresh: true);
                unawaited(_drainTranscriptions());
              },
        onTurnOnTranscription: () =>
            _showSettings(section: SettingsSection.voice),
        onRegenerateSummary: noteId == null || ref.transcript == null
            ? null
            : () {
                widget.transcriptions?.summarizeAgain(noteId, ref.hash);
                unawaited(_drainTranscriptions());
              },
        onChanged: noteId == null || !canEdit
            ? null
            : (next) => widget.notes.updateAttachment(
                noteId,
                ref.hash,
                (_) => next,
                // A speaker's name and a post written here are the note's
                // now, and every other device should have them.
                touch: true,
              ),
        onRewrite: widget.summarizer == null || ref.transcript == null
            ? null
            : (instruction) => widget.summarizer!.rewrite(
                text: ref.transcript!.text,
                lang: ref.transcript!.lang,
                instruction: instruction,
                jobId: ref.transcript!.jobId,
              ),
        summaryInstruction: widget.voicePrefs?.effectiveSummaryInstruction,
        onSaveSummaryInstruction: widget.voicePrefs == null
            ? null
            : (instruction) =>
                  widget.voicePrefs!.summaryInstruction = instruction,
        failureReason: _failureReasonFor(ref),
      ),
    );
  }

  /// The caption under "Couldn't transcribe", when there is one to give.
  String? _failureReasonFor(NoteVoiceRef ref) {
    final entry = widget.transcriptions?.entries
        .where((e) => e.hash == ref.hash)
        .firstOrNull;
    final code = entry?.lastError;
    if (code == null) return null;
    return describeSpeechError(SyncRefusedException(400, code, const {}));
  }

  /// The editor the user is actually looking at. Split panes keep every
  /// editor mounted; the focused pane's is the one global actions such as Add
  /// Image and Record address.
  NoteEditorState? get _selectedEditor {
    final id = _selectedId;
    return id == null ? null : _mountedEditorFor(id);
  }

  /// The editor showing [noteId], wherever on screen it is, or null.
  NoteEditorState? _mountedEditorFor(String noteId) {
    if (_usesCompactLayout) {
      return _selectedId == noteId ? _compactEditorKey.currentState : null;
    }
    if (_specialMode) {
      return _selectedId == noteId ? _archiveEditorKey.currentState : null;
    }
    return _paneEditorKeys[noteId]?.currentState;
  }

  GlobalKey<NoteEditorState> _paneEditorKey(String noteId) =>
      _paneEditorKeys.putIfAbsent(noteId, () => GlobalKey<NoteEditorState>());

  /// The recording bar is part of the footer, so its state is this page's to
  /// rebuild on.
  void _onRecordingChanged() {
    if (mounted) setState(() {});
  }

  void _onNotesChanged() {
    final collectionIds =
        (_archiveMode
                ? widget.notes.archivedNotes
                : _hiddenMode
                ? widget.notes.hiddenNotes
                : widget.notes.notes)
            .map((note) => note.id);
    final workspacePreview = _noteSwitchWorkspace;
    if (workspacePreview != null &&
        !workspacePreview.canContinueWith(collectionIds)) {
      _cancelNoteSwitchPreview();
    }
    final previous = _selectedId;
    widget.prefs.retainRecentlyOpenedNoteIds(
      widget.notes.allNotes.map((note) => note.id),
    );
    _reconcileSelection();
    final selected = _selectedId;
    if (selected != null && selected != previous) {
      widget.prefs.lastOpenedNoteId = selected;
    }
    _reactToSelectedTotal();
    if (mounted) setState(() {});
  }

  /// Keeps the selection pointing at a note that still exists.
  void _reconcileSelection() {
    _noteSwitcher.retain(widget.notes.allNotes.map((note) => note.id));
    if (!_noteSwitcher.isActive) _noteSwitchModifier = null;
    final available = _archiveMode
        ? widget.notes.archivedNotes
        : _hiddenMode
        ? widget.notes.hiddenNotes
        : widget.notes.notes;
    if (_specialMode) {
      if (available.isEmpty) {
        _setSelectedId(null);
        return;
      }
      if (available.any((note) => note.id == _selectedId)) return;
      _setSelectedId(available.first.id);
      return;
    }

    final preferred = widget.prefs.resolveOpeningNoteId(
      widget.notes.notes.map((note) => note.id),
    );
    final previous = _selectedId;
    _workspace.reconcile(
      available.map((note) => note.id),
      fallbackId: preferred ?? available.firstOrNull?.id,
    );
    _adoptWorkspaceSelection(previous);
    final parked = widget.notes.byId(_noteBeforeSpace);
    if (parked == null || parked.isHidden || parked.isArchived) {
      _noteBeforeSpace = _openedBySpace = null;
    }
    if (available.isEmpty && _usesCompactLayout) _scheduleInitialNote();
  }

  /// Only a phone has a compact layout: a desktop window of any width keeps
  /// the rail and the page.
  bool get _usesCompactLayout => AppPlatform.isMobile && !_listFits;

  /// Whether the window holds the notes list beside the page. Read from the
  /// window because selection is also reconciled, and the list shown, outside
  /// build.
  bool get _listFits {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio >=
        kTwoPaneBreakpoint;
  }

  /// Whether the notes list is on screen, beside the page or over it.
  bool get _listShown =>
      _listFits ? widget.prefs.sidebarVisible : _listOverlaid;

  /// Shows or hides the notes list in the wide layout. Every control that does
  /// either comes through here: the shortcut, the toolbar's button, the list's
  /// own hide button and divider, a sideways swipe, and an empty pane.
  ///
  /// Where the window has room, the list stands beside the page and the
  /// choice is [LayoutPrefs.sidebarVisible], which the settings switch shows.
  /// Where it has not, the list opens over the page and takes the keyboard
  /// from the note, so nothing typed lands in the note it covers, and
  /// closing it gives the keyboard back to the note.
  void _setListShown(bool shown) {
    if (_listFits) {
      if (widget.prefs.sidebarVisible != shown) widget.prefs.toggleSidebar();
      return;
    }
    if (shown == _listOverlaid) return;
    setState(() => _listOverlaid = shown);
    if (!shown) _focusSelectedEditorHere();
  }

  void _toggleList() => _setListShown(!_listShown);

  /// Puts away a list open over the page once a note is chosen from it. A
  /// list beside the page stays where it is.
  void _dismissListOverlay() {
    if (_listOverlaid) _setListShown(false);
  }

  void _setSelectedId(String? id, {bool selectionPreview = false}) {
    if (!selectionPreview) _cancelNoteSwitchPreview();
    final previous = _selectedId;
    if (_specialMode) {
      if (previous != id) {
        _archiveEditorKey = GlobalKey<NoteEditorState>();
        _compactEditorKey = GlobalKey<NoteEditorState>();
        widget.account?.sync?.leaveNote(previous);
        _namer?.left(previous);
        _scheduleDiscardAbandonedBlanks();
      }
      _selectedId = id;
      return;
    }

    if (id == null) {
      _workspace.reconcile(const <String>[], persist: true);
    } else {
      _workspace.open(id);
    }
    _adoptWorkspaceSelection(previous, selectionPreview: selectionPreview);
  }

  /// Takes up whatever the panes now have focused, after any change to them,
  /// and lets go of the editors of notes no longer on screen.
  void _adoptWorkspaceSelection(
    String? previous, {
    bool selectionPreview = false,
  }) {
    final next = _workspace.selectedNoteId;
    if (previous != next) {
      widget.account?.sync?.leaveNote(previous);
      _namer?.left(previous);
      _compactEditorKey = GlobalKey<NoteEditorState>();
      _showTabOf(next);
    }
    _selectedId = next;
    final open = _workspace.openNoteIds;
    _paneEditorKeys.removeWhere((id, _) => !open.contains(id));
    if (!selectionPreview) _scheduleDiscardAbandonedBlanks();
  }

  /// Runs [_discardAbandonedBlanks] once the change under way has settled.
  ///
  /// Selection moves inside `setState` and in the middle of pane changes, so
  /// the delete waits for a microtask rather than rebuilding the list under
  /// the code that is still rearranging it.
  void _scheduleDiscardAbandonedBlanks() {
    if (_freshNoteIds.isEmpty || _discardScheduled) return;
    _discardScheduled = true;
    scheduleMicrotask(() {
      _discardScheduled = false;
      if (mounted) _discardAbandonedBlanks();
    });
  }

  /// Deletes the new notes the reader left without writing anything.
  ///
  /// A note still on screen — selected, or in another pane — is still being
  /// looked at, and one mid-way through a held-key switch may be switched
  /// back to. A note that got any writing, picture or recording is a real
  /// note from then on, and stops being a candidate even if later emptied.
  void _discardAbandonedBlanks() {
    if (_noteSwitchWorkspace != null) return;
    final open = _workspace.openNoteIds;
    final recordingInto = widget.recording?.isRecording ?? false
        ? widget.recording?.session?.noteId
        : null;
    final abandoned = <String>[];
    for (final id in _freshNoteIds.toList()) {
      if (id == _selectedId || open.contains(id) || id == recordingInto) {
        continue;
      }
      _freshNoteIds.remove(id);
      final note = widget.notes.byId(id);
      // Filed away on purpose is not abandoned.
      if (note == null || note.isShared || note.isArchived) continue;
      if (note.isEmpty && note.attachments.isEmpty) abandoned.add(id);
    }
    if (abandoned.isEmpty) return;
    for (final id in abandoned) {
      _totalAnimatedFor.remove(id);
    }
    // Plain [NotesStore.deleteAll], not [_forget]: none of these is on screen,
    // so the selection stays put, and a blank note owns no attachments to
    // sweep.
    widget.notes.deleteAll(abandoned);
  }

  /// Lists the tab [id] is in, when a note is opened from somewhere other
  /// than the list: a link, a pane, the note put back after the archive. A
  /// row the reader clicked is in the tab on screen already, and the reader
  /// switching tabs moves no selection, so neither is overruled. A note that
  /// is not a drawing takes the list out of Drawings, for the same reason.
  void _showTabOf(String? id) {
    if (id == null || _specialMode) return;
    final note = widget.notes.byId(id);
    if (note == null) return;
    if (_drawingsOnly) {
      if (note.isDrawing) return;
      _drawingsOnly = false;
    }
    final sharing = widget.account?.sharing;
    if (sharing != null) _sidebarTab = sidebarTabOf(note, sharing);
  }

  /// Abandons a held-key preview before another interaction takes ownership.
  /// In split view that also restores the pane arrangement from the start of
  /// the gesture, so a click or structural pane action never inherits a
  /// half-previewed layout.
  bool _cancelNoteSwitchPreview() {
    _noteSwitchModifier = null;
    _committedSwitchAwaitingSelection = null;
    _noteSwitcher.cancel();
    final preview = _noteSwitchWorkspace;
    _noteSwitchWorkspace = null;
    if (preview == null) return false;

    final previous = _selectedId;
    preview.cancel();
    _selectedId = _workspace.selectedNoteId;
    if (previous != _selectedId) {
      widget.account?.sync?.leaveNote(previous);
      _namer?.left(previous);
      _compactEditorKey = GlobalKey<NoteEditorState>();
    }
    final open = _workspace.openNoteIds;
    _paneEditorKeys.removeWhere((id, _) => !open.contains(id));
    _scheduleDiscardAbandonedBlanks();
    return true;
  }

  void _scheduleInitialNote() {
    if (_initialNoteScheduled) return;
    _initialNoteScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialNoteScheduled = false;
      if (!mounted ||
          !_usesCompactLayout ||
          _specialMode ||
          !widget.notes.isEmpty) {
        return;
      }
      _createNote();
    });
  }

  /// Runs [change] at once, unless it would take the note being recorded into
  /// off the screen. That recording is delivered first, while the editor
  /// holding its note is still there to take it at the caret.
  void _afterRecordingLeaves(String? leaving, VoidCallback change) {
    final recording = widget.recording;
    if (leaving != null &&
        recording != null &&
        recording.isRecording &&
        recording.session?.noteId == leaving) {
      unawaited(
        recording.finishRecordingAndFlush().then((_) {
          if (mounted) change();
        }),
      );
      return;
    }
    change();
  }

  void _select(
    String id, {
    bool focusEditor = true,
    bool selectionPreview = false,
    EditorWorkspacePreviewSession? workspacePreview,
  }) {
    assert(workspacePreview == null || selectionPreview);
    final request = ++_selectionRequest;
    // Any explicit selection owns the interaction now, even when it lands on
    // the note already being previewed. Otherwise releasing an old modifier
    // could focus or re-promote a row after a sidebar click took over.
    if (!selectionPreview && _cancelNoteSwitchPreview() && mounted) {
      setState(() {});
    }
    // Showing a note replaces the focused one, unless it is already open in a
    // pane of its own, which is then only focused.
    final leaving = workspacePreview != null
        ? workspacePreview.displacedBy(id)
        : id != _selectedId &&
              (_usesCompactLayout || _specialMode || _workspace.paneOf(id) < 0)
        ? _selectedId
        : null;
    _afterRecordingLeaves(leaving, () {
      if (!mounted || request != _selectionRequest) return;
      _selectNow(
        id,
        focusEditor: focusEditor,
        selectionPreview: selectionPreview,
        workspacePreview: workspacePreview,
      );
    });
  }

  /// A press on a row. Beside the page the keyboard stays in the list, for
  /// the arrows to walk on from there; over the page the note opens and the
  /// list goes.
  void _selectFromSidebar(String id) {
    if (!_listOverlaid) {
      _select(id, focusEditor: false);
      return;
    }
    _dismissListOverlay();
    _select(id);
  }

  void _previewFromSidebar(String id) =>
      _select(id, focusEditor: false, selectionPreview: true);

  void _selectNow(
    String id, {
    required bool focusEditor,
    bool selectionPreview = false,
    EditorWorkspacePreviewSession? workspacePreview,
  }) {
    if (!focusEditor) {
      _selectionAutofocusSuppressed = true;
      // A preview may only activate an editor already mounted in another
      // pane. Move focus to the shortcut scope so the active-pane marker and
      // the real keyboard focus agree, while further Tabs still reach the
      // same held-key session.
      if (selectionPreview && _noteSwitcher.isActive) {
        _desktopShortcutFocus.requestFocus();
      }
    }
    final paneBefore = _workspace.activePane;
    setState(() {
      if (workspacePreview != null && workspacePreview.preview(id)) {
        final previous = _selectedId;
        _adoptWorkspaceSelection(previous, selectionPreview: true);
      } else {
        _setSelectedId(id, selectionPreview: selectionPreview);
      }
    });
    if (!selectionPreview) {
      widget.prefs.lastOpenedNoteId = id;
      _recordKapyActivity();
      _reactToSelectedTotal();
    }
    // Already open in another pane, whose editor is not rebuilt, so it will
    // not take the keyboard by itself.
    if (focusEditor && !_specialMode && _workspace.activePane != paneBefore) {
      _focusSelectedEditorHere();
    }
    if (!focusEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectionAutofocusSuppressed = false;
      });
    }
    final committed = _committedSwitchAwaitingSelection;
    if (selectionPreview && committed?.id == id) {
      _committedSwitchAwaitingSelection = null;
      _commitWorkspacePreview();
      if (committed!.focusEditor) _focusSelectedEditorHere();
    }
  }

  void _openNoteToSide(String id) {
    if (_usesCompactLayout || _specialMode) return;
    _dismissListOverlay();
    _afterRecordingLeaves(
      _workspace.displacedByOpenToSide(id),
      () => _openNoteToSideNow(id),
    );
  }

  void _openNoteToSideNow(String id) {
    final previous = _selectedId;
    setState(() {
      _workspace.openToSide(id);
      _adoptWorkspaceSelection(previous);
    });
    _afterPaneChange();
  }

  /// Opens an empty pane beside the focused note, for the next note chosen.
  void _splitEditor() {
    if (_usesCompactLayout || _specialMode || !_workspace.canSplit) return;
    final previous = _selectedId;
    setState(() {
      _workspace.split();
      _adoptWorkspaceSelection(previous);
    });
    // Nothing to focus yet: the empty pane takes the keyboard itself.
    _afterPaneChange(focus: false);
  }

  /// What every change to the panes ends on. The focused note is remembered
  /// for the next launch and, unless [focus] is false, given the keyboard.
  void _afterPaneChange({bool focus = true}) {
    final id = _selectedId;
    if (id != null) widget.prefs.lastOpenedNoteId = id;
    _recordKapyActivity();
    _reactToSelectedTotal();
    if (focus) _focusSelectedEditorHere();
  }

  void _activatePane(int index) {
    if (_specialMode || _usesCompactLayout) return;
    final previous = _selectedId;
    if (!_workspace.activate(index)) return;
    setState(() => _adoptWorkspaceSelection(previous));
    _afterPaneChange(focus: false);
  }

  /// Focuses the pane at [index] and puts the keyboard in its note: the
  /// pane's number shortcut, and a click on its title.
  void _focusPane(int index) {
    if (_specialMode || _usesCompactLayout) return;
    if (index >= _workspace.paneCount) return;
    _activatePane(index);
    _focusSelectedEditorHere();
  }

  /// Closes a pane. The note in it stays exactly where it is in the list.
  void _closePane(int index) {
    if (_specialMode || _usesCompactLayout) return;
    if (index >= _workspace.paneCount) return;
    final pane = _workspace.panes[index];
    _afterRecordingLeaves(pane.noteId, () {
      final previous = _selectedId;
      final at = _workspace.panes.indexWhere((open) => open.id == pane.id);
      if (!_workspace.close(at)) return;
      setState(() => _adoptWorkspaceSelection(previous));
      _afterPaneChange();
    });
  }

  PaneDropPlan? _planDrop(NoteDragData data, int index, PaneDropZone zone) {
    if (_specialMode || widget.notes.byId(data.noteId) == null) return null;
    return _workspace.planDrop(data.noteId, index, zone);
  }

  void _dropNote(NoteDragData data, int index, PaneDropZone zone) {
    final plan = _planDrop(data, index, zone);
    if (plan == null) return;
    final target = _workspace.panes[index];
    _afterRecordingLeaves(
      plan.action == PaneDropAction.replace ? target.noteId : null,
      () {
        final previous = _selectedId;
        final at = _workspace.panes.indexWhere((pane) => pane.id == target.id);
        if (!_workspace.drop(data.noteId, at, zone)) return;
        setState(() => _adoptWorkspaceSelection(previous));
        _afterPaneChange();
      },
    );
  }

  /// Previews another note in MRU order while the switching modifier is held.
  /// The final preview is committed and focused by [_handleHardwareKey] when
  /// that modifier is released.
  void _cycleNote(int delta) {
    // Walk the notes most recently opened first, grouped as the sidebar
    // groups them, so pins and shared spaces still lead and one Ctrl+Tab
    // toggles between the last two notes. The list itself keeps its
    // last-edited order.
    final visible = _visibleNotes;
    final opened = widget.prefs.recentlyOpenedNoteIds;
    final byId = {for (final note in visible) note.id: note};
    final openedIds = opened.toSet();
    final switchOrder = SidebarNoteGroups(
      notes: [
        for (final id in opened) ?byId[id],
        for (final note in visible)
          if (!openedIds.contains(note.id)) note,
      ],
      pinnedNoteIds: widget.notes.pinnedNoteIds,
      sharing: widget.account?.sharing,
      specialMode: _specialMode,
      tab: widget.account?.sharing == null || _specialMode ? null : _sidebarTab,
    ).displayOrder;
    final starting = !_noteSwitcher.isActive;
    final next = _noteSwitcher.advance(
      currentId: _selectedId,
      // A note already visible in another pane is still a note the user can
      // switch to. Selecting it activates that pane instead of duplicating it.
      eligibleIds: switchOrder.map((note) => note.id),
      delta: delta,
    );
    if (next == null) return;

    if (starting &&
        !_specialMode &&
        !_usesCompactLayout &&
        _workspace.isSplit) {
      _noteSwitchWorkspace = _workspace.beginPreviewSession();
    }

    final action = delta < 0
        ? ShortcutAction.previousNote
        : ShortcutAction.nextNote;
    _noteSwitchModifier ??= _NoteSwitchModifier.forBinding(
      widget.shortcuts.bindingFor(action),
    );
    _select(
      next,
      focusEditor: false,
      selectionPreview: true,
      workspacePreview: _noteSwitchWorkspace,
    );

    // Settings requires a modifier today, but keeping this fallback makes the
    // controller safe if that policy ever changes or a binding is migrated.
    if (_noteSwitchModifier == null) _commitNoteSwitch();
  }

  /// Observes the modifier independently of whichever editor is mounted. A
  /// preview replaces that editor, so tying key-up to its FocusNode would lose
  /// the exact event that commits the switch.
  bool _handleHardwareKey(KeyEvent event) {
    final modifier = _noteSwitchModifier;
    if (!_noteSwitcher.isActive ||
        modifier == null ||
        event is! KeyUpEvent ||
        !modifier.matches(event.logicalKey) ||
        modifier.isPressed(HardwareKeyboard.instance)) {
      return false;
    }
    _commitNoteSwitch();
    return false;
  }

  void _commitNoteSwitch({bool focusEditor = true}) {
    final id = _noteSwitcher.commit();
    _noteSwitchModifier = null;
    if (id == null) {
      _cancelNoteSwitchPreview();
      return;
    }

    widget.prefs.lastOpenedNoteId = id;
    _recordKapyActivity();
    _reactToSelectedTotal();
    if (_selectedId == id) {
      _commitWorkspacePreview();
      if (focusEditor) _focusSelectedEditorHere();
    } else {
      // A recording may still be flushing before the preview can replace its
      // editor. Its guarded selection callback focuses this committed target
      // when, and only when, that final request lands.
      _committedSwitchAwaitingSelection = (id: id, focusEditor: focusEditor);
    }
  }

  void _commitWorkspacePreview() {
    final preview = _noteSwitchWorkspace;
    _noteSwitchWorkspace = null;
    preview?.commit();
    _scheduleDiscardAbandonedBlanks();
  }

  /// Starts a new note, unless the one already open is a new note.
  ///
  /// Returns whether anything was actually created, which is what the swipe
  /// cue needs in order not to announce a note that does not exist.
  bool _createNote({bool drawing = false, String body = ''}) {
    final recording = widget.recording;
    if (recording != null && recording.isRecording) {
      unawaited(
        recording.finishRecordingAndFlush().then((_) {
          if (mounted) _createNoteNow(drawing: drawing, body: body);
        }),
      );
      // The recording is about to land in the note that is open, so that note
      // will not be blank by the time this runs and a new one will follow.
      return true;
    }
    return _createNoteNow(drawing: drawing, body: body);
  }

  /// What New makes in the space on screen: a drawing in Drawings, a note
  /// everywhere else.
  bool _createInSpace() {
    if (!_tasksMode) return _createNote(drawing: _drawingsOnly);
    _taskAddFocus.requestFocus();
    return true;
  }

  /// A note's name on a task's mark, with its space's after it when it is
  /// shared.
  String _taskNoteLabel(Note note) {
    final space = widget.account?.sharing?.spaceById(note.spaceId);
    return space == null ? note.title : '${note.title} · ${space.name}';
  }

  /// Opens a task's note where it lives, leaving Tasks.
  void _openTaskNote(String id) {
    final note = widget.notes.byId(id);
    final sharing = widget.account?.sharing;
    if (note == null) return;
    _showSpace(
      sharing != null && sidebarTabOf(note, sharing) == SidebarTab.shared
          ? LibrarySpace.shared
          : LibrarySpace.notes,
    );
    _select(id);
  }

  /// [body] is the note's first words, from the ⌘K menu's field.
  bool _createNoteNow({bool drawing = false, String body = ''}) {
    _recordKapyActivity();
    final creatingHidden = _hiddenMode;
    final blank = drawing || body.isNotEmpty ? null : _blankNoteAlreadyOpen();
    if (blank == null && !(_noteLimit?.canCreate ?? true)) {
      unawaited(_explainNoteLimit(creating: true));
      return false;
    }
    final note =
        blank ??
        widget.notes.create(
          body: drawing || body.isNotEmpty ? body : Note.blankBody,
          authored: body.isNotEmpty,
          hidden: creatingHidden,
        );
    if (drawing) widget.notes.setDrawingMode(note.id, drawing: true);
    if (blank == null) {
      _freshNoteIds.add(note.id);
    } else {
      widget.notes.startAsNew(blank.id);
    }
    setState(() {
      _archiveQuery = '';
      _archiveMode = false;
      _tasksMode = false;
      if (!creatingHidden) _hiddenMode = false;
      // A new note is the person's own, so it is listed where they can see
      // it being written.
      _sidebarTab = SidebarTab.mine;
      _drawingsOnly = drawing;
      // And it is written on the page, so a list open over the page goes.
      _listOverlaid = false;
      _setSelectedId(note.id);
    });
    widget.prefs.lastOpenedNoteId = note.id;
    if (!drawing) _focusSelectedEditorAtEnd();
    return blank == null;
  }

  /// The note already on screen, when asking for a new one would only produce
  /// a second one exactly like it.
  ///
  /// An empty note *is* the new note — making another leaves a blank behind on
  /// every device, and the reader has to work out which of the two they are
  /// in. So the caret goes back into this one instead, and the list stops
  /// filling up with notes nobody wrote.
  ///
  /// Three notes are never reused however blank they are. An archived one is
  /// not in the list a new note appears in. A shared one belongs to a space:
  /// "new note" means one of your own, not another empty line in somebody
  /// else's. And a note holding a picture or a recording is not empty, whatever
  /// its text says — [Note.isEmpty] only reads the body.
  Note? _blankNoteAlreadyOpen() {
    if (_archiveMode) return null;
    final id = _selectedId;
    if (id == null) return null;
    final note = widget.notes.byId(id);
    if (note == null || note.isArchived || note.isShared) return null;
    if (note.isHidden != _hiddenMode) return null;
    if (!note.isEmpty || note.attachments.isNotEmpty) return null;
    // A blank canvas was chosen as one: "new note" means a page to write on.
    if (note.isDrawing) return null;
    // Nobody can type into it, so it is not the new note either.
    if (_limitHolds(note)) return null;
    return note;
  }

  /// What the archive shortcut does to the note that is open.
  ///
  /// The rule the notes list follows too: the key does what that note's own
  /// glyph does. In the list it files the note away; in the archive, where
  /// there is nothing left to file, it is the permanent delete — behind the
  /// question that one always asks. Null where no note is open, or where a
  /// shared one is not this reader's to change.
  VoidCallback? get _removeOpenNote {
    final id = _selectedId;
    if (id == null || !_canEditNote(_shownNote(id))) return null;
    return _specialMode
        ? () => unawaited(_deleteNote(id))
        : () => _archiveNote(id);
  }

  void _archiveNote(String id) {
    if (!_canEditNote(widget.notes.byId(id))) return;
    _recordKapyActivity();
    _totalAnimatedFor.remove(id);
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    final index = widget.notes.activeIndexOf(id);
    final archivingSelected = id == _selectedId;
    final closesPane = !_usesCompactLayout && _workspace.isSplit;
    widget.notes.archive(id);
    Toast.show(
      context,
      'Moved to Archive',
      icon: archiveIcon,
      action: 'View',
      onAction: () => _viewArchived(id),
    );
    if (!archivingSelected) return;
    // Its pane closed with it, and the pane beside it has the focus. Opening
    // the next note in the list there would take the place of a note the
    // reader chose to keep on screen.
    if (closesPane) {
      widget.prefs.lastOpenedNoteId = _selectedId;
      _focusSelectedEditorHere();
      return;
    }

    final next = _successorInList(index);
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
    if (_usesCompactLayout && next == null) _scheduleInitialNote();
    _focusSelectedEditorAtEnd();
  }

  /// The note that takes the place of one that just left the list from
  /// [removedIndex] of the store's notes: the next one down that the list on
  /// screen still shows, else the nearest one above it.
  ///
  /// Only what the list shows — the tab, and any search. The store's order
  /// mixes the reader's own notes with other people's, and opening one from
  /// the other tab would put the caret in a note that is not theirs.
  String? _successorInList(int removedIndex) {
    final active = widget.notes.notes;
    if (removedIndex < 0 || active.isEmpty) {
      return widget.notes.successorTo(removedIndex);
    }
    final shown = {for (final note in _visibleNotes) note.id};
    final start = removedIndex.clamp(0, active.length - 1);
    for (var i = start; i < active.length; i++) {
      if (shown.contains(active[i].id)) return active[i].id;
    }
    for (var i = start - 1; i >= 0; i--) {
      if (shown.contains(active[i].id)) return active[i].id;
    }
    return null;
  }

  void _restoreNote(String id) {
    if (!_canEditNote(widget.notes.byId(id))) return;
    _recordKapyActivity();
    final restoringSelected = id == _selectedId;
    final index = _visibleNotes.indexWhere((note) => note.id == id);
    widget.notes.restore(id);
    Toast.show(context, 'Note restored', icon: restoreIcon);
    if (!restoringSelected) return;

    final remaining = _visibleNotes;
    final next = remaining.isEmpty
        ? null
        : remaining[index.clamp(0, remaining.length - 1)].id;
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
  }

  Future<void> _hideNote(String id) async {
    var note = widget.notes.byId(id);
    if (note == null || note.isArchived || note.isHidden || note.isShared) {
      return;
    }
    if (_hiddenAuthBusy) return;
    setState(() => _hiddenAuthBusy = true);
    final configured = await widget.hiddenNotesGate.ensureConfigured(context);
    if (!mounted) return;
    setState(() => _hiddenAuthBusy = false);
    if (!configured) return;

    note = widget.notes.byId(id);
    if (note == null || note.isArchived || note.isHidden || note.isShared) {
      return;
    }
    _recordKapyActivity();
    _totalAnimatedFor.remove(id);
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    final index = widget.notes.activeIndexOf(id);
    final hidingSelected = id == _selectedId;
    final closesPane = !_usesCompactLayout && _workspace.isSplit;
    widget.notes.hide(id);
    final shortcut = widget.shortcuts
        .bindingFor(ShortcutAction.toggleHiddenFolder)
        ?.displayLabel;
    final discovery = AppPlatform.hasPointer && shortcut != null
        ? 'Press $shortcut to find it.'
        : widget.prefs.hiddenFolderVisible
        ? 'Choose Hidden in the notes filter to find it.'
        : 'Show it from Settings to find it.';
    Toast.show(context, 'Moved to Hidden Notes. $discovery', icon: hiddenIcon);
    if (!hidingSelected) return;
    if (closesPane) {
      widget.prefs.lastOpenedNoteId = _selectedId;
      _focusSelectedEditorHere();
      return;
    }
    final next = _successorInList(index);
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
    if (_usesCompactLayout && next == null) _scheduleInitialNote();
    _focusSelectedEditorAtEnd();
  }

  void _unhideNote(String id) {
    final note = widget.notes.byId(id);
    if (note == null || !note.isHidden) return;
    _recordKapyActivity();
    final unhiddenSelected = id == _selectedId;
    final index = _visibleNotes.indexWhere((item) => item.id == id);
    widget.notes.unhide(id);
    Toast.show(context, 'Moved to Notes', icon: unhideIcon);
    if (!unhiddenSelected) return;

    final remaining = _visibleNotes;
    final next = remaining.isEmpty
        ? null
        : remaining[index.clamp(0, remaining.length - 1)].id;
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
  }

  void _togglePinnedNote(String id) {
    _recordKapyActivity();
    final pinned = widget.notes.togglePinned(id);
    if (pinned == null) return;
    Toast.show(
      context,
      pinned ? 'Note pinned' : 'Note unpinned',
      icon: pinned ? KapyIcons.pinRounded : KapyIcons.pinOutlined,
    );
  }

  /// Throws one archived note away for good.
  ///
  /// Guarded by a question, because nothing here can undo it: the note leaves
  /// this device and, through the tombstone, every other one it syncs to. A
  /// note somebody else shares with this account only leaves its own notes.
  Future<void> _deleteNote(String id) async {
    final note = widget.notes.byId(id);
    if (note == null || !_canEditNote(note)) return;
    _recordKapyActivity();
    final title = note.title.trim();
    final name = title.isEmpty ? 'this note' : '"$title"';
    final owner = _sharedBy(note);
    final confirmed = await _confirmDelete(
      title: owner == null ? 'Delete note?' : 'Remove from your notes?',
      body: owner == null
          ? 'Permanently deletes $name from every synced device.'
          : 'Removes $name from your notes on this device. $owner and '
                "everyone it's shared with keep it.",
      action: owner == null ? 'Delete' : 'Remove',
    );
    if (!confirmed || !mounted) return;
    _forget([id]);
    if (owner == null) {
      _announceDeleted(1);
    } else {
      Toast.show(context, 'Removed from your notes', icon: deleteIcon);
    }
  }

  /// Who owns [note]'s shared space, when that is somebody else. Only they
  /// delete it for everyone; here it only leaves this account's notes.
  String? _sharedBy(Note? note) {
    final space = note == null ? null : widget.account?.sharing?.spaceOf(note);
    if (space == null || !space.isTeam || space.isOwner) return null;
    return space.shortNameOf(space.ownerId);
  }

  /// What deleting [ids] from the archive does, said before it happens.
  String _deleteBody(List<String> ids) {
    final theirs = ids
        .where((id) => _sharedBy(widget.notes.byId(id)) != null)
        .length;
    const shared =
        'Notes shared with you are removed from your notes on this device '
        'only, and their owners keep them.';
    if (theirs == 0) {
      return 'Permanently deletes ${_noteCount(ids.length).toLowerCase()} '
          'from every synced device.';
    }
    if (theirs == ids.length) return shared;
    return 'Permanently deletes your own notes from every synced device. '
        '$shared';
  }

  /// Empties the archive.
  Future<void> _deleteAllArchived() async {
    final ids = widget.notes.archivedNotes
        .where((note) => _canEditNote(note))
        .map((note) => note.id)
        .toList();
    if (ids.isEmpty) return;
    _recordKapyActivity();
    final confirmed = await _confirmDelete(
      title: 'Empty Archived Notes?',
      body: _deleteBody(ids),
      action: 'Delete all',
    );
    if (!confirmed || !mounted) return;
    _forget(ids);
    _announceDeleted(ids.length);
  }

  Future<void> _deleteChecked() async {
    final ids = _checkedArchived.toList();
    if (ids.isEmpty) return;
    _recordKapyActivity();
    final confirmed = await _confirmDelete(
      title: ids.length == 1 ? 'Delete note?' : 'Delete ${ids.length} notes?',
      body: _deleteBody(ids),
      action: 'Delete',
    );
    if (!confirmed || !mounted) return;
    _forget(ids);
    _announceDeleted(ids.length);
  }

  void _restoreChecked() {
    final ids = _checkedArchived.toList();
    if (ids.isEmpty) return;
    _recordKapyActivity();
    for (final id in ids) {
      if (_canEditNote(widget.notes.byId(id))) widget.notes.restore(id);
    }
    setState(() {
      _checkedArchived.clear();
      _selectingArchived = false;
      _setSelectedId(_visibleNotes.firstOrNull?.id);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
    Toast.show(
      context,
      ids.length == 1 ? 'Note restored' : '${ids.length} notes restored',
      icon: restoreIcon,
    );
  }

  /// The part every delete shares: take the notes out, drop whatever the
  /// selection and the editor were holding onto, and reclaim the pictures and
  /// recordings nothing refers to any more.
  void _forget(List<String> ids) {
    final removing = ids.toSet();
    for (final id in removing) {
      _totalAnimatedFor.remove(id);
      if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    }
    final losingSelected = removing.contains(_selectedId);
    widget.notes.deleteAll(removing);
    setState(() {
      _checkedArchived.removeAll(removing);
      if (_checkedArchived.isEmpty) _selectingArchived = false;
      if (losingSelected) _setSelectedId(_visibleNotes.firstOrNull?.id);
    });
    if (losingSelected) widget.prefs.lastOpenedNoteId = _selectedId;
    // The notes are gone, so their attachments have no owner. See
    // [NotesStore.sweepBlobs] for why this is the only place that counts.
    unawaited(widget.notes.sweepBlobs());
  }

  void _announceDeleted(int count) {
    if (!mounted) return;
    Toast.show(
      context,
      count == 1 ? 'Note deleted' : '$count notes deleted',
      icon: deleteIcon,
    );
  }

  static String _noteCount(int count) =>
      count == 1 ? 'This note' : 'These $count notes';

  /// One question, asked the same way every time, with the destructive answer
  /// marked as one.
  Future<bool> _confirmDelete({
    required String title,
    required String body,
    required String action,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            body,
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
            key: const ValueKey('confirm-delete'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(action),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  void _toggleChecked(String id) {
    setState(() {
      if (!_checkedArchived.remove(id)) _checkedArchived.add(id);
    });
  }

  void _checkAllArchived() =>
      setState(() => _checkedArchived.addAll(_visibleNotes.map((n) => n.id)));

  void _startSelecting() => setState(() => _selectingArchived = true);

  void _cancelSelecting() => setState(() {
    _selectingArchived = false;
    _checkedArchived.clear();
  });

  void _toggleArchive() {
    _recordKapyActivity();
    setState(() {
      final entering = !_archiveMode;
      _archiveMode = entering;
      _hiddenMode = false;
      _selectingArchived = false;
      _checkedArchived.clear();
      _archiveQuery = '';
      if (entering) {
        _setSelectedId(_narrowed(widget.notes.archivedNotes).firstOrNull?.id);
      } else {
        final previous = _selectedId;
        _workspace.reconcile(
          widget.notes.notes.map((note) => note.id),
          fallbackId: widget.notes.notes.firstOrNull?.id,
        );
        _adoptWorkspaceSelection(previous);
      }
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
  }

  /// The archive toast's View: Notes with Archive chosen, on the note that
  /// was just filed there.
  void _viewArchived(String id) {
    if (!mounted || !(widget.notes.byId(id)?.isArchived ?? false)) return;
    _showSpace(LibrarySpace.notes);
    _toggleArchive();
    setState(() => _setSelectedId(id));
    widget.prefs.lastOpenedNoteId = id;
  }

  Future<void> _toggleHiddenNotes() async {
    _recordKapyActivity();
    if (_hiddenMode) {
      _leaveHiddenNotes();
      return;
    }
    if (_hiddenAuthBusy) return;
    setState(() => _hiddenAuthBusy = true);
    final unlocked = await widget.hiddenNotesGate.unlock(context);
    if (!mounted) return;
    setState(() => _hiddenAuthBusy = false);
    if (!unlocked) return;

    setState(() {
      _archiveMode = false;
      _hiddenMode = true;
      _selectingArchived = false;
      _checkedArchived.clear();
      _archiveQuery = '';
      _setSelectedId(_narrowed(widget.notes.hiddenNotes).firstOrNull?.id);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
  }

  void _leaveHiddenNotes() {
    if (!_hiddenMode || !mounted) return;
    final previous = _selectedId;
    setState(() {
      _hiddenMode = false;
      _archiveQuery = '';
      _workspace.reconcile(
        widget.notes.notes.map((note) => note.id),
        fallbackId: widget.notes.notes.firstOrNull?.id,
      );
      _adoptWorkspaceSelection(previous);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
    if (_usesCompactLayout && widget.notes.isEmpty) _scheduleInitialNote();
  }

  /// The Hidden Notes shortcut: Notes with Hidden chosen, behind its gate,
  /// whether or not the filter lists Hidden; or, from Hidden, back out.
  Future<void> _toggleHiddenFromShortcut() async {
    if (_hiddenMode) return _leaveHiddenNotes();
    await _toggleHiddenNotes();
    if (!mounted || !_hiddenMode) return;
    setState(() {
      _tasksMode = false;
      _drawingsOnly = false;
      _sidebarTab = SidebarTab.mine;
    });
  }

  /// Chooses which notes the list shows, from the notes filter.
  void _setShow(NotesShow show) {
    _pinnedOnly = false;
    switch (show) {
      case NotesShow.all:
        if (_archiveMode) _toggleArchive();
        if (_hiddenMode) _leaveHiddenNotes();
      case NotesShow.archive:
        if (!_archiveMode) _toggleArchive();
      case NotesShow.hidden:
        if (!_hiddenMode) unawaited(_toggleHiddenNotes());
    }
  }

  /// The filter's ✕: All notes, every kind of media ticked. Hidden locks
  /// again on the way out.
  void _clearFilter() {
    _setShow(NotesShow.all);
    setState(() {
      _mediaFilter = NoteMedia.values.toSet();
      _tagFilter = const TagFilter();
    });
  }

  /// The tags the lists offer, in the person's order, each with how many
  /// notes carry it: the archived ones in Archive, and otherwise the rest,
  /// with Hidden's only while Hidden is open. While it is locked no Hidden
  /// note counts and a tag found only on Hidden notes is left out, so
  /// neither gives Hidden away.
  List<TagEntry> _listedTags() {
    final store = widget.tags;
    if (store == null) return const [];
    final notes = widget.notes;
    final counted = _countedNoteIds();
    final open = {
      ...counted,
      for (final note in [...notes.notes, ...notes.archivedNotes]) note.id,
    };
    final counts = <String, int>{};
    final seen = <String>{};
    final shown = <String>{};
    for (final noteId in store.noteIds) {
      for (final tag in store.tagsOf(noteId)) {
        seen.add(tag.id);
        if (open.contains(noteId)) shown.add(tag.id);
        if (counted.contains(noteId)) {
          counts.update(tag.id, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    return [
      for (final tag in store.tags)
        if (!seen.contains(tag.id) || shown.contains(tag.id))
          (tag: tag, count: counts[tag.id] ?? 0),
    ];
  }

  /// The notes a tag's count counts: the archived ones in Archive, and
  /// otherwise the rest, with Hidden's only while Hidden is open.
  Set<String> _countedNoteIds() => {
    for (final note
        in _archiveMode
            ? widget.notes.archivedNotes
            : [
                ...widget.notes.notes,
                if (_hiddenMode) ...widget.notes.hiddenNotes,
              ])
      note.id,
  };

  /// How many of those carry no tag, for No tag.
  int _untaggedCount() => _countedNoteIds()
      .where((noteId) => widget.tags!.tagsOf(noteId).isEmpty)
      .length;

  /// The tag filter as far as the listed tags go.
  TagFilter get _tagsNarrowed =>
      _tagFilter.within([for (final entry in _listedTags()) entry.tag.id]);

  /// A chip's tap: the list, narrowed to that tag alone.
  void _filterToTag(String tagId) {
    setState(() => _tagFilter = TagFilter(ids: {tagId}));
    if (!_listShown) _setListShown(true);
  }

  /// The person's tags around [child], or null where there are none.
  TagShelf? _tagShelf(Widget child) {
    final store = widget.tags;
    if (store == null) return null;
    return TagShelf(
      store: store,
      listed: _listedTags,
      untagged: _untaggedCount,
      isShared: (noteId) => widget.notes.byId(noteId)?.isShared ?? false,
      onFilter: _filterToTag,
      child: child,
    );
  }

  Widget _withTags(Widget child) {
    final store = widget.tags;
    if (store == null) return child;
    return ListenableBuilder(
      listenable: store,
      child: child,
      builder: (context, child) => TagShelf(
        store: store,
        listed: _listedTags,
        untagged: _untaggedCount,
        isShared: (noteId) => widget.notes.byId(noteId)?.isShared ?? false,
        onFilter: _filterToTag,
        child: TagMarks(
          marksOf: (noteId) => [
            for (final tag in store.tagsOf(noteId)) tagMarkOf(tag),
          ],
          child: child!,
        ),
      ),
    );
  }

  /// Whether opening [note] should place the cursor at its end and raise the
  /// keyboard.
  ///
  /// True of every note but an untouched welcome note, which is there to be
  /// read: jumping to the bottom of it and covering the rest with a keyboard
  /// would show a first-time reader the one part that says nothing.
  bool _readyToTypeIn(Note note) =>
      _canWriteNote(note) &&
      !_editorFocusSuppressed &&
      widget.prefs.readyToTypeOnOpen &&
      note.id != _untouchedWelcomeId;

  /// Where opening [note] should put the caret, or null to start a fresh
  /// session at the end of it.
  ///
  /// Only when the note would have been focused at all: a caret restored into
  /// an editor nobody is typing in is a caret nobody can see, and the "Ready
  /// to type on open" switch is the one that decides that.
  int? _resumeCaretIn(Note note) =>
      _readyToTypeIn(note) ? widget.prefs.caretIn(note.id) : null;

  bool _canEditNote(Note? note) {
    if (note == null) return false;
    if (!note.isShared) return true;
    return widget.account?.sharing?.canEdit(note) ?? false;
  }

  int _videoAttachmentMaxBytes(Note note) {
    final account = widget.account;
    final space = account?.sharing?.spaceById(note.spaceId);
    // The account entitlement is freshest for a space this user owns, notably
    // immediately after an in-app upgrade. For somebody else's space, their
    // owner-paid limit comes only from the space response.
    return resolveAttachmentMaxBytes(
      accountUserId: account?.user?.id,
      spaceOwnerId: space?.ownerId,
      accountMaxBytes: account?.billing?.entitlements?.attachmentMaxBytes,
      spaceMaxBytes: space?.attachmentMaxBytes,
    );
  }

  NoteLimit? get _noteLimit => widget.account?.noteLimit;

  /// Whether [note]'s content may change: [_canEditNote], and not held
  /// read-only by the note limit. Archiving, restoring and deleting ask only
  /// [_canEditNote] — deleting is the way back under the limit, so a note the
  /// limit holds must never lose it.
  bool _canWriteNote(Note? note) => _canEditNote(note) && !_limitHolds(note!);

  bool _limitHolds(Note note) => _noteLimit?.isLocked(note) ?? false;

  /// Says why the note limit stopped something, and goes where the answer
  /// points: the Pro sheet, or the account pane to sign in first.
  Future<void> _explainNoteLimit({required bool creating}) async {
    final limit = _noteLimit?.limit;
    if (limit == null) return;
    final billing = widget.account?.billing;
    final wantsPro = await showNoteLimitDialog(
      context,
      limit: limit,
      creating: creating,
      canBuy: billing?.canPurchase ?? false,
    );
    if (!mounted || !wantsPro || billing == null) return;
    unawaited(showProSheet(context, billing: billing));
  }

  final DateTime _openedAt = DateTime.now();

  /// The one quiet suggestion for an account from before recovery keys: a
  /// toast, once, never in the first minute and never while somebody is
  /// typing. If the moment does not come, the next change of state tries
  /// again; Settings → Sync keeps the row until a key exists.
  void _offerRecoveryKey() {
    final account = widget.account;
    if (!mounted || account == null || !account.offersRecoveryNudge) return;
    if (DateTime.now().difference(_openedAt) < const Duration(minutes: 1)) {
      return;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.findAncestorWidgetOfExactType<EditableText>() != null) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    account.recoveryNudgeShown();
    Toast.show(
      context,
      'Add a recovery key, so a forgotten passphrase never locks you out.',
      action: 'Set up',
      onAction: () =>
          showKeyChangeDialog(context, account, KeyProofAction.recoveryKey),
    );
  }

  void _onNoteLimitChanged() {
    if (mounted) setState(() {});
  }

  void _updateDocument(
    String id,
    String body,
    List<NoteFormatRange> formats,
    List<NoteAttachmentRef> attachments,
    TextEdit? edit,
  ) {
    if (!_canWriteNote(widget.notes.byId(id))) return;
    _recordKapyActivity();
    widget.account?.sync?.reportTyping(id);
    // Typed in, so it is theirs now. Assigned rather than set: the editor
    // holding the cursor is already mounted, and nothing on screen changes
    // until it is next built.
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    widget.notes.updateDocument(id, body, formats, attachments, edit);
    _namer?.typed(id);
  }

  NoteNamer? _namer;

  /// Whether the namer may give [note] a title: this device may write it,
  /// nobody else is in it, and the person is not in its title themselves.
  bool _mayNameNote(Note note) =>
      _canWriteNote(note) &&
      !(_mountedEditorFor(note.id)?.selectionInTitle ?? false) &&
      (!note.isShared ||
          (widget.account?.sync?.caretsFor(note.id).isEmpty ?? true));

  /// The note as the store holds it this instant. An editor reads it on
  /// every edit: another device's words reach the store before the page has
  /// rebuilt around them, and an edit written without them would delete them.
  StoredNoteDocument? _storedDocument(String id) {
    final note = widget.notes.byId(id);
    return note == null
        ? null
        : (
            body: note.body,
            formats: note.formats,
            attachments: note.attachments,
          );
  }

  void _publishPreparedImage(
    String noteId,
    NoteImageRef staged,
    NoteImageRef prepared,
  ) {
    widget.notes.updateAttachment(
      noteId,
      staged.hash,
      (current) => current is NoteImageRef
          ? prepared.copyWith(
              offset: current.offset,
              widthFactor: current.widthFactor,
            )
          : current,
      key: staged.key,
      touch: true,
    );
  }

  /// Where this device's caret is in a shared note, for the people in it.
  /// A personal note has nobody to tell, and costs nothing here.
  void _reportPresence(
    String id,
    TextSelection selection,
    String text, {
    required bool edited,
  }) {
    final sync = widget.account?.sync;
    if (sync == null || !(widget.notes.byId(id)?.isShared ?? false)) return;
    if (!selection.isValid) {
      sync.reportPresence(id, edited: edited);
      return;
    }
    sync.reportPresence(
      id,
      base: selection.baseOffset,
      extent: selection.extentOffset,
      text: text,
      edited: edited,
    );
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

  /// The editable chord shown on the notes-list button in both layouts.
  String? get _sidebarShortcut =>
      widget.shortcuts.bindingFor(ShortcutAction.toggleSidebar)?.displayLabel;

  /// The editable chord taught beside the direct Settings action.
  String? get _settingsShortcut =>
      widget.shortcuts.bindingFor(ShortcutAction.openSettings)?.displayLabel;

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

  /// Shares whatever note is open, for the title bar's own action. Null with
  /// nothing selected, which greys that action rather than removing it and
  /// shifting the ones beside it every time the selection changes.
  VoidCallback? get _shareSelected {
    final id = _selectedId;
    return id == null || _specialMode || _shownNote(id) == null
        ? null
        : () => _shareNote(id);
  }

  /// Everyone the open note is shared with, for the avatars in the title bar.
  /// Empty on a personal note, and while the account is still locked: there is
  /// no roster to read until the keyring is open.
  List<SpaceMember> get _selectedMembers {
    final note = _shownNote(_selectedId);
    final sharing = widget.account?.sharing;
    if (note == null || !note.isShared || sharing == null) return const [];
    return sharing.spaceById(note.spaceId)?.members ?? const [];
  }

  /// Switches the sidebar between the person's own notes and other people's.
  /// The open note stays open: a tab is a way of looking at the list, not a
  /// choice of note.
  void _setSidebarTab(SidebarTab tab) {
    if (tab == _sidebarTab) return;
    setState(() => _sidebarTab = tab);
  }

  /// Opens a shared space's people from its heading in the notes list.
  void _openSpace(String spaceId) {
    final sharing = widget.account?.sharing;
    if (sharing == null) return;
    _recordKapyActivity();
    unawaited(showSpaceDialog(context, spaceId: spaceId, sharing: sharing));
  }

  /// Whoever else has the open note up right now.
  List<Collaborator> get _selectedPresence {
    final id = _selectedId;
    final sync = widget.account?.sync;
    if (id == null || sync == null || _shownNote(id) == null) return const [];
    return sync.collaboratorsIn(id);
  }

  /// Opens the share sheet for a note. Before the account is unlocked there
  /// is no key to share with, so Account & sync opens instead, on whatever
  /// step is missing, and says that step is why it opened.
  void _shareNote(String id) {
    _recordKapyActivity();
    final note = widget.notes.byId(id);
    final account = widget.account;
    final sharing = account?.sharing;
    if (note == null || note.isHidden || note.isArchived) return;
    if (account == null) {
      // A build with no sync at all has nobody to sign in as.
      _showSettings();
      return;
    }
    if (sharing == null) {
      _showSettings(
        section: SettingsSection.account,
        notice: _stepBeforeSharing(account.state),
      );
      return;
    }
    unawaited(showShareDialog(context, note: note, sharing: sharing));
  }

  /// What stands between this account and sharing, as the step Account & sync
  /// is about to show.
  static String _stepBeforeSharing(AccountState state) => switch (state) {
    AccountState.needsProfile => 'Choose your name first to share this note',
    AccountState.needsPassphrase =>
      'Choose a passphrase first to share this note',
    AccountState.locked => 'Unlock first to share this note',
    AccountState.needsAccountDecision =>
      'Finish signing in first to share this note',
    AccountState.restoring ||
    AccountState.signedOut ||
    AccountState.ready => 'Sign in first to share this note',
  };

  /// Whether Kapy AI's panel is open, and the note it was opened from.
  final _kapyPanel = KapyAiPanelController();

  /// Kapy AI, only where the build carries it.
  KapyAi? get _kapyAi => kapyAiAvailable ? widget.kapyAi : null;

  /// A note's title for the panel, or null for one it may not name: gone,
  /// or hidden, since Hidden notes never reach Kapy AI.
  String? _kapyNoteTitle(String id) {
    final note = widget.notes.byId(id);
    return note == null || note.isHidden ? null : note.title;
  }

  /// The button beside the pin and ⌘J: the panel beside the page, or the
  /// sheet on a phone. Opened from a note, it carries that note's chip.
  void _toggleKapyAi() {
    if (!_usesCompactLayout && _kapyPanel.isOpen) {
      _kapyPanel.close();
      return;
    }
    _openKapyAi();
  }

  /// Whether Kapy AI is there to be asked: in this build, and switched on.
  bool get _kapyAiOn => _kapyAi?.enabled ?? false;

  bool _kapyAiWasOn = false;

  /// The search fields' words follow the Settings switch, so they are drawn
  /// again when it changes.
  void _onKapyAi() {
    if (_kapyAiOn == _kapyAiWasOn) return;
    setState(() => _kapyAiWasOn = _kapyAiOn);
  }

  /// What the search fields read: they offer to ask Kapy AI only while it
  /// can be asked.
  String get _searchPlaceholder =>
      _kapyAiOn ? 'Search or Ask Kapy AI' : 'Search';

  /// Opens the panel, or the phone's sheet, from the note on screen so its
  /// chip is attached. With [question] it first starts a new chat and asks
  /// it there, which is how ⌘K's Ask row and its Tab reach Kapy AI.
  void _openKapyAi({String? question}) {
    final ai = _kapyAi;
    if (ai == null || !ai.enabled) return;
    final shown = _shownNote(_selectedId)?.id;
    final noteId = shown != null && _kapyNoteTitle(shown) != null
        ? shown
        : null;
    final draft = question != null && ai.answering ? question : null;
    if (question != null && draft == null) {
      ai.newChat();
      unawaited(ai.ask(question, noteId: noteId));
    }
    if (!_usesCompactLayout) {
      _kapyPanel.open(noteId: noteId, draft: draft);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _kapyPanel.open(noteId: noteId, draft: draft);
    unawaited(
      showKapyAiSheet(
        context,
        panel: (close) => _kapyAiPanel(
          ai,
          onClose: close,
          onOpenNote: (id) {
            close();
            _select(id);
          },
        ),
      ).whenComplete(_kapyPanel.close),
    );
  }

  Widget _kapyAiPanel(
    KapyAi ai, {
    required VoidCallback onClose,
    required ValueChanged<String> onOpenNote,
  }) => KapyAiPanel(
    kapyAi: ai,
    controller: _kapyPanel,
    noteTitle: _kapyNoteTitle,
    onOpenNote: onOpenNote,
    onManageAccounts: () => _showSettings(
      section: SettingsSection.voice,
      reveal: ai.accounts.isEmpty
          ? 'kapy-ai-toggle'
          : kapyAccountRowId(ai.accounts.first.kind),
    ),
    onClose: onClose,
    shortcut: AppPlatform.isDesktop
        ? widget.shortcuts.bindingFor(ShortcutAction.toggleKapyAi)?.keycapLabel
        : null,
    now: widget.notes.now,
  );

  /// The page with Kapy AI's panel beside it or over it, while it is open.
  Widget _withKapyAi(Widget page) {
    final ai = _kapyAi;
    if (ai == null) return page;
    return KapyAiDock(
      kapyAi: ai,
      controller: _kapyPanel,
      panel: _kapyAiPanel(ai, onClose: _kapyPanel.close, onOpenNote: _select),
      child: page,
    );
  }

  /// The Sparkles button for a toolbar, or null where Kapy AI is not built.
  Widget? _kapyAiButton({required double extent, required double gap}) {
    final ai = _kapyAi;
    if (ai == null) return null;
    return KapyAiToolbarButton(
      kapyAi: ai,
      controller: _kapyPanel,
      onPressed: _toggleKapyAi,
      shortcut: widget.shortcuts
          .bindingFor(ShortcutAction.toggleKapyAi)
          ?.displayLabel,
      extent: extent,
      trailingGap: gap,
    );
  }

  /// [notice] is said as a toast once settings is on screen, for whatever
  /// sent the person there rather than their own tap on the gear. [reveal]
  /// is the row it opens scrolled to.
  void _showSettings({
    SettingsSection? section,
    String? notice,
    String? reveal,
  }) {
    if (_settingsOpen) return;
    if (AppPlatform.isMobile) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _settingsOpen = true);
    }
    unawaited(_openSettings(section, notice, reveal));
  }

  Future<void> _openSettings(
    SettingsSection? section,
    String? notice,
    String? reveal,
  ) async {
    try {
      await showSettings(
        context,
        section: section,
        notice: notice,
        reveal: reveal,
        kapyAi: _kapyAi,
        namer: _namer,
        account: widget.account,
        notes: widget.notes,
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        rates: widget.rates,
        updates: widget.updates,
        desktopIntegration: widget.desktopIntegration,
        voicePrefs: widget.voicePrefs,
        localModels: widget.localModels,
        deviceSummarizer: widget.deviceSummarizer,
        deviceTranscriber: widget.deviceTranscriber,
        onTranscriptionReady: _resumeTranscriptionsFromSettings,
        cloudAccess: widget.cloudAccess,
        hiddenNotes: widget.hiddenNotesGate,
        tags: widget.tags,
        listedTags: _listedTags,
      );
    } finally {
      if (mounted && _settingsOpen) setState(() => _settingsOpen = false);
    }
  }

  void _focusSelectedEditorAtEnd() {
    // Not into a welcome note nobody has typed into — including on the way
    // out of the notes drawer, which is how settings is reached on a phone
    // and would otherwise answer "open the welcome note" with a keyboard over
    // the bottom half of it.
    if (_editorFocusSuppressed ||
        (_selectedId != null && _selectedId == _untouchedWelcomeId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editorFocusSuppressed) return;
      _selectedEditor?.focusAtEnd();
    });
  }

  /// Right Arrow comes after the sidebar's selection frame, so its editor is
  /// already mounted and can take the caret immediately. Unlike the deferred
  /// helper above, this does not depend on another frame being scheduled.
  void _enterSelectedEditorFromSidebar() {
    _dismissListOverlay();
    if (_editorFocusSuppressed ||
        (_selectedId != null && _selectedId == _untouchedWelcomeId)) {
      return;
    }
    final id = _selectedId;
    if (id != null) {
      _cancelNoteSwitchPreview();
      widget.prefs.lastOpenedNoteId = id;
      _recordKapyActivity();
      _reactToSelectedTotal();
    }
    _selectedEditor?.focusHere();
  }

  void _focusSelectedEditorHere() {
    if (_editorFocusSuppressed ||
        (_selectedId != null && _selectedId == _untouchedWelcomeId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_editorFocusSuppressed) _selectedEditor?.focusHere();
    });
  }

  /// Whether Hidden is listed in the notes filter and in Go to: while the
  /// setting that shows it is on and something is in it, and while it is
  /// open.
  bool get _hiddenReachable =>
      _hiddenMode ||
      (widget.prefs.hiddenFolderVisible && widget.notes.hiddenNotes.isNotEmpty);

  /// The notes filter and the list/cards switch, for the list beside the
  /// rail. A phone's drawer has the filter alone, as its list has no cards.
  Widget _notesControls(LibrarySpace space, {bool cards = true}) =>
      NotesListControls(
        show: _show,
        offersShow: space != LibrarySpace.shared,
        onShowChanged: _setShow,
        hiddenListed: _hiddenReachable,
        hiddenShortcut: widget.shortcuts
            .bindingFor(ShortcutAction.toggleHiddenFolder)
            ?.displayLabel,
        archivedCount: _narrowed(widget.notes.archivedNotes).length,
        media: space == LibrarySpace.drawings ? null : _mediaFilter,
        onMediaChanged: (media) => setState(() => _mediaFilter = media),
        onClear: _clearFilter,
        tags: widget.tags == null ? null : _tagsNarrowed,
        onTagsChanged: (tags) => setState(() => _tagFilter = tags),
        cards: widget.prefs.noteCards,
        onCardsChanged: cards
            ? (cards) => widget.prefs.noteCards = cards
            : null,
      );

  /// Opens the ⌘K menu over whatever is on screen, and does what was chosen.
  Future<void> _openCommandMenu() async {
    _recordKapyActivity();
    final choice = await showCommandMenu(
      context,
      notes: widget.notes,
      shortcuts: widget.shortcuts,
      space: _space,
      destinations: [
        LibrarySpace.notes,
        if (_taskController != null) LibrarySpace.tasks,
        LibrarySpace.drawings,
        if (widget.account?.sharing != null) LibrarySpace.shared,
      ],
      recentIds: widget.prefs.recentlyOpenedNoteIds,
      displayTime: widget.prefs.displayTime,
      taskLabel: _taskNoteLabel,
      tasks: _taskController?.read(),
      showHidden: _hiddenReachable,
      hiddenUnlocked: _hiddenMode,
      askKapyAi: _kapyAiOn,
      tags: _tagShelf(const SizedBox.shrink()),
      marksOf: widget.tags == null
          ? null
          : (noteId) => [
              for (final tag in widget.tags!.tagsOf(noteId)) tagMarkOf(tag),
            ],
      tagNote: _tasksMode ? null : _shownNote(_selectedId),
      settingsIndex: (lend) => SettingsDialog(
        onIndex: lend,
        kapyAi: _kapyAi,
        namer: _namer,
        account: widget.account,
        notes: widget.notes,
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        rates: widget.rates,
        updates: widget.updates,
        desktopIntegration: widget.desktopIntegration,
        voicePrefs: widget.voicePrefs,
        localModels: widget.localModels,
        deviceSummarizer: widget.deviceSummarizer,
        deviceTranscriber: widget.deviceTranscriber,
        cloudAccess: widget.cloudAccess,
        hiddenNotes: widget.hiddenNotesGate,
      ),
    );
    if (!mounted || choice == null) return;
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState!.closeDrawer();
    }
    _dismissListOverlay();
    switch (choice) {
      case OpenNoteChoice(:final note):
        if (note.isHidden) {
          _select(note.id);
        } else if (note.isDrawing) {
          _showSpace(LibrarySpace.drawings);
          _select(note.id);
        } else {
          _openTaskNote(note.id);
        }
      case OpenTaskChoice(:final task):
        _showSpace(LibrarySpace.tasks);
        setState(() => _taskFilter = TaskFilter.note(task.note.id));
      case NewNoteChoice(:final text):
        _createNote(body: text);
      case NewTaskChoice(:final text):
        _newTask(text);
      case NewDrawingChoice():
        _createNote(drawing: true);
      case GoToChoice(:final space):
        _showSpace(space);
      case ShowNotesChoice(:final show):
        _showNotes(show);
      case FilterTagChoice(:final tagId):
        if (_space != LibrarySpace.notes && _space != LibrarySpace.drawings) {
          _showSpace(LibrarySpace.notes);
        }
        final filter = _tagsNarrowed;
        setState(
          () => _tagFilter = filter.copyWith(ids: {...filter.ids, tagId}),
        );
        if (!_listShown) _setListShown(true);
      case OpenSettingsChoice():
        _showSettings();
      case RevealSettingChoice(:final section, :final reveal):
        _showSettings(section: section, reveal: reveal);
      case SearchArchiveChoice(:final query):
        _showNotes(NotesShow.archive);
        setState(() => _archiveQuery = query);
      case AskKapyAiChoice(:final text):
        _openKapyAi(question: text);
    }
  }

  /// Opens Tasks to add [text] to the end of the list, or, with no text, on
  /// its add row.
  void _newTask([String text = '']) {
    final tasks = _taskController;
    if (tasks == null) return;
    _showSpace(LibrarySpace.tasks);
    if (text.isNotEmpty) {
      unawaited(tasks.add(text));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _taskAddFocus.requestFocus();
    });
  }

  /// Narrows [notes] to the space the list is showing. The ordinary list is
  /// split by whose the notes are once there is an account to have shared
  /// anything with, or narrowed to drawings from the rail, and everything that
  /// walks the list (the arrow keys, the note after an archived one) walks
  /// what is on screen. Drawings keeps to drawings in the archive and Hidden
  /// Notes too; from Notes, both hold every note of theirs.
  List<Note> _narrowed(List<Note> notes) {
    if (_drawingsOnly) {
      return [
        for (final note in notes)
          if (note.isDrawing) note,
      ];
    }
    if (_specialMode) return notes;
    final sharing = widget.account?.sharing;
    if (sharing == null) return notes;
    return [
      for (final note in notes)
        if (sidebarTabOf(note, sharing) == _sidebarTab) note,
    ];
  }

  /// The space the rail shows as open.
  LibrarySpace get _space => _tasksMode
      ? LibrarySpace.tasks
      : _drawingsOnly
      ? LibrarySpace.drawings
      : widget.account?.sharing != null && _sidebarTab == SidebarTab.shared
      ? LibrarySpace.shared
      : LibrarySpace.notes;

  /// Which notes the filter shows.
  NotesShow get _show => _archiveMode
      ? NotesShow.archive
      : _hiddenMode
      ? NotesShow.hidden
      : NotesShow.all;

  /// What the list is called over it and in the editor's toolbar: the space,
  /// or Hidden or Archive while the filter has one chosen.
  String get _listTitle => _specialMode ? _show.label : _space.title;

  /// [notes] narrowed to the space and to the media the filter has ticked.
  /// Drawings has no media filter: every item in it is a drawing.
  List<Note> _filtered(List<Note> notes) {
    final tags = widget.tags;
    final byTag = tags == null ? const TagFilter() : _tagsNarrowed;
    final byMedia =
        !_drawingsOnly && _mediaFilter.length < NoteMedia.values.length;
    return [
      for (final note in _narrowed(notes))
        if ((!byMedia || NoteMedia.shows(note, _mediaFilter)) &&
            (!byTag.narrowed ||
                byTag.matches([
                  for (final tag in tags!.tagsOf(note.id)) tag.id,
                ])))
          note,
    ];
  }

  /// How many notes match the filter, for the bar over the list, whatever
  /// the search has narrowed the list to.
  int get _matchingCount => _filtered(
    _archiveMode
        ? widget.notes.archivedNotes
        : _hiddenMode
        ? widget.notes.hiddenNotes
        : widget.notes.notes,
  ).length;

  /// Opens [space] from the rail with nothing narrowed, the way the tabs it
  /// replaces did. Choosing the space already open is how the list goes back
  /// to All notes, as the filter's ✕ does.
  void _showSpace(LibrarySpace space) {
    _pinnedOnly = false;
    _clearFilter();
    setState(() {
      _tasksMode = space == LibrarySpace.tasks;
      _drawingsOnly = space == LibrarySpace.drawings;
      _sidebarTab = space == LibrarySpace.shared
          ? SidebarTab.shared
          : SidebarTab.mine;
      if (_tasksMode || _specialMode || _usesCompactLayout) return;
      final open = widget.notes.byId(_selectedId);
      final parked = widget.notes.byId(_noteBeforeSpace);
      if (parked != null && _selectedId == _openedBySpace && _inSpace(parked)) {
        _noteBeforeSpace = _openedBySpace = null;
        _setSelectedId(parked.id);
        return;
      }
      if (open == null || _inSpace(open)) return;
      _noteBeforeSpace = open.id;
      _openedBySpace = null;
      final first = _visibleNotes.firstOrNull;
      if (first == null) return;
      _openedBySpace = first.id;
      _setSelectedId(first.id);
    });
  }

  /// Whether [note] belongs to the space on screen, so the page only ever
  /// holds an item of the section the list is showing. The note a space
  /// does not hold stays open underneath, and comes back with its space.
  bool _inSpace(Note note) =>
      _mayRevealInCurrentCollection(note) &&
      (_tasksMode || _specialMode || _narrowed([note]).isNotEmpty);

  /// The note on the page, or null where there is none or it is in another
  /// space.
  Note? _shownNote(String? id) {
    final note = widget.notes.byId(id);
    return note != null && _inSpace(note) ? note : null;
  }

  /// My notes with the filter on [show], as Go to and its key open Hidden
  /// and Archive.
  void _showNotes(NotesShow show) {
    if (_space != LibrarySpace.notes) _showSpace(LibrarySpace.notes);
    _setShow(show);
  }

  List<Note> get _visibleNotes {
    final notes = _filtered(
      _archiveMode
          ? widget.notes.searchArchived(_archiveQuery)
          : _hiddenMode
          ? widget.notes.hiddenNotes
          : widget.notes.search(''),
    );
    if (!_showingPinnedOnly) return notes;
    final pinned = widget.notes.pinnedNoteIds;
    return [
      for (final note in notes)
        if (pinned.contains(note.id)) note,
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Keep LayoutBuilder as the first render object: the app's whole-window
    // golden harness captures this boundary directly.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            AppPlatform.isMobile && constraints.maxWidth < kTwoPaneBreakpoint;
        final page = _withTags(
          compact ? _buildCompact(context) : _buildWide(context),
        );
        final gesturePage = AppPlatform.isDesktop
            ? SidebarSwipe(
                sidebarVisible: _listShown,
                onToggle: _toggleList,
                child: page,
              )
            : page;
        final content = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _recordKapyActivity(),
          child: gesturePage,
        );

        if (!AppPlatform.isDesktop) return content;
        return ListenableBuilder(
          listenable: widget.shortcuts,
          builder: (context, _) => _DesktopShortcuts(
            focusNode: _desktopShortcutFocus,
            shortcuts: widget.shortcuts,
            onNewNote: _createInSpace,
            onCompleteTask: _tasksMode
                ? () => _tasksPage.currentState?.completeDoNow()
                : null,
            onSearch: _openCommandMenu,
            onNewTask: _taskController == null ? null : _newTask,
            onNewDrawing: () => _createNote(drawing: true),
            onShowSpace: _showSpace,
            onShowArchive: () => _showNotes(NotesShow.archive),
            showsTasks: _taskController != null,
            showsShared: widget.account?.sharing != null,
            onNextNote: () => _cycleNote(1),
            onPreviousNote: () => _cycleNote(-1),
            onSplitEditor: _specialMode || !_workspace.canSplit
                ? null
                : _splitEditor,
            // Unbound with a single pane, so the chord closes nothing at all
            // rather than something the reader did not mean it to.
            onClosePane: _specialMode || !_workspace.isSplit
                ? null
                : () => _closePane(_workspace.activePane),
            onFocusPane: [
              for (var index = 0; index < EditorWorkspace.maxPanes; index++)
                _specialMode || index >= _workspace.paneCount
                    ? null
                    : () => _focusPane(index),
            ],
            onOpenSettings: _showSettings,
            onIncreaseEditorTextSize: widget.prefs.increaseEditorTextSize,
            onDecreaseEditorTextSize: widget.prefs.decreaseEditorTextSize,
            onResetEditorTextSize: widget.prefs.resetEditorTextSize,
            onInsertImage: () => unawaited(
              _selectedEditor?.pickAndInsertImages() ?? Future<void>.value(),
            ),
            onRecordVoice: () => unawaited(_startVoiceRecording()),
            onToggleSidebar: _toggleList,
            onToggleHiddenFolder: () => unawaited(_toggleHiddenFromShortcut()),
            onToggleResults: widget.prefs.toggleResults,
            onToggleAlwaysOnTop: AppPlatform.isDesktop
                ? widget.prefs.toggleAlwaysOnTop
                : null,
            onDeleteNote: _removeOpenNote,
            onToggleKapyAi: _kapyAi == null ? null : _toggleKapyAi,
            autofocus: _selectedId == null || !widget.prefs.readyToTypeOnOpen,
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final selected = _shownNote(_selectedId);
    // A tablet reaches this layout too, and it has no Scaffold to resize
    // around the software keyboard. Desktop reports zero here.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    // The canvas left around the page, on every side but the one against the
    // notes list, whose own margin keeps the two apart.
    const pageInset = 12.0;

    // The desktop layout is its own chrome rather than a Scaffold, but text
    // fields, menus and ink still need a Material ancestor. It is the canvas
    // the rail, the notes list and the page stand on, and transparent in glass
    // mode so the window's blurred desktop is what shows through the thinned
    // surfaces: a window with no material behind it shows black through any
    // gap.
    return Material(
      color: context.palette.isGlass
          ? Colors.transparent
          : context.palette.sidebarColor,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: ListenableBuilder(
          listenable: _toolbarSources,
          builder: (context, _) {
            final space = _space;
            final listFits = _listFits;
            final listShown = _listShown;
            final pinned =
                selected != null &&
                widget.notes.pinnedNoteIds.contains(selected.id);
            final unloaded = [
              for (final ref in selected?.attachments ?? const [])
                if (ref case NoteImageRef(src: _?, isPreparing: false)) ref,
            ];
            final taskBoard = _taskController?.read();
            final tasks = _tasksMode ? _taskController : null;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SpacesRail(
                  space: space,
                  onSelected: _showSpace,
                  invitations: widget.account?.sharing?.invites.length,
                  openTasks: taskBoard?.open.length,
                  streak: widget.notes.streak,
                  onSettingsPressed: _showSettings,
                  settingsShortcut: widget.shortcuts.bindingFor(
                    ShortcutAction.openSettings,
                  ),
                  updates: widget.updates,
                  onAccountPressed: widget.account == null
                      ? null
                      : () => _showSettings(section: SettingsSection.account),
                  user: widget.account?.user,
                  syncStatus: widget.account?.sync?.status,
                ),
                Expanded(
                  child: SplitView(
                    sidebarVisible: listShown,
                    overlay: !listFits,
                    sidebarWidth: widget.prefs.sidebarWidth,
                    minSidebarWidth: LayoutPrefs.minSidebarWidth,
                    maxSidebarWidth: LayoutPrefs.maxSidebarWidth,
                    onWidthChanged: (value) =>
                        widget.prefs.sidebarWidth = value,
                    onHide: () => _setListShown(false),
                    sidebar: tasks != null && taskBoard != null
                        ? TasksSidebar(
                            board: taskBoard,
                            filter: _taskFilter,
                            onFilter: (filter) =>
                                setState(() => _taskFilter = filter),
                            labelOf: _taskNoteLabel,
                            onSearch: _openCommandMenu,
                            searchShortcut: widget.shortcuts.bindingFor(
                              ShortcutAction.findNotes,
                            ),
                            searchPlaceholder: _searchPlaceholder,
                            windowBar: SidebarWindowBar(
                              title: space.title,
                              count: taskBoard.open.length,
                              countLabel: 'open',
                              noun: 'task',
                              onCreate: _createInSpace,
                              newNoteShortcut: widget.shortcuts.bindingFor(
                                ShortcutAction.newNote,
                              ),
                              onHide: () => _setListShown(false),
                              hideShortcut: widget.shortcuts.bindingFor(
                                ShortcutAction.toggleSidebar,
                              ),
                            ),
                          )
                        : Sidebar(
                            notes: _visibleNotes,
                            pinnedNoteIds: widget.notes.pinnedNoteIds,
                            lockedNoteIds: _noteLimit?.lockedIds ?? const {},
                            selectedId: _selectedId,
                            query: _archiveQuery,
                            displayTime: widget.prefs.displayTime,
                            onSearch: _openCommandMenu,
                            onClearQuery: () =>
                                setState(() => _archiveQuery = ''),
                            onSelect: AppPlatform.isDesktop
                                ? _selectFromSidebar
                                : _select,
                            onMoveSelect: AppPlatform.isDesktop
                                ? _previewFromSidebar
                                : null,
                            onEnterSelected: AppPlatform.isDesktop
                                ? _enterSelectedEditorFromSidebar
                                : null,
                            onOpenToSide: _specialMode ? null : _openNoteToSide,
                            openElsewhereIds: _specialMode
                                ? const {}
                                : _workspace.openNoteIds.difference({
                                    ?_selectedId,
                                  }),
                            onArchive: _archiveNote,
                            onRestore: _restoreNote,
                            onHide: (id) => unawaited(_hideNote(id)),
                            onUnhide: _unhideNote,
                            onTogglePin: _specialMode
                                ? null
                                : _togglePinnedNote,
                            archiveMode: _archiveMode,
                            hiddenMode: _hiddenMode,
                            onDelete: _deleteNote,
                            onDeleteAll: () => unawaited(_deleteAllArchived()),
                            selecting: _selectingArchived,
                            checkedIds: _checkedArchived,
                            onToggleChecked: _toggleChecked,
                            onStartSelecting: _startSelecting,
                            onCancelSelecting: _cancelSelecting,
                            onCheckAll: _checkAllArchived,
                            onDeleteChecked: () => unawaited(_deleteChecked()),
                            onRestoreChecked: _restoreChecked,
                            onShare: widget.account == null ? null : _shareNote,
                            sharing: widget.account?.sharing,
                            collaborators:
                                widget.account?.sync?.collaboratorsByNote ??
                                const {},
                            onOpenSpace: widget.account?.sharing == null
                                ? null
                                : _openSpace,
                            tab: _sidebarTab,
                            onTabChanged: _setSidebarTab,
                            searchShortcut: widget.shortcuts.bindingFor(
                              ShortcutAction.findNotes,
                            ),
                            searchPlaceholder: _searchPlaceholder,
                            archiveShortcut: widget.shortcuts.bindingFor(
                              ShortcutAction.deleteNote,
                            ),
                            drawings: space == LibrarySpace.drawings,
                            onNewDrawing: () => _createNote(drawing: true),
                            engine: widget.engines.engine,
                            now: widget.notes.now,
                            cards: widget.prefs.noteCards,
                            controls: _notesControls(space),
                            pinnedOnly: _showingPinnedOnly,
                            onPinnedOnlyChanged: (value) =>
                                setState(() => _pinnedOnly = value),
                            windowBar: SidebarWindowBar(
                              title: _listTitle,
                              count: _matchingCount,
                              noun: space == LibrarySpace.drawings
                                  ? 'drawing'
                                  : 'note',
                              onCreate: _createInSpace,
                              newNoteShortcut: widget.shortcuts.bindingFor(
                                ShortcutAction.newNote,
                              ),
                              onHide: () => _setListShown(false),
                              hideShortcut: widget.shortcuts.bindingFor(
                                ShortcutAction.toggleSidebar,
                              ),
                            ),
                          ),
                    // No bottom inset here: on a tablet the note's footer
                    // holds its own controls above the home indicator, and
                    // the empty state does the same with its paper.
                    body: SafeArea(
                      left: false,
                      bottom: false,
                      child: _withKapyAi(
                        Stack(
                          fit: StackFit.expand,
                          children: [
                            const Positioned(
                              left: 0,
                              top: 0,
                              right: 0,
                              height: pageInset,
                              child: WindowDragArea(child: SizedBox.expand()),
                            ),
                            AnimatedPadding(
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                              padding: EdgeInsets.fromLTRB(
                                listFits && listShown ? 0 : pageInset,
                                pageInset,
                                pageInset,
                                pageInset,
                              ),
                              child: PageCard(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (tasks != null)
                                      ..._buildTasksPage(
                                        tasks,
                                        listVisible: listFits && listShown,
                                      )
                                    else ...[
                                      PageToolbar(
                                        space: _listTitle,
                                        section: pinned ? 'Pinned' : null,
                                        listVisible: listFits && listShown,
                                        onShowList: _toggleList,
                                        showListShortcut: _sidebarShortcut,
                                        noun: space == LibrarySpace.drawings
                                            ? 'drawing'
                                            : 'note',
                                        onCreate: _createInSpace,
                                        newNoteShortcut: widget.shortcuts
                                            .bindingFor(ShortcutAction.newNote)
                                            ?.displayLabel,
                                        noteOpen: selected != null,
                                        syncStatus:
                                            widget.account?.sync?.status,
                                        unloadedPictures: unloaded.length,
                                        onShowUnloadedPicture: unloaded.isEmpty
                                            ? null
                                            : () => _selectedEditor
                                                  ?.showAttachment(
                                                    unloaded.first.offset,
                                                  ),
                                        members: _selectedMembers,
                                        present: _selectedPresence,
                                        currentUserId:
                                            widget.account?.sharing?.userId ??
                                            '',
                                        noteShared: selected?.isShared ?? false,
                                        onShare: _shareSelected,
                                        assistant: _kapyAiButton(
                                          extent: AppPlatform.hasPointer
                                              ? 32
                                              : AppControlMetrics
                                                    .iconButtonExtent,
                                          gap: 6,
                                        ),
                                        pinned: pinned,
                                        onTogglePin:
                                            selected == null || _specialMode
                                            ? null
                                            : () => _togglePinnedNote(
                                                selected.id,
                                              ),
                                        keepOnTop: widget.prefs.alwaysOnTop,
                                        onToggleKeepOnTop: _pinToggle,
                                        keepOnTopShortcut: _pinShortcut,
                                        moreActions: _pageActions(selected),
                                        onMore: (action) =>
                                            _runPageAction(action, selected),
                                        updates: widget.updates,
                                        center:
                                            selected != null &&
                                                _canChooseMode(selected)
                                            ? NoteModeSwitch(
                                                drawing: selected.isDrawing,
                                                onChanged: (drawing) =>
                                                    _setDrawingMode(
                                                      selected.id,
                                                      drawing: drawing,
                                                    ),
                                              )
                                            : null,
                                      ),
                                      Expanded(child: _buildWideWorkspace()),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// What the page's More menu offers: the window's own actions, then the
  /// open note's, in the order and on the terms of that note's menu in the
  /// list.
  List<KapyMenuAction> _pageActions(Note? note) {
    final splitBlocker = _specialMode
        ? null
        : _workspace.paneCount >= EditorWorkspace.maxPanes
        ? 'Up to three notes side by side'
        : _selectedId == null
        ? 'Choose a note for this pane first'
        : null;
    final canSplit = !_specialMode && _workspace.canSplit;
    final mayEdit = note != null && _canEditNote(note);
    final removeShortcut = widget.shortcuts
        .bindingFor(ShortcutAction.deleteNote)
        ?.displayLabel;
    final alwaysOnTop = widget.prefs.alwaysOnTop;
    return [
      KapyMenuAction(
        value: 'split',
        label: canSplit ? 'Split view' : splitBlocker ?? 'Split view',
        icon: KapyIcons.viewColumnOutlined,
        hint: canSplit
            ? widget.shortcuts
                  .bindingFor(ShortcutAction.splitEditor)
                  ?.displayLabel
            : null,
        enabled: canSplit,
      ),
      if (_pinToggle != null)
        KapyMenuAction(
          value: 'on-top',
          label: alwaysOnTop ? 'Stop keeping on top' : 'Keep on top',
          icon: KapyIcons.layersRounded,
          hint: _pinShortcut,
        ),
      if (mayEdit && !_specialMode && !note.isShared)
        const KapyMenuAction(
          value: 'hide',
          label: 'Move to Hidden Notes',
          icon: hiddenIcon,
        ),
      if (mayEdit && _archiveMode)
        const KapyMenuAction(
          value: 'restore',
          label: 'Restore note',
          icon: restoreIcon,
        ),
      if (mayEdit && _hiddenMode)
        const KapyMenuAction(
          value: 'unhide',
          label: 'Move to Notes',
          icon: unhideIcon,
        ),
      if (mayEdit)
        KapyMenuAction(
          value: _specialMode ? 'delete' : 'archive',
          label: _specialMode ? 'Delete permanently' : 'Archive note',
          icon: _specialMode ? deleteIcon : archiveIcon,
          hint: removeShortcut,
          destructive: true,
        ),
    ];
  }

  void _runPageAction(String action, Note? note) {
    switch (action) {
      case 'split':
        _splitEditor();
      case 'on-top':
        _pinToggle?.call();
    }
    if (note == null) return;
    switch (action) {
      case 'hide':
        unawaited(_hideNote(note.id));
      case 'restore':
        _restoreNote(note.id);
      case 'unhide':
        _unhideNote(note.id);
      case 'archive':
        _archiveNote(note.id);
      case 'delete':
        unawaited(_deleteNote(note.id));
    }
  }

  /// Tasks on the page: its own breadcrumb and Pick again over Today, or
  /// over the Done view.
  List<Widget> _buildTasksPage(
    TasksController tasks, {
    required bool listVisible,
  }) {
    final filter = _taskFilter;
    final note = filter.noteId == null
        ? null
        : widget.notes.byId(filter.noteId);
    final home = note != null && tasks.read().home?.id == note.id;
    final palette = context.palette;
    return [
      PageToolbar(
        space: LibrarySpace.tasks.title,
        section: filter.done
            ? 'Done'
            : note == null || home
            ? 'Today'
            : _taskNoteLabel(note),
        listVisible: listVisible,
        onShowList: _toggleList,
        showListShortcut: _sidebarShortcut,
        noun: 'task',
        onCreate: _createInSpace,
        newNoteShortcut: widget.shortcuts
            .bindingFor(ShortcutAction.newNote)
            ?.displayLabel,
        keepOnTop: widget.prefs.alwaysOnTop,
        onToggleKeepOnTop: _pinToggle,
        keepOnTopShortcut: _pinShortcut,
        updates: widget.updates,
        actions: [
          if (!filter.done)
            TextButton.icon(
              key: const ValueKey('tasks-pick-again'),
              onPressed: () => _tasksPage.currentState?.pickAgain(),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: palette.textTertiary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                textStyle: uiStyle(
                  12.5,
                  16,
                  FontWeight.w500,
                  palette.textTertiary,
                ),
              ),
              icon: KapyIcon(
                KapyIcons.refreshRounded,
                size: 15,
                strokeWidth: 1.8,
                color: palette.textTertiary,
              ),
              label: const Text('Pick again'),
            ),
        ],
      ),
      Expanded(
        child: TasksScreen(
          key: _tasksPage,
          controller: tasks,
          filter: filter,
          addFocus: _taskAddFocus,
          labelOf: _taskNoteLabel,
          onOpenNote: _openTaskNote,
          newTaskShortcut: widget.shortcuts
              .bindingFor(ShortcutAction.newNote)
              ?.keycapLabel,
        ),
      ),
    ];
  }

  Widget _buildWideWorkspace() {
    if (_specialMode) {
      final selected = widget.notes.byId(_selectedId);
      return selected == null
          ? EmptyState(onCreate: _createNote)
          : _buildEditor(selected, key: _archiveEditorKey, active: true);
    }
    final panes = _workspace.panes;
    if (panes.isEmpty) return _emptyPage();

    return PaneSplitView(
      weights: _workspace.weights,
      onWeightsChanged: (weights) =>
          setState(() => _workspace.weights = weights),
      onEqualize: () => setState(_workspace.equalizeWeights),
      children: [
        for (var index = 0; index < panes.length; index++) _buildPane(index),
      ],
    );
  }

  Widget _buildPane(int index) {
    final pane = _workspace.panes[index];
    final note = _shownNote(pane.noteId);
    final active = _workspace.activePane == index;
    final split = _workspace.isSplit;

    final Widget body;
    if (note != null) {
      body = _buildEditor(
        note,
        key: _paneEditorKey(note.id),
        active: active,
        onFocus: () => _activatePane(index),
      );
    } else if (split) {
      body = EmptyPane(
        active: active,
        onCreate: _createInSpace,
        onShowNotes: _listShown ? null : () => _setListShown(true),
      );
    } else {
      body = _emptyPage();
    }

    return EditorPaneFrame(
      key: ValueKey('editor-pane-${pane.id}'),
      index: index,
      paneCount: _workspace.paneCount,
      active: active,
      title: note?.title,
      shared: note?.isShared ?? false,
      dragData: note == null
          ? null
          : NoteDragData(noteId: note.id, title: note.title),
      onActivate: () => _activatePane(index),
      onTitlePressed: () => _focusPane(index),
      onClose: split ? () => _closePane(index) : null,
      closeShortcut: widget.shortcuts
          .bindingFor(ShortcutAction.closePane)
          ?.displayLabel,
      planDrop: (data, zone) => _planDrop(data, index, zone),
      onDrop: (data, zone) => _dropNote(data, index, zone),
      child: body,
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

    final compactPage = AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        key: _scaffoldKey,
        // The wide layout is its own chrome; here the Scaffold would cover the
        // window material that the translucent surfaces are meant to sit on.
        backgroundColor: palette.isGlass
            ? Colors.transparent
            : palette.editorBackground,
        // The full-page observer below opens it instead, from anywhere and
        // without taking the editor's vertical-scroll or text-selection
        // gestures away from it.
        drawerEnableOpenDragGesture: false,
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
            side: BorderSide(
              color: palette.separator,
              width: AppHairline.of(context),
            ),
          ),
          child: _drawerContentReady
              ? Builder(
                  builder: (drawerContext) => ListenableBuilder(
                    listenable: _toolbarSources,
                    builder: (context, _) => Sidebar(
                      notes: _visibleNotes,
                      pinnedNoteIds: widget.notes.pinnedNoteIds,
                      lockedNoteIds: _noteLimit?.lockedIds ?? const {},
                      selectedId: _selectedId,
                      query: _archiveQuery,
                      displayTime: widget.prefs.displayTime,
                      onSearch: _openCommandMenu,
                      onClearQuery: () => setState(() => _archiveQuery = ''),
                      onSelect: (id) {
                        _select(id);
                        Navigator.of(drawerContext).pop();
                      },
                      onCreate: () {
                        _createNote();
                        Navigator.of(drawerContext).pop();
                      },
                      onArchive: _archiveNote,
                      onRestore: _restoreNote,
                      onHide: (id) => unawaited(_hideNote(id)),
                      onUnhide: _unhideNote,
                      onTogglePin: _specialMode ? null : _togglePinnedNote,
                      archiveMode: _archiveMode,
                      hiddenMode: _hiddenMode,
                      onDelete: _deleteNote,
                      onDeleteAll: () => unawaited(_deleteAllArchived()),
                      selecting: _selectingArchived,
                      checkedIds: _checkedArchived,
                      onToggleChecked: _toggleChecked,
                      onStartSelecting: _startSelecting,
                      onCancelSelecting: _cancelSelecting,
                      onCheckAll: _checkAllArchived,
                      onDeleteChecked: () => unawaited(_deleteChecked()),
                      onRestoreChecked: _restoreChecked,
                      streak: widget.notes.streak,
                      onShare: widget.account == null ? null : _shareNote,
                      sharing: widget.account?.sharing,
                      collaborators:
                          widget.account?.sync?.collaboratorsByNote ?? const {},
                      onOpenSpace: widget.account?.sharing == null
                          ? null
                          : _openSpace,
                      tab: _sidebarTab,
                      onTabChanged: _setSidebarTab,
                      onSettingsPressed: _showSettings,
                      searchShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.findNotes,
                      ),
                      searchPlaceholder: _searchPlaceholder,
                      settingsShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.openSettings,
                      ),
                      archiveShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.deleteNote,
                      ),
                      updates: widget.updates,
                      controls: _notesControls(_space, cards: false),
                    ),
                  ),
                )
              : ColoredBox(color: palette.sidebarColor),
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
                sidebarShortcut: _sidebarShortcut,
                settingsShortcut: _settingsShortcut,
                showActions: !_drawerOpen,
                onToggleSidebar: () {
                  FocusScope.of(scaffoldContext).unfocus();
                  Scaffold.of(scaffoldContext).openDrawer();
                },
                onSettingsPressed: _showSettings,
                onCreate: _createNote,
                onShare: _shareSelected,
                assistant: _kapyAiButton(
                  extent: AppControlMetrics.iconButtonExtent,
                  gap: 2,
                ),
                members: _selectedMembers,
                present: _selectedPresence,
                currentUserId: widget.account?.sharing?.userId ?? '',
                noteShared: selected?.isShared ?? false,
                newNoteShortcut: widget.shortcuts
                    .bindingFor(ShortcutAction.newNote)
                    ?.displayLabel,
                updates: widget.updates,
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                // The footer belongs on the bottom edge, the way the toolbar
                // above belongs on the top one. It insets its own controls
                // past the home indicator; a page inset would only strand the
                // bar above a strip of background. Left and right stay, for
                // the display cutout a landscape phone puts beside the text.
                bottom: false,
                child: selected == null
                    ? EmptyState(onCreate: _createNote)
                    : _buildCompactEditor(selected),
              ),
            ),
          ],
        ),
      ),
    );

    return MobilePageSwipe(
      enabled: !_drawerOpen,
      onOpenNotes: () {
        FocusManager.instance.primaryFocus?.unfocus();
        _scaffoldKey.currentState?.openDrawer();
      },
      onCreateNote: _createNote,
      child: compactPage,
    );
  }

  Widget _buildCompactEditor(Note note) {
    if (note.isDrawing) return _buildDrawing(note, modeSwitch: true);
    final editor = ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: _toolbarSources,
        builder: (context, _) => NoteEditor(
          key: _compactEditorKey,
          player: widget.player,
          voiceStateFor: _voiceStateFor,
          onOpenVoiceNote: _openVoiceNote,
          recording: widget.recording,
          onRecordVoice: _canWriteNote(note)
              ? () => unawaited(_startVoiceRecording())
              : null,
          voiceActionBusy: _voiceActionBusy,
          imageAcquirer: (context) => _acquireImages(context, note.id),
          videoAcquirer: () => _acquireVideos(note.id),
          fileAcquirer: () => _acquireFiles(note.id),
          videoAttachmentMaxBytes: () => _videoAttachmentMaxBytes(note),
          onImagePrepared: (staged, prepared) =>
              _publishPreparedImage(note.id, staged, prepared),
          noteId: note.id,
          initialBody: note.body,
          initialFormats: note.formats,
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          keepResultRoom: true,
          resultsVisible: true,
          autofocus: _readyToTypeIn(note),
          startAtEnd: _readyToTypeIn(note),
          namedByPerson: !(_namer?.willName(note) ?? false),
          onDefaultTitleEntered: () => _namer?.personNaming(note.id),
          initialCaret: _resumeCaretIn(note),
          onCaretChanged: (offset) =>
              widget.prefs.rememberCaret(note.id, offset),
          ensureKeyboardVisible:
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          idlePeekHeld: () => _kapyAi?.answering ?? false,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          paperStyle: widget.prefs.paperStyle,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          editorTextScale: widget.prefs.editorTextScale,
          slashHint: widget.prefs.slashHint,
          onSlashCommandUsed: widget.prefs.noteSlashCommandUsed,
          lastSlashCommand: SlashCommandType.values
              .asNameMap()[widget.prefs.lastSlashCommand],
          onSlashCommandChosen: (command) =>
              widget.prefs.lastSlashCommand = command.name,
          now: widget.notes.now,
          shortcuts: widget.shortcuts,
          spellCheckEnabled: widget.prefs.spellCheckEnabled,
          markdownEnabled: widget.prefs.markdownEnabled,
          onMarkdownEnabledChanged: (enabled) =>
              widget.prefs.markdownEnabled = enabled,
          initialAttachments: note.attachments,
          images: widget.notes.blobs,
          imageFetch: widget.account?.imageFetch,
          uploadProgressFor: widget.account?.uploadProgressFor,
          typing: widget.account?.sync?.typistsIn(note.id) ?? const [],
          remoteCarets: note.isShared ? widget.account?.sync : null,
          onActivity: (selection, text, {required edited}) =>
              _reportPresence(note.id, selection, text, edited: edited),
          readOnly: !_canWriteNote(note),
          readOnlyLabel: _limitHolds(note) ? 'Read-only on Free' : 'View only',
          readOnlyIcon: _limitHolds(note)
              ? Icons.lock_outline_rounded
              : Icons.visibility_outlined,
          onReadOnlyPressed: _limitHolds(note)
              ? () => unawaited(_explainNoteLimit(creating: false))
              : null,
          onDocumentChanged: (body, formats, attachments, edit) =>
              _updateDocument(note.id, body, formats, attachments, edit),
          storedDocument: () => _storedDocument(note.id),
          onSettingsPressed: _showSettings,
        ),
      ),
    );
    return _withModeSwitch(note, editor);
  }

  Widget _buildEditor(
    Note note, {
    required GlobalKey<NoteEditorState> key,
    required bool active,
    VoidCallback? onFocus,
  }) {
    if (note.isDrawing) return _buildDrawing(note, onFocus: onFocus);
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        // The wide layout already listens to the account around this body.
        listenable: widget.prefs,
        builder: (context, _) => NoteEditor(
          // A key per note keeps one note's editing state from leaking into
          // the next, and lets it follow its note when the panes reorder.
          key: key,
          noteId: note.id,
          initialBody: note.body,
          initialFormats: note.formats,
          player: widget.player,
          voiceStateFor: _voiceStateFor,
          onOpenVoiceNote: _openVoiceNote,
          recording: widget.recording,
          onRecordVoice: _canWriteNote(note)
              ? () {
                  onFocus?.call();
                  unawaited(_startVoiceRecording(noteId: note.id));
                }
              : null,
          voiceActionBusy: _voiceActionBusy,
          imageAcquirer: (context) => _acquireImages(context, note.id),
          videoAcquirer: () => _acquireVideos(note.id),
          fileAcquirer: () => _acquireFiles(note.id),
          videoAttachmentMaxBytes: () => _videoAttachmentMaxBytes(note),
          onImagePrepared: (staged, prepared) =>
              _publishPreparedImage(note.id, staged, prepared),
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          resultsVisible: widget.prefs.resultsVisible,
          autofocus:
              active && !_selectionAutofocusSuppressed && _readyToTypeIn(note),
          startAtEnd: active && _readyToTypeIn(note),
          namedByPerson: !(_namer?.willName(note) ?? false),
          onDefaultTitleEntered: () => _namer?.personNaming(note.id),
          initialCaret: _resumeCaretIn(note),
          onCaretChanged: (offset) =>
              widget.prefs.rememberCaret(note.id, offset),
          ensureKeyboardVisible:
              active &&
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          idlePeekHeld: () => _kapyAi?.answering ?? false,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          paperStyle: widget.prefs.paperStyle,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          editorTextScale: widget.prefs.editorTextScale,
          slashHint: widget.prefs.slashHint,
          onSlashCommandUsed: widget.prefs.noteSlashCommandUsed,
          lastSlashCommand: SlashCommandType.values
              .asNameMap()[widget.prefs.lastSlashCommand],
          onSlashCommandChosen: (command) =>
              widget.prefs.lastSlashCommand = command.name,
          now: widget.notes.now,
          shortcuts: widget.shortcuts,
          spellCheckEnabled: widget.prefs.spellCheckEnabled,
          markdownEnabled: widget.prefs.markdownEnabled,
          onMarkdownEnabledChanged: (enabled) =>
              widget.prefs.markdownEnabled = enabled,
          initialAttachments: note.attachments,
          images: widget.notes.blobs,
          imageFetch: widget.account?.imageFetch,
          uploadProgressFor: widget.account?.uploadProgressFor,
          typing: widget.account?.sync?.typistsIn(note.id) ?? const [],
          remoteCarets: note.isShared ? widget.account?.sync : null,
          onFocus: onFocus,
          onActivity: (selection, text, {required edited}) {
            // Only the focused pane says where this device is. An editor that
            // is merely on screen beside it is not the one being worked in.
            if (_selectedId != note.id) return;
            _reportPresence(note.id, selection, text, edited: edited);
          },
          readOnly: !_canWriteNote(note),
          readOnlyLabel: _limitHolds(note) ? 'Read-only on Free' : 'View only',
          readOnlyIcon: _limitHolds(note)
              ? Icons.lock_outline_rounded
              : Icons.visibility_outlined,
          onReadOnlyPressed: _limitHolds(note)
              ? () => unawaited(_explainNoteLimit(creating: false))
              : null,
          onDocumentChanged: (body, formats, attachments, edit) =>
              _updateDocument(note.id, body, formats, attachments, edit),
          storedDocument: () => _storedDocument(note.id),
          onSettingsPressed: _showSettings,
        ),
      ),
    );
  }

  /// Whether [note] can still become a drawing, or go back to being a page:
  /// only while it is blank, and only for somebody who may write in it.
  bool _canChooseMode(Note note) =>
      _canWriteNote(note) &&
      !note.isArchived &&
      note.isEmpty &&
      note.attachments.isEmpty;

  /// The phone's editor, with "Write | Draw" over its corner while the note
  /// is new.
  ///
  /// Always the same Stack, with or without the switch: the first keystroke
  /// takes the switch away, and a tree that changed shape under the editor
  /// at that moment would rebuild it out from under the caret.
  Widget _withModeSwitch(Note note, Widget editor) {
    return Stack(
      fit: StackFit.expand,
      children: [
        editor,
        if (_canChooseMode(note))
          Positioned(
            top: 10,
            right: 14,
            child: NoteModeSwitch(
              drawing: false,
              onChanged: (drawing) {
                if (drawing) _setDrawingMode(note.id, drawing: true);
              },
            ),
          ),
      ],
    );
  }

  void _setDrawingMode(String id, {required bool drawing}) {
    final note = widget.notes.byId(id);
    if (note == null || !_canChooseMode(note)) return;
    // The caret was in the page this note is no longer going to be.
    if (drawing) FocusManager.instance.primaryFocus?.unfocus();
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    widget.notes.setDrawingMode(id, drawing: drawing);
  }

  /// The page with nothing open on it, which in Drawings points at New
  /// drawing rather than offering a note.
  Widget _emptyPage() => _drawingsOnly
      ? EmptyState.drawings(
          shortcut: widget.shortcuts
              .bindingFor(ShortcutAction.newNote)
              ?.keycapLabel,
        )
      : EmptyState(onCreate: _createNote);

  /// A phone shows Write | Draw in the drawing's title row when
  /// [modeSwitch]; a window shows it in the page toolbar.
  Widget _buildDrawing(
    Note note, {
    VoidCallback? onFocus,
    bool modeSwitch = false,
  }) {
    final canWrite = _canWriteNote(note);
    return DrawingCanvas(
      key: ValueKey('drawing-${note.id}'),
      drawing: note.drawing ?? NoteDrawing.empty,
      title: note.body,
      edited: SidebarTimestamp.edited(
        note.updatedAt,
        now: widget.notes.now(),
        displayTime: widget.prefs.displayTime,
      ),
      readOnly: !canWrite,
      onFocus: onFocus,
      onSwitchToWrite: modeSwitch && _canChooseMode(note)
          ? () => _setDrawingMode(note.id, drawing: false)
          : null,
      onChanged: (drawing) => _updateDrawing(note.id, drawing: drawing),
      onTitleChanged: (title) => _updateDrawing(note.id, title: title),
    );
  }

  void _updateDrawing(String id, {NoteDrawing? drawing, String? title}) {
    final note = widget.notes.byId(id);
    if (note == null || !note.isDrawing || !_canWriteNote(note)) return;
    _recordKapyActivity();
    widget.account?.sync?.reportTyping(id);
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    widget.notes.updateDrawing(id, drawing ?? note.drawing!, title: title);
  }
}

/// The modifier whose release commits a note-switch session.
///
/// Shift is normally only the direction reversal in Ctrl+Shift+Tab, so the
/// first non-Shift modifier owns the session. A Shift-only custom binding
/// still works and commits when Shift itself is released.
enum _NoteSwitchModifier {
  meta,
  control,
  alt,
  shift;

  static _NoteSwitchModifier? forBinding(ShortcutBinding? binding) {
    if (binding == null) return null;
    if (binding.meta) return meta;
    if (binding.control) return control;
    if (binding.alt) return alt;
    if (binding.shift) return shift;
    return null;
  }

  bool matches(LogicalKeyboardKey key) => switch (this) {
    meta =>
      key == LogicalKeyboardKey.metaLeft || key == LogicalKeyboardKey.metaRight,
    control =>
      key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight,
    alt =>
      key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight,
    shift =>
      key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight,
  };

  bool isPressed(HardwareKeyboard keyboard) => switch (this) {
    meta => keyboard.isMetaPressed,
    control => keyboard.isControlPressed,
    alt => keyboard.isAltPressed,
    shift => keyboard.isShiftPressed,
  };
}

/// Keyboard shortcuts that a desktop user expects to just work.
class _DesktopShortcuts extends StatelessWidget {
  const _DesktopShortcuts({
    required this.child,
    required this.focusNode,
    required this.onNewNote,
    required this.onCompleteTask,
    required this.onSearch,
    required this.onNewTask,
    required this.onNewDrawing,
    required this.onShowSpace,
    required this.onShowArchive,
    required this.showsTasks,
    required this.showsShared,
    required this.onNextNote,
    required this.onPreviousNote,
    required this.onSplitEditor,
    required this.onClosePane,
    required this.onFocusPane,
    required this.onOpenSettings,
    required this.onIncreaseEditorTextSize,
    required this.onDecreaseEditorTextSize,
    required this.onResetEditorTextSize,
    required this.onInsertImage,
    required this.onRecordVoice,
    required this.onToggleSidebar,
    required this.onToggleHiddenFolder,
    required this.onToggleResults,
    required this.onToggleAlwaysOnTop,
    required this.onDeleteNote,
    required this.onToggleKapyAi,
    required this.shortcuts,
    required this.autofocus,
  });

  final Widget child;
  final FocusNode focusNode;
  final VoidCallback onNewNote;

  /// Done on Do now, while Tasks is open: ⌘↵, or Ctrl+Enter.
  final VoidCallback? onCompleteTask;
  final VoidCallback onSearch;
  final VoidCallback? onNewTask;
  final VoidCallback onNewDrawing;

  /// Opens a section from its Go to key; Tasks and Shared only where they
  /// are on the rail.
  final ValueChanged<LibrarySpace> onShowSpace;
  final VoidCallback onShowArchive;
  final bool showsTasks;
  final bool showsShared;
  final VoidCallback onNextNote;
  final VoidCallback onPreviousNote;
  final VoidCallback? onSplitEditor;
  final VoidCallback? onClosePane;

  /// One per pane position, left to right; null past the panes that are open.
  final List<VoidCallback?> onFocusPane;
  final VoidCallback onOpenSettings;
  final VoidCallback onIncreaseEditorTextSize;
  final VoidCallback onDecreaseEditorTextSize;
  final VoidCallback onResetEditorTextSize;
  final VoidCallback onInsertImage;
  final VoidCallback onRecordVoice;
  final VoidCallback onToggleSidebar;
  final VoidCallback onToggleHiddenFolder;
  final VoidCallback onToggleResults;
  final VoidCallback? onToggleAlwaysOnTop;
  final VoidCallback? onDeleteNote;

  /// Null where Kapy AI is not built in, which leaves its chord unbound.
  final VoidCallback? onToggleKapyAi;
  final ShortcutPrefs shortcuts;
  final bool autofocus;

  ShortcutBinding get _find => ShortcutBinding(
    logicalKey: LogicalKeyboardKey.keyF,
    physicalKey: PhysicalKeyboardKey.keyF,
    meta: AppPlatform.isMacOS,
    control: !AppPlatform.isMacOS,
  );

  @override
  Widget build(BuildContext context) {
    // A cleared shortcut leaves no entry behind: the action keeps whatever
    // button it has, and the keyboard simply says nothing about it.
    return CallbackShortcuts(
      bindings: {
        ?shortcuts.bindingFor(ShortcutAction.newNote)?.activator: onNewNote,
        SingleActivator(
          LogicalKeyboardKey.enter,
          meta: AppPlatform.isMacOS,
          control: !AppPlatform.isMacOS,
        ): ?onCompleteTask,
        ?shortcuts.bindingFor(ShortcutAction.findNotes)?.activator: onSearch,
        // Find's own chord opens search too, unless it was given to
        // something else.
        if (shortcuts.conflictFor(ShortcutAction.findNotes, _find) == null)
          _find.activator: onSearch,
        ?shortcuts.bindingFor(ShortcutAction.newTask)?.activator: ?onNewTask,
        ?shortcuts.bindingFor(ShortcutAction.newDrawing)?.activator:
            onNewDrawing,
        ?shortcuts.bindingFor(ShortcutAction.showNotes)?.activator: () =>
            onShowSpace(LibrarySpace.notes),
        if (showsTasks)
          ?shortcuts.bindingFor(ShortcutAction.showTasks)?.activator: () =>
              onShowSpace(LibrarySpace.tasks),
        ?shortcuts.bindingFor(ShortcutAction.showDrawings)?.activator: () =>
            onShowSpace(LibrarySpace.drawings),
        if (showsShared)
          ?shortcuts.bindingFor(ShortcutAction.showShared)?.activator: () =>
              onShowSpace(LibrarySpace.shared),
        ?shortcuts.bindingFor(ShortcutAction.showArchive)?.activator:
            onShowArchive,
        ?shortcuts.bindingFor(ShortcutAction.nextNote)?.activator: onNextNote,
        ?shortcuts.bindingFor(ShortcutAction.previousNote)?.activator:
            onPreviousNote,
        ?shortcuts.bindingFor(ShortcutAction.splitEditor)?.activator:
            ?onSplitEditor,
        ?shortcuts.bindingFor(ShortcutAction.closePane)?.activator:
            ?onClosePane,
        ?shortcuts.bindingFor(ShortcutAction.focusFirstPane)?.activator:
            ?onFocusPane[0],
        ?shortcuts.bindingFor(ShortcutAction.focusSecondPane)?.activator:
            ?onFocusPane[1],
        ?shortcuts.bindingFor(ShortcutAction.focusThirdPane)?.activator:
            ?onFocusPane[2],
        ?shortcuts.bindingFor(ShortcutAction.openSettings)?.activator:
            onOpenSettings,
        ?shortcuts.bindingFor(ShortcutAction.increaseEditorTextSize)?.activator:
            onIncreaseEditorTextSize,
        ?shortcuts.bindingFor(ShortcutAction.decreaseEditorTextSize)?.activator:
            onDecreaseEditorTextSize,
        ?shortcuts.bindingFor(ShortcutAction.resetEditorTextSize)?.activator:
            onResetEditorTextSize,
        ?shortcuts.bindingFor(ShortcutAction.insertImage)?.activator:
            onInsertImage,
        ?shortcuts.bindingFor(ShortcutAction.recordVoiceNote)?.activator:
            onRecordVoice,
        ?shortcuts.bindingFor(ShortcutAction.toggleSidebar)?.activator:
            onToggleSidebar,
        ?shortcuts.bindingFor(ShortcutAction.toggleHiddenFolder)?.activator:
            onToggleHiddenFolder,
        ?shortcuts.bindingFor(ShortcutAction.toggleResults)?.activator:
            onToggleResults,
        ?shortcuts.bindingFor(ShortcutAction.toggleAlwaysOnTop)?.activator:
            ?onToggleAlwaysOnTop,
        ?shortcuts.bindingFor(ShortcutAction.deleteNote)?.activator:
            ?onDeleteNote,
        ?shortcuts.bindingFor(ShortcutAction.toggleKapyAi)?.activator:
            ?onToggleKapyAi,
      },
      child: Focus(focusNode: focusNode, autofocus: autofocus, child: child),
    );
  }
}
