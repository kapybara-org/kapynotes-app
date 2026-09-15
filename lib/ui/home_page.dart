import 'dart:async';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../audio/voice_availability.dart';
import '../audio/voice_player.dart';
import '../audio/voice_recording_controller.dart';
import '../billing/note_limit.dart';
import '../data/voice_prefs.dart';
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
import '../data/daily_separator.dart';
import '../data/editor_workspace.dart';
import '../data/layout_prefs.dart';
import '../data/local_store.dart';
import '../data/note.dart';
import '../data/note_attachment.dart';
import '../data/note_format.dart';
import '../data/notes_store.dart';
import 'editor/voice_chip.dart';
import 'editor/voice_insertion.dart';
import 'voice_note_dialog.dart';
import '../speech/speech_api.dart';
import '../speech/speech_errors.dart';
import 'voice_consent_sheet.dart';
import '../sync/aead.dart';
import '../sync/sync_api.dart';
import '../sync/account.dart';
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
import 'editor_panes.dart';
import 'billing/note_limit_dialog.dart';
import 'billing/pro_sheet.dart';
import 'empty_state.dart';
import 'hidden_notes_gate.dart';
import 'kapy_header_mascot.dart';
import 'mobile_page_swipe.dart';
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
    this.launchIntent = LaunchIntent.open,
    this.recording,
    this.player,
    this.transcriptions,
    this.voicePrefs,
    this.localModels,
    this.deviceSummarizer,
    this.summarizer,
    this.deviceTranscriber,
    this.transcriber,
    this.imageAcquirer,
    this.lostImageRetriever,
    required this.hiddenNotesGate,
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

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _pendingImageNoteKey = 'pendingImageNote.v1';
  static final _totalCue = RegExp(r'\btotal\b', caseSensitive: false);

  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  final KapyHeaderController _kapyHeader = KapyHeaderController();
  final Set<String> _totalAnimatedFor = {};
  GlobalKey<NoteEditorState> _compactEditorKey = GlobalKey<NoteEditorState>();
  GlobalKey<NoteEditorState> _archiveEditorKey = GlobalKey<NoteEditorState>();

  /// One key per note on screen in the panes, rather than one per pane, so a
  /// note keeps its caret, scroll and undo while its pane moves or swaps. A
  /// note that leaves the screen loses its key, and comes back fresh.
  final Map<String, GlobalKey<NoteEditorState>> _paneEditorKeys = {};
  late final EditorWorkspace _workspace;

  String? _selectedId;
  String _query = '';
  bool _initialNoteScheduled = false;
  bool _openSessionScheduled = false;
  bool _drawerContentReady = false;
  bool _drawerOpen = false;
  bool _settingsOpen = false;
  bool _archiveMode = false;
  bool _hiddenMode = false;
  bool _hiddenAuthBusy = false;
  int _hiddenSystemUiDepth = 0;
  bool _voiceActionBusy = false;

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
    widget.notes.addListener(_onNotesChanged);
    widget.account?.noteLimit?.addListener(_onNoteLimitChanged);
    // The system-wide new-note shortcut has already raised the window by the
    // time this runs; the note itself is this page's to make.
    widget.desktopIntegration?.onNewNoteRequested = _createNote;
    widget.desktopIntegration?.onOpenRequested = _beginOpenSession;
    // The controller owns the microphone but knows nothing about notes or
    // editors; this is where a finished recording becomes a ref in one.
    widget.recording?.onFinished = _deliverRecording;
    widget.recording?.addListener(_onRecordingChanged);
    _reconcileSelection();
    // Keep timers and mascot work behind the first editable frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    WidgetsBinding.instance.removeObserver(this);
    widget.notes.removeListener(_onNotesChanged);
    widget.account?.noteLimit?.removeListener(_onNoteLimitChanged);
    widget.desktopIntegration?.onNewNoteRequested = null;
    widget.desktopIntegration?.onOpenRequested = null;
    _kapyIdleTimer?.cancel();
    _kapyHeader.dispose();
    _searchFocus.dispose();
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
      _kapyIdleTimer?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    // An open compact drawer is disposed when a desktop window crosses into
    // the two-pane layout. Scaffold cannot report a closing transition after
    // that disposal, so clear the transient flag here. Otherwise returning to
    // a compact width builds a closed drawer whose toolbar still hides every
    // edge action.
    if (mounted && _drawerOpen && !_usesCompactLayout) {
      setState(() => _drawerOpen = false);
    }
    // A narrow window shows only the focused pane's note. An empty pane has
    // none, so focus a pane that does rather than show nothing at all.
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
  /// toolbar mic, the footer button, the shortcut and the context menu. While
  /// [voiceNotesEnabled] is off a Dictate tap is a Write tap — the note is
  /// open, at the end, with the keyboard up, which is the part of dictating
  /// the phone's own keyboard can already finish.
  Future<void> _startVoiceRecording({String? noteId}) async {
    if (!voiceNotesEnabled || _voiceActionBusy) return;
    final recording = widget.recording;
    final id = noteId ?? _selectedId;
    if (recording == null || id == null) return;

    final stopping = recording.isRecording;
    if (!stopping && !_canWriteNote(widget.notes.byId(id))) return;
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
        progress.error('Kapy Notes needs microphone access to record');
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
    _reconcileSelection();
    _reactToSelectedTotal();
    if (mounted) setState(() {});
  }

  /// Keeps the selection pointing at a note that still exists.
  void _reconcileSelection() {
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
    if (available.isEmpty && _usesCompactLayout) _scheduleInitialNote();
  }

  /// Read from the window because selection is also reconciled outside build.
  bool get _usesCompactLayout {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width / view.devicePixelRatio < kTwoPaneBreakpoint;
  }

  void _setSelectedId(String? id) {
    final previous = _selectedId;
    if (_specialMode) {
      if (previous != id) {
        _archiveEditorKey = GlobalKey<NoteEditorState>();
        _compactEditorKey = GlobalKey<NoteEditorState>();
        widget.account?.sync?.leaveNote(previous);
      }
      _selectedId = id;
      return;
    }

    if (id == null) {
      _workspace.reconcile(const <String>[], persist: true);
    } else {
      _workspace.open(id);
    }
    _adoptWorkspaceSelection(previous);
  }

  /// Takes up whatever the panes now have focused, after any change to them,
  /// and lets go of the editors of notes no longer on screen.
  void _adoptWorkspaceSelection(String? previous) {
    final next = _workspace.selectedNoteId;
    if (previous != next) {
      widget.account?.sync?.leaveNote(previous);
      _compactEditorKey = GlobalKey<NoteEditorState>();
    }
    _selectedId = next;
    final open = _workspace.openNoteIds;
    _paneEditorKeys.removeWhere((id, _) => !open.contains(id));
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

  void _select(String id) {
    // Showing a note replaces the focused one, unless it is already open in a
    // pane of its own, which is then only focused.
    final replaces =
        id != _selectedId &&
        (_usesCompactLayout || _specialMode || _workspace.paneOf(id) < 0);
    _afterRecordingLeaves(replaces ? _selectedId : null, () => _selectNow(id));
  }

  void _selectNow(String id) {
    final paneBefore = _workspace.activePane;
    setState(() => _setSelectedId(id));
    widget.prefs.lastOpenedNoteId = id;
    _recordKapyActivity();
    _reactToSelectedTotal();
    // Already open in another pane, whose editor is not rebuilt, so it will
    // not take the keyboard by itself.
    if (!_specialMode && _workspace.activePane != paneBefore) {
      _focusSelectedEditorHere();
    }
  }

  void _openNoteToSide(String id) {
    if (_usesCompactLayout || _specialMode) return;
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

  /// Walks the selection [delta] notes along the list the sidebar is showing,
  /// wrapping round at both ends.
  ///
  /// The visible list rather than every note, so a walk under an active search
  /// stays inside the results the reader is looking at. Selecting does not
  /// reorder anything — only editing moves a note to the top — so holding the
  /// key down passes each note exactly once.
  void _cycleNote(int delta) {
    // Past the notes open in other panes: they are already on screen, and
    // walking onto one would only move the focus sideways.
    final panes = !_specialMode && !_usesCompactLayout;
    final visible = [
      for (final note in _visibleNotes)
        if (!panes || note.id == _selectedId || _workspace.paneOf(note.id) < 0)
          note,
    ];
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

  /// Starts a new note, unless the one already open is a new note.
  ///
  /// Returns whether anything was actually created, which is what the swipe
  /// cue needs in order not to announce a note that does not exist.
  bool _createNote() {
    final recording = widget.recording;
    if (recording != null && recording.isRecording) {
      unawaited(
        recording.finishRecordingAndFlush().then((_) {
          if (mounted) _createNoteNow();
        }),
      );
      // The recording is about to land in the note that is open, so that note
      // will not be blank by the time this runs and a new one will follow.
      return true;
    }
    return _createNoteNow();
  }

  bool _createNoteNow() {
    _recordKapyActivity();
    final creatingHidden = _hiddenMode;
    final blank = _blankNoteAlreadyOpen();
    if (blank == null && !(_noteLimit?.canCreate ?? true)) {
      unawaited(_explainNoteLimit(creating: true));
      return false;
    }
    final note = blank ?? widget.notes.create(hidden: creatingHidden);
    setState(() {
      _query = '';
      _archiveMode = false;
      if (!creatingHidden) _hiddenMode = false;
      _setSelectedId(note.id);
    });
    widget.prefs.lastOpenedNoteId = note.id;
    _focusSelectedEditorAtEnd();
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
    if (id == null || !_canEditNote(widget.notes.byId(id))) return null;
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
    Toast.show(context, 'Note moved to Archived Notes', icon: archiveIcon);
    if (!archivingSelected) return;
    // Its pane closed with it, and the pane beside it has the focus. Opening
    // the next note in the list there would take the place of a note the
    // reader chose to keep on screen.
    if (closesPane) {
      widget.prefs.lastOpenedNoteId = _selectedId;
      _focusSelectedEditorHere();
      return;
    }

    final next = widget.notes.successorTo(index);
    setState(() => _setSelectedId(next));
    widget.prefs.lastOpenedNoteId = next;
    if (_usesCompactLayout && next == null) _scheduleInitialNote();
    _focusSelectedEditorAtEnd();
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
    final discovery = AppPlatform.isMobile
        ? 'Pull down below Search to find it.'
        : widget.prefs.hiddenFolderVisible
        ? 'Open Hidden Notes from the sidebar.'
        : shortcut == null
        ? 'Show it from Settings to find it.'
        : 'Show it from Settings or press $shortcut.';
    Toast.show(context, 'Moved to Hidden Notes. $discovery', icon: hiddenIcon);
    if (!hidingSelected) return;
    if (closesPane) {
      widget.prefs.lastOpenedNoteId = _selectedId;
      _focusSelectedEditorHere();
      return;
    }
    final next = widget.notes.successorTo(index);
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
  /// this device and, through the tombstone, every other one it syncs to.
  Future<void> _deleteNote(String id) async {
    final note = widget.notes.byId(id);
    if (note == null || !_canEditNote(note)) return;
    _recordKapyActivity();
    final title = note.title.trim();
    final confirmed = await _confirmDelete(
      title: 'Delete note?',
      body: title.isEmpty
          ? 'Permanently deletes this note from every synced device.'
          : 'Permanently deletes "$title" from every synced device.',
      action: 'Delete',
    );
    if (!confirmed || !mounted) return;
    _forget([id]);
    _announceDeleted(1);
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
      body:
          'Permanently deletes ${_noteCount(ids.length).toLowerCase()} from '
          'every synced device.',
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
      body:
          'Permanently deletes ${_noteCount(ids.length).toLowerCase()} from '
          'every synced device.',
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
      _query = '';
      if (entering) {
        _setSelectedId(widget.notes.archivedNotes.firstOrNull?.id);
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
      _query = '';
      _setSelectedId(widget.notes.hiddenNotes.firstOrNull?.id);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
  }

  void _leaveHiddenNotes() {
    if (!_hiddenMode || !mounted) return;
    final previous = _selectedId;
    setState(() {
      _hiddenMode = false;
      _query = '';
      _workspace.reconcile(
        widget.notes.notes.map((note) => note.id),
        fallbackId: widget.notes.notes.firstOrNull?.id,
      );
      _adoptWorkspaceSelection(previous);
    });
    widget.prefs.lastOpenedNoteId = _selectedId;
    if (_usesCompactLayout && widget.notes.isEmpty) _scheduleInitialNote();
  }

  void _toggleHiddenFolderVisibility() {
    final hiding = widget.prefs.hiddenFolderVisible;
    if (hiding && _hiddenMode) _leaveHiddenNotes();
    widget.prefs.toggleHiddenFolder();
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

  void _onNoteLimitChanged() {
    if (mounted) setState(() {});
  }

  void _updateDocument(
    String id,
    String body,
    List<NoteFormatRange> formats,
    List<NoteAttachmentRef> attachments,
  ) {
    if (!_canWriteNote(widget.notes.byId(id))) return;
    _recordKapyActivity();
    widget.account?.sync?.reportTyping(id);
    // Typed in, so it is theirs now. Assigned rather than set: the editor
    // holding the cursor is already mounted, and nothing on screen changes
    // until it is next built.
    if (id == _untouchedWelcomeId) _untouchedWelcomeId = null;
    widget.notes.updateDocument(id, body, formats, attachments);
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
    return id == null || _specialMode ? null : () => _shareNote(id);
  }

  /// Everyone the open note is shared with, for the avatars in the title bar.
  /// Empty on a personal note, and while the account is still locked: there is
  /// no roster to read until the keyring is open.
  List<SpaceMember> get _selectedMembers {
    final note = widget.notes.byId(_selectedId);
    final sharing = widget.account?.sharing;
    if (note == null || !note.isShared || sharing == null) return const [];
    return sharing.spaceById(note.spaceId)?.members ?? const [];
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
    if (id == null || sync == null) return const [];
    return sync.collaboratorsIn(id);
  }

  /// Opens the share sheet for a note. Before the account is unlocked there
  /// is no key to share with, so Profile & sync opens instead, on whatever
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
        section: SettingsSection.sync,
        notice: _stepBeforeSharing(account.state),
      );
      return;
    }
    unawaited(showShareDialog(context, note: note, sharing: sharing));
  }

  /// What stands between this account and sharing, as the step Profile & sync
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

  /// [notice] is said as a toast once settings is on screen, for whatever
  /// sent the person there rather than their own tap on the gear.
  void _showSettings({SettingsSection? section, String? notice}) {
    if (_settingsOpen) return;
    if (AppPlatform.isMobile) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _settingsOpen = true);
    }
    unawaited(_openSettings(section, notice));
  }

  Future<void> _openSettings(SettingsSection? section, String? notice) async {
    try {
      await showSettings(
        context,
        section: section,
        notice: notice,
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
        authorizeHiddenNotes: widget.hiddenNotesGate.unlock,
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

  void _focusSelectedEditorHere() {
    if (_editorFocusSuppressed ||
        (_selectedId != null && _selectedId == _untouchedWelcomeId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_editorFocusSuppressed) _selectedEditor?.focusHere();
    });
  }

  /// Opens whichever shape the notes list has at this width, then hands its
  /// search field the keyboard. Deferring focus matters when the shortcut is
  /// what makes a hidden sidebar or an unbuilt compact drawer exist.
  void _focusGlobalSearch() {
    _recordKapyActivity();
    if (!_usesCompactLayout) {
      if (!widget.prefs.sidebarVisible) widget.prefs.toggleSidebar();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
      return;
    }

    if (!_drawerContentReady) setState(() => _drawerContentReady = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scaffold = _scaffoldKey.currentState;
      if (scaffold == null) return;
      if (!scaffold.isDrawerOpen) {
        FocusManager.instance.primaryFocus?.unfocus();
        scaffold.openDrawer();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    });
  }

  List<Note> get _visibleNotes => _archiveMode
      ? widget.notes.searchArchived(_query)
      : _hiddenMode
      ? widget.notes.searchHidden(_query)
      : widget.notes.search(_query);

  @override
  Widget build(BuildContext context) {
    // Keep LayoutBuilder as the first render object: the app's whole-window
    // golden harness captures this boundary directly.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < kTwoPaneBreakpoint;
        final page = compact ? _buildCompact(context) : _buildWide(context);
        final gesturePage = AppPlatform.isDesktop
            ? SidebarSwipe(
                sidebarVisible: compact
                    ? _drawerOpen
                    : widget.prefs.sidebarVisible,
                onToggle: compact
                    ? _toggleCompactSidebarFromTrackpad
                    : widget.prefs.toggleSidebar,
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
            shortcuts: widget.shortcuts,
            onNewNote: _createNote,
            onFindNotes: _focusGlobalSearch,
            onNextNote: () => _cycleNote(1),
            onPreviousNote: () => _cycleNote(-1),
            onSplitEditor: compact || _specialMode || !_workspace.canSplit
                ? null
                : _splitEditor,
            // Unbound with a single pane, so the chord closes nothing at all
            // rather than something the reader did not mean it to.
            onClosePane: compact || _specialMode || !_workspace.isSplit
                ? null
                : () => _closePane(_workspace.activePane),
            onFocusPane: [
              for (var index = 0; index < EditorWorkspace.maxPanes; index++)
                compact || _specialMode || index >= _workspace.paneCount
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
            onToggleSidebar: compact
                ? _toggleCompactSidebarFromTrackpad
                : widget.prefs.toggleSidebar,
            onToggleHiddenFolder: _toggleHiddenFolderVisibility,
            onToggleResults: widget.prefs.toggleResults,
            onToggleAlwaysOnTop: AppPlatform.isDesktop
                ? widget.prefs.toggleAlwaysOnTop
                : null,
            onDeleteNote: _removeOpenNote,
            autofocus: _selectedId == null || !widget.prefs.readyToTypeOnOpen,
            child: content,
          ),
        );
      },
    );
  }

  void _toggleCompactSidebarFromTrackpad() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    if (scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    scaffold.openDrawer();
  }

  Widget _buildWide(BuildContext context) {
    final selected = widget.notes.byId(_selectedId);
    // A tablet reaches this layout too, and it has no Scaffold to resize
    // around the software keyboard. Desktop reports zero here.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    // The desktop layout is its own chrome rather than a Scaffold, but text
    // fields, menus and ink still need a Material ancestor.
    // Transparent in glass mode so the window's blurred desktop is what shows
    // through the thinned surfaces; solid otherwise, since a window with no
    // material behind it shows black through any gap.
    return Material(
      color: context.palette.isGlass
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
                sidebarShortcut: _sidebarShortcut,
                settingsShortcut: _settingsShortcut,
                onToggleSidebar: widget.prefs.toggleSidebar,
                onSettingsPressed: _showSettings,
                onCreate: _createNote,
                onShare: _shareSelected,
                members: _selectedMembers,
                present: _selectedPresence,
                currentUserId: widget.account?.sharing?.userId ?? '',
                noteShared: selected?.isShared ?? false,
                alwaysOnTop: widget.prefs.alwaysOnTop,
                onToggleAlwaysOnTop: _pinToggle,
                alwaysOnTopShortcut: _pinShortcut,
                onSplit: _specialMode || !_workspace.canSplit
                    ? null
                    : _splitEditor,
                splitTooltip: _splitTooltip,
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
                    pinnedNoteIds: widget.notes.pinnedNoteIds,
                    lockedNoteIds: _noteLimit?.lockedIds ?? const {},
                    selectedId: _selectedId,
                    query: _query,
                    displayTime: widget.prefs.displayTime,
                    searchFocusNode: _searchFocus,
                    onQueryChanged: (value) => setState(() => _query = value),
                    onSelect: _select,
                    onCreate: _createNote,
                    onOpenToSide: _specialMode ? null : _openNoteToSide,
                    openElsewhereIds: _specialMode
                        ? const {}
                        : _workspace.openNoteIds.difference({?_selectedId}),
                    onArchive: _archiveNote,
                    onRestore: _restoreNote,
                    onHide: (id) => unawaited(_hideNote(id)),
                    onUnhide: _unhideNote,
                    onTogglePin: _specialMode ? null : _togglePinnedNote,
                    onArchiveToggle: _toggleArchive,
                    onHiddenToggle: () => unawaited(_toggleHiddenNotes()),
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
                    archivedCount: widget.notes.archivedNotes.length,
                    hiddenCount: widget.notes.hiddenNotes.length,
                    showHiddenFolder: widget.prefs.hiddenFolderVisible,
                    streak: widget.notes.streak,
                    onShare: widget.account == null ? null : _shareNote,
                    sharing: widget.account?.sharing,
                    collaborators:
                        widget.account?.sync?.collaboratorsByNote ?? const {},
                    onOpenSpace: widget.account?.sharing == null
                        ? null
                        : _openSpace,
                    onSettingsPressed: _showSettings,
                    searchShortcut: widget.shortcuts.bindingFor(
                      ShortcutAction.findNotes,
                    ),
                    settingsShortcut: widget.shortcuts.bindingFor(
                      ShortcutAction.openSettings,
                    ),
                    archiveShortcut: widget.shortcuts.bindingFor(
                      ShortcutAction.deleteNote,
                    ),
                    hiddenShortcut: widget.shortcuts.bindingFor(
                      ShortcutAction.toggleHiddenFolder,
                    ),
                    updates: widget.updates,
                    showHeader: false,
                  ),
                  // No bottom inset here: on a tablet the note's footer runs
                  // to the bottom edge and holds its own controls above the
                  // home indicator, and the empty state does the same with its
                  // paper.
                  body: _buildWideWorkspace(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The split button's words, which also say why it is grey when it is.
  String get _splitTooltip {
    if (!_specialMode) {
      if (_workspace.paneCount >= EditorWorkspace.maxPanes) {
        return 'Up to three notes side by side';
      }
      if (_selectedId == null) return 'Choose a note for this pane first';
    }
    return [
      'Split view',
      ?widget.shortcuts.bindingFor(ShortcutAction.splitEditor)?.displayLabel,
    ].join('  ');
  }

  Widget _buildWideWorkspace() {
    if (_specialMode) {
      final selected = widget.notes.byId(_selectedId);
      return selected == null
          ? EmptyState(onCreate: _createNote)
          : _buildEditor(selected, key: _archiveEditorKey, active: true);
    }
    final panes = _workspace.panes;
    if (panes.isEmpty) return EmptyState(onCreate: _createNote);

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
    final note = widget.notes.byId(pane.noteId);
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
        onCreate: _createNote,
        onShowNotes: widget.prefs.sidebarVisible
            ? null
            : widget.prefs.toggleSidebar,
      );
    } else {
      body = EmptyState(onCreate: _createNote);
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
    // Narrow desktop windows retain Flutter's draggable edge. Phones use the
    // full-page observer below, which can begin anywhere without taking the
    // editor's vertical-scroll or text-selection gestures away from it.
    final drawerEdgeDragWidth = MediaQuery.sizeOf(context).width / 3;
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
        drawerEnableOpenDragGesture: !AppPlatform.isMobile,
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
                      pinnedNoteIds: widget.notes.pinnedNoteIds,
                      lockedNoteIds: _noteLimit?.lockedIds ?? const {},
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
                      onArchive: _archiveNote,
                      onRestore: _restoreNote,
                      onHide: (id) => unawaited(_hideNote(id)),
                      onUnhide: _unhideNote,
                      onTogglePin: _specialMode ? null : _togglePinnedNote,
                      onArchiveToggle: _toggleArchive,
                      onHiddenToggle: () => unawaited(_toggleHiddenNotes()),
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
                      archivedCount: widget.notes.archivedNotes.length,
                      hiddenCount: widget.notes.hiddenNotes.length,
                      showHiddenFolder: widget.prefs.hiddenFolderVisible,
                      streak: widget.notes.streak,
                      onShare: widget.account == null ? null : _shareNote,
                      sharing: widget.account?.sharing,
                      collaborators:
                          widget.account?.sync?.collaboratorsByNote ?? const {},
                      onOpenSpace: widget.account?.sharing == null
                          ? null
                          : _openSpace,
                      onSettingsPressed: _showSettings,
                      searchShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.findNotes,
                      ),
                      settingsShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.openSettings,
                      ),
                      archiveShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.deleteNote,
                      ),
                      hiddenShortcut: widget.shortcuts.bindingFor(
                        ShortcutAction.toggleHiddenFolder,
                      ),
                      updates: widget.updates,
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
                members: _selectedMembers,
                present: _selectedPresence,
                currentUserId: widget.account?.sharing?.userId ?? '',
                noteShared: selected?.isShared ?? false,
                alwaysOnTop: widget.prefs.alwaysOnTop,
                onToggleAlwaysOnTop: _pinToggle,
                alwaysOnTopShortcut: _pinShortcut,
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

    if (!AppPlatform.isMobile) return compactPage;
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
    // Narrow desktop windows still have a precise pointer and enough room for
    // the results column to be resized. On Windows, the native minimum is an
    // outer window size, so the Flutter client can be a few pixels narrower
    // than that minimum. Platform capability is therefore the durable rule.
    // Phones preserve the fixed mobile gutter, and wide phones get enough
    // room for a grouped currency plus its three-letter code.
    final compactWidth = MediaQuery.sizeOf(context).width;
    final desktopResultsDivider = AppPlatform.isDesktop;
    final mobileGutterWidth = compactWidth >= 400 ? 152.0 : 132.0;
    return ListenableBuilder(
      listenable: widget.engines,
      builder: (context, _) => ListenableBuilder(
        listenable: _toolbarSources,
        builder: (context, _) => NoteEditor(
          key: _compactEditorKey,
          player: widget.player,
          voiceStateFor: _voiceStateFor,
          onOpenVoiceNote: _openVoiceNote,
          recording: widget.recording,
          onRecordVoice: voiceNotesEnabled && _canWriteNote(note)
              ? () => unawaited(_startVoiceRecording())
              : null,
          voiceActionBusy: _voiceActionBusy,
          imageAcquirer: (context) => _acquireImages(context, note.id),
          videoAcquirer: () => _acquireVideos(note.id),
          videoAttachmentMaxBytes: () => _videoAttachmentMaxBytes(note),
          onImagePrepared: (staged, prepared) =>
              _publishPreparedImage(note.id, staged, prepared),
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
          initialCaret: _resumeCaretIn(note),
          onCaretChanged: (offset) =>
              widget.prefs.rememberCaret(note.id, offset),
          ensureKeyboardVisible:
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          paperStyle: widget.prefs.paperStyle,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          editorTextScale: widget.prefs.editorTextScale,
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
          onDocumentChanged: (body, formats, attachments) =>
              _updateDocument(note.id, body, formats, attachments),
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

  Widget _buildEditor(
    Note note, {
    required GlobalKey<NoteEditorState> key,
    required bool active,
    VoidCallback? onFocus,
  }) {
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
          onRecordVoice: voiceNotesEnabled && _canWriteNote(note)
              ? () {
                  onFocus?.call();
                  unawaited(_startVoiceRecording(noteId: note.id));
                }
              : null,
          voiceActionBusy: _voiceActionBusy,
          imageAcquirer: (context) => _acquireImages(context, note.id),
          videoAcquirer: () => _acquireVideos(note.id),
          videoAttachmentMaxBytes: () => _videoAttachmentMaxBytes(note),
          onImagePrepared: (staged, prepared) =>
              _publishPreparedImage(note.id, staged, prepared),
          engine: widget.engines.engine,
          highlighter: widget.engines.highlighter,
          gutterWidth: widget.prefs.gutterWidth,
          resultsVisible: widget.prefs.resultsVisible,
          autofocus: active && _readyToTypeIn(note),
          startAtEnd: active && _readyToTypeIn(note),
          initialCaret: _resumeCaretIn(note),
          onCaretChanged: (offset) =>
              widget.prefs.rememberCaret(note.id, offset),
          ensureKeyboardVisible:
              active &&
              _readyToTypeIn(note) &&
              (AppPlatform.isMobile || AppPlatform.isFlutterTest),
          lastUpdatedAt: note.updatedAt,
          dailySeparatorsEnabled: widget.prefs.dailySeparatorsEnabled,
          paperStyle: widget.prefs.paperStyle,
          displayTime: widget.prefs.displayTime,
          writingFont: widget.prefs.writingFont,
          editorTextScale: widget.prefs.editorTextScale,
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
          onDocumentChanged: (body, formats, attachments) =>
              _updateDocument(note.id, body, formats, attachments),
          onGutterWidthChanged: (value) => widget.prefs.gutterWidth = value,
          onResultsVisibilityChanged: (value) =>
              widget.prefs.resultsVisible = value,
          onGutterWidthReset: widget.prefs.resetGutterWidth,
          onSettingsPressed: _showSettings,
          hideEmptyResults: AppPlatform.isMobile,
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
    required this.shortcuts,
    required this.autofocus,
  });

  final Widget child;
  final VoidCallback onNewNote;
  final VoidCallback onFindNotes;
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
      },
      child: Focus(autofocus: autofocus, child: child),
    );
  }
}
