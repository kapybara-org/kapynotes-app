import 'dart:async';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        PhysicalKeyboardKey,
        SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../audio/noise_removals.dart';
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
import '../core/app_zoom.dart';
import '../core/desktop_integration.dart';
import '../core/platform.dart';
import '../core/quick_capture.dart';
import '../core/status_bar.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../core/type_ahead.dart';
import '../data/engine_provider.dart';
import '../data/attachment_limits.dart';
import '../data/auto_titles.dart';
import '../data/daily_separator.dart';
import '../data/editor_workspace.dart';
import '../data/day_tabs.dart';
import '../data/folders.dart';
import '../data/note_days.dart';
import '../data/layout_prefs.dart';
import '../data/local_store.dart';
import '../data/tags.dart';
import '../data/task_board.dart';
import '../data/task_library.dart';
import '../data/note.dart';
import '../data/note_drawing.dart';
import '../files/file_picker.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';
import '../data/note_switcher.dart';
import '../data/notes_store.dart';
import '../data/onboarding.dart';
import 'editor/voice_chip.dart';
import 'editor/voice_insertion.dart';
import 'voice_note_ask.dart';
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
import '../data/store_updates.dart';
import '../data/task_folds.dart';
import '../data/update_checker.dart';
import '../data/writing_streak.dart';
import '../images/image_picker.dart';
import '../video/video_picker.dart';
import 'editor/note_editor.dart';
import 'editor/note_header.dart' show DateLineSaved, NoteFolders;
import 'editor/image_insertion.dart';
import 'editor/slash_commands.dart';
import 'editor_panes.dart';
import 'back_entry.dart';
import 'back_forward.dart';
import 'billing/note_limit_dialog.dart';
import 'billing/pro_sheet.dart';
import 'command_menu.dart';
import 'compact_icon_button.dart';
import 'empty_state.dart';
import 'folders_ui.dart'
    show
        FolderPage,
        fileNotes,
        folderActions,
        folderRefusalText,
        moveNotesToFolder,
        runFolderAction,
        showAddNotesSheet,
        showFolderMenu;
import 'context_menu.dart';
import 'day_strip.dart';
import 'day_tabs_row.dart';
import 'hidden_notes_gate.dart';
import 'kapy_ai/kapy_ai_page.dart';
import 'kapy_ai/kapy_ai_panel.dart';
import 'kapy_ai/kapy_ai_settings.dart';
import 'note_picks.dart';
import 'note_tabs.dart';
import 'notes_grouping.dart';
import 'notes_list.dart';
import 'page_pane.dart';
import 'page_toolbar.dart';
import 'phone_folder_tiles.dart';
import 'phone_home_header.dart';
import 'phone_note_header.dart';
import 'note_day_scope.dart' show withNoteDays;
import 'tasks/task_marks.dart';
import 'tasks/tasks_controller.dart';
import 'tasks/tasks_screen.dart';
import 'tasks/tasks_sidebar.dart';
import 'sidebar.dart';
import 'sidebar_timestamp.dart';
import 'settings_dialog.dart';
import 'storage_full_sheet.dart';
import 'settings/sharing_section.dart' show SharingStart;
import 'tag_colours.dart';
import 'tag_ui.dart';
import 'spaces_rail.dart';
import 'split_view.dart';
import 'draw/drawing_canvas.dart';

/// The narrowest window that holds the notes list beside the page. Below it a
/// phone switches to the compact editor with a notes drawer, while a desktop
/// window keeps the rail and the page and opens the list over the page.
const double kTwoPaneBreakpoint = 720;

/// The height a page needs above a software keyboard to keep its toolbar, its
/// margins and the editor's top and bottom padding. A phone on its side has
/// less, and gives them up while the keyboard is up so the lines being typed
/// stay in sight; a tablet has more. Measured from the top of the window, so
/// hiding the status bar for the room does not change the answer.
const double kCrampedPageHeight = 240;

/// Whether a window of [size], [keyboardInset] of it under the keyboard,
/// leaves a cramped page; see [kCrampedPageHeight].
bool isCrampedPage(Size size, double keyboardInset) =>
    keyboardInset > 0 && size.height - keyboardInset < kCrampedPageHeight;

/// What the toast says as notes go: [deleted] of the reader's own, which
/// go for good, and [removed] that somebody else shares, which only leave
/// the reader's notes.
String forgottenMessage({required int deleted, required int removed}) {
  if (deleted == 0) return 'Removed from your notes';
  final gone = deleted == 1 ? 'Note deleted' : '$deleted notes deleted';
  return removed == 0 ? gone : '$gone, and $removed removed from your notes';
}

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
    this.folders,
    this.days,
    this.dayTabs,
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
    this.storeUpdates,
  });

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

  /// The person's folders and the notes filed in them.
  final FolderStore? folders;

  /// The day each note was given, where one was given. Null leaves days out,
  /// as in a build that has no folders either.
  final NoteDayStore? days;

  /// The order a person put each day's notes in as a phone's tabs, and the
  /// tabs they pinned. Null keeps every day in the order its notes came.
  final DayTabsStore? dayTabs;
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
  /// Android camera or photo-library result.
  final ImageFileAcquirer? imageAcquirer;
  final LostImageRetriever? lostImageRetriever;
  final HiddenNotesGate hiddenNotesGate;

  /// Kapy AI: its panel, its button beside the pin, and ⌘J. Null, or the
  /// feature not built in, leaves all three out.
  final KapyAi? kapyAi;

  /// The model on this device that names new notes. Null names none.
  final TitleModel? titleModel;

  /// What the App Store or Google Play offers, for Settings › About &
  /// updates on a phone. Null on a computer, which has [updates].
  final StoreUpdates? storeUpdates;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _pendingImageNoteKey = 'pendingImageNote.v1';

  final FocusScopeNode _desktopShortcutFocus = FocusScopeNode(
    debugLabel: 'desktop-shortcuts',
  );
  final NoteSwitcher _noteSwitcher = NoteSwitcher();
  GlobalKey<NoteEditorState> _phoneEditorKey = GlobalKey<NoteEditorState>();
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

  /// How far back that list reaches, kept the same way.
  NotesWhen _when = NotesWhen.anyTime;

  /// Whether that list shows every pinned note, after View all.
  bool _pinnedOnly = false;

  /// Whether a phone's filter row is showing. It starts put away, so the list
  /// keeps the room, and the button beside the search brings it back.
  bool _phoneFiltersOpen = false;

  /// Whether a phone note's week is open under its header. It opens by
  /// default, and only the day button closes it (M11).
  bool _phoneWeekOpen = true;

  bool get _showingPinnedOnly =>
      _pinnedOnly && !_specialMode && widget.notes.pinnedNoteIds.isNotEmpty;

  bool _openSessionScheduled = false;

  /// Whether a phone shows the note's page over the list. A launch opens the
  /// note the opening-note setting chooses, ready to type, with the list
  /// under it; back shows the list.
  bool _phonePageOpen = true;

  /// The notes as [_reconcileSelection] last saw them, to tell what the note
  /// it had open was once it has gone.
  List<Note> _notesSeen = const [];

  /// The phone bar's tab on screen.
  PhoneTab _phoneTab = PhoneTab.notes;

  /// The folder whose notes a phone's Folders shows, or null for the tree.
  String? _phoneFolder;

  /// Bumped by New folder, beside a phone's Search folders or under the
  /// desktop's search field, for the tree to name a new folder.
  final _newFolder = ValueNotifier(0);

  final GlobalKey<NavigatorState> _phoneNavigator = GlobalKey();

  /// Phone Tasks' own navigator, under the bar, that a task's page is pushed
  /// on (M14), so the bar stays while it shows.
  final GlobalKey<NavigatorState> _tasksNavigator = GlobalKey();

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

  /// The note on screen when the arrows began walking the list, which ⌘↵
  /// puts back. Null once anything else takes over.
  String? _listWalkStart;

  /// True for a selection frame that only previews a note. The new editor is
  /// prepared at its normal caret but cannot steal focus from either sidebar
  /// scrubbing or an active Ctrl/Cmd switch session, nor from a day of the
  /// page's week picked from the keyboard. See [_holdEditorAutofocus].
  bool _selectionAutofocusSuppressed = false;

  /// The notes picked to act on together. Let go of on the way into or out
  /// of the archive or Hidden Notes: a selection is about the list it was
  /// made in.
  final NotePicks _picks = NotePicks();

  bool get _specialMode => _archiveMode || _hiddenMode;

  /// A mobile overlay owns the screen while it is open. Editors can rebuild
  /// underneath one when a folder changes, but must not reclaim focus and
  /// raise the software keyboard behind it.
  bool get _editorFocusSuppressed => AppPlatform.isMobile && _settingsOpen;

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
    ?widget.days,
    ?widget.dayTabs,
  ]);

  /// Tasks, while the rail has it open.
  bool _tasksMode = false;

  /// The note that was open when a space it is not in was chosen, and the
  /// item that space opened in its place. Choosing a space that holds the
  /// note again, with that item still the one open, puts the note back.
  String? _noteBeforeSpace;
  String? _openedBySpace;
  TaskFilter _taskFilter = const TaskFilter.all();

  /// The steps the page takes, which its tab row's steps slide too.
  final BackForwardSteps _pageSteps = BackForwardSteps();

  /// The steps Tasks takes, from its filter list or its page.
  final BackForwardSteps _taskSteps = BackForwardSteps();

  /// The folders a Back over the list stepped up out of, the nearest last,
  /// for Forward to step back down into.
  final List<String> _foldersSteppedOut = [];
  final FocusNode _taskAddFocus = FocusNode(debugLabel: 'Add a task');

  /// The words in Tasks' add row, kept here so a half-typed task is still
  /// there when Tasks opens again.
  final _taskWords = TextEditingController();
  final GlobalKey<TasksScreenState> _tasksPage = GlobalKey();

  /// Quick find's words, kept while a phone's page holds a note it opened, so
  /// Back from that note opens Quick find again with them.
  final _findWords = TextEditingController();

  /// Whether Back from the phone's page opens Quick find again, and whether
  /// it came from the list's search field.
  ({bool field})? _findOnBack;

  /// The notes a phone had on its page before a note opened from it (its
  /// week, Kapy AI, its tasks), latest last, each still on a page of its own
  /// with its own editor under the one on top, which Back returns to in turn.
  final List<_PhoneNotePage> _phonePagesUnder = [];

  /// The page in [_phonePagesUnder] Back is returning to, on top until its note
  /// is the one selected, when it takes its editor back; see
  /// [_phoneEditorFor].
  _PhoneNotePage? _phoneReturning;

  /// The day whose notes the page on top shows as tabs under its week, from
  /// a day of several picked there until a note from elsewhere takes the
  /// page's place (see [_pickPhoneDay]).
  DateTime? _phoneDay;

  /// The key of the page showing [_phoneDay]'s tabs, the same whichever of
  /// them is open, so a tab opens its note in place, under the same week and
  /// row.
  LocalKey? _phoneDayPage;

  /// The notes [_phoneDay] had when the page on top began to show its tabs,
  /// and the note open there. Each keeps its tab until the page leaves the
  /// day, by Back, Home or another day picked, though its first words move a
  /// note with no day of its own to today.
  Set<String> _phoneDayKept = const {};

  /// The key of the page on top of a phone's notes.
  LocalKey get _phoneTopPage => _phoneDayPage ?? ObjectKey(_phoneEditorKey);

  /// The page's days, keyed so they keep their place in the week wherever
  /// the bar is built.
  final _dayStrip = GlobalKey();
  late final TasksController? _taskController = switch (widget.tasks) {
    final tasks? => TasksController(
      notes: widget.notes,
      library: tasks,
      canEdit: _canEditNote,
      now: widget.notes.now,
    ),
    null => null,
  };

  /// Whether "How Tasks works" was put away, on this device. Null until
  /// read, so the card never flashes.
  TaskFolds? _taskFolds;

  Future<void> _loadTaskFolds() async {
    final folds = await TaskFolds.open();
    if (mounted) setState(() => _taskFolds = folds);
  }

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
    FocusManager.instance.addListener(_syncStatusBar);
    if (_taskController != null) unawaited(_loadTaskFolds());
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
        today: _today,
        openingNoteId: openingId,
      );
    // A draft still blank after a restart is still one nobody wrote in.
    if (widget.notes.byId(_workspace.draft) case final draft?
        when draft.isEmpty && draft.attachments.isEmpty) {
      _freshNoteIds.add(draft.id);
    }
    _startNewDay();
    _selectedId = _workspace.selectedNoteId;
    // Opens on the tab that lists the note it opens on.
    _showTabOf(_selectedId);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    widget.notes.addListener(_onNotesChanged);
    widget.dayTabs?.addListener(_onDayTabsChanged);
    if (widget.folders case final folders?) {
      folders.addListener(_onFoldersChanged);
      unawaited(
        folders.load().then((_) {
          _foldersRead = true;
          _onFoldersChanged();
        }),
      );
    }
    _picks.addListener(_onPicksChanged);
    widget.account?.noteLimit?.addListener(_onNoteLimitChanged);
    widget.account?.addListener(_offerRecoveryKey);
    widget.account?.addListener(_tellStorageFull);
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
    FocusManager.instance.removeListener(_syncStatusBar);
    if (_statusBarHidden) unawaited(StatusBar.setHidden(false));
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    widget.dayTabs?.removeListener(_onDayTabsChanged);
    widget.folders?.removeListener(_onFoldersChanged);
    widget.account?.noteLimit?.removeListener(_onNoteLimitChanged);
    widget.account?.removeListener(_offerRecoveryKey);
    widget.account?.removeListener(_tellStorageFull);
    widget.desktopIntegration?.onNewNoteRequested = null;
    widget.desktopIntegration?.onOpenRequested = null;
    widget.desktopIntegration?.window = null;
    _desktopShortcutFocus.dispose();
    _newFolder.dispose();
    _kapyAi?.removeListener(_onKapyAi);
    _kapyPanel.dispose();
    _pageSteps.dispose();
    _taskSteps.dispose();
    _taskAddFocus.dispose();
    _taskWords.dispose();
    _findWords.dispose();
    _taskController?.dispose();
    _picks.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncStatusBar();
    if (_hiddenMode &&
        _hiddenSystemUiDepth == 0 &&
        state != AppLifecycleState.resumed) {
      _leaveHiddenNotes();
    }
    if (state == AppLifecycleState.resumed) {
      _beginOpenSession();
      // A widget tapped while the app was already running. The platform has
      // been holding that fact since the intent or the URL arrived, and gives
      // it up once, to whoever asks first — so asking on every resume costs
      // an ordinary resume one unanswered question and nothing else.
      unawaited(_runWidgetActions(QuickCapture.launchIntent()));
    } else {
      // A window can lose the matching modifier-up event while focus moves to
      // the operating system. Commit the last preview so the switcher cannot
      // remain half-open when the app returns.
      _commitNoteSwitch(focusEditor: false);
      _namer?.left(_selectedId);
    }
  }

  @override
  void didChangeMetrics() {
    _syncStatusBar();
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

  /// Today, by the clock the notes are dated by.
  int get _today => WritingStreak.dayOf(widget.notes.now());

  /// Whether the next open starts a new day: on the desktop, outside the
  /// special modes, with tabs that belong to an earlier one.
  bool get _isNewDay =>
      AppPlatform.isDesktop && !_specialMode && _workspace.day != _today;

  /// The first open of a new day on the desktop: the tabs left from earlier
  /// days close into Recently closed, and the day starts on the note chosen
  /// to open on launch, or else on a blank draft. Today's notes from other
  /// devices stay in the list. Returns whether it was a new day.
  bool _startNewDay() {
    if (!_isNewDay) return false;
    final opening = _workspace.selectedNoteId;
    _workspace.rollOver(_today);
    final fixed = widget.notes.byId(widget.prefs.defaultNoteId);
    if (fixed != null && !fixed.isArchived && !fixed.isHidden) {
      _workspace.open(fixed.id);
    } else if (!_openDraft() && opening != null) {
      _workspace.open(opening);
    }
    return true;
  }

  /// Opens the day's blank draft. One left blank from an earlier day is used
  /// again rather than another made beside it, and like any new note it is
  /// discarded if it is left without a word in it. False where the note limit
  /// leaves no room for one.
  bool _openDraft() {
    final kept = widget.notes.byId(_workspace.draft);
    final reused = kept != null && _isBlankPage(kept);
    if (!reused && !(_noteLimit?.canCreate ?? true)) return false;
    final id = reused
        ? kept.id
        : widget.notes.create(body: Note.blankBody, authored: false).id;
    if (reused) widget.notes.startAsNew(id);
    _freshNoteIds.add(id);
    _workspace
      ..open(id)
      ..draft = id;
    return true;
  }

  void _beginOpenSession() {
    // A new day closes the tabs on screen, so a recording into one of their
    // notes is delivered first, as on every other way off the screen.
    _afterRecordingLeaves(_isNewDay ? _workspace.openNoteIds : const {}, () {
      final previous = _selectedId;
      if (_startNewDay()) setState(() => _adoptWorkspaceSelection(previous));
      // A welcome note nobody has typed into yet is there to be read.
      // Appending a dated line to it and dropping the cursor underneath is
      // the opposite of that, and on a phone it would raise a keyboard over
      // the half that explains itself.
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
    });
  }

  /// The half of a widget tap that is not the note it opened.
  ///
  /// The note is already chosen and on screen: Write wanted nothing more than
  /// that. Capture and Dictate are each one thing done *in* that note, and on
  /// a tap that arrives while the app is already open that note is simply the
  /// one being read — the same note the widget would have opened.
  Future<void> _runWidgetAction(LaunchIntent intent) async {
    if (!mounted || intent == LaunchIntent.open) return;
    if (intent == LaunchIntent.recording) return _showRecordingNote();
    if (Onboarding.holdsOnlyWelcome(widget.notes)) {
      _createNoteNow();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    if (!_phonePageOpen) setState(() => _phonePageOpen = true);
    switch (intent) {
      case LaunchIntent.open:
      case LaunchIntent.continueWriting:
      case LaunchIntent.recording:
        return;
      case LaunchIntent.capture:
        await _selectedEditor?.pickAndInsertImages();
      case LaunchIntent.dictate:
        await _startVoiceRecording();
    }
  }

  /// A tap on the recording's notification or Live Activity: the note being
  /// recorded into, on screen. Never a hidden note from outside Hidden Notes,
  /// which only their own gate opens; the app simply comes back as it was.
  void _showRecordingNote() {
    final id = widget.recording?.session?.noteId;
    final note = id == null ? null : widget.notes.byId(id);
    if (id == null || note == null || (note.isHidden && !_hiddenMode)) return;
    if (id != _selectedId) _select(id, focusEditor: false);
    if (!_phonePageOpen) setState(() => _phonePageOpen = true);
  }

  /// Runs the action [intent] names, then one whose answer missed the
  /// launch's deadline, once that answer arrives.
  Future<void> _runWidgetActions(Future<LaunchIntent> intent) async {
    await _runWidgetAction(await intent);
    await _runWidgetAction(await QuickCapture.lateIntent());
  }

  Future<void> _runInitialImageAndWidgetActions() async {
    final interruptedSelection = await _recoverInterruptedImageSelection();
    if (!mounted || interruptedSelection) return;
    await _runWidgetActions(Future.value(widget.launchIntent));
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
        takePhoto: () => _pickImagesOnAndroid(noteId, takeNotePhoto),
        chooseFromLibrary: () =>
            _pickImagesOnAndroid(noteId, pickExistingImageFiles),
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
  /// its camera or system photo picker. This durable marker is needed where the
  /// operating system may reclaim the Activity while another one is open.
  Future<List<XFile>> _pickImagesOnAndroid(
    String noteId,
    Future<List<XFile>> Function() pick,
  ) async {
    widget.store.put(_pendingImageNoteKey, noteId);
    await widget.store.flush();
    try {
      return await pick();
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
        final silent = await recording.finishRecordingAndFlush(
          discardSilent: true,
        );
        if (!mounted) {
          progress.dismiss();
        } else if (silent) {
          progress.error('Nothing saved: the microphone was silent');
        } else {
          progress.success('Recording stopped');
        }
        return;
      }
      if (!await recording.hasMicrophone()) {
        if (mounted) {
          progress.error('No microphone found');
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
    if (mounted) NoiseRemovalScope.read(context)?.recorded(hash);
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
    final ai = _kapyAiOn ? _kapyAi : null;
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
        ask: ai == null || note == null
            ? null
            : VoiceAskActions(
                kapyAi: ai,
                noteId: note.id,
                hidden: note.isHidden,
                onManageAccounts: () => _manageKapyAccounts(ai),
                onSignIn: _kapySignIn,
                onUpgrade: _kapyUpgrade,
              ),
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
    return describeSpeechError(
      SyncRefusedException(400, code, {'lang': entry?.lang}),
    );
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
      return _selectedId == noteId ? _phoneEditorKey.currentState : null;
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
    if (widget.days case final days?) {
      for (final id in _dayOfFreshNote.keys.toList()) {
        final note = widget.notes.byId(id);
        if (note == null) {
          _dayOfFreshNote.remove(id);
          continue;
        }
        if (note.isEmpty && note.attachments.isEmpty) continue;
        if (days.setDay(id, _dayOfFreshNote.remove(id)!) == false && mounted) {
          Toast.show(
            context,
            'This note stays on today. $_dayCap',
            isError: true,
          );
        }
      }
    }
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
    if (mounted) setState(() {});
  }

  /// Whether [HomePage.folders] has read what this device holds, so that a
  /// folder it doesn't hold was deleted.
  bool _foldersRead = false;

  /// A folder made, renamed, filed into or deleted, here or on another
  /// device. A deleted folder's tab closes, once the folders are read.
  void _onFoldersChanged() {
    if (!mounted) return;
    final tree = widget.folders!.tree;
    if (_foldersRead &&
        _workspace.reconcileFolders((id) => tree.byId(id) != null)) {
      _reconcileSelection();
    }
    setState(() {});
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
    final seen = _notesSeen;
    _notesSeen = widget.notes.allNotes;
    final gone = widget.notes.byId(previous) == null
        ? seen.where((note) => note.id == previous).firstOrNull
        : null;
    // Leaving a note shared with you, with no copy kept, takes its page back
    // to the list, as archiving, hiding and deleting do. A copy kept stays
    // on the page in its place.
    if (_usesCompactLayout &&
        gone?.spaceId != null &&
        widget.account?.sharing?.spaceById(gone!.spaceId)?.isOwner != true &&
        !widget.notes.notes.any(
          (note) => !note.isShared && note.createdAt == gone!.createdAt,
        )) {
      _phonePageOpen = false;
      _findOnBack = null;
      _phonePagesUnder.clear();
      _phoneReturning = null;
      _phoneDay = null;
      _phoneDayPage = null;
    }
    _workspace.reconcile(
      available.map((note) => note.id),
      fallbackId: preferred ?? available.firstOrNull?.id,
    );
    _adoptWorkspaceSelection(
      previous,
      keepList: _usesCompactLayout && !_phonePageOpen,
    );
    final parked = widget.notes.byId(_noteBeforeSpace);
    if (parked == null || parked.isHidden || parked.isArchived) {
      _noteBeforeSpace = _openedBySpace = null;
    }
  }

  /// Only a phone has a compact layout: a desktop window of any width keeps
  /// the rail and the page.
  bool get _usesCompactLayout => AppPlatform.isMobile && !_listFits;

  /// Whether the window holds the notes list beside the page. Read from the
  /// window because selection is also reconciled, and the list shown, outside
  /// build.
  bool get _listFits {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return zoomedSizeOf(view).width >= kTwoPaneBreakpoint;
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
        _phoneEditorKey = _phoneEditorFor(id);
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
  /// and lets go of the editors of notes no longer on screen. With [keepList]
  /// the list on screen stays as it is rather than following the selection.
  void _adoptWorkspaceSelection(
    String? previous, {
    bool selectionPreview = false,
    bool keepList = false,
  }) {
    final next = _workspace.selectedNoteId;
    if (previous != next) {
      widget.account?.sync?.leaveNote(previous);
      _namer?.left(previous);
      _phoneEditorKey = _phoneEditorFor(next);
      if (!keepList) _showTabOf(next);
    }
    _selectedId = next;
    if (_phoneDay != null) {
      final note = widget.notes.byId(next);
      final nextDay = note == null ? _dayOfFreshNote[next] : _dayOfNote(note);
      if (previous != next &&
          nextDay != _phoneDay &&
          !_phoneDayKept.contains(next)) {
        _phoneDay = null;
        _phoneDayPage = null;
      }
    }
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
  /// A note still open — on screen, in a tab behind, or in the tabs a day's
  /// notes took the place of — is still being looked at, and one mid-way
  /// through a held-key switch may be switched back to. A note that got any
  /// writing, picture or recording is a real note from then on, and stops
  /// being a candidate even if later emptied.
  void _discardAbandonedBlanks() {
    if (_noteSwitchWorkspace != null) return;
    final open = {..._workspace.tabbedNoteIds, ..._workspace.keptNoteIds};
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
    // Plain [NotesStore.deleteAll], not [_forget]: none of these is on screen,
    // so the selection stays put, and a blank note owns no attachments to
    // sweep.
    widget.notes.deleteAll(abandoned);
  }

  /// Drawings on or off. A phone's Drawings is a page of Folders, so its bar
  /// follows: Folders into Drawings, and Notes out of it.
  void _setDrawingsOnly(bool on) {
    if (on == _drawingsOnly) return;
    _drawingsOnly = on;
    _phoneTab = on ? PhoneTab.folders : PhoneTab.notes;
  }

  /// Lists the tab [id] is in, when a note is opened from somewhere other
  /// than the list: a link, a pane, the note put back after the archive. A
  /// row the reader clicked is in the tab on screen already, a note of their
  /// own they share is in both, and the reader switching tabs moves no
  /// selection, so none of these is overruled. Beside the rail a drawing
  /// takes the list to Drawings, and a note takes it back to Notes, in the
  /// archive and Hidden Notes too.
  void _showTabOf(String? id) {
    if (id == null) return;
    final note = widget.notes.byId(id);
    if (note == null) return;
    if (!_listsKind(note)) _setDrawingsOnly(!_drawingsOnly);
    if (_specialMode || _drawingsOnly) return;
    final sharing = widget.account?.sharing;
    if (sharing != null && !sidebarTabLists(_sidebarTab, note, sharing)) {
      _sidebarTab = sidebarTabOf(note, sharing);
      // A phone's Shared is a page of Folders, as Drawings is.
      _phoneTab = _sidebarTab == SidebarTab.shared
          ? PhoneTab.folders
          : PhoneTab.notes;
    }
  }

  /// Abandons a held-key preview, and a walk down the list, before another
  /// interaction takes ownership. On the desktop that also puts the tabs back
  /// as the gesture found them, so a click or a change to the panes never
  /// inherits a half-previewed layout.
  bool _cancelNoteSwitchPreview() {
    _listWalkStart = null;
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
      _phoneEditorKey = _phoneEditorFor(_selectedId);
    }
    final open = _workspace.openNoteIds;
    _paneEditorKeys.removeWhere((id, _) => !open.contains(id));
    _scheduleDiscardAbandonedBlanks();
    return true;
  }

  /// Runs [change] at once, unless it would take the note being recorded into
  /// off the screen: one of [leaving]. That recording is delivered first,
  /// while the editor holding its note is still there to take it at the
  /// caret.
  void _afterRecordingLeaves(Set<String> leaving, VoidCallback change) {
    final recording = widget.recording;
    if (recording != null &&
        recording.isRecording &&
        leaving.contains(recording.session?.noteId)) {
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
    final leaving = workspacePreview?.displacedBy(id) ?? _leavingFor(id);
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

  void _previewFromSidebar(String id) {
    _listWalkStart ??= _selectedId;
    _select(id, focusEditor: false, selectionPreview: true);
  }

  /// The notes on screen that showing [id] would take off it: the focused
  /// one, which [id] takes the place of, or every one in front when [id]'s
  /// own tab comes forward instead. A folder, with a null [id], takes the
  /// place of every one.
  Set<String> _leavingFor(String? id) {
    if (id == null) return _workspace.openNoteIds;
    if (id == _selectedId) return const {};
    if (_usesCompactLayout || _specialMode) return {?_selectedId};
    if (_workspace.paneOf(id) >= 0) return const {};
    return _workspace.tabOf(id) >= 0 ? _workspace.openNoteIds : {?_selectedId};
  }

  void _selectNow(
    String id, {
    required bool focusEditor,
    bool selectionPreview = false,
    EditorWorkspacePreviewSession? workspacePreview,
  }) {
    if (!focusEditor) {
      _holdEditorAutofocus();
      // A preview may only activate an editor already mounted in another
      // pane. Move focus to the shortcut scope so the active-pane marker and
      // the real keyboard focus agree, while further Tabs still reach the
      // same held-key session.
      if (selectionPreview && _noteSwitcher.isActive) {
        _desktopShortcutFocus.requestScopeFocus();
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
      if (!selectionPreview) _phonePageOpen = true;
    });
    if (!selectionPreview) {
      widget.prefs.lastOpenedNoteId = id;
    }
    // Already open in another pane, whose editor is not rebuilt, so it will
    // not take the keyboard by itself.
    if (focusEditor && !_specialMode && _workspace.activePane != paneBefore) {
      _focusSelectedEditorHere();
    }
    final committed = _committedSwitchAwaitingSelection;
    if (selectionPreview && committed?.id == id) {
      _committedSwitchAwaitingSelection = null;
      _commitWorkspacePreview();
      if (committed!.focusEditor) _focusSelectedEditorHere();
    }
  }

  /// Keeps the editors that the next frame builds from taking the keyboard.
  void _holdEditorAutofocus() {
    _selectionAutofocusSuppressed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _selectionAutofocusSuppressed = false;
    });
  }

  void _openNoteToSide(String id) {
    if (_usesCompactLayout || _specialMode) return;
    _dismissListOverlay();
    _afterRecordingLeaves({
      ?_workspace.displacedByOpenToSide(id),
    }, () => _openNoteToSideNow(id));
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
  /// The note's editor lets go of the keyboard first: More hands it back to
  /// that editor as it closes, which would focus the note's pane again.
  void _splitEditor() {
    if (_usesCompactLayout || _specialMode || !_workspace.canSplit) return;
    final previous = _selectedId;
    _selectedEditor?.releaseKeyboard();
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
    _afterRecordingLeaves({?pane.noteId}, () {
      final previous = _selectedId;
      final at = _workspace.panes.indexWhere((open) => open.id == pane.id);
      if (!_workspace.close(at)) return;
      setState(() => _adoptWorkspaceSelection(previous));
      _afterPaneChange();
    });
  }

  PaneDropPlan? _planDrop(NoteDragData data, int index, PaneDropZone zone) {
    if (_specialMode ||
        data.notes.length > 1 ||
        widget.notes.byId(data.noteId) == null) {
      return null;
    }
    return _workspace.planDrop(data.noteId, index, zone);
  }

  void _dropNote(NoteDragData data, int index, PaneDropZone zone) {
    final plan = _planDrop(data, index, zone);
    if (plan == null) return;
    final target = _workspace.panes[index];
    _afterRecordingLeaves(
      {if (plan.action == PaneDropAction.replace) ?target.noteId},
      () {
        final previous = _selectedId;
        final at = _workspace.panes.indexWhere((pane) => pane.id == target.id);
        if (!_workspace.drop(data.noteId, at, zone)) return;
        setState(() => _adoptWorkspaceSelection(previous));
        _afterPaneChange();
      },
    );
  }

  /// Where the tab with [tabId] is on the row, or -1.
  int _tabIndex(String tabId) =>
      _workspace.tabs.indexWhere((tab) => '${tab.id}' == tabId);

  /// Changes the tabs once any recording into a note [leaving] the screen is
  /// delivered, then takes up the note in front. [change] finds its tab again
  /// by id, since delivering a recording can take a moment.
  void _changeTabs(
    Set<String> leaving,
    bool Function() change, {
    bool focus = true,
  }) {
    if (_specialMode) return;
    if (_cancelNoteSwitchPreview()) setState(() {});
    _afterRecordingLeaves(leaving, () {
      if (!mounted) return;
      final previous = _selectedId;
      if (!change()) return;
      setState(() => _adoptWorkspaceSelection(previous));
      _afterPaneChange(focus: focus);
    });
  }

  void _activateTab(String tabId) {
    final index = _tabIndex(tabId);
    if (index < 0) return;
    _changeTabs(
      index == _workspace.frontTabIndex ? const {} : _workspace.openNoteIds,
      () => _workspace.activateTab(_tabIndex(tabId)),
    );
  }

  /// Closes a tab, and offers it back for a moment. Its notes stay exactly
  /// where they are in the list.
  void _closeTab(String tabId) {
    final index = _tabIndex(tabId);
    if (index < 0) return;
    final tab = _workspace.tabs[index];
    final title = switch (tab.folderId) {
      final folderId? => widget.folders?.tree.byId(folderId)?.name,
      null => widget.notes.byId(tab.noteId)?.title,
    };
    _changeTabs(
      index == _workspace.frontTabIndex ? _workspace.openNoteIds : const {},
      () {
        if (!_workspace.closeTab(_tabIndex(tabId))) return false;
        Toast.show(
          context,
          title == null ? 'Closed the tab' : 'Closed "$title"',
          icon: KapyIcons.closeRounded,
          action: 'Reopen',
          onAction: _reopenTab,
        );
        return true;
      },
    );
  }

  void _closeOtherTabs(String tabId) {
    final index = _tabIndex(tabId);
    if (index < 0) return;
    _changeTabs(
      index == _workspace.frontTabIndex ? const {} : _workspace.openNoteIds,
      () {
        final at = _tabIndex(tabId);
        if (at < 0) return false;
        _workspace.closeOthers(at);
        return true;
      },
    );
  }

  /// Opens the tab closed last again, in front and in its place on the row,
  /// and takes down the toast that offered it back.
  void _reopenTab() {
    if (!_workspace.canReopen) return;
    Toast.withdraw(_reopenTab);
    _changeTabs(_workspace.openNoteIds, _workspace.reopen);
  }

  void _goBack() {
    if (!_workspace.canGoBack) return;
    _changeTabs(_leavingFor(_workspace.backNoteId), _workspace.back);
  }

  void _goForward() {
    if (!_workspace.canGoForward) return;
    _changeTabs(_leavingFor(_workspace.forwardNoteId), _workspace.forward);
  }

  /// A swipe or the mouse's Back and Forward over the page, and wherever no
  /// closer place takes them: through the notes shown, as Go back and Go
  /// forward do.
  bool _stepNotesShown(BackForwardStep step) {
    final back = step == BackForwardStep.back;
    if (!(back ? _workspace.canGoBack : _workspace.canGoForward)) return false;
    back ? _goBack() : _goForward();
    return true;
  }

  /// A step over the tab row: to the tab beside the one in front.
  bool _stepTabs(BackForwardStep step) {
    final next =
        _workspace.frontTabIndex + (step == BackForwardStep.back ? -1 : 1);
    if (next < 0 || next >= _workspace.tabs.length) return false;
    _activateTab('${_workspace.tabs[next].id}');
    return true;
  }

  /// A step over the list beside the page, where Notes and Folders are two
  /// tabs and the folder in front is a level of Folders. Back goes up out of
  /// the folder, then to Notes; Forward goes to Folders, then back down the
  /// way Back came up. The list stays open, over the page or beside it, and
  /// slides when it turns; a step between folders slides the page. A list
  /// with no Folders, such as Drawings', steps as the page does.
  bool _stepList(BackForwardStep step) {
    final tree = widget.folders?.tree;
    if (tree == null || !_offersFolders) {
      if (_stepNotesShown(step)) _pageSteps.took(step);
      return false;
    }
    final inFront = switch (_folderInFront) {
      final id? => tree.byId(id),
      null => null,
    };
    void show(String folderId) => _changeTabs(
      _workspace.openNoteIds,
      () => _workspace.openFolder(folderId),
      focus: false,
    );
    if (step == BackForwardStep.back) {
      if (!_foldersShown) return false;
      if (inFront?.parentId case final parentId?) {
        _foldersSteppedOut.add(inFront!.id);
        show(parentId);
        _pageSteps.took(step);
        return false;
      }
      widget.prefs.foldersShown = false;
      return true;
    }
    if (!_foldersShown) {
      widget.prefs.foldersShown = true;
      return true;
    }
    final into = _foldersSteppedOut.isEmpty
        ? null
        : tree.byId(_foldersSteppedOut.removeLast());
    if (into == null || inFront == null || into.parentId != inFront.id) {
      _foldersSteppedOut.clear();
      return false;
    }
    show(into.id);
    _pageSteps.took(step);
    return false;
  }

  /// A step over Tasks, its filter list or its page: to the filter beside the
  /// one shown, in the list's order.
  bool _stepTasks(BackForwardStep step) {
    final controller = _taskController;
    if (controller == null) return false;
    final choices = taskFilterChoices(
      board: controller.read(),
      today: _todayTasks(controller),
      labelOf: _taskNoteLabel,
    );
    final at = choices.indexWhere((choice) => choice.filter == _taskFilter);
    final next = at + (step == BackForwardStep.back ? -1 : 1);
    if (at < 0 || next < 0 || next >= choices.length) return false;
    setState(() => _taskFilter = choices[next].filter);
    return true;
  }

  /// What ⌘W closes: the focused pane while the tab is split, else the tab
  /// while there is another to show. Unbound with one tab of one note, so
  /// the chord never leaves an empty page the reader did not mean to.
  VoidCallback? get _closeShortcutAction {
    if (_specialMode || _usesCompactLayout) return null;
    if (_workspace.isSplit) return () => _closePane(_workspace.activePane);
    final front = _workspace.frontTab;
    if (front == null || _workspace.tabs.length < 2) return null;
    return () => _closeTab('${front.id}');
  }

  /// Opens each of [ids] in a tab of its own at the end of the row, behind
  /// the one in front, and leaves the screen as it is.
  void _openInNewTabs(List<String> ids) {
    if (_specialMode || _usesCompactLayout) return;
    final previous = _selectedId;
    var opened = false;
    for (final id in ids) {
      opened = _workspace.openInNewTab(id) || opened;
    }
    if (!opened) return;
    setState(() => _adoptWorkspaceSelection(previous));
  }

  /// Shows [folderId] in the tab in front, or with [behind] in a new tab
  /// behind it, the way a note opens from the list.
  void _openFolder(String folderId, {required bool behind}) {
    if (behind) {
      final previous = _selectedId;
      if (!_workspace.openFolderInNewTab(folderId)) return;
      setState(() => _adoptWorkspaceSelection(previous));
      return;
    }
    _dismissListOverlay();
    _changeTabs(
      _workspace.openNoteIds,
      () => _workspace.openFolder(folderId),
      focus: false,
    );
  }

  /// ⌘↵ in the list: the note the arrows walked to moves to a tab of its own
  /// behind this one, and this tab goes back to the note the walk began on.
  void _openSelectedInNewTab() {
    final id = _selectedId;
    final start = _listWalkStart;
    if (id == null ||
        start == null ||
        start == id ||
        _usesCompactLayout ||
        widget.notes.byId(start) == null) {
      return;
    }
    _changeTabs({id}, () {
      _workspace.open(start);
      return _workspace.openInNewTab(id);
    }, focus: false);
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
        _workspace.frontTab != null) {
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

  /// The day a note was given, where it has one.
  DateTime? _ownDayOf(Note note) => widget.days?.dayOf(note.id);

  /// The day [note] sits on: the one it was started from, its own, or the
  /// day it was last edited.
  DateTime _dayOfNote(Note note) =>
      _dayOfFreshNote[note.id] ??
      noteDay(note, widget.prefs.displayTime, ownDay: _ownDayOf(note));

  /// A day picked in the page's week or its month: [notes], its notes, become
  /// the tabs in the day's own order where it has one, pinned tabs first, and
  /// otherwise the earliest written first. They open one to a tab, the first
  /// in front, up to [EditorWorkspace.dayTabLimit] of them, a later day's
  /// too, though the list leaves that day out until it comes. All of them are
  /// lit in the list, which stays whole. A day with none opens a page to
  /// write on it, in the folder in front if there is one. The tabs open
  /// before the first day was picked come back with the notice's Undo, or a
  /// click on the day picked.
  void _openDay(DateTime day, List<Note> notes) {
    if (day == _workspace.dayInTabs) return _leaveDay();
    if (notes.isEmpty &&
        (widget.days == null || !(_noteLimit?.canCreate ?? true))) {
      // No page can be made: the open note is given the day if it is blank,
      // and otherwise the note limit says why.
      return _writeOnDay(day);
    }
    final folderId = _folderInFront;
    final keyboard = _weekHasKeyboard;
    if (_cancelNoteSwitchPreview()) setState(() {});
    _afterRecordingLeaves(_workspace.openNoteIds, () {
      if (!mounted) return;
      final previous = _selectedId;
      final first = _workspace.dayInTabs == null;
      final ids = [for (final note in notes) note.id];
      final opened = _workspace.showDay(
        day,
        widget.dayTabs?.arrange(day, ids).order ?? ids,
      );
      if (keyboard) _holdEditorAutofocus();
      setState(() => _adoptWorkspaceSelection(previous));
      Toast.show(
        context,
        _dayOpened(day, opened: opened, of: notes.length),
        icon: KapyIcons.calendarOutlined,
        action: first ? 'Undo' : null,
        onAction: first ? _leaveDay : null,
      );
      if (notes.isEmpty) {
        _writeOnDay(day, folderId: folderId);
      } else {
        _afterPaneChange(focus: !keyboard);
      }
    });
  }

  /// Brings back the tabs open before the first day was picked.
  void _leaveDay() {
    if (_workspace.dayInTabs == null) return;
    final keyboard = _weekHasKeyboard;
    _changeTabs(_workspace.openNoteIds, () {
      if (keyboard) _holdEditorAutofocus();
      return _workspace.leaveDay();
    }, focus: !keyboard);
  }

  /// A day's tabs arranged anew, here or on another device: the tabs of the
  /// day open now take the new order, the one in front staying in front.
  void _onDayTabsChanged() {
    final day = _workspace.dayInTabs;
    final tabs = widget.dayTabs;
    if (day == null || tabs == null) return;
    final order = tabs.arrange(day, [..._workspace.dayNoteIds]).order;
    if (_workspace.arrangeDay(order)) setState(() {});
  }

  /// Whether the keyboard is on a day of the page's week, there by Tab. A day
  /// picked from there keeps it, so Return again brings the tabs back.
  bool get _weekHasKeyboard =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<DayStrip>() !=
      null;

  /// What the notice says once [day]'s notes are the tabs: "Opened today's
  /// note", "Opened the 3 notes on Tue 18", "Opened 12 of the 15 notes on
  /// Tue 18", or for a day with none, "No notes on Sat 22".
  String _dayOpened(DateTime day, {required int opened, required int of}) {
    final brief = SidebarTimestamp.briefDay(
      day,
      today: dayShown(widget.notes.now(), widget.prefs.displayTime),
    );
    final near = switch (brief) {
      'Today' || 'Yesterday' || 'Tomorrow' => brief.toLowerCase(),
      _ => null,
    };
    String notes(String what) =>
        near == null ? 'the $what on $brief' : "$near's $what";
    return switch (of) {
      0 => near == null ? 'No notes on $brief' : 'No notes $near',
      1 => 'Opened ${notes('note')}',
      _ when opened < of => 'Opened $opened of ${notes('$of notes')}',
      _ => 'Opened ${notes('$of notes')}',
    };
  }

  /// The day a note started from a tapped day will be given once it has its
  /// first words: a page left untouched writes neither the note nor a day.
  final Map<String, DateTime> _dayOfFreshNote = {};

  /// Why a note can't be given a day, once 20,000 notes have one.
  static const _dayCap =
      '20,000 notes already have a day, the most Kapy Notes keeps.';

  /// Writes on [day]: a page with no note behind it until the first words, so
  /// leaving it untouched leaves nothing. With [folderId] the page goes into
  /// that folder, as one made with the folder's tab in front does.
  void _writeOnDay(DateTime day, {String? folderId}) {
    if (widget.days == null) return;
    _createNote(
      titled: false,
      onMade: (id) {
        _dayOfFreshNote[id] = day;
        if (folderId == null) return;
        if (widget.folders?.file([id], folderId) case final refusal?) {
          Toast.show(context, folderRefusalText(refusal), isError: true);
        }
      },
    );
  }

  /// Gives the note whose page is open another day, or none at all.
  Future<void> _moveToAnotherDay(Note note) async {
    final days = widget.days;
    if (days == null) return;
    final displayTime = widget.prefs.displayTime;
    final today = dayShown(widget.notes.now(), displayTime);
    final picked = await showDayPicker(
      context,
      today: today,
      filled: days.dayOf(note.id) ?? noteDay(note, displayTime),
      firstWeekday: firstWeekday(context),
      sheet:
          AppPlatform.isMobile &&
          MediaQuery.sizeOf(context).width < kTwoPaneBreakpoint,
    );
    if (picked == null || !mounted) return;
    if (days.setDay(note.id, picked) == false) {
      Toast.show(context, "Couldn't move this note. $_dayCap", isError: true);
    }
  }

  /// Starts a new note, unless the one already open is a new note.
  ///
  /// Returns whether anything was actually created, which is what the swipe
  /// cue needs in order not to announce a note that does not exist.
  /// [onMade] is told the note the page opens on, made or reused, and never
  /// called when none is, as at the note limit.
  bool _createNote({
    bool drawing = false,
    String body = '',
    bool titled = true,
    ValueChanged<String>? onMade,
  }) {
    final recording = widget.recording;
    if (recording != null && recording.isRecording) {
      unawaited(
        recording.finishRecordingAndFlush().then((_) {
          if (mounted) {
            _createNoteNow(
              drawing: drawing,
              body: body,
              titled: titled,
              onMade: onMade,
            );
          }
        }),
      );
      // The recording is about to land in the note that is open, so that note
      // will not be blank by the time this runs and a new one will follow.
      return true;
    }
    return _createNoteNow(
      drawing: drawing,
      body: body,
      titled: titled,
      onMade: onMade,
    );
  }

  /// What New makes in the space on screen: a drawing in Drawings, a note
  /// everywhere else.
  bool _createInSpace() {
    if (!_tasksMode) return _createNote(drawing: _drawingsOnly);
    _taskAddFocus.requestFocus();
    return true;
  }

  /// A note's name on a task's mark, with its space's name after it when
  /// that name exists. Shared by the Tasks list, the phone home, and ⌘K.
  String _taskNoteLabel(Note note) =>
      taskNoteLabel(note, widget.account?.sharing?.spaceById(note.spaceId));

  /// Today's open tasks: every open one but those whose note waits for a
  /// later day, as the Tasks page lists them and its counts count them.
  List<TaskItem> _todayTasks(TasksController tasks) {
    tasks.waits = taskWaitsToday(context, tasks, widget.prefs.displayTime);
    return tasks.openIn(null);
  }

  /// Opens a task's note where it lives, leaving Tasks.
  void _openTaskNote(String id) {
    final note = widget.notes.byId(id);
    final sharing = widget.account?.sharing;
    if (note == null) return;
    // A phone opens it over the list it was asked from, Tasks included, so
    // Back comes back to that list as it was left.
    if (_usesCompactLayout && _shownNote(id) != null) return _openFromPage(id);
    _showSpace(
      sharing != null && sidebarTabOf(note, sharing) == SidebarTab.shared
          ? LibrarySpace.shared
          : LibrarySpace.notes,
    );
    _select(id);
  }

  /// [body] is the note's first words, from the ⌘K menu's field. A note made
  /// while a folder's tab is in front, or a phone shows a folder, goes into
  /// that folder. One that isn't [titled] starts as an empty page rather than
  /// under "New Note", as a day tapped on a phone's week opens it (M11).
  bool _createNoteNow({
    bool drawing = false,
    String body = '',
    bool titled = true,
    ValueChanged<String>? onMade,
  }) {
    final creatingHidden = _hiddenMode;
    final folderId = drawing ? null : _folderInFront ?? _phoneFolderShown?.id;
    final blank = drawing || body.isNotEmpty ? null : _blankNoteAlreadyOpen();
    if (blank == null && !(_noteLimit?.canCreate ?? true)) {
      unawaited(_explainNoteLimit(creating: true));
      return false;
    }
    final note =
        blank ??
        widget.notes.create(
          body: drawing || body.isNotEmpty || !titled ? body : Note.blankBody,
          authored: body.isNotEmpty,
          hidden: creatingHidden,
          drawing: drawing,
        );
    if (blank == null) {
      _freshNoteIds.add(note.id);
    } else if (titled) {
      widget.notes.startAsNew(blank.id);
    } else {
      widget.notes.startAsEmpty(blank.id);
    }
    onMade?.call(note.id);
    if (folderId != null) {
      if (widget.folders?.file([note.id], folderId) case final refusal?) {
        Toast.show(context, folderRefusalText(refusal), isError: true);
      }
    }
    setState(() {
      _archiveQuery = '';
      _archiveMode = false;
      _tasksMode = false;
      if (!creatingHidden) _hiddenMode = false;
      // A new note is the person's own, so it is listed where they can see
      // it being written.
      _sidebarTab = SidebarTab.mine;
      _setDrawingsOnly(drawing);
      // And it is written on the page, so a list open over the page goes.
      _listOverlaid = false;
      _setSelectedId(note.id);
      _phonePageOpen = true;
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
    final note = widget.notes.byId(_selectedId);
    return note != null && _isBlankPage(note) ? note : null;
  }

  /// Whether [note] is still a blank page, which a new note may as well be.
  /// See [_blankNoteAlreadyOpen].
  bool _isBlankPage(Note note) {
    if (note.isArchived || note.isShared) return false;
    if (note.isHidden != _hiddenMode) return false;
    if (!note.isEmpty || note.attachments.isNotEmpty) return false;
    // A blank canvas was chosen as one: "new note" means a page to write on.
    if (note.isDrawing) return false;
    // Nobody can type into it, so it is not the new note either.
    return !_limitHolds(note);
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

  void _archiveNote(String id) => _archiveNotes([id]);

  /// Files notes away: one from its row or the keyboard, or every picked one
  /// the reader may change, in one go.
  void _archiveNotes(List<String> ids) {
    final going = [
      for (final id in ids)
        if (_canEditNote(widget.notes.byId(id))) id,
    ];
    if (going.isEmpty) return;
    _letGo(going);
    final open = _selectedId;
    final archivingSelected = going.contains(open);
    final index = archivingSelected ? widget.notes.activeIndexOf(open!) : -1;
    final othersOpen =
        !_usesCompactLayout &&
        (_workspace.isSplit || _workspace.tabs.length > 1);
    // A phone's one note, archived from its row or its page, can come
    // straight back to where it was.
    final before = _usesCompactLayout && going.length == 1
        ? widget.notes.byId(going.single)
        : null;
    final at = before == null ? -1 : widget.notes.indexOf(before.id);
    widget.notes.archiveAll(going);
    _picks.clear();
    if (before != null) {
      final title = before.title.trim();
      Toast.show(
        context,
        title.isEmpty ? 'Archived' : 'Archived “$title”',
        icon: archiveIcon,
        action: 'Undo',
        onAction: () => widget.notes.undoArchive(before, at),
      );
    } else {
      Toast.show(
        context,
        going.length == 1
            ? 'Moved to Archive'
            : 'Moved ${going.length} notes to Archive',
        icon: archiveIcon,
        action: 'View',
        onAction: () => _viewArchived(going.first),
      );
    }
    if (archivingSelected) _openInPlaceOf(index, othersOpen: othersOpen);
  }

  /// Forgets what the page kept for notes that are leaving the list.
  void _letGo(Iterable<String> ids) {
    for (final id in ids) {
      if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    }
  }

  /// Opens what takes the place of the open note, which has just left the
  /// list from [index] of the store's notes: archived, hidden or deleted.
  ///
  /// Its pane or its tab closed with it, and a note the reader opened is in
  /// front in its place: opening the next note in the list there would take
  /// the place of a note the reader chose to keep open. Otherwise the next
  /// one down.
  void _openInPlaceOf(int index, {required bool othersOpen}) {
    if (othersOpen) {
      widget.prefs.lastOpenedNoteId = _selectedId;
      _focusSelectedEditorHere();
      return;
    }
    final next = _successorInList(index);
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
    if (_usesCompactLayout) _closePhonePage();
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

  void _restoreNote(String id) => _restoreNotes([id]);

  /// Returns archived notes to the list, one or every picked one.
  void _restoreNotes(List<String> ids) {
    final going = [
      for (final id in ids)
        if (_canEditNote(widget.notes.byId(id))) id,
    ];
    if (going.isEmpty) return;
    final index = _visibleNotes.indexWhere((note) => note.id == _selectedId);
    widget.notes.restoreAll(going);
    _picks.clear();
    Toast.show(
      context,
      going.length == 1 ? 'Note restored' : '${going.length} notes restored',
      icon: restoreIcon,
    );
    if (going.contains(_selectedId)) _openNearby(index);
  }

  /// Opens the note now at [index] of the list on screen, or the last one,
  /// once the open note has gone from the archive or Hidden Notes.
  void _openNearby(int index) {
    final remaining = _visibleNotes;
    final next = remaining.isEmpty
        ? null
        : remaining[index.clamp(0, remaining.length - 1)].id;
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
  }

  Future<void> _hideNote(String id) => _hideNotes([id]);

  /// Moves the reader's own notes behind Hidden Notes, one or every picked
  /// one, once Hidden Notes is set up.
  Future<void> _hideNotes(List<String> ids) async {
    bool hides(Note? note) =>
        note != null && !note.isArchived && !note.isHidden && !note.isShared;
    if (!ids.any((id) => hides(widget.notes.byId(id)))) return;
    if (_hiddenAuthBusy) return;
    setState(() => _hiddenAuthBusy = true);
    final configured = await widget.hiddenNotesGate.ensureConfigured(context);
    if (!mounted) return;
    setState(() => _hiddenAuthBusy = false);
    if (!configured) return;

    final going = [
      for (final id in ids)
        if (hides(widget.notes.byId(id))) id,
    ];
    if (going.isEmpty) return;
    _letGo(going);
    final open = _selectedId;
    final hidingSelected = going.contains(open);
    final index = hidingSelected ? widget.notes.activeIndexOf(open!) : -1;
    final othersOpen =
        !_usesCompactLayout &&
        (_workspace.isSplit || _workspace.tabs.length > 1);
    widget.notes.hideAll(going);
    _picks.clear();
    final shortcut = widget.shortcuts
        .hintFor(ShortcutAction.toggleHiddenFolder)
        ?.displayLabel;
    final them = going.length == 1 ? 'it' : 'them';
    final discovery = AppPlatform.hasPointer && shortcut != null
        ? 'Press $shortcut to find $them.'
        : widget.prefs.hiddenFolderVisible
        ? 'Choose Hidden in the notes filter to find $them.'
        : 'Show it from Settings to find $them.';
    Toast.show(
      context,
      going.length == 1
          ? 'Moved to Hidden Notes. $discovery'
          : 'Moved ${going.length} notes to Hidden Notes. $discovery',
      icon: hiddenIcon,
    );
    if (hidingSelected) _openInPlaceOf(index, othersOpen: othersOpen);
  }

  void _unhideNote(String id) => _unhideNotes([id]);

  /// Returns hidden notes to the ordinary list, one or every picked one.
  void _unhideNotes(List<String> ids) {
    final going = [
      for (final id in ids)
        if (widget.notes.byId(id)?.isHidden ?? false) id,
    ];
    if (going.isEmpty) return;
    final index = _visibleNotes.indexWhere((note) => note.id == _selectedId);
    widget.notes.unhideAll(going);
    _picks.clear();
    Toast.show(
      context,
      going.length == 1
          ? 'Moved to Notes'
          : 'Moved ${going.length} notes to Notes',
      icon: unhideIcon,
    );
    if (going.contains(_selectedId)) _openNearby(index);
  }

  void _togglePinnedNote(String id) =>
      _pinNotes([id], pinned: !widget.notes.isPinned(id));

  /// Pins notes, or unpins them: one from its row, or every picked one.
  void _pinNotes(List<String> ids, {required bool pinned}) {
    final changed = widget.notes.pinAll(ids, pinned: pinned);
    if (changed == 0) return;
    _picks.clear();
    final count = changed == 1 ? 'Note' : '$changed notes';
    Toast.show(
      context,
      pinned ? '$count pinned' : '$count unpinned',
      icon: KapyIcons.pinOutlined,
    );
  }

  /// Does what was chosen for the picked notes, to the ones the list says
  /// it applies to.
  void _actOnPicked(PickedAction action, List<String> ids) {
    switch (action) {
      case PickedAction.openTabs:
        _openInNewTabs(ids);
        _picks.clear();
      case PickedAction.pin || PickedAction.unpin:
        _pinNotes(ids, pinned: action == PickedAction.pin);
      case PickedAction.hide:
        unawaited(_hideNotes(ids));
      case PickedAction.unhide:
        _unhideNotes(ids);
      case PickedAction.archive:
        _archiveNotes(ids);
      case PickedAction.restore:
        _restoreNotes(ids);
      case PickedAction.delete:
        unawaited(_deletePicked(ids));
    }
  }

  void _onPicksChanged() {
    if (mounted) setState(() {});
  }

  /// Throws one note away, for good once its toast's Undo has gone: see
  /// [_forget].
  ///
  /// The note leaves this device and, through the tombstone, every other one
  /// it syncs to. A note somebody else shares with this account only leaves
  /// its own notes. A question goes first; it offers not to be asked again,
  /// and Settings asks it again.
  Future<void> _deleteNote(String id) async {
    final note = widget.notes.byId(id);
    if (note == null || !_canRemoveNote(note)) return;
    final owner = _sharedBy(note);
    if (widget.prefs.askBeforeDeleting) {
      final title = note.title.trim();
      final name = title.isEmpty ? 'this note' : '"$title"';
      final confirmed = await _confirmDelete(
        title: owner == null ? 'Delete note?' : 'Remove from your notes?',
        body: owner == null
            ? 'Deletes $name from every synced device.'
            : 'Removes $name from your notes, and from your other devices '
                  'once they are up to date. $owner and '
                  "everyone it's shared with keep it.",
        action: owner == null ? 'Delete' : 'Remove',
        canStopAsking: true,
      );
      if (!confirmed || !mounted) return;
    }
    _forget([id]);
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
        'Notes shared with you are removed from your notes, and from your '
        'other devices once they are up to date. Their owners keep them.';
    if (theirs == 0) {
      return 'Deletes ${_noteCount(ids.length).toLowerCase()} from every '
          'synced device.';
    }
    if (theirs == ids.length) return shared;
    return 'Deletes your own notes from every synced device. $shared';
  }

  /// Empties the archive.
  Future<void> _deleteAllArchived() async {
    final ids = widget.notes.archivedNotes
        .where((note) => _canEditNote(note))
        .map((note) => note.id)
        .toList();
    if (ids.isEmpty) return;
    final removed = _sharedByOthers(ids);
    final confirmed = await _confirmDelete(
      title: 'Empty Archived Notes?',
      body: _deleteBody(ids),
      action: removed == ids.length ? 'Remove all' : 'Delete all',
    );
    if (!confirmed || !mounted) return;
    _forget(ids);
  }

  /// Throws picked notes away. One goes as its row's Delete does, asking
  /// only if the reader still wants to be asked; several always ask, with
  /// how many.
  Future<void> _deletePicked(List<String> picked) async {
    if (picked.length == 1) return _deleteNote(picked.single);
    final ids = picked
        .where((id) => _canRemoveNote(widget.notes.byId(id)))
        .toList();
    if (ids.isEmpty) return;
    final removed = _sharedByOthers(ids);
    final theirs = removed == ids.length;
    final confirmed = await _confirmDelete(
      title: theirs
          ? 'Remove from your notes?'
          : ids.length == 1
          ? 'Delete note?'
          : 'Delete ${ids.length} notes?',
      body: _deleteBody(ids),
      action: theirs ? 'Remove' : 'Delete',
    );
    if (!confirmed || !mounted) return;
    _forget(ids);
    _picks.clear();
  }

  /// How many of [ids] somebody else shares with this account.
  int _sharedByOthers(List<String> ids) =>
      ids.where((id) => _sharedBy(widget.notes.byId(id)) != null).length;

  /// The part every delete shares: take the notes out of every list, drop
  /// whatever the selection and the editor were holding onto, and say so,
  /// with Undo. They go for good once the toast does, with the pictures and
  /// recordings nothing else refers to. Until then nothing of them has
  /// changed, so Undo puts them back as they were, the open one open again
  /// on a desktop's page, and the app being killed keeps them. Leaving the
  /// app ends the toast as its time running out would: see
  /// [Toast.giveUpUndo].
  void _forget(List<String> ids) {
    final removing = ids.toSet();
    final removed = _sharedByOthers(ids);
    _letGo(removing);
    final losingSelected = removing.contains(_selectedId);
    final index = losingSelected
        ? widget.notes.activeIndexOf(_selectedId!)
        : -1;
    final othersOpen =
        !_usesCompactLayout &&
        (_workspace.isSplit || _workspace.tabs.length > 1);
    final reopen =
        losingSelected && !_usesCompactLayout && (_specialMode || !othersOpen)
        ? _selectedId
        : null;
    final notes = widget.notes..holdDelete(removing);
    _picks.drop(removing);
    setState(() {
      if (losingSelected && _specialMode) {
        _setSelectedId(_visibleNotes.firstOrNull?.id);
      }
    });
    if (losingSelected && _specialMode) {
      widget.prefs.lastOpenedNoteId = _selectedId;
    } else if (losingSelected) {
      _openInPlaceOf(index, othersOpen: othersOpen);
    }
    final inItsPlace = _selectedId;
    Toast.show(
      context,
      forgottenMessage(deleted: ids.length - removed, removed: removed),
      icon: deleteIcon,
      action: 'Undo',
      onAction: () {
        notes.undoDelete(removing);
        if (reopen == null || !mounted || _selectedId != inItsPlace) return;
        setState(() => _setSelectedId(reopen));
        widget.prefs.lastOpenedNoteId = reopen;
      },
      onGone: () {
        notes.deleteAll(removing);
        // The notes are gone, so their attachments have no owner. See
        // [NotesStore.sweepBlobs] for why this is the only place that counts.
        unawaited(notes.sweepBlobs());
      },
    );
  }

  static String _noteCount(int count) =>
      count == 1 ? 'This note' : 'These $count notes';

  /// One question, asked the same way every time, with the destructive answer
  /// marked as one.
  ///
  /// [canStopAsking] adds "Don’t ask again", for one note at a time only.
  /// Ticked, it counts once the answer is yes; deleting several notes at once
  /// always asks.
  Future<bool> _confirmDelete({
    required String title,
    required String body,
    required String action,
    bool canStopAsking = false,
  }) async {
    var stopAsking = false;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                body,
                style: TextStyle(
                  fontSize: AppTypeScale.control,
                  color: context.palette.textPrimary,
                  height: 1.4,
                ),
              ),
              if (canStopAsking) ...[
                const SizedBox(height: 10),
                StatefulBuilder(
                  builder: (context, setState) => CheckboxListTile(
                    key: const ValueKey('delete-stop-asking'),
                    value: stopAsking,
                    onChanged: (value) =>
                        setState(() => stopAsking = value ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Don’t ask again',
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: context.palette.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
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
    final confirmed = answer ?? false;
    if (confirmed && stopAsking) widget.prefs.askBeforeDeleting = false;
    return confirmed;
  }

  void _toggleArchive() {
    _picks.clear();
    setState(() {
      final entering = !_archiveMode;
      _archiveMode = entering;
      _hiddenMode = false;
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

    _picks.clear();
    setState(() {
      _archiveMode = false;
      _hiddenMode = true;
      _archiveQuery = '';
      _setSelectedId(_narrowed(widget.notes.hiddenNotes).firstOrNull?.id);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
  }

  void _leaveHiddenNotes() {
    if (!_hiddenMode || !mounted) return;
    final previous = _selectedId;
    _picks.clear();
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
  }

  /// The Hidden Notes shortcut: Notes with Hidden chosen, behind its gate,
  /// whether or not the filter lists Hidden; or, from Hidden, back out.
  Future<void> _toggleHiddenFromShortcut() async {
    if (_hiddenMode) return _leaveHiddenNotes();
    await _toggleHiddenNotes();
    if (!mounted || !_hiddenMode) return;
    setState(() {
      _tasksMode = false;
      _setDrawingsOnly(false);
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
      _when = NotesWhen.anyTime;
    });
  }

  void _setWhen(NotesWhen when) => setState(() => _when = when);

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
      if (_listsKind(note)) note.id,
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

  /// Whether [note] may leave this account's notes: what it may change, and
  /// a note somebody else shares with it, view-only too.
  bool _canRemoveNote(Note? note) {
    if (note == null) return false;
    if (!note.isShared) return true;
    return widget.account?.sharing?.mayRemove(note) ?? false;
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

  /// Something just added can't sync because the account is full: said once,
  /// over whatever is on screen unless a sheet or dialog is already up, in
  /// which case the next change of state tries again.
  void _tellStorageFull() {
    final account = widget.account;
    final refused = account?.storageFull;
    if (!mounted || account == null || refused == null) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    account.storageFullShown();
    unawaited(_showStorageFull(refused));
  }

  Future<void> _showStorageFull(NoteAttachmentRef refused) async {
    final see = await showStorageFullSheet(context, refused);
    if (!see || !mounted) return;
    _showSettings(
      section: SettingsSection.account,
      reveal: 'plan-storage-usage',
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

  /// Null once the pin's shortcut is cleared, which drops the chord from
  /// More rather than leaving it promising a key that does nothing.
  String? get _pinShortcut =>
      widget.shortcuts.hintFor(ShortcutAction.toggleAlwaysOnTop)?.keycapLabel;

  /// Keep on top as More offers it on the note's page and a folder's.
  KapyMenuAction? get _onTopAction => _pinToggle == null
      ? null
      : KapyMenuAction(
          value: 'on-top',
          label: widget.prefs.alwaysOnTop
              ? 'Stop keeping on top'
              : 'Keep on top',
          icon: KapyIcons.layersRounded,
          hint: _pinShortcut,
        );

  /// The editable chord shown on the notes-list button in both layouts.
  String? get _sidebarShortcut =>
      widget.shortcuts.hintFor(ShortcutAction.toggleSidebar)?.displayLabel;

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
    _picks.clear();
    setState(() => _sidebarTab = tab);
  }

  /// Opens a person's page in Settings → Sharing from a heading in Shared.
  void _openPerson(String email) => _showSettings(
    section: SettingsSection.sharing,
    sharing: SharingStart.person(email),
  );

  /// Opens Settings → Sharing on Share with someone, from the empty Shared
  /// list.
  void _startSharing() => _showSettings(
    section: SettingsSection.sharing,
    sharing: const SharingStart.picking(),
  );

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
    unawaited(
      showShareDialog(
        context,
        note: note,
        sharing: sharing,
        billing: account.billing,
      ),
    );
  }

  /// What stands between this account and sharing, as the step Account & sync
  /// is about to show.
  static String _stepBeforeSharing(AccountState state) => switch (state) {
    AccountState.needsProfile => 'Choose your name first to share this note',
    AccountState.needsPassphrase =>
      'Choose a passphrase first to share this note',
    AccountState.locked ||
    AccountState.keysChanged => 'Unlock first to share this note',
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
    _openKapyAi(fromNote: true);
  }

  /// Whether Kapy AI is there to be asked: in this build, and switched on.
  bool get _kapyAiOn => _kapyAi?.enabled ?? false;

  bool _kapyAiWasOn = false;

  /// The search fields' words follow the Settings switch, so they are drawn
  /// again when it changes.
  void _onKapyAi() {
    if (_kapyAiOn == _kapyAiWasOn) return;
    setState(() {
      _kapyAiWasOn = _kapyAiOn;
      // Switched off, a phone's Kapy AI tab goes, so its bar is back on Notes.
      if (!_kapyAiOn && _phoneTab == PhoneTab.kapyAi) {
        _phoneTab = PhoneTab.notes;
      }
    });
  }

  /// What the phone's and Tasks' search fields read: Drawings' names what
  /// it finds, and the rest offer to ask Kapy AI only while it can be asked.
  /// The list beside the rail just says Search.
  String get _searchPlaceholder => _kapyAiOn && _space != LibrarySpace.drawings
      ? 'Search or Ask Kapy AI'
      : _space == LibrarySpace.drawings
      ? 'Search drawings'
      : _offersFolders && !_usesCompactLayout
      ? 'Search notes and folders'
      : 'Search';

  /// Opens the panel, or the phone's sheet, from the note on screen so its
  /// chip is attached. With [question] it first starts a new chat and asks
  /// it there, which is how ⌘K's Ask row and its Tab reach Kapy AI. On a
  /// phone, the note's own button ([fromNote]) has the sheet rest over the
  /// note; everything else opens it at full height. [typing] opens it with
  /// its field ready to type in, keyboard up, as the bar's New chat does.
  /// With [aboutNote] false the chat is about no note, whichever is open
  /// behind: the Kapy AI tab's + is not a note's own button.
  void _openKapyAi({
    String? question,
    bool fromNote = false,
    bool typing = false,
    bool aboutNote = true,
  }) {
    final ai = _kapyAi;
    if (ai == null || !ai.enabled) return;
    final shown = aboutNote ? _shownNote(_selectedId)?.id : null;
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
        rest: fromNote && noteId != null,
        typing: typing,
        panel: (close, expand, compact) => _kapyAiPanel(
          ai,
          onClose: close,
          compact: compact,
          inSheet: true,
          onExpand: expand,
          onOpenNote: (id) {
            close();
            _openFromPage(id);
          },
        ),
      ).whenComplete(_kapyPanel.close),
    );
  }

  Widget _kapyAiPanel(
    KapyAi ai, {
    required VoidCallback onClose,
    required ValueChanged<String> onOpenNote,
    bool compact = false,
    bool inSheet = false,
    VoidCallback? onExpand,
  }) => KapyAiPanel(
    kapyAi: ai,
    compact: compact,
    inSheet: inSheet,
    onExpand: onExpand,
    controller: _kapyPanel,
    noteTitle: _kapyNoteTitle,
    onOpenNote: onOpenNote,
    onManageAccounts: () => _manageKapyAccounts(ai),
    onSignIn: _kapySignIn,
    onUpgrade: _kapyUpgrade,
    onClose: onClose,
    now: widget.notes.now,
  );

  /// Settings › Voice & AI, at the accounts Kapy AI can answer with.
  void _manageKapyAccounts(KapyAi ai) => _showSettings(
    section: SettingsSection.voice,
    reveal: ai.accounts.isEmpty
        ? 'kapy-ai-toggle'
        : kapyAccountRowId(ai.accounts.first.kind),
  );

  VoidCallback? get _kapySignIn => widget.account == null
      ? null
      : () => _showSettings(section: SettingsSection.account);

  VoidCallback? get _kapyUpgrade => switch (widget.account?.billing) {
    final billing? => () => unawaited(showProSheet(context, billing: billing)),
    null => null,
  };

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
  /// In the page's bar it is a 32 control with a 16 icon, last behind a
  /// hairline.
  Widget? _kapyAiButton({
    required double extent,
    double gap = 0,
    bool pageBar = false,
    bool showsOpen = true,
  }) {
    final ai = _kapyAi;
    if (ai == null) return null;
    return KapyAiToolbarButton(
      kapyAi: ai,
      controller: _kapyPanel,
      onPressed: _toggleKapyAi,
      shortcut: widget.shortcuts
          .hintFor(ShortcutAction.toggleKapyAi)
          ?.displayLabel,
      extent: extent,
      radius: pageBar ? 8 : 10,
      iconSize: pageBar ? 16 : 17,
      trailingGap: gap,
      divided: pageBar,
      showsOpen: showsOpen,
    );
  }

  /// [notice] is said as a toast once settings is on screen, for whatever
  /// sent the person there rather than their own tap on the gear. [reveal]
  /// is the row it opens scrolled to, and [sharing] where Sharing opens.
  void _showSettings({
    SettingsSection? section,
    String? notice,
    String? reveal,
    SharingStart? sharing,
  }) {
    if (_settingsOpen) return;
    if (AppPlatform.isMobile) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _settingsOpen = true);
    }
    unawaited(_openSettings(section, notice, reveal, sharing));
  }

  Future<void> _openSettings(
    SettingsSection? section,
    String? notice,
    String? reveal,
    SharingStart? sharing,
  ) async {
    try {
      await showSettings(
        context,
        section: section,
        notice: notice,
        reveal: reveal,
        sharingStart: sharing,
        kapyAi: _kapyAi,
        namer: _namer,
        account: widget.account,
        notes: widget.notes,
        layoutPrefs: widget.prefs,
        shortcuts: widget.shortcuts,
        rates: widget.rates,
        updates: widget.updates,
        storeUpdates: widget.storeUpdates,
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
        onOpenNote: _select,
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
    TypeAhead.hold();
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

  /// The View menu, for the list beside the rail: what it shows, how it
  /// groups the notes, and List or Grid. A phone's filter row has the filter
  /// and the tags instead, and the archive, Hidden Notes and the pinned list
  /// keep their own order, so they have no Group by. On a folder's page it
  /// leaves out Archive and Hidden, whose notes are in no folder.
  Widget _notesControls(
    LibrarySpace space, {
    bool phone = false,
    bool onFolder = false,
    bool sort = true,
  }) => NotesListControls(
    show: _show,
    offersShow: !onFolder && space != LibrarySpace.shared,
    onShowChanged: _setShow,
    hiddenListed: _hiddenReachable,
    hiddenShortcut: widget.shortcuts
        .hintFor(ShortcutAction.toggleHiddenFolder)
        ?.displayLabel,
    archivedCount: _narrowed(widget.notes.archivedNotes).length,
    media: space == LibrarySpace.drawings ? null : _mediaFilter,
    onMediaChanged: (media) => setState(() => _mediaFilter = media),
    tags: widget.tags == null ? null : _tagsNarrowed,
    onTagsChanged: (tags) => setState(() => _tagFilter = tags),
    when: _when,
    onWhenChanged: _setWhen,
    today: dayShown(widget.notes.now(), widget.prefs.displayTime),
    cards: widget.prefs.noteCards,
    onCardsChanged: phone ? null : (cards) => widget.prefs.noteCards = cards,
    grouping: sort ? widget.prefs.notesGrouping : null,
    onGroupingChanged: sort
        ? (grouping) => widget.prefs.notesGrouping = grouping
        : null,
    phone: phone,
  );

  /// What narrows the list beside the rail, as one chip under its search
  /// or before the View icon on a folder's page; null while nothing does.
  Widget? _notesFilterChip(LibrarySpace space) {
    final media = space == LibrarySpace.drawings ? null : _mediaFilter;
    final tags = widget.tags == null ? null : _tagsNarrowed;
    if (!NotesFilterChip.shows(
      show: _show,
      media: media,
      tags: tags,
      when: _when,
    )) {
      return null;
    }
    return NotesFilterChip(
      show: _show,
      media: media,
      tags: tags,
      when: _when,
      onClear: _clearFilter,
    );
  }

  /// The page's days, in My notes and on a folder in front, counting what
  /// the list shows or what the folder holds; a day picked there opens those
  /// notes as the tabs ([_openDay]). Their month takes the bar's top left, so
  /// the open note's folders go in the line above its title. Kapy AI open
  /// over the page's right edge leaves them the one button for the day.
  Widget Function(bool compact, PlaceDays place)? _pageDays() {
    final folderId = _folderInFront;
    if (folderId == null && (_space != LibrarySpace.notes || _specialMode)) {
      return null;
    }
    final displayTime = widget.prefs.displayTime;
    return (compact, place) => ListenableBuilder(
      listenable: _kapyPanel,
      builder: (context, _) => DayStrip(
        key: _dayStrip,
        place: place,
        compact:
            compact ||
            (_kapyPanel.isOpen &&
                (_kapyAi?.enabled ?? false) &&
                MediaQuery.sizeOf(context).width < kapyAiOverlayBelow),
        today: dayShown(widget.notes.now(), displayTime),
        picked: _workspace.dayInTabs,
        onPick: _openDay,
        notes: folderId == null
            ? _filtered(widget.notes.search(''), anyTime: true)
            : widget.folders!.tree.notesIn(
                _filtered(_folderNotes, anyTime: true),
                folderId,
                deep: true,
              ),
        displayTime: displayTime,
        firstWeekday: firstWeekday(context),
        ownDay: widget.days == null ? null : _ownDayOf,
        opensTabs: true,
      ),
    );
  }

  /// Opens the ⌘K menu over whatever is on screen, and does what was chosen.
  /// From a list's own search field ([field]), Drawings' searches drawings
  /// alone.
  Future<void> _openCommandMenu({
    bool field = false,
    bool again = false,
  }) async {
    TypeAhead.hold();
    final shown = _tasksMode ? null : _shownNote(_selectedId);
    _findOnBack = null;
    if (!again) _findWords.clear();
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
      folders: widget.folders?.tree,
      showHidden: _hiddenReachable,
      hiddenUnlocked: _hiddenMode,
      askKapyAi: _kapyAiOn,
      tags: _tagShelf(const SizedBox.shrink()),
      marksOf: widget.tags == null
          ? null
          : (noteId) => [
              for (final tag in widget.tags!.tagsOf(noteId)) tagMarkOf(tag),
            ],
      tagNote: shown,
      fileNote: shown != null && _canMoveToFolder(shown) ? shown : null,
      phone:
          AppPlatform.isMobile &&
          MediaQuery.sizeOf(context).width < kTwoPaneBreakpoint,
      drawings: field && _space == LibrarySpace.drawings,
      field: _usesCompactLayout ? _findWords : null,
      onSetTaskDone: _taskController?.setDone,
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
        storeUpdates: widget.storeUpdates,
        desktopIntegration: widget.desktopIntegration,
        voicePrefs: widget.voicePrefs,
        localModels: widget.localModels,
        deviceSummarizer: widget.deviceSummarizer,
        deviceTranscriber: widget.deviceTranscriber,
        cloudAccess: widget.cloudAccess,
        hiddenNotes: widget.hiddenNotesGate,
      ),
    );
    if (choice is OpenNoteChoice && _usesCompactLayout && !_phonePageShown) {
      _findOnBack = (field: field);
    }
    if (!mounted || choice == null) return;
    _dismissListOverlay();
    switch (choice) {
      case OpenNoteChoice(:final note):
        if (note.isHidden) {
          _select(note.id);
        } else if (note.isDrawing) {
          if (_shownNote(note.id) == null) _showSpace(LibrarySpace.drawings);
          _select(note.id);
        } else {
          _openTaskNote(note.id);
        }
      case OpenFolderChoice(:final folderId) when _usesCompactLayout:
        _showFolders();
        setState(() => _phoneFolder = folderId);
      case OpenFolderChoice(:final folderId):
        _showNotes(NotesShow.all);
        _openFolder(folderId, behind: false);
      case MoveToFolderChoice(:final note):
        final window = MediaQuery.sizeOf(context);
        unawaited(
          moveNotesToFolder(
            context,
            spotAt(
              Offset(
                (window.width - TagPopover.defaultWidth) / 2,
                commandMenuTop(window),
              ),
            ),
            widget.folders!,
            [note.id],
          ),
        );
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
    TypeAhead.hold();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _taskAddFocus.requestFocus();
    });
  }

  /// Whether the list holds [note]: Drawings holds the drawings, with its
  /// archive and Hidden Notes, and every other list holds the notes, and a
  /// drawing that a sync race left words beside, for those words.
  bool _listsKind(Note note) => _drawingsOnly
      ? note.isDrawing
      : !note.isDrawing || note.hasTextBesideDrawing;

  /// Narrows [notes] to the space the list is showing, and everything that
  /// walks the list (the arrow keys, the note after an archived one) walks
  /// what is on screen. The ordinary list is also split by whose the notes
  /// are once there is an account to have shared anything with.
  List<Note> _narrowed(List<Note> notes) {
    final sharing = _drawingsOnly || _specialMode
        ? null
        : widget.account?.sharing;
    return [
      for (final note in notes)
        if (_listsKind(note) &&
            (sharing == null || sidebarTabLists(_sidebarTab, note, sharing)))
          note,
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

  /// [notes] narrowed to the space, to the tags and media the filter has
  /// ticked, and unless [anyTime] to When's days. Drawings has no media
  /// filter: every item in it is a drawing.
  List<Note> _filtered(List<Note> notes, {bool anyTime = false}) {
    final tags = widget.tags;
    final byTag = tags == null ? const TagFilter() : _tagsNarrowed;
    final byMedia =
        !_drawingsOnly && _mediaFilter.length < NoteMedia.values.length;
    final displayTime = widget.prefs.displayTime;
    final span = anyTime
        ? null
        : _when.span(
            today: dayShown(widget.notes.now(), displayTime),
            firstWeekday: firstWeekday(context),
          );
    return [
      for (final note in _narrowed(notes))
        if (!_dayOfFreshNote.containsKey(note.id) &&
            (span == null ||
                span.covers(
                  noteDay(note, displayTime, ownDay: _ownDayOf(note)),
                )) &&
            (!byMedia || NoteMedia.shows(note, _mediaFilter)) &&
            (!byTag.narrowed ||
                byTag.matches([
                  for (final tag in tags!.tagsOf(note.id)) tag.id,
                ])))
          note,
    ];
  }

  /// How many notes the list shows as the filter narrows it, for the bar
  /// over the list, whatever the search has narrowed the list to. By day,
  /// Notes leaves out a note for a later day until its day, and so does
  /// Drawings beside the rail. A [phone] lists every drawing under Recent, so
  /// its Drawings counts them all.
  int _matchingCount({required bool phone}) {
    final notes = _filtered(
      _archiveMode
          ? widget.notes.archivedNotes
          : _hiddenMode
          ? widget.notes.hiddenNotes
          : widget.notes.notes,
    );
    return (_space == LibrarySpace.notes ||
                (_space == LibrarySpace.drawings && !phone)) &&
            widget.prefs.notesGrouping == NotesGrouping.byDate
        ? _listedByDay(notes).length
        : notes.length;
  }

  /// Opens [space] from the rail with nothing narrowed, the way the tabs it
  /// replaces did. Choosing the space already open is how the list goes back
  /// to All notes, as the filter's ✕ does.
  void _showSpace(LibrarySpace space) {
    _pinnedOnly = false;
    _clearFilter();
    _picks.clear();
    _openSpace(space);
  }

  /// Turns a phone's Home between Notes and Tasks. Unlike [_showSpace] it
  /// leaves the Notes list as it was, its filter, Pinned and picks waiting
  /// for the way back; the bar is how the list goes back to All notes.
  void _showHome({required bool tasks}) {
    if (tasks == _tasksMode) return;
    _openSpace(tasks ? LibrarySpace.tasks : LibrarySpace.notes);
  }

  /// A phone's Folders with its tree, from Drawings, Shared or a folder's
  /// notes, or from another tab.
  void _showFolders() {
    if (_drawingsOnly || _sharedPage) _showSpace(LibrarySpace.notes);
    setState(() {
      _phoneTab = PhoneTab.folders;
      _phoneFolder = null;
      _tasksMode = false;
    });
  }

  /// A tap on the phone's bar. A tab tapped again starts its page over: Notes
  /// goes back to All notes and Folders to its tree. Notes tapped on Tasks,
  /// which it holds, turns back as the header does, keeping the list.
  void _selectPhoneTab(PhoneTab tab) {
    final again = tab == _phoneTab;
    // Drawings and Shared are pages of Folders, so another tab leaves them,
    // for All notes as Notes' own tap there does.
    if (!again && (_drawingsOnly || _sharedPage)) {
      _showSpace(LibrarySpace.notes);
    }
    switch (tab) {
      case PhoneTab.notes when again && _tasksMode:
        _showHome(tasks: false);
      case PhoneTab.notes when again:
        _showSpace(LibrarySpace.notes);
      case PhoneTab.folders when again:
        _showFolders();
      case _:
        // Tasks is a page of Notes, so another tab leaves it too, with the
        // Notes list kept as it was.
        setState(() {
          _phoneTab = tab;
          _tasksMode = false;
        });
    }
  }

  /// What opening [space] sets up, whether or not the list was reset.
  void _openSpace(LibrarySpace space) {
    setState(() {
      _phonePageOpen = false;
      _findOnBack = null;
      _phonePagesUnder.clear();
      _phoneReturning = null;
      _phoneDay = null;
      _phoneDayPage = null;
      // A phone's Drawings and Shared are pages of Folders; the other spaces
      // are Notes.
      _phoneTab = space == LibrarySpace.drawings || space == LibrarySpace.shared
          ? PhoneTab.folders
          : PhoneTab.notes;
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

  /// Whether the list beside the rail offers the Notes | Folders switch:
  /// in My notes' ordinary list, so not in Drawings, Shared, Archive or
  /// Hidden Notes.
  bool get _offersFolders =>
      widget.folders != null && _space == LibrarySpace.notes && !_specialMode;

  /// Whether the list beside the rail shows the folder tree.
  bool get _foldersShown => _offersFolders && widget.prefs.foldersShown;

  /// The folder the tab in front shows, where it shows one.
  String? get _folderInFront =>
      _specialMode || _usesCompactLayout || widget.folders == null
      ? null
      : _workspace.frontTab?.folderId;

  /// Whether Move to folder… files [note] from ⌘K or the page's More, as it
  /// does from the note's row: one of the person's own, beside the folders.
  bool _canMoveToFolder(Note note) =>
      widget.folders != null &&
      !_specialMode &&
      !_usesCompactLayout &&
      _canFile(note);

  /// Whether folders hold [note]: one of the person's own notes, and not a
  /// drawing.
  bool _canFile(Note note) {
    final sharing = widget.account?.sharing;
    return !note.isDrawing &&
        (sharing == null || sidebarTabOf(note, sharing) == SidebarTab.mine);
  }

  /// The notes the folder tree files: the person's own, unfiltered. A
  /// drawing, an archived or Hidden note and a note shared with them never
  /// shows in a folder, so no count gives one away.
  List<Note> get _folderNotes => [
    for (final note in widget.notes.notes)
      if (_canFile(note)) note,
  ];

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
          compact ? _buildPhone(context) : _buildWide(context),
        );
        // Over the open note, and wherever no closer place takes them, a
        // swipe and the mouse's Back and Forward walk the notes shown.
        final content = BackForwardArea(
          steps: _pageSteps,
          onStep: _stepNotesShown,
          child: page,
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
            onKeepChoice: _tasksMode
                ? () => _tasksPage.currentState?.keepChoice() ?? false
                : null,
            onTakeNext: _tasksMode
                ? () => _tasksPage.currentState?.takeNext() ?? false
                : null,
            onStartEarly: _tasksMode
                ? () => _tasksPage.currentState?.startEarly() ?? false
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
            onCloseTab: _closeShortcutAction,
            onReopenTab: _specialMode ? null : _reopenTab,
            onGoBack: _specialMode ? null : _goBack,
            onGoForward: _specialMode ? null : _goForward,
            onFocusPane: [
              for (var index = 0; index < EditorWorkspace.maxPanes; index++)
                _specialMode || index >= _workspace.paneCount
                    ? null
                    : () => _focusPane(index),
            ],
            onOpenSettings: _showSettings,
            onZoomIn: widget.prefs.zoomIn,
            onZoomOut: widget.prefs.zoomOut,
            onResetZoom: widget.prefs.resetZoom,
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
    // A phone on its side with the keyboard up has no room to spare: the page
    // gives up its bar for the lines being typed.
    final cramped = isCrampedPage(MediaQuery.sizeOf(context), keyboardInset);
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
            final pageDays = _pageDays();
            final moreActions = _folderInFront == null
                ? _pageActions(selected)
                : [
                    ?_onTopAction,
                    for (final group in folderActions()) ...group,
                  ];
            final unloaded = [
              for (final ref in selected?.attachments ?? const [])
                if (ref case NoteImageRef(src: _?, isPreparing: false)) ref,
            ];
            final taskBoard = _taskController?.read();
            final taskToday = switch (_taskController) {
              final controller? => _todayTasks(controller),
              null => const <TaskItem>[],
            };
            final tasks = _tasksMode ? _taskController : null;
            final createNoun = tasks != null && taskBoard != null
                ? 'task'
                : space == LibrarySpace.drawings
                ? 'drawing'
                : 'note';
            final newNoteShortcut = widget.shortcuts.hintFor(
              ShortcutAction.newNote,
            );
            final create = (
              label: 'New $createNoun',
              tooltip: SidebarWindowBar.newTooltip(createNoun, newNoteShortcut),
              onPressed: _createInSpace,
            );
            final assistant = _kapyAiButton(
              extent: AppPlatform.hasPointer
                  ? 32
                  : AppControlMetrics.iconButtonExtent,
              pageBar: true,
            );
            final sidebar = Sidebar(
              notes: _foldersShown ? _folderNotes : _visibleNotes,
              pinnedNoteIds: widget.notes.pinnedNoteIds,
              lockedNoteIds: _noteLimit?.lockedIds ?? const {},
              selectedId: _selectedId,
              query: _archiveQuery,
              displayTime: widget.prefs.displayTime,
              onSearch: () => unawaited(_openCommandMenu(field: true)),
              onClearQuery: () => setState(() => _archiveQuery = ''),
              onSelect: AppPlatform.isDesktop ? _selectFromSidebar : _select,
              onMoveSelect: AppPlatform.isDesktop ? _previewFromSidebar : null,
              onEnterSelected: AppPlatform.isDesktop
                  ? _enterSelectedEditorFromSidebar
                  : null,
              onOpenToSide: _specialMode ? null : _openNoteToSide,
              onOpenInNewTab: _specialMode
                  ? null
                  : (id) => _openInNewTabs([id]),
              onOpenSelectedInNewTab: _specialMode
                  ? null
                  : _openSelectedInNewTab,
              tabbedIds: _specialMode ? const {} : _workspace.tabbedNoteIds,
              openElsewhereIds: _specialMode
                  ? const {}
                  : _workspace.openNoteIds.difference({?_selectedId}),
              onArchive: _archiveNote,
              onRestore: _restoreNote,
              onHide: (id) => unawaited(_hideNote(id)),
              onUnhide: _unhideNote,
              onTogglePin: _specialMode ? null : _togglePinnedNote,
              archiveMode: _archiveMode,
              hiddenMode: _hiddenMode,
              onDelete: _deleteNote,
              asksBeforeDeleting: widget.prefs.askBeforeDeleting,
              onDeleteAll: () => unawaited(_deleteAllArchived()),
              picks: _picks,
              onPicked: _actOnPicked,
              onShare: widget.account == null ? null : _shareNote,
              sharing: widget.account?.sharing,
              collaborators:
                  widget.account?.sync?.collaboratorsByNote ?? const {},
              onOpenPerson: widget.account?.sharing == null
                  ? null
                  : _openPerson,
              onStartSharing: widget.account?.sharing == null
                  ? null
                  : _startSharing,
              tab: _sidebarTab,
              onTabChanged: _setSidebarTab,
              searchShortcut: widget.shortcuts.hintFor(
                ShortcutAction.findNotes,
              ),
              archiveShortcut: widget.shortcuts.hintFor(
                ShortcutAction.deleteNote,
              ),
              drawings: space == LibrarySpace.drawings,
              onNewDrawing: () => _createNote(drawing: true),
              engine: widget.engines.engine,
              now: widget.notes.now,
              cards: widget.prefs.noteCards,
              controls: _notesControls(
                space,
                sort: !_specialMode && !_showingPinnedOnly,
              ),
              filterChip: _notesFilterChip(space),
              grouping: widget.prefs.notesGrouping,
              ownDay: widget.days == null ? null : _ownDayOf,
              ofPickedDay: switch (_workspace.dayInTabs) {
                null => null,
                final day =>
                  (note) =>
                      _dayOfNote(note) == day ||
                      _workspace.dayNoteIds.contains(note.id),
              },
              when: _when,
              onWhenChanged: _setWhen,
              folders: switch (widget.folders) {
                final store? => (
                  store: store,
                  shown: _foldersShown,
                  onShown: _offersFolders
                      ? (shown) => widget.prefs.foldersShown = shown
                      : null,
                  open: widget.prefs.openFolders,
                  onOpen: widget.prefs.setFolderOpen,
                  inFront: _folderInFront,
                  onTab: _openFolder,
                  newFolder: _newFolder,
                  onMade: (folderId) {
                    widget.prefs.addNotesShown = true;
                    _openFolder(folderId, behind: false);
                  },
                ),
                null => null,
              },
              pinnedOnly: _showingPinnedOnly,
              onPinnedOnlyChanged: (value) =>
                  setState(() => _pinnedOnly = value),
              windowBar: SidebarWindowBar(
                title: _listTitle,
                count: _matchingCount(phone: false),
                noun: createNoun,
                onCreate: _createInSpace,
                newNoteShortcut: newNoteShortcut,
                onHide: () => _setListShown(false),
                hideShortcut: widget.shortcuts.hintFor(
                  ShortcutAction.toggleSidebar,
                ),
                onAskKapy: _kapyAiOn && space != LibrarySpace.drawings
                    ? _openKapyAi
                    : null,
                askKapyShortcut: widget.shortcuts.hintFor(
                  ShortcutAction.toggleKapyAi,
                ),
              ),
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SpacesRail(
                  space: space,
                  onSelected: _showSpace,
                  invitations: widget.account?.sharing?.invites.length,
                  tasks: taskBoard != null,
                  streak: widget.notes.streak,
                  onSettingsPressed: _showSettings,
                  settingsShortcut: widget.shortcuts.hintFor(
                    ShortcutAction.openSettings,
                  ),
                  updates: widget.updates,
                  onAccountPressed: widget.account == null
                      ? null
                      : () => _showSettings(section: SettingsSection.account),
                  user: widget.account?.user,
                  syncStatus: widget.account?.syncStatus,
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
                        ? BackForwardArea(
                            steps: _taskSteps,
                            onStep: _stepTasks,
                            child: TasksSidebar(
                              board: taskBoard,
                              today: taskToday,
                              filter: _taskFilter,
                              onFilter: (filter) =>
                                  setState(() => _taskFilter = filter),
                              labelOf: _taskNoteLabel,
                              onSearch: _openCommandMenu,
                              searchShortcut: widget.shortcuts.hintFor(
                                ShortcutAction.findNotes,
                              ),
                              searchPlaceholder: _searchPlaceholder,
                              onGotIt: switch (_taskFolds) {
                                final folds? when !folds.howSeen =>
                                  () => setState(folds.markHowSeen),
                                _ => null,
                              },
                              windowBar: SidebarWindowBar(
                                title: space.title,
                                count: taskToday.length,
                                countLabel: 'open',
                                noun: createNoun,
                                onCreate: _createInSpace,
                                newNoteShortcut: newNoteShortcut,
                                onHide: () => _setListShown(false),
                                hideShortcut: widget.shortcuts.hintFor(
                                  ShortcutAction.toggleSidebar,
                                ),
                              ),
                            ),
                          )
                        : BackForwardArea(onStep: _stepList, child: sidebar),
                    // No bottom inset here: on a tablet the note's footer
                    // holds its own controls above the home indicator, and
                    // the empty state does the same with its paper.
                    body: SafeArea(
                      left: false,
                      bottom: false,
                      child: _withKapyAi(
                        PagePane(
                          divided: listFits && listShown,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (tasks != null)
                                _buildTasksPage(
                                  tasks,
                                  listVisible: listFits && listShown,
                                  underList: !listFits && listShown,
                                  create: create,
                                )
                              else ...[
                                if (!cramped)
                                  PageToolbar(
                                    path: pageDays == null
                                        ? _pagePath(selected)
                                        : null,
                                    days: pageDays,
                                    onOpenFolder: widget.folders == null
                                        ? null
                                        : _openFolder,
                                    listVisible: listFits && listShown,
                                    underList: !listFits && listShown,
                                    onShowList: _toggleList,
                                    showListShortcut: _sidebarShortcut,
                                    create: create,
                                    noteOpen: selected != null,
                                    syncStatus: widget.account?.syncStatus,
                                    unloadedPictures: unloaded.length,
                                    onShowUnloadedPicture: unloaded.isEmpty
                                        ? null
                                        : () => _selectedEditor?.showAttachment(
                                            unloaded.first.offset,
                                          ),
                                    members: _selectedMembers,
                                    present: _selectedPresence,
                                    currentUserId:
                                        widget.account?.sharing?.userId ?? '',
                                    noteShared: selected?.isShared ?? false,
                                    onShare: _shareSelected,
                                    assistant: assistant,
                                    actions: _folderInFront == null
                                        ? null
                                        : const [],
                                    moreActions: moreActions,
                                    onMore: moreActions.isEmpty
                                        ? null
                                        : (action, at) => _runPageAction(
                                            action,
                                            selected,
                                            at,
                                          ),
                                    updates: widget.updates,
                                  ),
                                TabRowReveal(
                                  shown:
                                      !_specialMode &&
                                      _workspace.tabs.length > 1,
                                  child: BackForwardArea(
                                    steps: _pageSteps,
                                    onStep: _stepTabs,
                                    child: _buildTabRow(),
                                  ),
                                ),
                                Expanded(
                                  child: BackForwardSlide(
                                    child: LayoutBuilder(
                                      builder: (context, page) => DateLineSaved(
                                        saved: _savedOnDateLine(
                                          selected,
                                          page.maxWidth,
                                          unloadedPictures: unloaded.length,
                                          withNew: !listShown,
                                        ),
                                        child: switch ((
                                          widget.folders,
                                          pageDays,
                                        )) {
                                          (final folders?, _?) => NoteFolders(
                                            tree: folders.tree,
                                            onOpenFolder: _openFolder,
                                            child: _buildWideWorkspace(
                                              sidebar,
                                              cramped: cramped,
                                            ),
                                          ),
                                          _ => _buildWideWorkspace(
                                            sidebar,
                                            cramped: cramped,
                                          ),
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
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

  /// Where a page with no days is, for its bar: the list's place, then the
  /// open note's folders, or a drawing's name. Archived and Hidden notes are
  /// in no folder.
  PagePath _pagePath(Note? note) {
    final tree = widget.folders?.tree;
    final folderId = note == null || _specialMode || !_canFile(note)
        ? null
        : tree?.folderOf(note.id);
    return PagePath(
      icon: _archiveMode
          ? archiveIcon
          : _hiddenMode
          ? hiddenIcon
          : switch (_space) {
              LibrarySpace.notes => KapyIcons.noteOutlined,
              LibrarySpace.tasks => KapyIcons.tasksOutlined,
              LibrarySpace.drawings => KapyIcons.penRounded,
              LibrarySpace.shared => KapyIcons.groupOutlined,
            },
      root: _listTitle,
      levels: [
        if (tree != null && folderId != null)
          for (final folder in tree.pathOf(folderId))
            (name: folder.name, folderId: folder.id),
        if (note != null && note.isDrawing) (name: note.title, folderId: null),
      ],
    );
  }

  /// Saved, for the open note's date line while the page is too narrow for
  /// it in the bar, or for the count of pictures that didn't load that
  /// stands in for it there.
  ({String label, String? tooltip})? _savedOnDateLine(
    Note? note,
    double pageWidth, {
    required int unloadedPictures,
    required bool withNew,
  }) {
    if (note == null ||
        _folderInFront != null ||
        PageToolbar.savedFits(
          pageWidth,
          unloadedPictures: unloadedPictures,
          withNew: withNew,
        )) {
      return null;
    }
    final saved = savedState(widget.account?.syncStatus);
    return (label: saved.label, tooltip: saved.tooltip);
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
        .hintFor(ShortcutAction.deleteNote)
        ?.keycapLabel;
    final pinned = note != null && widget.notes.isPinned(note.id);
    return [
      KapyMenuAction(
        value: 'split',
        label: canSplit ? 'Split view' : splitBlocker ?? 'Split view',
        icon: KapyIcons.viewColumnOutlined,
        hint: canSplit
            ? widget.shortcuts.hintFor(ShortcutAction.splitEditor)?.keycapLabel
            : null,
        enabled: canSplit,
      ),
      ?_onTopAction,
      if (note != null && !_specialMode)
        KapyMenuAction(
          value: 'pin',
          label: pinned ? 'Unpin note' : 'Pin note',
          icon: KapyIcons.pinOutlined,
        ),
      if (note != null && _canMoveToFolder(note))
        const KapyMenuAction(
          value: 'folder',
          label: 'Move to folder…',
          icon: KapyIcons.folderMoveOutlined,
        ),
      if (mayEdit && widget.days != null) ...[
        const KapyMenuAction(
          value: 'day',
          label: 'Move to another day',
          icon: KapyIcons.calendarOutlined,
        ),
        if (widget.days!.dayOf(note.id) != null)
          const KapyMenuAction(
            value: 'undate',
            label: 'Remove day',
            icon: KapyIcons.calendarRemoveOutlined,
          ),
      ],
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
      if (!mayEdit && note != null && _sharedBy(note) != null)
        KapyMenuAction(
          value: 'delete',
          label: widget.prefs.askBeforeDeleting
              ? 'Remove note…'
              : 'Remove note',
          icon: deleteIcon,
          destructive: true,
        ),
      if (mayEdit)
        KapyMenuAction(
          value: _specialMode ? 'delete' : 'archive',
          label: _specialMode ? 'Delete permanently' : 'Archive note',
          icon: _specialMode ? deleteIcon : archiveIcon,
          hint: removeShortcut,
          destructive: _specialMode,
        ),
    ];
  }

  /// A phone note's More menu, in M09's groups: its day, then what files and
  /// shares it, then Hidden Notes, then the ways out of the list.
  KapyMenu _phoneMenu(Note note) {
    final mayEdit = _canEditNote(note);
    final days = widget.days;
    return (
      heading: null,
      groups: [
        [
          if (mayEdit && days != null) ...[
            const KapyMenuAction(
              value: 'day',
              label: 'Move to another day',
              icon: KapyIcons.calendarOutlined,
            ),
            if (days.dayOf(note.id) != null)
              const KapyMenuAction(
                value: 'undate',
                label: 'Remove day',
                icon: KapyIcons.calendarRemoveOutlined,
              ),
          ],
        ],
        [
          if (!_specialMode)
            KapyMenuAction(
              value: 'pin',
              label: widget.notes.isPinned(note.id) ? 'Unpin note' : 'Pin note',
              icon: KapyIcons.pinOutlined,
            ),
          if (!_specialMode &&
              widget.account != null &&
              (note.isShared || mayEdit))
            KapyMenuAction(
              value: 'share',
              label: note.isShared ? 'Sharing' : 'Share note',
              icon: KapyIcons.shareRounded,
            ),
          if (widget.folders != null && !_specialMode && _canFile(note))
            const KapyMenuAction(
              value: 'folder',
              label: 'Move to folder…',
              icon: KapyIcons.folderMoveOutlined,
            ),
          if (mayEdit && !_specialMode && widget.tags != null)
            const KapyMenuAction(
              value: 'tags',
              label: 'Tags',
              icon: KapyIcons.tagRounded,
            ),
        ],
        [
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
        ],
        [
          if (mayEdit && !_specialMode)
            const KapyMenuAction(
              value: 'archive',
              label: 'Archive note',
              icon: archiveIcon,
            ),
          if (_canRemoveNote(note))
            KapyMenuAction(
              value: 'delete',
              label: [
                _sharedBy(note) != null
                    ? 'Remove note'
                    : _specialMode
                    ? 'Delete permanently'
                    : 'Delete note',
                if (widget.prefs.askBeforeDeleting) '…',
              ].join(),
              icon: deleteIcon,
              destructive: true,
            ),
        ],
      ],
    );
  }

  /// Does what the page's More menu names: the window's own actions, then
  /// the folder's in front or the open note's. [at] is where a list or a
  /// field it opens goes.
  void _runPageAction(String action, Note? note, MenuSpot at) {
    switch (action) {
      case 'split':
        _splitEditor();
      case 'on-top':
        _pinToggle?.call();
    }
    if (_folderInFront case final folderId?) {
      if (widget.folders!.tree.byId(folderId) case final folder?) {
        unawaited(_runFolderAction(action, folder, at));
      }
      return;
    }
    if (note == null) return;
    switch (action) {
      case 'day':
        unawaited(_moveToAnotherDay(note));
      case 'undate':
        widget.days?.clearDay(note.id);
      case 'pin':
        _togglePinnedNote(note.id);
      case 'share':
        _shareNote(note.id);
      case 'folder':
        unawaited(moveNotesToFolder(context, at, widget.folders!, [note.id]));
      case 'tags':
        if (_phoneNavigator.currentContext case final page?) {
          unawaited(showTagPickerAt(page, at, [note.id]));
        }
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

  void _openTasksDone() =>
      setState(() => _taskFilter = const TaskFilter.done());

  /// Tasks on the page: Today and its date, how much is done and Choose
  /// again over Today, or the breadcrumb over the Done view.
  Widget _buildTasksPage(
    TasksController tasks, {
    required bool listVisible,
    required bool underList,
    required ({String label, String tooltip, VoidCallback onPressed}) create,
  }) {
    final filter = _taskFilter;
    final note = filter.noteId == null
        ? null
        : widget.notes.byId(filter.noteId);
    final home = note != null && tasks.read().home?.id == note.id;
    return Expanded(
      child: BackForwardArea(
        steps: _taskSteps,
        onStep: _stepTasks,
        child: TasksScreen(
          key: _tasksPage,
          controller: tasks,
          filter: filter,
          addFocus: _taskAddFocus,
          words: _taskWords,
          labelOf: _taskNoteLabel,
          onOpenNote: _openTaskNote,
          onOpenDone: _openTasksDone,
          images: widget.notes.blobs,
          displayTime: widget.prefs.displayTime,
          newTaskShortcut: widget.shortcuts
              .hintFor(ShortcutAction.newNote)
              ?.keycapLabel,
          toolbar: PageToolbar(
            path: filter.done
                ? PagePath(
                    icon: KapyIcons.tasksOutlined,
                    root: LibrarySpace.tasks.title,
                    levels: const [(name: 'Done', folderId: null)],
                  )
                : null,
            crumb: filter.done
                ? null
                : TasksTodayCrumb(
                    title: note == null || home
                        ? 'Today'
                        : _taskNoteLabel(note),
                    now: tasks.now(),
                  ),
            listVisible: listVisible,
            underList: underList,
            onShowList: _toggleList,
            showListShortcut: _sidebarShortcut,
            create: create,
            updates: widget.updates,
            actions: [
              if (!filter.done)
                TasksBandActions(
                  controller: tasks,
                  filter: filter,
                  onChooseAgain: () => _tasksPage.currentState?.chooseAgain(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The open tabs, under the toolbar while there is more than one.
  Widget _buildTabRow() {
    final front = _workspace.frontTab;
    final day = _workspace.dayInTabs;
    final ofDay = _workspace.dayNoteIds;
    var pinned = const <String>{};
    if ((day, widget.dayTabs) case (final day?, final tabs?)) {
      final arranged = tabs.arrange(day, [...ofDay]);
      pinned = arranged.order.take(arranged.pinned).toSet();
    }
    return NoteTabRow(
      tabs: [
        for (final tab in _workspace.tabs)
          if (tab.folderId case final folderId?) ...[
            if (widget.folders?.tree.byId(folderId) case final folder?)
              NoteTab(
                id: '${tab.id}',
                title: folder.name,
                icon: KapyIcons.folderOutlined,
              ),
          ] else if (widget.notes.byId(tab.noteId) case final note?)
            NoteTab(
              id: '${tab.id}',
              title: note.title,
              icon: _tabIcon(note),
              pinned:
                  widget.dayTabs != null &&
                      tab.noteIds.length == 1 &&
                      ofDay.contains(note.id)
                  ? pinned.contains(note.id)
                  : null,
            ),
      ],
      activeId: front == null ? null : '${front.id}',
      recentIds: [for (final tab in _workspace.recentTabs) '${tab.id}'],
      onSelect: _activateTab,
      onClose: _closeTab,
      onCloseOthers: _closeOtherTabs,
      onPin: day == null
          ? null
          : (id, {required pin}) {
              final tab = _workspace.tabs.firstWhere(
                (tab) => '${tab.id}' == id,
              );
              if (tab.noteId case final noteId?) {
                _pinDayTab(
                  day,
                  noteId,
                  pin: pin,
                  kept: {..._workspace.dayNoteIds},
                );
              }
            },
      // While the tab is split, the chord closes its focused pane first.
      closeShortcut: _workspace.isSplit
          ? null
          : widget.shortcuts.hintFor(ShortcutAction.closeTab)?.keycapLabel,
    );
  }

  /// The rail's icon for where a tab's note lives.
  static KapyIconData _tabIcon(Note note) => note.isDrawing
      ? KapyIcons.penRounded
      : note.isShared
      ? KapyIcons.groupOutlined
      : KapyIcons.noteOutlined;

  Widget _buildWideWorkspace(Sidebar sidebar, {required bool cramped}) {
    if (_specialMode) {
      final selected = widget.notes.byId(_selectedId);
      return selected == null
          ? EmptyState(onCreate: _createNote)
          : _buildEditor(
              selected,
              key: _archiveEditorKey,
              active: true,
              cramped: cramped,
            );
    }
    if (_folderInFront case final folderId?) {
      return _buildFolderPage(folderId, sidebar);
    }
    final panes = _workspace.panes;
    if (panes.isEmpty) return _emptyPage();

    return PaneSplitView(
      weights: _workspace.weights,
      onWeightsChanged: (weights) =>
          setState(() => _workspace.weights = weights),
      onEqualize: () => setState(_workspace.equalizeWeights),
      children: [
        for (var index = 0; index < panes.length; index++)
          _buildPane(index, cramped: cramped),
      ],
    );
  }

  /// The folder the tab in front shows: what is in it, filtered and grouped
  /// as the notes list is, with the list's own cards and rows.
  Widget _buildFolderPage(String folderId, Sidebar sidebar) {
    final displayTime = widget.prefs.displayTime;
    final folders = widget.folders!;
    final filed = _folderNotes;
    return FolderPage(
      key: ValueKey('folder-page-$folderId'),
      tree: folders.tree,
      folderId: folderId,
      filed: filed,
      notes: _filtered(filed),
      controls: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_notesFilterChip(LibrarySpace.notes) case final chip?) ...[
            Flexible(child: chip),
            const SizedBox(width: 8),
          ],
          _notesControls(LibrarySpace.notes, onFolder: true),
        ],
      ),
      cards: widget.prefs.noteCards,
      group: (context, notes) => groupNotes(
        notes,
        widget.prefs.notesGrouping,
        today: dayShown(widget.notes.now(), displayTime),
        displayTime: displayTime,
        firstTag: (note) => TagMarks.of(context, note.id).firstOrNull?.name,
        ownDay: widget.days == null ? null : _ownDayOf,
      ),
      noteTile: sidebar.noteTile,
      onTab: _openFolder,
      onMenu: (folder, at) => unawaited(_showFolderMenu(folder, at)),
      onFile: (noteIds, into, {adding = false}) =>
          fileNotes(context, folders, noteIds, into, adding: adding),
      addNotes: widget.prefs.addNotesShown,
      onAddNotes: (shown) => widget.prefs.addNotesShown = shown,
      dateOf: _changedOn,
    );
  }

  /// When [note] last changed, as the notes list says it, which Add notes
  /// gives with its title.
  String _changedOn(Note note) => SidebarTimestamp.glance(
    note.updatedAt,
    now: widget.notes.now(),
    displayTime: widget.prefs.displayTime,
  );

  /// A folder card's menu on its folder's page.
  Future<void> _showFolderMenu(Folder folder, Offset at) async {
    var spot = spotAt(at);
    final action = await showFolderMenu(
      context,
      at,
      folder,
      newInside: false,
      onClosed: (placed) => spot = placed,
    );
    if (action == null || !mounted) return;
    await _runFolderAction(action, folder, spot);
  }

  /// Does a folder's action from its card or, while it is in front, from the
  /// page's More. [at] is where a list or a field it opens goes.
  Future<void> _runFolderAction(String action, Folder folder, MenuSpot at) =>
      runFolderAction(
        context,
        action,
        at,
        store: widget.folders!,
        notes: _folderNotes,
        folder: folder,
      );

  Widget _buildPane(int index, {required bool cramped}) {
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
        cramped: cramped,
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
          .hintFor(ShortcutAction.closeTab)
          ?.displayLabel,
      planDrop: (data, zone) => _planDrop(data, index, zone),
      onDrop: (data, zone) => _dropNote(data, index, zone),
      child: body,
    );
  }

  /// A phone: the space's list over the bar and the +, and a note's page
  /// pushed over the list while it is open. Back, from the page's own button,
  /// iOS's edge swipe or Android's predictive back, pops the page.
  Widget _buildPhone(BuildContext context) {
    final selected = _shownNote(_selectedId);
    final level = _phoneLevelPage;
    final below = [
      for (final page in _phonePagesUnder)
        if (_shownNote(page.id) case final note?) (page: page, note: note),
    ];
    // Every level is a page, so Back, from Android's gesture or iOS's edge
    // swipe, which follows the finger, goes up one: a note to the note it
    // was opened from and then to its list, and a list opened from its tab's
    // own page (Pinned, Archive, Hidden, Drawings, Shared, a folder) to that
    // page. There, what the page has open goes next (see [_phoneRootBack]),
    // and only then does the app itself leave.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: ToastClearanceScope(
        child: NavigatorPopHandler(
          onPopWithResult: (_) {
            if (_phoneNavigator.currentState case final pages?) {
              unawaited(pages.maybePop());
            }
          },
          child: Navigator(
            key: _phoneNavigator,
            pages: [
              MaterialPage(key: _phoneListPage, child: _phoneList(root: true)),
              if (level != null) MaterialPage(key: level, child: _phoneList()),
              if (_phonePageOpen && selected != null) ...[
                for (final (:page, :note) in below)
                  MaterialPage(
                    key: page.page,
                    child: _phonePage(
                      note,
                      page.editor,
                      day: page.day,
                      kept: page.kept,
                    ),
                  ),
                // Until the note Back returns to is selected, its page is on
                // top, and the note leaving has none.
                if (_phoneReturning == null &&
                    !below.any((below) => below.page.editor == _phoneEditorKey))
                  MaterialPage(
                    key: _phoneTopPage,
                    child: _phonePage(
                      selected,
                      _phoneEditorKey,
                      day: _phoneDay,
                      kept: _phoneDayKept,
                    ),
                  ),
              ],
            ],
            onDidRemovePage: _popLevel,
          ),
        ),
      ),
    );
  }

  /// Whether this page has hidden Android's status bar; see [_syncStatusBar].
  bool _statusBarHidden = false;

  /// Hides Android's status bar while the keyboard leaves a phone on its side
  /// a cramped page to write in, and shows it again as soon as that stops:
  /// the keyboard closes, the phone turns upright, the caret leaves the note,
  /// or the app leaves the foreground. iPhones hide it in landscape on their
  /// own.
  void _syncStatusBar() {
    if (!AppPlatform.isAndroid || !mounted) return;
    final view = View.of(context);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final hide =
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        isCrampedPage(
          view.physicalSize / view.devicePixelRatio,
          view.viewInsets.bottom / view.devicePixelRatio,
        ) &&
        (_phoneEditorKey.currentState?.writing ??
            _selectedEditor?.writing ??
            false);
    if (hide == _statusBarHidden) return;
    _statusBarHidden = hide;
    unawaited(StatusBar.setHidden(hide));
  }

  static const _phoneListPage = ValueKey('phone-list');

  /// Whether Home's list is narrowed by a tag, a kind of note or a time,
  /// which Android's Back clears before it leaves the app.
  bool get _homeNarrowed =>
      _when != NotesWhen.anyTime ||
      filtersNarrowed(show: _show, media: _mediaFilter, tags: _tagsNarrowed);

  /// Whether a phone's page is up, over the list.
  bool get _phonePageShown => _phonePageOpen && _shownNote(_selectedId) != null;

  /// Back from the page to the list it was pushed over, past any notes
  /// opened from it.
  void _closePhonePage() {
    if (!_phonePageOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _phonePageOpen = false;
      _phonePagesUnder.clear();
      _phoneReturning = null;
      _phoneDay = null;
      _phoneDayPage = null;
    });
    _scheduleDiscardAbandonedBlanks();
    final find = _findOnBack;
    _findOnBack = null;
    if (find == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_openCommandMenu(field: find.field, again: true));
      }
    });
  }

  /// The list a phone opens from its tab's own page, on a page of its own
  /// over it, or null on that page. Tasks and Kapy AI open none: a list left
  /// under Tasks comes back with Notes.
  _PhoneLevel? get _phoneLevel {
    if (_tasksMode) return null;
    if (_hiddenMode) return _PhoneLevel.hidden;
    if (_archiveMode) return _PhoneLevel.archive;
    return switch (_phoneTab) {
      PhoneTab.notes when _showingPinnedOnly => _PhoneLevel.pinned,
      PhoneTab.folders when _drawingsOnly => _PhoneLevel.drawings,
      PhoneTab.folders when _sharedPage => _PhoneLevel.shared,
      PhoneTab.folders when _phoneFolderShown != null => _PhoneLevel.folder,
      _ => null,
    };
  }

  /// The key of [_phoneLevel]'s page. A folder's names the folder, so
  /// another folder is another page.
  ValueKey<Object>? get _phoneLevelPage => switch (_phoneLevel) {
    null => null,
    final level => ValueKey((level, _phoneFolderShown?.id)),
  };

  /// The page Back took off the phone's navigator: the note on top goes back
  /// to the one under it, and a level to its tab's own page. A page the
  /// state let go of first, as opening a tab or a space does, changes
  /// nothing more.
  void _popLevel(Page<Object?> page) {
    // The page Back was returning to, still waiting for its note, as a
    // recording into the note left finishes: that wait is over too.
    if (_phoneReturning case final returning? when page.key == returning.page) {
      _selectionRequest++;
      _phoneReturning = null;
      _phonePagesUnder.remove(returning);
      return _phonePageBack();
    }
    if (page.key == _phoneTopPage) return _phonePageBack();
    if (page.key != _phoneLevelPage) return;
    switch (_phoneLevel) {
      case _PhoneLevel.pinned:
        setState(() => _pinnedOnly = false);
      case _PhoneLevel.archive || _PhoneLevel.hidden:
        _setShow(NotesShow.all);
      case _:
        _showFolders();
    }
  }

  /// Back on the phone's tab's own page, where Tasks, the picks, another tab
  /// and a filter are in the page rather than pages of their own: a task's
  /// page returns to Tasks, Tasks to Notes, and the picks let go, though not
  /// on Kapy AI, which doesn't show them; then another tab returns to Notes,
  /// and Notes clears its filter.
  bool get _phoneRootHolds =>
      _tasksMode ||
      (_picks.on && _phoneTab != PhoneTab.kapyAi) ||
      _phoneTab != PhoneTab.notes ||
      _homeNarrowed;

  void _phoneRootBack() {
    final tasks = _tasksNavigator.currentState;
    if (tasks != null && tasks.canPop()) {
      unawaited(tasks.maybePop());
    } else if (_tasksMode) {
      _showHome(tasks: false);
    } else if (_picks.on && _phoneTab != PhoneTab.kapyAi) {
      _picks.clear();
    } else if (_phoneTab != PhoneTab.notes) {
      setState(() => _phoneTab = PhoneTab.notes);
    } else {
      _showSpace(LibrarySpace.notes);
    }
  }

  /// Draws [build] as the phone's tab's own page has the list under the
  /// level opened from it: nothing pinned-only, archived, hidden, drawn,
  /// shared or in a folder. The fields are back before it returns, so only
  /// what it builds sees the change; Back to that page makes it for good
  /// (see [_popLevel]).
  T _asPhoneRoot<T>(T Function() build) {
    final pinned = _pinnedOnly;
    final archive = _archiveMode;
    final hidden = _hiddenMode;
    final drawings = _drawingsOnly;
    final tab = _sidebarTab;
    final folder = _phoneFolder;
    _pinnedOnly = _archiveMode = _hiddenMode = _drawingsOnly = false;
    _sidebarTab = SidebarTab.mine;
    _phoneFolder = null;
    try {
      return build();
    } finally {
      _pinnedOnly = pinned;
      _archiveMode = archive;
      _hiddenMode = hidden;
      _drawingsOnly = drawings;
      _sidebarTab = tab;
      _phoneFolder = folder;
    }
  }

  /// Opens [id] from the note on a phone's page, on a page of its own over
  /// that note's, which Back comes back to with the tabs it keeps, unless
  /// [leavingDay]. The page Back is returning to is already under it.
  void _openFromPage(String id, {bool leavingDay = false}) {
    final from = _shownNote(_selectedId)?.id;
    if (_phoneReturning == null &&
        _phonePageShown &&
        from != null &&
        from != id) {
      setState(() {
        _phonePagesUnder.add((
          id: from,
          editor: _phoneEditorKey,
          page: _phoneTopPage,
          day: _phoneDay,
          kept: leavingDay ? const {} : _phoneDayKept,
        ));
        _phoneDay = null;
        _phoneDayPage = null;
      });
    }
    _select(id);
  }

  /// Back from the note on top of a phone's pages: to the note it was opened
  /// from, whose page and editor are still there, else to the list.
  void _phonePageBack() {
    while (_phonePagesUnder.isNotEmpty) {
      final page = _phonePagesUnder.last;
      if (_shownNote(page.id) == null) {
        _phonePagesUnder.removeLast();
        continue;
      }
      setState(() => _phoneReturning = page);
      _select(page.id, focusEditor: false);
      return;
    }
    _closePhonePage();
  }

  /// The editor for [id] on a phone's page: the one its page already has
  /// when Back is returning to it, else a new one. Either way Back is no
  /// longer returning: a note chosen in the meantime goes on top, with the
  /// page Back was returning to under it.
  GlobalKey<NoteEditorState> _phoneEditorFor(String? id) {
    final returning = _phoneReturning;
    _phoneReturning = null;
    if (returning == null || returning.id != id) {
      return GlobalKey<NoteEditorState>();
    }
    _phonePagesUnder.remove(returning);
    _phoneDay = returning.day;
    _phoneDayPage = returning.day == null ? null : returning.page;
    if (returning.day case final day?) {
      _phoneDayKept = {...returning.kept, ..._phoneDayIds(day), returning.id};
    }
    return returning.editor;
  }

  /// A phone's list: its tab's own page, or with [root] false the page of
  /// the level opened from it (see [_phoneLevel]). On the tab's page, what
  /// it has open goes back first; on a level's, its picks.
  Widget _phoneList({bool root = false}) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: _picks,
      builder: (context, child) => PopScope(
        canPop: root ? !_phoneRootHolds : !_picks.on,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || BackEntry.anyOpen) return;
          if (root) {
            _phoneRootBack();
          } else {
            _picks.clear();
          }
        },
        child: child!,
      ),
      child: ColoredBox(
        color: palette.isGlass ? Colors.transparent : palette.paperColor,
        child: ListenableBuilder(
          listenable: _toolbarSources,
          builder: (context, _) =>
              root ? _asPhoneRoot(_phoneListBody) : _phoneListBody(),
        ),
      ),
    );
  }

  Widget _phoneListBody() {
    final tasks = _tasksMode && _phoneTab == PhoneTab.notes
        ? _taskController
        : null;
    final ai = _phoneTab == PhoneTab.kapyAi && _kapyAiOn ? _kapyAi : null;
    // A swipe left turns Home to Tasks, and a swipe right turns Tasks
    // back to Notes, or goes back from a level's page, as its left
    // edge does.
    final turns = _taskController != null && _phoneHome;
    final level = _phoneLevel != null;
    // The Notes list stays built under Tasks, out of sight, so it comes
    // back scrolled and narrowed as it was left.
    final page = Stack(
      fit: StackFit.expand,
      children: [
        Visibility(
          visible: tasks == null && ai == null,
          maintainState: true,
          child:
              _phoneTab == PhoneTab.folders &&
                  !_drawingsOnly &&
                  !_sharedPage &&
                  widget.folders == null
              // A build without folders still has Drawings to open.
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PhoneListTitle(title: 'Folders', trailing: _phoneAccount()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: _phoneFolderTiles(),
                    ),
                  ],
                )
              : _phoneNotes(),
        ),
        if (ai != null)
          KapyAiPage(
            kapyAi: ai,
            onOpenChat: _openKapyAi,
            account: _phoneAccount(),
            now: widget.notes.now,
          ),
        if (tasks != null)
          Navigator(
            key: _tasksNavigator,
            pages: [
              MaterialPage(
                key: const ValueKey('phone-tasks'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _phoneHomeHeader(),
                    Expanded(
                      child: TasksScreen(
                        key: _tasksPage,
                        phone: true,
                        controller: tasks,
                        filter: _taskFilter,
                        onFilter: (filter) =>
                            setState(() => _taskFilter = filter),
                        addFocus: _taskAddFocus,
                        words: _taskWords,
                        labelOf: _taskNoteLabel,
                        onOpenNote: _openTaskNote,
                        onOpenTask: (item) {
                          widget.prefs.rememberCaret(
                            item.note.id,
                            item.line.end,
                          );
                          _openTaskNote(item.note.id);
                        },
                        onOpenDone: _openTasksDone,
                        images: widget.notes.blobs,
                        displayTime: widget.prefs.displayTime,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            onDidRemovePage: (_) {},
          ),
      ],
    );
    return PhoneSpaces(
      tab: _phoneTab,
      onSelected: _selectPhoneTab,
      foldersDot: _invitationsWaiting > 0,
      // Kapy AI's tab only while it can be asked, as its other ways in
      // are: its page has no switched-off state of its own.
      showKapyAi: _kapyAiOn,
      createLabel: tasks != null
          ? 'New task'
          : ai != null
          ? 'New chat'
          : _drawingsOnly
          ? 'New drawing'
          : 'New note',
      onCreate: tasks != null
          ? _createInSpace
          : ai != null
          ? () {
              ai.newChat();
              _openKapyAi(typing: true, aboutNote: false);
            }
          : () => _createNote(drawing: _drawingsOnly),
      createActions: [
        const KapyMenuAction(
          value: 'note',
          label: 'New note',
          icon: KapyIcons.noteAddRounded,
        ),
        if (_taskController != null)
          const KapyMenuAction(
            value: 'task',
            label: 'New task',
            icon: KapyIcons.tasksOutlined,
          ),
        if (widget.recording != null)
          const KapyMenuAction(
            value: 'voice',
            label: 'New voice note',
            icon: KapyIcons.micRounded,
          ),
        const KapyMenuAction(
          value: 'drawing',
          label: 'New drawing',
          icon: KapyIcons.penRounded,
        ),
      ],
      onCreateAction: _createFromPhone,
      child: SafeArea(
        bottom: false,
        child: PhoneHomeSwipe(
          onTurn: turns || level ? _phoneTurn : null,
          // Android's pages have no back swipe of their own, so there the
          // edge goes back ahead of a row's swipe, out of a level or Tasks.
          backFromEdge:
              (level || _tasksMode) &&
              Theme.of(context).platform != TargetPlatform.iOS,
          child: page,
        ),
      ),
    );
  }

  /// A sideways swipe on a phone's list, left for Tasks: see [PhoneHomeSwipe].
  void _phoneTurn(bool tasks) {
    final taskPage = _tasksNavigator.currentState;
    if (tasks) {
      if (_taskController != null && _phoneHome) _showHome(tasks: true);
    } else if (_phoneLevel != null) {
      unawaited(_phoneNavigator.currentState?.maybePop());
    } else if (taskPage != null && taskPage.canPop()) {
      unawaited(taskPage.maybePop());
    } else {
      _showHome(tasks: false);
    }
  }

  /// The rest of New, from a long press on the phone's +.
  void _createFromPhone(String choice) {
    switch (choice) {
      case 'note':
        _createNote();
      case 'task':
        _newTask();
      case 'voice':
        if (!_createNote()) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_startVoiceRecording());
        });
      case 'drawing':
        _createNote(drawing: true);
    }
  }

  /// Shared on a phone: a page of Folders, reached from its tile, which its
  /// arrow goes back to.
  bool get _sharedPage => !_specialMode && _space == LibrarySpace.shared;

  /// Home on a phone: Notes or Tasks, under the header that turns between
  /// them, rather than Drawings, Shared, Archive or Hidden.
  bool get _phoneHome =>
      _phoneTab == PhoneTab.notes &&
      !_specialMode &&
      (_space == LibrarySpace.notes || _space == LibrarySpace.tasks);

  /// A phone's Folders: the tree, or with [_phoneFolder] one folder's notes.
  /// Drawings and Shared, reached from it, are their own lists.
  bool get _phoneFolders =>
      _phoneTab == PhoneTab.folders &&
      !_drawingsOnly &&
      !_sharedPage &&
      widget.folders != null;

  /// The folder whose notes a phone's Folders shows, while it still exists.
  Folder? get _phoneFolderShown => _phoneFolders && _phoneFolder != null
      ? widget.folders!.tree.byId(_phoneFolder!)
      : null;

  /// [notes] as a list by day shows them, and so as the count over it
  /// counts them: a note for a later day stays off until its day, though a
  /// pinned one stays with Pinned. Archived and Hidden Notes list them all.
  List<Note> _listedByDay(List<Note> notes) {
    if (_specialMode || widget.days == null) return notes;
    final today = dayShown(widget.notes.now(), widget.prefs.displayTime);
    final pinned = widget.notes.pinnedNoteIds;
    return [
      for (final note in notes)
        if (pinned.contains(note.id) ||
            !waitsForLaterDay(_ownDayOf(note), today))
          note,
    ];
  }

  /// The notes a phone lists under Home's header, which counts them.
  List<Note> get _phoneHomeNotes => _space == LibrarySpace.notes
      ? _listedByDay(_visibleNotes)
      : _visibleNotes;

  Widget _phoneHomeHeader() => PhoneHomeHeader(
    tasks: _tasksMode,
    notesCount: _phoneHomeNotes.length,
    tasksCount: switch (_taskController) {
      final tasks? => _todayTasks(tasks).length,
      null => 0,
    },
    onNotes: () => _showHome(tasks: false),
    onTasks: _taskController == null ? null : () => _showHome(tasks: true),
    streak: widget.notes.streak,
    user: widget.account?.user,
    onSettings: _showSettings,
  );

  /// S, which opens Settings, where a phone's title row ends.
  Widget _phoneAccount() => AccountAvatar(
    key: const ValueKey('phone-account'),
    label: 'Settings',
    target: 44,
    user: widget.account?.user,
    onPressed: _showSettings,
  );

  /// The phone's list for Notes, Drawings, Shared and Folders: the list
  /// beside the rail, drawn for a phone under Home's header or the page's
  /// large title. Folders shows the tree under its Drawings and Shared tiles
  /// (M02), and a folder from it its notes.
  Widget _phoneNotes() {
    final folders = _phoneFolders;
    final folder = _phoneFolderShown;
    final tree = folders && folder == null;
    final notes = folder != null
        ? _filtered(
            widget.folders!.tree.notesIn(_folderNotes, folder.id, deep: true),
          )
        : tree
        ? _folderNotes
        : _phoneHomeNotes;
    final page = folder != null || _drawingsOnly || _sharedPage;
    final pinnedPage = !folders && _showingPinnedOnly;
    return Sidebar(
      key: _sharedPage
          ? const ValueKey('shared-page')
          : pinnedPage
          ? const ValueKey('pinned-page')
          : folder != null
          ? ValueKey('phone-folder-${folder.id}')
          : tree
          ? const ValueKey('phone-folders')
          : null,
      phone: true,
      ownDay: widget.days == null ? null : _ownDayOf,
      // The Pinned page from View all is titled as Drawings is, and its
      // arrow goes back to Home.
      windowBar: pinnedPage
          ? PhoneListTitle(
              title: 'Pinned',
              count: notes.length,
              onBack: () => setState(() => _pinnedOnly = false),
              trailing: _phoneAccount(),
            )
          : _phoneHome
          ? _phoneHomeHeader()
          : tree
          ? PhoneListTitle(title: 'Folders', trailing: _phoneAccount())
          : PhoneListTitle(
              title: folder?.name ?? _listTitle,
              count: folder != null
                  ? _listedByDay(notes).length
                  : _matchingCount(phone: true),
              onBack: page ? _showFolders : null,
              trailing: page ? _phoneAccount() : null,
            ),
      notes: notes,
      pinnedNoteIds: widget.notes.pinnedNoteIds,
      lockedNoteIds: _noteLimit?.lockedIds ?? const {},
      selectedId: _phonePageOpen ? _selectedId : null,
      query: _archiveQuery,
      displayTime: widget.prefs.displayTime,
      onSearch: () => unawaited(_openCommandMenu(field: true)),
      onClearQuery: () => setState(() => _archiveQuery = ''),
      onSelect: _select,
      onArchive: _archiveNote,
      onRestore: _restoreNote,
      onHide: (id) => unawaited(_hideNote(id)),
      onUnhide: _unhideNote,
      onTogglePin: _specialMode ? null : _togglePinnedNote,
      archiveMode: _archiveMode,
      hiddenMode: _hiddenMode,
      onDelete: _deleteNote,
      asksBeforeDeleting: widget.prefs.askBeforeDeleting,
      onDeleteAll: () => unawaited(_deleteAllArchived()),
      picks: _picks,
      onPicked: _actOnPicked,
      onShare: widget.account == null ? null : _shareNote,
      sharing: widget.account?.sharing,
      onOpenPerson: widget.account?.sharing == null ? null : _openPerson,
      onStartSharing: widget.account?.sharing == null ? null : _startSharing,
      collaborators: widget.account?.sync?.collaboratorsByNote ?? const {},
      tab: _sidebarTab,
      onTabChanged: _setSidebarTab,
      searchPlaceholder: tree
          ? 'Search folders'
          : pinnedPage
          ? 'Search pinned notes'
          : _kapyAiOn || _space == LibrarySpace.drawings
          ? _searchPlaceholder
          : _sharedPage
          ? 'Search shared notes'
          : _taskController == null
          ? 'Search notes'
          : 'Search notes and tasks',
      drawings: _space == LibrarySpace.drawings,
      onNewDrawing: () => _createNote(drawing: true),
      engine: widget.engines.engine,
      now: widget.notes.now,
      controls: tree ? null : _notesControls(_space, phone: true),
      filtersOpen: _phoneFiltersOpen,
      filtersActive: filtersNarrowed(
        show: _show,
        media: _space == LibrarySpace.drawings ? null : _mediaFilter,
        tags: _tagFilter,
      ),
      onFiltersToggled: () =>
          setState(() => _phoneFiltersOpen = !_phoneFiltersOpen),
      pinnedOnly: pinnedPage,
      // Only Home's Pinned has View all, which opens the whole list, as its
      // card did, with nothing narrowing it.
      onPinnedOnlyChanged: _phoneHome
          ? (value) {
              if (value) _clearFilter();
              setState(() => _pinnedOnly = value);
            }
          : null,
      folders: tree
          ? (
              store: widget.folders!,
              shown: true,
              onShown: null,
              open: widget.prefs.openFolders,
              onOpen: widget.prefs.setFolderOpen,
              inFront: null,
              onTab: (folderId, {required behind}) =>
                  setState(() => _phoneFolder = folderId),
              newFolder: _newFolder,
              onMade: null,
            )
          : null,
      onAddNotes: folder == null
          ? null
          : () => unawaited(_openAddNotes(folder)),
      phoneTiles: tree
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: _phoneFolderTiles(),
            )
          : null,
    );
  }

  /// Add notes on a phone's folder page: a sheet of the notes in no folder,
  /// kept current while it is up, whose ticked notes go into [folder]
  /// together, with an Undo.
  Future<void> _openAddNotes(Folder folder) {
    final folders = widget.folders!;
    return showAddNotesSheet(
      context,
      folder: folder,
      changes: Listenable.merge([widget.notes, folders]),
      notes: () => folders.tree.notesIn(_folderNotes, null),
      dateOf: _changedOn,
      onAdd: (noteIds) =>
          fileNotes(context, folders, noteIds, folder.id, adding: true),
    );
  }

  /// Folders' tiles: Drawings and Shared, each naming its newest note and
  /// that note's day.
  Widget _phoneFolderTiles() {
    final displayTime = widget.prefs.displayTime;
    final today = dayShown(widget.notes.now(), displayTime);
    String? newest(List<Note> notes) => switch (notes.firstOrNull) {
      final note? =>
        '${note.title} · '
            '${SidebarTimestamp.briefDay(noteDay(note, displayTime), today: today)}',
      null => null,
    };
    final drawings = [
      for (final note in widget.notes.search(''))
        if (note.isDrawing) note,
    ];
    final shared = widget.account?.sharing == null
        ? null
        : [
            for (final note in widget.notes.search(''))
              if (note.isShared) note,
          ];
    return PhoneFolderTiles(
      drawings: drawings,
      newest: newest(drawings),
      onOpenDrawings: () => _showSpace(LibrarySpace.drawings),
      shared: shared,
      latest: shared == null ? null : newest(shared),
      invitations: _invitationsWaiting,
      onOpenShared: () => _showSpace(LibrarySpace.shared),
    );
  }

  /// Invitations waiting under Shared, which its tile counts and the phone
  /// bar's Folders marks.
  int get _invitationsWaiting => widget.account?.sharing?.invites.length ?? 0;

  /// A note's page on a phone: back, then the note's own actions, over the
  /// editor that [editor] keys.
  Widget _phonePage(
    Note note,
    GlobalKey<NoteEditorState> editor, {
    DateTime? day,
    Set<String> kept = const {},
  }) {
    // A stroke from a drawing's left edge draws, so its page lets go of the
    // back swipe; Back and the page's Home still leave.
    final drawing = _opensAsDrawing(note) && _canWriteNote(note);
    return PopScope(
      canPop: !drawing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || BackEntry.anyOpen || !drawing) return;
        _phoneNavigator.currentState?.pop();
      },
      child: _phonePageBody(note, editor, day, kept),
    );
  }

  Widget _phonePageBody(
    Note note,
    GlobalKey<NoteEditorState> editor,
    DateTime? day,
    Set<String> kept,
  ) => Builder(
    builder: (outer) => Scaffold(
      backgroundColor: context.palette.paperColor,
      body: ListenableBuilder(
        listenable: _toolbarSources,
        builder: (context, _) {
          // A phone on its side with the keyboard up has no room to spare: the
          // bar steps aside and the lines take its room and the padding's.
          final cramped = isCrampedPage(
            MediaQuery.sizeOf(context),
            MediaQuery.viewInsetsOf(context).bottom,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The bar steps aside on its side with the keyboard up, so the
              // lines take its room; Back is still the phone's gesture.
              if (!cramped)
                SafeArea(
                  bottom: false,
                  child: _phoneNoteHeader(
                    note,
                    // The Scaffold takes the keyboard out of its own body's
                    // insets, so the page's are read from above it, where only
                    // this page rebuilds as the keyboard slides. A blank
                    // page (M11) keeps its header as it is until the first
                    // words.
                    typing:
                        note.body.isNotEmpty &&
                        MediaQuery.viewInsetsOf(outer).bottom > 0,
                    tabsOn: day,
                    kept: {...kept, note.id},
                  ),
                ),
              Expanded(
                child: SafeArea(
                  top: false,
                  // The footer insets its own controls past the home indicator,
                  // as the page bar does past the status bar.
                  bottom: false,
                  child: _phoneEditor(note, editor, cramped: cramped),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  /// A phone note's header: Home, its day, Kapy AI and More, then its week
  /// and its day's tasks, and on a page showing [tabsOn]'s notes as tabs,
  /// those and the ones it keeps, [kept] (A1). The week is only for My
  /// notes, as on a Mac.
  Widget _phoneNoteHeader(
    Note note, {
    required bool typing,
    DateTime? tabsOn,
    Set<String> kept = const {},
  }) {
    final displayTime = widget.prefs.displayTime;
    final today = dayShown(widget.notes.now(), displayTime);
    final day = noteDay(
      note,
      displayTime,
      ownDay: _dayOfFreshNote[note.id] ?? _ownDayOf(note),
    );
    final hasDays = _space == LibrarySpace.notes && !_specialMode;
    final counted = hasDays
        ? _filtered(widget.notes.search(''), anyTime: true)
        : const <Note>[];
    // On an earlier day's tabs the line would count today's tasks, which are
    // not that day's.
    final tasks = hasDays && !(tabsOn?.isBefore(today) ?? false)
        ? _phoneTasksOn(day, today)
        : 0;
    final tabs = hasDays && tabsOn != null
        ? _phoneTabsOn(tabsOn, counted: counted, kept: kept)
        : null;
    return PhoneNoteHeader(
      onHome: _phoneGoHome,
      typing: typing,
      day: hasDays ? day : null,
      today: today,
      weekOpen: _phoneWeekOpen,
      onWeekToggled: () => setState(() => _phoneWeekOpen = !_phoneWeekOpen),
      week: hasDays
          ? DayStrip(
              phone: true,
              place: (_, week) => week!,
              today: today,
              picked: tabsOn ?? day,
              onPick: (day, _) => _pickPhoneDay(day),
              notes: counted,
              displayTime: displayTime,
              firstWeekday: firstWeekday(context),
              ownDay: widget.days == null ? null : _ownDayOf,
            )
          : null,
      tabs: tabs == null || tabsOn == null
          ? null
          : DayTabsRow(
              notes: tabs.notes,
              pinned: tabs.pinned,
              open: note.id,
              onOpen: (id) => _select(id, focusEditor: false),
              onNew: () => _writeOnDay(tabsOn),
              onList: () =>
                  unawaited(_openPhoneDayNotes(tabsOn, tabs.notes, note.id)),
              onPin: (id, {required pin}) =>
                  _pinDayTab(tabsOn, id, pin: pin, kept: kept),
              onMove: (id, to) => _movePhoneTab(tabsOn, id, to, kept: kept),
            ),
      tasks: tasks,
      onTasks: tasks == 0 ? null : () => unawaited(_openPhoneTasks()),
      members: _selectedMembers,
      present: _selectedPresence,
      currentUserId: widget.account?.sharing?.userId ?? '',
      onMembers: _shareSelected,
      assistant: _kapyAiButton(
        extent: AppControlMetrics.iconButtonExtent,
        gap: 2,
        showsOpen: false,
      ),
      menu: _phoneMenu(note),
      onMenu: (action, at) => _runPageAction(action, note, at),
    );
  }

  /// A day picked in a phone note's week: with no notes, a page to write on
  /// it; with one, that note over the one open; with several, their tabs
  /// under the week (A1), on the first, over the note open, which Back goes
  /// back to. Picked on a page already showing a day's tabs, or on one of
  /// the day's own notes, the tabs come in place.
  void _pickPhoneDay(DateTime day) {
    if (day == _phoneDay) return;
    final tabs = _phoneTabsOn(day).notes;
    if (tabs.isEmpty) return _writeOnDay(day);
    if (tabs.length == 1) {
      return _openFromPage(tabs.single.id, leavingDay: true);
    }
    final open = _shownNote(_selectedId)?.id;
    final onDay = tabs.any((note) => note.id == open);
    if (_phoneDay == null && !onDay) {
      _openFromPage(tabs.first.id);
      setState(() {
        _phoneDay = day;
        _phoneDayPage = UniqueKey();
        _phoneDayKept = _phoneDayIds(day).toSet();
      });
      return;
    }
    setState(() {
      _phoneDayPage ??= _phoneTopPage;
      _phoneDay = day;
      _phoneDayKept = _phoneDayIds(day).toSet();
    });
    if (!onDay) _select(tabs.first.id, focusEditor: false);
  }

  /// The notes on [day] a phone's week counts, of [counted] where it has
  /// them, earliest started first, as a day shows them with no order of the
  /// person's own, and a note started on the day still blank, which the week
  /// counts from its first words. [kept], the notes the page showing them
  /// keeps tabs for (see [_phoneDayKept]), stay among them though their
  /// first words move them to today.
  List<Note> _phoneDayNotes(
    DateTime day, {
    List<Note>? counted,
    Set<String> kept = const {},
  }) =>
      [
        for (final note
            in counted ?? _filtered(widget.notes.search(''), anyTime: true))
          if (!_dayOfFreshNote.containsKey(note.id) &&
              (kept.contains(note.id) || _dayOfNote(note) == day))
            note,
        for (final MapEntry(key: id, value: started) in _dayOfFreshNote.entries)
          if (started == day) ?widget.notes.byId(id),
      ]..sort((a, b) {
        final started = a.createdAt.compareTo(b.createdAt);
        return started != 0 ? started : a.id.compareTo(b.id);
      });

  /// Every note on [day], those the list's filter leaves out too: the whole
  /// day a pin or a move arranges, so a note out of sight keeps its place
  /// and its pin, and [kept], as in [_phoneDayNotes], so a kept tab keeps
  /// its place too. The day's record can then name a note no longer on the
  /// day, which [DayTabsStore.arrange] skips, with its pin, once the tab
  /// goes, and the day's next pin or move leaves out.
  List<String> _phoneDayIds(DateTime day, {Set<String> kept = const {}}) => [
    for (final note in _phoneDayNotes(
      day,
      counted: widget.notes.search(''),
      kept: kept,
    ))
      note.id,
  ];

  /// [day]'s notes in the order their tabs show on a page keeping [kept],
  /// and how many from the front are pinned.
  ({List<Note> notes, int pinned}) _phoneTabsOn(
    DateTime day, {
    List<Note>? counted,
    Set<String> kept = const {},
  }) {
    final notes = _phoneDayNotes(day, counted: counted, kept: kept);
    final tabs = widget.dayTabs;
    if (tabs == null) return (notes: notes, pinned: 0);
    final byId = {for (final note in notes) note.id: note};
    final (:order, :pinned) = tabs.arrange(day, _phoneDayIds(day, kept: kept));
    return (
      notes: [for (final id in order) ?byId[id]],
      pinned: order.take(pinned).where(byId.containsKey).length,
    );
  }

  /// Why a day's tabs can't take an order of their own, once 2,000 days
  /// have one.
  static const _tabsCap =
      '2,000 days already have an order of their own, the most Kapy Notes '
      'keeps.';

  /// Moves [id]'s tab to [to] among the tabs [day] shows on a page keeping
  /// [kept]: between the same two in the day's whole order, so the notes the
  /// list's filter leaves out keep their places.
  void _movePhoneTab(
    DateTime day,
    String id,
    int to, {
    required Set<String> kept,
  }) {
    final tabs = widget.dayTabs;
    if (tabs == null) return;
    final shown = [
      for (final note in _phoneTabsOn(day, kept: kept).notes) note.id,
    ];
    final from = shown.indexOf(id);
    if (from < 0 || from == to || shown.length < 2) return;
    shown.removeAt(from);
    final ids = _phoneDayIds(day, kept: kept);
    final order = [...tabs.arrange(day, ids).order]..remove(id);
    final at = to.clamp(0, shown.length);
    final place = at < shown.length
        ? order.indexOf(shown[at])
        : order.indexOf(shown.last) + 1;
    if (!tabs.move(day, ids, id, place)) {
      Toast.show(context, "Couldn't move this tab. $_tabsCap", isError: true);
    }
  }

  void _pinDayTab(
    DateTime day,
    String id, {
    required bool pin,
    required Set<String> kept,
  }) {
    final tabs = widget.dayTabs;
    if (tabs == null) return;
    final ids = _phoneDayIds(day, kept: kept);
    if (pin ? tabs.pin(day, ids, id) : tabs.unpin(day, ids, id)) return;
    Toast.show(
      context,
      pin && tabs.arrange(day, ids).pinned >= dayTabsOrderMax
          ? "Couldn't pin this tab. A day keeps $dayTabsOrderMax pinned at "
                'most.'
          : "Couldn't ${pin ? 'pin' : 'unpin'} this tab. $_tabsCap",
      isError: true,
    );
  }

  /// Every note on [day] in a sheet (A4), [open] ticked; the one picked opens
  /// in its tab's place.
  Future<void> _openPhoneDayNotes(
    DateTime day,
    List<Note> notes,
    String open,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final id = await showDayNotes(
      context,
      day: day,
      notes: notes,
      open: open,
      displayTime: widget.prefs.displayTime,
    );
    if (id != null && mounted) _select(id, focusEditor: false);
  }

  /// Home from a note's page: back to the notes it was opened over, or to
  /// Notes from Shared, Drawings, the archive or Hidden Notes.
  void _phoneGoHome() {
    _findOnBack = null;
    if (_phoneHome) {
      _closePhonePage();
    } else {
      _showSpace(LibrarySpace.notes);
    }
  }

  /// How many tasks the line under a phone note's week counts: today's list
  /// for a note of today or before, whose tasks are on it, or the tasks
  /// waiting for a later [day] in that day's notes.
  int _phoneTasksOn(DateTime day, DateTime today) {
    final open = _taskController?.read().open ?? const [];
    final displayTime = widget.prefs.displayTime;
    return open.where((item) {
      final ownDay = _ownDayOf(item.note);
      final waits = ownDay != null && ownDay.isAfter(today);
      return day.isAfter(today)
          ? waits && noteDay(item.note, displayTime, ownDay: ownDay) == day
          : !waits;
    }).length;
  }

  /// The tasks sheet over a phone note (M15): Tasks' own list, with Do now
  /// first, pulled up from the bottom. It closes back to the note.
  Future<void> _openPhoneTasks() async {
    final tasks = _taskController;
    if (tasks == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Theme.of(context).drawerTheme.scrimColor,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        builder: (sheet, scroll) {
          final palette = sheet.palette;
          return withNoteDays(
            widget.days,
            DecoratedBox(
              key: const ValueKey('phone-tasks-sheet'),
              decoration: BoxDecoration(
                color: palette.paperColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        color: palette.textDivider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 6, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Tasks',
                            style: chromeStyle(
                              size: AppTypeScale.body,
                              line: 22,
                              weight: AppWeight.button,
                              color: palette.textPrimary,
                            ),
                          ),
                        ),
                        CompactIconButton(
                          key: const ValueKey('phone-tasks-sheet-close'),
                          tooltip: 'Close',
                          extent: AppControlMetrics.iconButtonExtent,
                          onPressed: () => Navigator.of(sheet).pop(),
                          icon: const KapyIcon(
                            KapyIcons.chevronDownRounded,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TasksScreen(
                      phone: true,
                      sheet: true,
                      scrollController: scroll,
                      controller: tasks,
                      filter: const TaskFilter.all(),
                      addFocus: _taskAddFocus,
                      labelOf: _taskNoteLabel,
                      displayTime: widget.prefs.displayTime,
                      images: widget.notes.blobs,
                      onOpenNote: (id) {
                        Navigator.of(sheet).pop();
                        _openTaskNote(id);
                      },
                      onOpenDone: () {
                        Navigator.of(sheet).pop();
                        _openTasksDone();
                        _showHome(tasks: true);
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _phoneEditor(
    Note note,
    GlobalKey<NoteEditorState> key, {
    required bool cramped,
  }) {
    if (_opensAsDrawing(note)) return _buildDrawing(note);
    final folders = widget.folders;
    final editor = _phoneNoteEditor(note, key, cramped: cramped);
    return folders == null
        ? editor
        : NoteFolders(tree: folders.tree, child: editor);
  }

  Widget _phoneNoteEditor(
    Note note,
    GlobalKey<NoteEditorState> key, {
    required bool cramped,
  }) {
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: _toolbarSources,
        builder: (context, _) => NoteEditor(
          key: key,
          cramped: cramped,
          phone: true,
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
          createdAt: note.createdAt,
          idlePeekHeld: () => _kapyAi?.answering ?? false,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          paperStyle: widget.prefs.paperStyle,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          editorTextScale: widget.prefs.editorTextScale,
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
              ? KapyIcons.lockRounded
              : KapyIcons.visibilityOutlined,
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

  Widget _buildEditor(
    Note note, {
    required GlobalKey<NoteEditorState> key,
    required bool active,
    bool cramped = false,
    VoidCallback? onFocus,
  }) {
    if (_opensAsDrawing(note)) return _buildDrawing(note, onFocus: onFocus);
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        // The wide layout already listens to the account around this body.
        listenable: widget.prefs,
        builder: (context, _) => NoteEditor(
          // A key per note keeps one note's editing state from leaking into
          // the next, and lets it follow its note when the panes reorder.
          key: key,
          cramped: cramped,
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
              ? KapyIcons.lockRounded
              : KapyIcons.visibilityOutlined,
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

  /// Whether [note] opens on the canvas. A drawing does, except from a list
  /// that holds it for the words a sync race left beside it, where it opens
  /// as those words.
  bool _opensAsDrawing(Note note) =>
      note.isDrawing && (_drawingsOnly || !note.hasTextBesideDrawing);

  /// The page with nothing open on it, which in Drawings points at New
  /// drawing rather than offering a note.
  Widget _emptyPage() => _drawingsOnly
      ? EmptyState.drawings(
          shortcut: widget.shortcuts
              .hintFor(ShortcutAction.newNote)
              ?.keycapLabel,
        )
      : EmptyState(onCreate: _createNote);

  Widget _buildDrawing(Note note, {VoidCallback? onFocus}) {
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
      writingFont: widget.prefs.writingFont,
      onChanged: (drawing) => _updateDrawing(note.id, drawing: drawing),
      onTitleChanged: (title) => _updateDrawing(note.id, title: title),
    );
  }

  void _updateDrawing(String id, {NoteDrawing? drawing, String? title}) {
    final note = widget.notes.byId(id);
    if (note == null || !note.isDrawing || !_canWriteNote(note)) return;
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
    this.onKeepChoice,
    this.onTakeNext,
    this.onStartEarly,
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
    required this.onCloseTab,
    required this.onReopenTab,
    required this.onGoBack,
    required this.onGoForward,
    required this.onFocusPane,
    required this.onOpenSettings,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetZoom,
    required this.onInsertImage,
    required this.onRecordVoice,
    required this.onToggleSidebar,
    required this.onToggleHiddenFolder,
    required this.onToggleResults,
    required this.onToggleAlwaysOnTop,
    required this.onDeleteNote,
    required this.onToggleKapyAi,
    required this.shortcuts,
  });

  final Widget child;
  final FocusScopeNode focusNode;
  final VoidCallback onNewNote;

  /// The pair's keys, unless they belong to a field being typed in.
  KeyEventResult _pairKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final action = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => onKeepChoice,
      LogicalKeyboardKey.arrowRight => onTakeNext,
      LogicalKeyboardKey.escape => onStartEarly,
      _ => null,
    };
    if (action == null) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    return action() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Done on Do now, while Tasks is open: ⌘↵, or Ctrl+Enter.
  final VoidCallback? onCompleteTask;

  /// The pair on Tasks: ← keeps your choice, → takes the next task, and esc
  /// starts with your choice so far.
  final bool Function()? onKeepChoice;
  final bool Function()? onTakeNext;
  final bool Function()? onStartEarly;
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

  /// Null where the chord would close nothing the reader could see go.
  final VoidCallback? onCloseTab;
  final VoidCallback? onReopenTab;
  final VoidCallback? onGoBack;
  final VoidCallback? onGoForward;

  /// One per pane position, left to right; null past the panes that are open.
  final List<VoidCallback?> onFocusPane;
  final VoidCallback onOpenSettings;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetZoom;
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
        ?shortcuts.bindingFor(ShortcutAction.closeTab)?.activator: ?onCloseTab,
        ?shortcuts.bindingFor(ShortcutAction.reopenTab)?.activator:
            ?onReopenTab,
        ?shortcuts.bindingFor(ShortcutAction.goBack)?.activator: ?onGoBack,
        ?shortcuts.bindingFor(ShortcutAction.goForward)?.activator:
            ?onGoForward,
        ?shortcuts.bindingFor(ShortcutAction.focusFirstPane)?.activator:
            ?onFocusPane[0],
        ?shortcuts.bindingFor(ShortcutAction.focusSecondPane)?.activator:
            ?onFocusPane[1],
        ?shortcuts.bindingFor(ShortcutAction.focusThirdPane)?.activator:
            ?onFocusPane[2],
        ?shortcuts.bindingFor(ShortcutAction.openSettings)?.activator:
            onOpenSettings,
        ?shortcuts.bindingFor(ShortcutAction.zoomIn)?.activator: onZoomIn,
        ?shortcuts.bindingFor(ShortcutAction.zoomOut)?.activator: onZoomOut,
        ?shortcuts.bindingFor(ShortcutAction.resetZoom)?.activator: onResetZoom,
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
      child: FocusScope(
        node: focusNode,
        autofocus: true,
        onKeyEvent: _pairKey,
        child: child,
      ),
    );
  }
}

/// A note on a phone's page under the one on top: the note, its editor, the
/// key of its page, the day whose tabs the page shows, if it shows any, and
/// the notes it keeps tabs for there.
typedef _PhoneNotePage = ({
  String id,
  GlobalKey<NoteEditorState> editor,
  LocalKey page,
  DateTime? day,
  Set<String> kept,
});

/// A list a phone opens from its tab's own page, on a page of its own over
/// it, which Back leaves for that page.
enum _PhoneLevel { pinned, archive, hidden, drawings, shared, folder }
