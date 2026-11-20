import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/kapy_ai.dart';
import '../calc/format.dart';
import '../core/appearance.dart';
import '../core/desktop_integration.dart';
import '../core/device_memory.dart';
import '../core/editor_font.dart';
import '../core/linux_desktop.dart';
import '../core/mobile_data.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/auto_titles.dart';
import '../data/layout_prefs.dart';
import '../data/note.dart';
import '../data/notes_store.dart';
import '../data/rates.dart';
import '../data/release_history.dart';
import '../data/shortcut_prefs.dart';
import '../data/tags.dart';
import '../data/time_zones.dart';
import '../data/update_checker.dart';
import '../data/voice_prefs.dart';
import '../speech/cloud_access.dart';
import '../speech/device_summaries.dart';
import '../speech/local_model_store.dart';
import '../speech/local_models.dart';
import '../speech/speech_api.dart';
import '../speech/summarizer.dart';
import '../speech/summary_instructions.dart';
import '../speech/transcriber.dart';
import '../sync/account.dart';
import 'account/plan_group.dart';
import 'account/sync_pane.dart';
import 'control_surface.dart';
import 'export_import.dart';
import 'hidden_notes_gate.dart';
import 'kapy_ai/kapy_ai_parts.dart';
import 'kapy_ai/kapy_ai_settings.dart';
import 'mcp_pane.dart';
import 'mobile_data_sheet.dart';
import 'model_terms_sheet.dart';
import 'notebook_paper.dart';
import 'settings/sharing_section.dart';
import 'settings_rows.dart';
import 'theme_cards.dart';
import 'settings_search.dart';
import 'settings_update_card.dart';
import 'sidebar_timestamp.dart';
import 'tag_ui.dart';
import 'tonal_button.dart';
import 'voice_consent_sheet.dart';
import 'voice_note_dialog.dart';

/// The groups of settings, one per rail entry, in the rail's order.
///
/// Adding a section is meant to be the whole job of adding a category of
/// options: name it here, give it its groups in [_SettingsDialogState], and
/// every layout and the search pick it up.
enum SettingsSection {
  appearance,
  notes,
  voice,
  mcp,
  window,
  shortcuts,
  account,
  sharing,
  about,
}

const _sheetCorners = BorderRadius.vertical(top: Radius.circular(22));
const _sheetIndexKey = ValueKey('settings-sheet-index');

/// Wide enough for the full desktop dialog, its insets, and the Windows frame.
const double _windowsSettingsWindowWidth = 1004;

extension SettingsSectionCopy on SettingsSection {
  String get label => switch (this) {
    SettingsSection.appearance => 'Appearance',
    SettingsSection.notes => 'Notes',
    SettingsSection.voice => 'Voice & AI',
    SettingsSection.mcp => mcpSectionLabel,
    SettingsSection.window => 'Window',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.account => 'Account & sync',
    SettingsSection.sharing => 'Sharing',
    SettingsSection.about => 'About & updates',
  };

  KapyIconData get icon => switch (this) {
    SettingsSection.appearance => KapyIcons.paintBoardOutlined,
    SettingsSection.notes => KapyIcons.noteOutlined,
    SettingsSection.voice => KapyIcons.micRounded,
    SettingsSection.mcp => mcpSectionIcon,
    SettingsSection.window => KapyIcons.computerOutlined,
    SettingsSection.shortcuts => KapyIcons.commandOutlined,
    SettingsSection.account => KapyIcons.accountCircleOutlined,
    SettingsSection.sharing => KapyIcons.peopleOutlined,
    SettingsSection.about => KapyIcons.infoOutlined,
  };

  /// What is behind the label: the line under a pane's title, and under a
  /// category on the phone's list. Names the contents rather than selling
  /// them, because it is read while looking for something.
  String get summary => switch (this) {
    SettingsSection.appearance =>
      'How Kapy Notes looks: theme, paper, fonts and text size',
    SettingsSection.notes =>
      'How notes open, typing and calculations, backup and Hidden Notes',
    SettingsSection.voice =>
      kapyAiAvailable
          ? 'Voice notes, transcripts, summaries and Kapy AI, and where each '
                'one runs'
          : 'Voice notes, transcripts and summaries, and where each one runs',
    SettingsSection.mcp => mcpSectionSummary,
    SettingsSection.window =>
      'What the window shows, and what happens when it closes',
    SettingsSection.shortcuts =>
      'Every key, grouped by what it does. Click a key to change it',
    SettingsSection.account => 'Your profile, sync, plan and sign-out',
    SettingsSection.sharing =>
      'The people you share notes with, and what each of them can see',
    SettingsSection.about => 'The version you have, updates and what changed',
  };
}

/// Everything settings search can reach, read as it stands.
typedef SettingsIndex = List<SettingsSearchEntry<SettingsSection>> Function();

/// Opens settings in the shape the platform wants.
///
/// A pointer gets the dialog: a rail beside a pane, everything one click
/// away. A thumb gets a sheet that opens on a list of categories and pushes
/// into one at a time, because every pane stacked into one phone-width column
/// is a scroll with no map.
Future<void> showSettings(
  BuildContext context, {
  required LayoutPrefs layoutPrefs,
  required ShortcutPrefs shortcuts,
  required RatesRepository rates,
  required NotesStore notes,
  Account? account,
  UpdateChecker? updates,
  DesktopIntegration? desktopIntegration,
  VoicePrefs? voicePrefs,
  LocalModelStore? localModels,
  Summarizer? deviceSummarizer,
  Transcriber? deviceTranscriber,
  VoidCallback? onTranscriptionReady,
  CloudAccess? cloudAccess,
  HiddenNotesGate? hiddenNotes,
  TagStore? tags,
  List<TagEntry> Function()? listedTags,
  KapyAi? kapyAi,
  NoteNamer? namer,
  SettingsSection? section,
  String? reveal,
  String? notice,
  SharingStart? sharingStart,
  ValueChanged<String>? onOpenNote,
}) {
  SettingsDialog build({required bool asSheet}) => SettingsDialog(
    layoutPrefs: layoutPrefs,
    shortcuts: shortcuts,
    rates: rates,
    notes: notes,
    account: account,
    updates: updates,
    desktopIntegration: desktopIntegration,
    voicePrefs: voicePrefs,
    localModels: localModels,
    deviceSummarizer: deviceSummarizer,
    deviceTranscriber: deviceTranscriber,
    onTranscriptionReady: onTranscriptionReady,
    cloudAccess: cloudAccess,
    hiddenNotes: hiddenNotes,
    tags: tags,
    listedTags: listedTags,
    kapyAi: kapyAi,
    namer: namer,
    section: section,
    reveal: reveal,
    notice: notice,
    sharingStart: sharingStart,
    onOpenNote: onOpenNote,
    asSheet: asSheet,
  );

  if (!AppPlatform.isMobile) {
    Future<void> openDialog() {
      if (!context.mounted) return Future<void>.value();
      return showDialog<void>(
        context: context,
        builder: (context) => build(asSheet: false),
      );
    }

    if (AppPlatform.isWindows && desktopIntegration != null) {
      return desktopIntegration.withMinimumWindowWidth(
        _windowsSettingsWindowWidth,
        openDialog,
      );
    }
    return openDialog();
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // The sheet paints its own rounded top, and reaches the bottom edge
    // rather than floating above the home indicator.
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => build(asSheet: true),
  );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.layoutPrefs,
    required this.shortcuts,
    required this.rates,
    required this.notes,
    this.account,
    this.updates,
    this.desktopIntegration,
    this.voicePrefs,
    this.localModels,
    this.deviceSummarizer,
    this.deviceTranscriber,
    this.onTranscriptionReady,
    this.cloudAccess,
    this.hiddenNotes,
    this.tags,
    this.listedTags,
    this.kapyAi,
    this.namer,
    this.section,
    this.reveal,
    this.notice,
    this.sharingStart,
    this.onOpenNote,
    this.onIndex,
    this.asSheet = false,
  });

  final LayoutPrefs layoutPrefs;
  final ShortcutPrefs shortcuts;
  final RatesRepository rates;
  final NotesStore notes;

  /// Null when the app was built without sync wired up.
  final Account? account;
  final VoicePrefs? voicePrefs;

  /// The speech and summary models this device has downloaded, or null in a
  /// build with no local models wired up at all.
  final LocalModelStore? localModels;

  /// The device half of summarising. Asked once, when this opens, for whether
  /// it could work here — never for a summary.
  final Summarizer? deviceSummarizer;

  /// The device half of transcribing, so the pane can offer it and say what
  /// is in the way when this machine cannot.
  final Transcriber? deviceTranscriber;

  /// Runs queued recordings as soon as a usable transcription route is
  /// selected or cloud consent is accepted.
  final VoidCallback? onTranscriptionReady;

  /// Which engines the plan lets this device use, and the line that says
  /// why when the cloud is not one of them. Null where there is no account
  /// to have a plan.
  final CloudAccess? cloudAccess;

  /// What guards Hidden Notes: asked before an export can include them, and
  /// for the PIN a desktop unlocks them with. Null only in isolated settings
  /// tests, which then refuse an export containing them.
  final HiddenNotesGate? hiddenNotes;

  /// The tags Settings › Notes › Tags orders and changes, as the window
  /// lists them.
  final TagStore? tags;
  final List<TagEntry> Function()? listedTags;
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;

  /// The pane to open on, when something outside sent the user here to do one
  /// thing. Null starts where settings always starts.
  final SettingsSection? section;

  /// Kapy AI's chats, models and accounts, for its two groups in Voice & AI.
  /// Null, or the feature not built in, leaves both out.
  final KapyAi? kapyAi;

  /// What names new notes, for its row in Typing and calculations. Null
  /// leaves the row out.
  final NoteNamer? namer;

  /// The row [section] opens scrolled to and lit, by its key: "Manage
  /// accounts…" in Kapy AI lands on Your accounts.
  final String? reveal;

  /// Where Sharing opens, when [section] is Sharing: one person's page, or
  /// Share with someone.
  final SharingStart? sharingStart;

  /// Opens a note once settings has closed, for Sharing's Open. Null leaves
  /// Open out.
  final ValueChanged<String>? onOpenNote;

  /// Why whatever sent the user here did so — "Sign in first to share this
  /// note" — said as a toast once this is on screen. Raised here rather than
  /// by the caller: on Windows this opens only after the window has widened,
  /// and a toast shown before it would be drawn underneath.
  final String? notice;

  /// Set by the ⌘K menu, which only borrows what settings can find. This then
  /// builds nothing and does none of the loading an open settings does, and
  /// hands over the search index, read live, so the menu finds exactly what
  /// settings search finds.
  final ValueChanged<SettingsIndex>? onIndex;

  /// Present as the phone sheet — a list of categories you push through —
  /// instead of the rail dialog. Set by [showSettings]. Both shapes are the
  /// same widget so that a new section still only has to be written once.
  final bool asSheet;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

/// One setting: the row a pane draws, and the entry a search finds.
///
/// Written once so the two cannot drift apart, and so whether it has moved
/// off its default — the dot, the reset, the count in the rail — is decided
/// in one place too.
class _Setting {
  const _Setting(
    this.id,
    this.title, {
    this.subtitle,
    this.tag,
    this.keywords = const [],
    this.value,
    this.changed = false,
    this.onReset,
    this.control,
    this.wide = false,
    this.below,
    this.onTap,
    this.row,
  });

  /// The row's key, and how a search result finds it.
  final String id;
  final String title;
  final String? subtitle;
  final String? tag;

  /// The other words people use for it — "dark mode" for the theme.
  final List<String> keywords;

  /// What it is set to, in a word, for a search result.
  final String? value;
  final bool changed;
  final VoidCallback? onReset;
  final Widget? control;
  final bool wide;
  final Widget? below;
  final VoidCallback? onTap;

  /// A row of its own making, for the few that are more than words and a
  /// control: a switch, which flips from anywhere on it, or an update.
  final Widget? row;

  Widget build() => KeyedSubtree(
    key: ValueKey(id),
    child:
        row ??
        SettingsRow(
          title: title,
          subtitle: subtitle,
          tag: tag,
          trailing: control,
          wide: wide,
          below: below,
          changed: changed,
          onReset: onReset,
          onTap: onTap,
        ),
  );
}

/// A heading and the card of settings under it.
class _Group {
  const _Group(
    this.title,
    this.settings, {
    this.detail,
    this.caption,
    this.after = const [],
  });

  final String title;
  final String? detail;

  /// A line under the heading, for a group that needs saying what it is.
  final String? caption;
  final List<_Setting> settings;

  /// What is said under the card: a note, an error.
  final List<Widget> after;
}

/// The shortcut a row is recording, and — when the keys pressed already
/// belong to another — the swap waiting for Return.
typedef _ShortcutSwap = ({
  ShortcutAction action,
  ShortcutBinding binding,
  ShortcutAction holder,
});

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  /// Other desktop platforms may still stack at their narrowest. Windows
  /// borrows enough host-window width before opening, and always keeps the
  /// section rail visible while that resize reaches Flutter.
  static const double _railBreakpoint = 560;
  static const double _dialogWidth = 940;
  static const double _dialogHeight = 760;
  static const double _navWidth = 232;

  String? _shortcutError;
  String? _loginItemError;
  SettingsSection _section = SettingsSection.appearance;

  /// Which section the sheet has pushed, or null while it is showing the
  /// list of categories. Kept apart from [_section] because the dialog always
  /// has one selected and the sheet deliberately starts with none.
  SettingsSection? _sheetSection;
  final GlobalKey<NavigatorState> _sheetNavigator = GlobalKey<NavigatorState>();
  final ScrollController _scrollController = ScrollController();

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'settings-search');

  /// What the search field says, trimmed. Empty while not searching.
  String _query = '';

  /// The result Return opens, moved with the arrow keys.
  int _resultIndex = 0;

  /// The dialog's scrolling pane, searched for the row a result points at.
  final GlobalKey _paneKey = GlobalKey();

  /// The row a result has just led to, and the light that finds it for the
  /// eye. See [SettingsFlashLayer].
  final ValueNotifier<RenderBox?> _flashTarget = ValueNotifier<RenderBox?>(
    null,
  );
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// The shortcuts pane's own filter: a name, or the keys somebody remembers.
  final TextEditingController _shortcutFilter = TextEditingController();
  final FocusNode _shortcutFilterFocus = FocusNode(
    debugLabel: 'shortcut-filter',
  );

  /// Where keys go while a shortcut row is listening for new ones. Asked for
  /// outright, because the search field already holds focus when settings
  /// opens and an autofocus would defer to it.
  final FocusNode _recordingFocus = FocusNode(debugLabel: 'shortcut-recording');

  /// Whether the next chord pressed fills [_shortcutFilter] rather than
  /// being typed into it.
  bool _pressingKeys = false;

  /// The shortcut a row is listening for, and a clash it is waiting to swap.
  ShortcutAction? _recording;
  _ShortcutSwap? _swap;
  String? _recordError;

  /// Whether this device unlocks Hidden Notes with a PIN of its own, which
  /// is the only case a PIN can be changed. Asked once, as this opens.
  bool _usesPin = false;

  bool get _searching => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.onIndex case final lend?) {
      lend(_searchIndex);
      return;
    }
    _search.addListener(_onSearchChanged);
    _shortcutFilter.addListener(() => setState(() {}));
    if (!widget.asSheet) HardwareKeyboard.instance.addHandler(_onFindKey);
    _shortcutError = widget.desktopIntegration?.registrationError;
    _loadSpeechState();
    unawaited(widget.account?.billing?.refresh());
    unawaited(widget.namer?.check());
    // The only disk read this dialog does, and only in a build that offers
    // models: a handful of `stat` calls to see which are already here.
    unawaited(widget.localModels?.refresh());
    _loadDeviceSummaryState();
    _loadDeviceTranscriptState();
    unawaited(
      DeviceMemory().total().then((bytes) {
        if (mounted && bytes != null) {
          setState(() => _deviceMemoryBytes = bytes);
        }
      }),
    );
    unawaited(
      widget.hiddenNotes?.usesPin().then((value) {
        if (mounted) setState(() => _usesPin = value);
      }),
    );
    // System Settings and the Task Manager can both drop the login item
    // without telling the app, so the switch is re-read every time this opens
    // rather than trusted from launch.
    final integration = widget.desktopIntegration;
    if (integration != null) {
      unawaited(
        integration.refreshLoginItem().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    // The gear that opened this is badged when a release is waiting, so open
    // on the pane that badge is about rather than making it be hunted for.
    if (widget.updates?.hasUpdate ?? false) {
      _section = SettingsSection.about;
      _sheetSection = SettingsSection.about;
    }
    // An explicit destination wins over both: whoever asked for this pane knew
    // what the user was trying to do.
    final wanted = widget.section;
    if (wanted != null && _isAvailable(wanted)) {
      _section = wanted;
      _sheetSection = wanted;
      if (widget.reveal case final reveal?) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_reveal(ValueKey<String>(reveal))),
        );
      }
    }
    final notice = widget.notice;
    if (notice != null) {
      // After the first frame, so the toast goes above this, not under it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Toast.show(context, notice, icon: KapyIcons.infoOutlined);
      });
    }
  }

  @override
  void dispose() {
    if (!widget.asSheet) HardwareKeyboard.instance.removeHandler(_onFindKey);
    _search.dispose();
    _searchFocus.dispose();
    _shortcutFilter.dispose();
    _shortcutFilterFocus.dispose();
    _recordingFocus.dispose();
    _flash.dispose();
    _flashTarget.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _exportNotes() async {
    if (widget.notes.hiddenNotes.isNotEmpty) {
      final gate = widget.hiddenNotes;
      if (gate == null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Hidden Notes'),
            content: const Text(
              'Unlock Hidden Notes before exporting all notes.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
      if (!await gate.unlock(context) || !mounted) return;
    }
    if (!mounted) return;
    await runExport(context, widget.notes);
  }

  void _onSearchChanged() {
    final query = _search.text.trim();
    if (query == _query) return;
    final wasSearching = _searching;
    setState(() {
      _query = query;
      _resultIndex = 0;
    });
    // Results and a pane share the scroll; whichever takes over starts at
    // the top rather than wherever the other was left.
    if (wasSearching != _searching && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// ⌘F or Ctrl+F, from anywhere in the dialog, goes to the search field —
  /// the same chord that finds things everywhere else — and so does "/"
  /// while nothing is being typed. Only while this is the route on top, and
  /// never while a shortcut row is listening for keys of its own.
  bool _onFindKey(KeyEvent event) {
    if (event is! KeyDownEvent || _recording != null || _pressingKeys) {
      return false;
    }
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final keyboard = HardwareKeyboard.instance;
    final slash =
        event.logicalKey == LogicalKeyboardKey.slash &&
        !keyboard.isMetaPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() ==
            null;
    final chord =
        event.logicalKey == LogicalKeyboardKey.keyF &&
        (AppPlatform.isMacOS
            ? keyboard.isMetaPressed && !keyboard.isControlPressed
            : keyboard.isControlPressed && !keyboard.isMetaPressed) &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    if (!slash && !chord) return false;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  /// A section appears only where its subject does: the window and its keys
  /// are desktop ideas, updates need the checker that only a platform which
  /// can update itself is given, and the account needs a server.
  bool _isAvailable(SettingsSection section) => switch (section) {
    SettingsSection.window ||
    SettingsSection.shortcuts => AppPlatform.isDesktop,
    // A phone has no updater, but the notes still live here, the same place a
    // computer keeps them. Closing the notice at the top of the list must not
    // be the last way in.
    SettingsSection.about => widget.updates != null || AppPlatform.isMobile,
    SettingsSection.account ||
    SettingsSection.sharing => widget.account != null,
    // Present even signed out, and even with no transcription configured:
    // recording works without an account, and the pane says so rather than
    // hiding and leaving the user to wonder where the setting went.
    SettingsSection.voice => widget.voicePrefs != null,
    SettingsSection.appearance ||
    SettingsSection.notes ||
    SettingsSection.mcp => true,
  };

  List<SettingsSection> get _sections =>
      SettingsSection.values.where(_isAvailable).toList();

  /// What the device summariser could do here. Null until the answer
  /// arrives, which takes a platform call and is not worth a spinner.
  SummarizerReadiness? _deviceSummaryState;
  TranscriberReadiness? _deviceTranscriptState;

  /// This device's RAM, or null where the platform will not say. Read once,
  /// and only to decide whether a model is worth offering at all.
  int? _deviceMemoryBytes;

  SpeechConsentStatus? _speechConsent;
  bool _speechBusy = false;
  String? _speechError;

  /// Asks the server what this account agreed to.
  ///
  /// Consent lives on the server rather than in a local flag so that a second
  /// device shows the same answer, and so withdrawing it actually stops jobs
  /// rather than merely hiding a choice.
  void _loadSpeechState() {
    final speech = widget.account?.speech;
    if (speech == null) return;
    speech
        .consent()
        .then((value) {
          if (mounted) setState(() => _speechConsent = value);
        })
        .catchError((Object _) {});
  }

  Future<bool> _setTranscription(bool on) async {
    final speech = widget.account?.speech;
    if (speech == null || _speechBusy) return false;

    setState(() {
      _speechBusy = true;
      _speechError = null;
    });
    final status = await setCloudTranscription(
      context,
      speech: speech,
      prefs: widget.voicePrefs,
      on: on,
      onError: (message) => setState(() => _speechError = message),
    );
    if (mounted) {
      setState(() {
        _speechBusy = false;
        if (status != null) _speechConsent = status;
      });
    }
    return status != null && status.isAccepted == on;
  }

  Future<void> _selectCloudTranscription(VoicePrefs prefs) async {
    if (_speechBusy || widget.account?.speech == null) return;
    if (!(_speechConsent?.isAccepted ?? false) &&
        !await _setTranscription(true)) {
      return;
    }
    if (!mounted) return;
    prefs.transcriptEngine = TranscriptEngine.cloud;
    widget.onTranscriptionReady?.call();
  }

  static String _languageName(String? code) =>
      speechLanguages[code] ?? 'Detect automatically';

  Future<void> _pickSpeechLanguage(VoicePrefs prefs) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Language'),
        children: [
          for (final code in [null, ...speechLanguages.keys])
            SimpleDialogOption(
              key: ValueKey('voice-language-${code ?? 'auto'}'),
              onPressed: () => Navigator.of(context).pop(code ?? ''),
              child: Text(_languageName(code)),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    prefs.language = chosen.isEmpty ? null : chosen;
  }

  Future<void> _editSummaryInstruction(VoicePrefs prefs) async {
    final asked = await showInstructionSheet(
      context,
      title: 'Summary instructions',
      help:
          'These instructions apply to every recording. Summaries only use '
          'the transcript.',
      hint: defaultSummaryInstruction,
      initial: prefs.effectiveSummaryInstruction,
      confirmLabel: 'Save',
      resetLabel: 'Restore default',
      resetTo: defaultSummaryInstruction,
    );
    if (asked == null || !mounted) return;
    prefs.summaryInstruction = asked;
  }

  /// Asks the device summariser whether it could work here.
  ///
  /// Every time this opens rather than once at launch: Apple Intelligence can
  /// be switched on, and a model can be downloaded, while the app is running.
  void _loadDeviceSummaryState() {
    final summarizer = widget.deviceSummarizer;
    if (summarizer == null) return;
    unawaited(
      summarizer.readiness().then((state) {
        if (mounted) setState(() => _deviceSummaryState = state);
      }),
    );
  }

  /// Asks the device recogniser whether it could work here, for the same
  /// reason: a model can be downloaded, and a locale fetched, while the app
  /// is running.
  void _loadDeviceTranscriptState() {
    final transcriber = widget.deviceTranscriber;
    if (transcriber == null) return;
    unawaited(
      transcriber.readiness().then((state) {
        if (mounted) setState(() => _deviceTranscriptState = state);
      }),
    );
  }

  /// Why this model cannot be downloaded onto this device, or null.
  ///
  /// Only ever about memory today: a model that will be killed on load is one
  /// nobody should be invited to spend a download on.
  String? _downloadBlockedReason(DownloadableModel model) {
    if (model is! LocalSummaryModel) return null;
    final total = _deviceMemoryBytes;
    if (total == null || total >= model.minimumMemoryBytes) return null;
    return 'Needs ${fileSize(model.minimumMemoryBytes)} memory · '
        'This device has ${fileSize(total)}';
  }

  /// Starts a download, asking for agreement first where the model's licence
  /// requires it.
  Future<void> _startDownload(
    LocalModelStore store,
    DownloadableModel model,
  ) async {
    final terms = model.terms;
    final prefs = widget.voicePrefs;
    if (terms != null &&
        prefs != null &&
        !prefs.hasAcceptedTerms(model.id, terms.version)) {
      final accepted = await showModelTermsSheet(context, model: model);
      if (accepted != true || !mounted) return;
      prefs.acceptTerms(model.id, terms.version);
    }
    if (model.bytes > MobileData.askAboveBytes &&
        await store.mobileData.inUse()) {
      if (!mounted) return;
      final choice = await showMobileDataSheet(
        context,
        name: model.name,
        bytes: model.bytes,
      );
      if (choice == MobileDataChoice.onWifi) {
        unawaited(store.downloadOnWifi(model));
      }
      if (choice != MobileDataChoice.now) return;
    }
    unawaited(store.download(model));
  }

  /// Whether a device engine can run now: the platform's own, or a model
  /// that has finished downloading.
  bool _deviceReady(DownloadableModel? model, {required bool builtIn}) =>
      builtIn ||
      (model != null &&
          widget.localModels?.stateOf(model).status == LocalModelStatus.ready);

  List<DownloadableModel> get _localModelCredits {
    final catalogue = widget.localModels?.catalogue;
    if (catalogue == null) return const [];
    return <DownloadableModel>[
      ?catalogue.whereType<LocalSpeechModel>().firstOrNull,
      ?catalogue.whereType<LocalSummaryModel>().firstOrNull,
    ];
  }

  void _openSheetSection(SettingsSection section) =>
      setState(() => _sheetSection = section);

  /// Leaves settings for a note shared from or to this account.
  void _openNote(String id) {
    Navigator.of(context).pop();
    widget.onOpenNote?.call(id);
  }

  /// The plan, in Account & sync, from sharing's Pro line.
  void _showPlan() {
    if (widget.asSheet) {
      _openSheetSection(SettingsSection.account);
    } else {
      _showSection(SettingsSection.account);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_reveal(const ValueKey<String>('plan-current'))),
    );
  }

  /// Back to the list of categories, whether that came from the button, the
  /// system back gesture, or a swipe from the edge.
  void _closeSheetSection() {
    if (_sheetSection != null) setState(() => _sheetSection = null);
  }

  void _showSection(SettingsSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _recording = null;
      _swap = null;
    });
    // A pane the user has not seen should start at its top, not wherever the
    // previous one was scrolled to.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// A category chosen from the rail while results are showing is a change
  /// of mind about searching, so the search goes with it.
  void _selectFromRail(SettingsSection section) {
    _search.clear();
    _showSection(section);
  }

  /// Where a search result goes: its category, scrolled to its row, with the
  /// row lit for a moment so the eye does not have to hunt for it again.
  ///
  /// The dialog lets the search go, because the pane it led to is now the
  /// thing on screen. The sheet keeps it: the results are the page under the
  /// one it pushed, and going back should land on them.
  void _openResult(SettingsSearchEntry<SettingsSection> entry) {
    if (entry.elsewhere != null) return;
    if (widget.asSheet) {
      FocusManager.instance.primaryFocus?.unfocus();
      _openSheetSection(entry.section);
    } else {
      _search.clear();
      _showSection(entry.section);
    }
    final target = entry.target;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_reveal(ValueKey<String>(target))),
    );
  }

  List<SettingsSearchEntry<SettingsSection>> get _results =>
      searchSettings(_searchIndex(), _query);

  void _openMarkedResult() {
    final results = _results;
    if (results.isEmpty) return;
    _openResult(results[_resultIndex.clamp(0, results.length - 1)]);
  }

  void _moveResult(int delta) {
    final count = _results.length;
    if (count == 0) return;
    setState(() => _resultIndex = (_resultIndex + delta).clamp(0, count - 1));
  }

  Future<void> _reveal(Key target) async {
    if (!mounted) return;
    final root = widget.asSheet
        ? _sheetNavigator.currentContext
        : _paneKey.currentContext;
    final row = _findKeyed(root, target);
    // A row that only some states of a pane draw — an account row while
    // signed out — leaves the category open at its top, which is the next
    // best place to have been sent.
    if (row == null) return;
    await Scrollable.ensureVisible(
      row,
      alignment: 0.2,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || !row.mounted) return;
    final box = row.renderObject;
    if (box is! RenderBox || !box.attached) return;
    _flashTarget.value = box;
    unawaited(_flash.forward(from: 0));
  }

  /// The element under [root] whose widget carries [key]: the same search a
  /// test's find.byKey does, done once, on a tap.
  static Element? _findKeyed(BuildContext? root, Key key) {
    if (root is! Element) return null;
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        found = element;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return found;
  }

  /// The search field, which heads settings in every shape it takes.
  Widget _searchField({required bool autofocus}) => SettingsSearchField(
    controller: _search,
    focusNode: _searchFocus,
    autofocus: autofocus,
    // On a phone the keyboard's Search key only puts the keyboard away: the
    // results are already there, and the thumb picks one.
    onSubmitted: widget.asSheet ? _searchFocus.unfocus : _openMarkedResult,
    onMove: widget.asSheet ? null : _moveResult,
  );

  Widget _searchResults() => SettingsSearchResults<SettingsSection>(
    key: const ValueKey('settings-search-results'),
    query: _query,
    results: _results,
    marked: widget.asSheet ? null : _resultIndex,
    onOpen: _openResult,
  );

  // ---------------------------------------------------------------------------
  // Shortcuts

  /// Hands [changes] to the OS first, where a system-wide chord has to be
  /// given back before the preference forgets which one it was, then keeps
  /// them. Nothing is kept unless everything is.
  Future<bool> _applyShortcuts(
    Map<ShortcutAction, ShortcutBinding?> changes,
  ) async {
    final integration = widget.desktopIntegration;
    final global = changes.keys.where((action) => action.isGlobal).toList();
    if (integration != null && global.isNotEmpty) {
      final progress = Toast.showProgress(context, 'Updating shortcut…');
      final done = <ShortcutAction>[];
      for (final action in global) {
        final error = await integration.trySystemShortcut(
          action,
          changes[action],
        );
        if (error == null) {
          done.add(action);
          continue;
        }
        for (final undo in done) {
          await integration.trySystemShortcut(
            undo,
            widget.shortcuts.bindingFor(undo),
          );
        }
        if (mounted) setState(() => _shortcutError = error);
        progress.error(error);
        return false;
      }
      progress.success('Shortcut updated');
    }
    for (final MapEntry(key: action, value: binding) in changes.entries) {
      if (binding == null) {
        widget.shortcuts.clear(action);
      } else {
        widget.shortcuts.update(action, binding);
      }
    }
    if (mounted) setState(() => _shortcutError = null);
    return true;
  }

  void _startRecording(ShortcutAction action) {
    setState(() {
      _recording = action;
      _swap = null;
      _recordError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _recordingFocus.requestFocus(),
    );
  }

  void _stopRecording() => setState(() {
    _recording = null;
    _swap = null;
    _recordError = null;
  });

  /// Keys pressed while a row is listening. Escape lets go, Backspace on its
  /// own takes the shortcut away — what the same key does in macOS's own
  /// shortcut editor — and a chord that belongs to something else waits for
  /// Return to swap the two.
  KeyEventResult _onRecordingKey(FocusNode node, KeyEvent event) {
    final action = _recording;
    if (action == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    final swap = _swap;
    if (swap != null &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _stopRecording();
      unawaited(
        _applyShortcuts({
          swap.holder: widget.shortcuts.bindingFor(swap.action),
          swap.action: swap.binding,
        }),
      );
      return KeyEventResult.handled;
    }
    final binding = _chordFrom(event);
    if (binding == null) return KeyEventResult.handled;
    if (!binding.hasModifier) {
      if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        _stopRecording();
        unawaited(_applyShortcuts({action: null}));
        return KeyEventResult.handled;
      }
      setState(() {
        _swap = null;
        _recordError = AppPlatform.isMacOS
            ? 'Include Command, Control, Option or Shift.'
            : AppPlatform.isLinux
            ? 'Include Ctrl, Alt, Shift or Super.'
            : 'Include Ctrl, Alt, Shift or Windows.';
      });
      return KeyEventResult.handled;
    }
    if (binding == widget.shortcuts.bindingFor(action)) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    final holder = widget.shortcuts.conflictFor(action, binding);
    if (holder != null) {
      setState(() {
        _swap = (action: action, binding: binding, holder: holder);
        _recordError = null;
      });
      return KeyEventResult.handled;
    }
    _stopRecording();
    unawaited(_applyShortcuts({action: binding}));
    return KeyEventResult.handled;
  }

  /// The chord [event] makes with the modifiers held, or null for a lone
  /// modifier, which only starts one.
  static ShortcutBinding? _chordFrom(KeyEvent event) {
    if (_modifierKeys.contains(event.logicalKey)) return null;
    final keyboard = HardwareKeyboard.instance;
    return ShortcutBinding(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
      meta: keyboard.isMetaPressed,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
  }

  static final Set<LogicalKeyboardKey> _modifierKeys = {
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  };

  /// "Press keys": the next chord fills the filter with its name, so the
  /// shortcut somebody half remembers finds itself.
  KeyEventResult _onPressKeys(FocusNode node, KeyEvent event) {
    if (!_pressingKeys) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _pressingKeys = false);
      return KeyEventResult.handled;
    }
    final binding = _chordFrom(event);
    if (binding == null) return KeyEventResult.handled;
    setState(() => _pressingKeys = false);
    _shortcutFilter.text = binding.displayLabel;
    return KeyEventResult.handled;
  }

  int get _changedShortcuts => ShortcutAction.values
      .where(
        (action) =>
            widget.shortcuts.bindingFor(action) !=
            ShortcutPrefs.defaultFor(action),
      )
      .length;

  Future<void> _restoreShortcutDefaults() async {
    final restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore all shortcuts?'),
        content: const Text(
          'Every shortcut goes back to the keys it came with.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('restore-shortcuts-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (restore != true || !mounted) return;
    final changes = {
      for (final action in ShortcutAction.values)
        if (widget.shortcuts.bindingFor(action) !=
            ShortcutPrefs.defaultFor(action))
          action: ShortcutPrefs.defaultFor(action),
    };
    if (await _applyShortcuts(changes) && mounted) {
      Toast.show(context, 'Shortcuts restored');
    }
  }

  /// Turning this on changes what the close button does, which is worth
  /// saying out loud once. The tray icon appearing is the only other notice
  /// the user gets, and it is easy to miss.
  void _setKeepRunning(bool value) {
    widget.layoutPrefs.keepRunningInBackground = value;
    if (!value) return;
    Toast.show(
      context,
      AppPlatform.isMacOS
          ? 'Kapy Notes now has a menu bar icon.'
          : 'Closing the window now keeps Kapy Notes in the tray.',
      icon: KapyIcons.checkRounded,
    );
  }

  Future<void> _setLoginItem(bool value) async {
    final integration = widget.desktopIntegration;
    if (integration == null) return;
    final progress = Toast.showProgress(
      context,
      value ? 'Adding to startup…' : 'Removing from startup…',
    );
    final error = await integration.setLoginItemEnabled(value);
    if (!mounted) {
      progress.dismiss();
      return;
    }
    setState(() => _loginItemError = error);
    if (error == null) {
      progress.success(value ? 'Opens at login' : 'Removed from startup');
    } else {
      progress.error(error);
    }
  }

  Future<void> _chooseTimeZone() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _TimeZonePickerDialog(
        // Normalized here, where the table is parsed anyway to list the
        // zones: an id it does not know reads as following the device.
        selectedId: AppTimeZones.normalize(widget.layoutPrefs.timeZoneId),
      ),
    );
    if (!mounted || selected == null) return;
    widget.layoutPrefs.timeZoneId = selected.isEmpty ? null : selected;
  }

  Future<void> _chooseDefaultNote() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _DefaultNotePickerDialog(
        notes: widget.notes.notes,
        selectedId: widget.layoutPrefs.defaultNoteId,
      ),
    );
    if (!mounted || selected == null) return;
    widget.layoutPrefs.defaultNoteId = selected.isEmpty ? null : selected;
  }

  Future<void> _chooseNightTheme() async {
    final prefs = widget.layoutPrefs;
    final chosen = await showDialog<AppTheme>(
      context: context,
      builder: (context) => _ListPickerDialog<AppTheme>(
        title: 'Night theme',
        options: AppTheme.values,
        selected: prefs.nightTheme.theme,
        label: (theme) => theme.label,
        keyFor: (theme) => 'night-theme-${theme.name}',
        leading: (theme) =>
            _AccentRing(KapyTheme.palette(theme, Brightness.dark).accent),
      ),
    );
    if (chosen == null || !mounted) return;
    prefs.nightTheme = prefs.nightTheme.copyWith(theme: chosen);
  }

  /// The hour the night starts at, or the hour it ends at.
  Future<void> _chooseNightHour({required bool start}) async {
    final prefs = widget.layoutPrefs;
    final night = prefs.nightTheme;
    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => _ListPickerDialog<int>(
        title: start ? 'Night starts at' : 'Night ends at',
        options: [for (var hour = 0; hour < 24; hour++) hour * 60],
        selected: start ? night.from : night.to,
        label: NightTheme.clock,
        keyFor: (minute) => 'night-hour-$minute',
      ),
    );
    if (chosen == null || !mounted) return;
    final now = prefs.nightTheme;
    prefs.nightTheme = start
        ? now.copyWith(from: chosen)
        : now.copyWith(to: chosen);
  }

  Future<void> _changePin() async {
    final gate = widget.hiddenNotes;
    if (gate == null) return;
    if (await gate.changePin(context) && mounted) {
      Toast.show(context, 'PIN changed', icon: KapyIcons.checkRounded);
    }
  }

  Future<void> _openRates() async {
    final url = widget.rates.attributionUrl;
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    Toast.show(
      context,
      'Could not open ${url.host}',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  String get _defaultNoteLabel {
    final id = widget.layoutPrefs.defaultNoteId;
    final note = id == null ? null : widget.notes.byId(id);
    return note == null || note.isArchived || note.isHidden
        ? 'Last opened note'
        : note.title;
  }

  String _keys(ShortcutAction action) =>
      widget.shortcuts.bindingFor(action)?.displayLabel ?? '';

  String _keycaps(ShortcutAction action) =>
      widget.shortcuts.bindingFor(action)?.keycapLabel ?? '';

  // ---------------------------------------------------------------------------
  // The settings themselves

  _Setting _toggle(
    String id,
    String title,
    String subtitle, {
    required bool value,
    required ValueChanged<bool>? onChanged,
    bool? byDefault,
    String? tag,
    List<String> keywords = const [],
  }) {
    final changed = byDefault != null && value != byDefault;
    final reset = onChanged == null || byDefault == null
        ? null
        : () => onChanged(byDefault);
    return _Setting(
      id,
      title,
      subtitle: subtitle,
      tag: tag,
      keywords: keywords,
      value: value ? 'On' : 'Off',
      changed: changed,
      onReset: reset,
      row: SettingsToggleRow(
        title: title,
        subtitle: subtitle,
        tag: tag,
        value: value,
        onChanged: onChanged,
        changed: changed,
        onReset: reset,
      ),
    );
  }

  _Setting _choice<T extends Enum>(
    String id,
    String title,
    String subtitle, {
    required List<T> options,
    required T selected,
    required String Function(T option) label,
    required ValueChanged<T> onSelected,
    required String keyPrefix,
    T? byDefault,
    TextStyle Function(T option)? styleFor,
    bool Function(T option)? enabledFor,
    Widget? below,
    List<String> keywords = const [],
  }) {
    final changed = byDefault != null && selected != byDefault;
    return _Setting(
      id,
      title,
      subtitle: subtitle,
      keywords: keywords,
      value: label(selected),
      changed: changed,
      onReset: byDefault == null ? null : () => onSelected(byDefault),
      wide: true,
      below: below,
      control: SettingsSegmented<T>(
        options: options,
        selected: selected,
        labelFor: label,
        keyFor: (option) => ValueKey('$keyPrefix-${option.name}'),
        onSelected: onSelected,
        styleFor: styleFor,
        enabledFor: enabledFor,
      ),
    );
  }

  List<_Group> _groupsFor(SettingsSection section) => switch (section) {
    SettingsSection.appearance => _appearanceGroups(),
    SettingsSection.notes => _notesGroups(),
    SettingsSection.voice => _voiceGroups(),
    SettingsSection.window => _windowGroups(),
    SettingsSection.shortcuts => _shortcutGroups(),
    SettingsSection.about => _aboutGroups(),
    SettingsSection.account ||
    SettingsSection.sharing ||
    SettingsSection.mcp => const [],
  };

  /// The slider's left end is Off, and the rest of it is the amount from its
  /// subtlest to its clearest, so "on, at the subtlest" never reads as off.
  static const double _transparencyFloor = 0.08;

  List<_Group> _appearanceGroups() {
    final prefs = widget.layoutPrefs;
    final touch = !AppPlatform.hasPointer;
    final night = prefs.nightTheme;
    // The app puts every platform's request for more contrast here, the ones
    // Flutter cannot read included.
    final systemAsks = MediaQuery.highContrastOf(context);
    final scale = prefs.editorTextScale;
    final percent = '${(scale * 100).round()}%';
    final transparency = prefs.transparencyEnabled
        ? _transparencyFloor +
              (1 - _transparencyFloor) * prefs.transparencyAmount
        : 0.0;
    final textKeys = [
      ShortcutAction.increaseEditorTextSize,
      ShortcutAction.decreaseEditorTextSize,
      ShortcutAction.resetEditorTextSize,
    ].map(_keycaps).where((keys) => keys.isNotEmpty).join(' ');
    return [
      _Group('Look', [
        _choice<AppearanceMode>(
          'mode-setting',
          'Mode',
          touch
              ? 'Follow your device, or choose one.'
              : 'Follow your computer, or choose one.',
          options: AppearanceMode.values,
          selected: prefs.appearance,
          label: (mode) => mode.label,
          onSelected: (mode) => prefs.appearance = mode,
          byDefault: AppearanceMode.system,
          keyPrefix: 'appearance',
          keywords: ['dark mode', 'light mode', 'night', 'colour', 'color'],
        ),
        _Setting(
          'theme-setting',
          'Theme',
          subtitle: 'Each comes in dark and light; Midnight is dark only.',
          keywords: [
            'colour',
            'color',
            'palette',
            'scheme',
            for (final theme in AppTheme.values) theme.label,
          ],
          value: prefs.theme.label,
          changed: prefs.theme != AppTheme.riverbank,
          onReset: () => prefs.theme = AppTheme.riverbank,
          below: ThemeCards(
            selected: prefs.theme,
            onSelected: (theme) => prefs.theme = theme,
          ),
        ),
        _toggle(
          'increase-contrast-setting',
          'Increase contrast',
          touch
              ? 'Stronger text and borders in any theme.'
              : 'Stronger text, borders and tag labels in any theme. Turns '
                    'on with your system setting.',
          value: prefs.increaseContrast ?? systemAsks,
          onChanged: (on) => prefs.setIncreaseContrast(on, asks: systemAsks),
          byDefault: systemAsks,
          keywords: [
            'accessibility',
            'high contrast',
            'legibility',
            'readability',
            'borders',
          ],
        ),
        _toggle(
          'night-theme-setting',
          'At night, use a different theme',
          touch
              ? 'Switches back in the morning.'
              : 'It switches by itself, and back again in the morning.',
          value: night.enabled,
          onChanged: (on) => prefs.nightTheme = night.copyWith(enabled: on),
          byDefault: false,
          keywords: ['bedtime', 'evening', 'schedule', 'sleep', 'late'],
        ),
        if (night.enabled) ...[
          _Setting(
            'night-theme-choice-setting',
            'Night theme',
            keywords: ['bedtime', 'evening'],
            value: night.theme.label,
            changed: night.theme != const NightTheme().theme,
            onReset: () => prefs.nightTheme = night.copyWith(
              theme: const NightTheme().theme,
            ),
            control: SettingsMenuButton(
              key: const ValueKey('night-theme-button'),
              leading: _AccentRing(
                KapyTheme.palette(night.theme, Brightness.dark).accent,
              ),
              label: night.theme.label,
              onPressed: _chooseNightTheme,
            ),
          ),
          _Setting(
            'night-hours-setting',
            'From',
            keywords: ['bedtime', 'hours', 'time', 'until'],
            value:
                '${NightTheme.clock(night.from)} to '
                '${NightTheme.clock(night.to)}',
            changed:
                night.from != const NightTheme().from ||
                night.to != const NightTheme().to,
            onReset: () => prefs.nightTheme = night.copyWith(
              from: const NightTheme().from,
              to: const NightTheme().to,
            ),
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SettingsMenuButton(
                  key: const ValueKey('night-from-button'),
                  label: NightTheme.clock(night.from),
                  chevron: false,
                  onPressed: () => _chooseNightHour(start: true),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'to',
                    style: TextStyle(
                      color: context.palette.textTertiary,
                      fontSize: SettingsMetrics.buttonLabelSize,
                    ),
                  ),
                ),
                SettingsMenuButton(
                  key: const ValueKey('night-to-button'),
                  label: NightTheme.clock(night.to),
                  chevron: false,
                  onPressed: () => _chooseNightHour(start: false),
                ),
              ],
            ),
          ),
        ],
        _choice<PaperStyle>(
          'paper-setting',
          'Paper',
          'The background behind your writing',
          options: PaperStyle.values,
          selected: prefs.paperStyle,
          label: (paper) => paper.label,
          onSelected: (paper) => prefs.paperStyle = paper,
          byDefault: PaperStyle.plain,
          keyPrefix: 'paper-style',
          keywords: ['ruled', 'lined', 'notepad', 'plain', 'texture'],
        ),
        if (LayoutPrefs.supportsTransparency)
          _Setting(
            'transparency-setting',
            'Transparency',
            subtitle: 'Let the desktop show through the window',
            tag: 'Mac and Windows',
            keywords: [
              'blur',
              'glass',
              'translucent',
              'see-through',
              'opacity',
            ],
            value: prefs.transparencyEnabled ? 'On' : 'Off',
            changed: prefs.transparencyEnabled,
            onReset: () => prefs.transparencyEnabled = false,
            wide: true,
            control: _TransparencySlider(
              value: transparency,
              onChanged: (value) {
                prefs.transparencyEnabled = value >= _transparencyFloor / 2;
                if (!prefs.transparencyEnabled) return;
                prefs.transparencyAmount =
                    ((value - _transparencyFloor) / (1 - _transparencyFloor))
                        .clamp(0.0, 1.0);
              },
            ),
          ),
      ]),
      _Group('Text', [
        _choice<WritingFont>(
          'writing-font-setting',
          'Writing font',
          'The font your notes are written in',
          options: WritingFont.values,
          selected: prefs.writingFont,
          label: (font) => font == WritingFont.monospace ? 'Mono' : font.label,
          onSelected: (font) => prefs.writingFont = font,
          byDefault: WritingFont.clean,
          keyPrefix: 'writing-font',
          styleFor: (font) {
            // Mixed is named in the type its numbers are set in.
            final shown = font == WritingFont.mixed
                ? WritingFont.monospace
                : font;
            return TextStyle(
              fontFamily: shown.fontFamily,
              fontFamilyFallback: shown.fontFamilyFallback,
              fontVariations: shown.fontVariations,
            );
          },
          keywords: ['font', 'typeface', 'handwritten', 'mono', 'clean'],
        ),
        _Setting(
          'note-text-size-setting',
          'Note text size',
          subtitle: textKeys.isEmpty
              ? 'Text inside notes'
              : 'Text inside notes · $textKeys',
          keywords: ['zoom', 'bigger text', 'larger', 'smaller', 'font size'],
          value: percent,
          changed: scale != LayoutPrefs.defaultEditorTextScale,
          onReset: prefs.resetEditorTextSize,
          control: SettingsStepper(
            label: percent,
            onDecrease: scale > LayoutPrefs.minEditorTextScale
                ? prefs.decreaseEditorTextSize
                : null,
            onIncrease: scale < LayoutPrefs.maxEditorTextScale
                ? prefs.increaseEditorTextSize
                : null,
          ),
        ),
        _choice<AppTextSize>(
          'app-text-size-setting',
          'Interface text size',
          'Menus, lists and labels',
          options: AppTextSize.values,
          selected: prefs.appTextSize,
          label: (size) => size.label,
          onSelected: (size) => prefs.appTextSize = size,
          byDefault: AppTextSize.standard,
          keyPrefix: 'app-text-size',
          keywords: ['font size', 'ui scale', 'zoom', 'bigger text', 'larger'],
        ),
      ]),
    ];
  }

  List<_Group> _notesGroups() {
    final prefs = widget.layoutPrefs;
    final rates = widget.rates;
    final hiddenKeys = _keycaps(ShortcutAction.toggleHiddenFolder);
    final zone =
        '${AppTimeZones.displayName(prefs.timeZoneId)} · '
        '${AppTimeZones.offsetLabel(prefs.timeZoneId)}';
    return [
      _Group('Opening', [
        _Setting(
          'default-note-setting',
          'Note opened at launch',
          subtitle: 'Which note is open when Kapy Notes starts',
          keywords: ['default note', 'startup', 'start'],
          value: _defaultNoteLabel,
          changed: prefs.defaultNoteId != null,
          onReset: () => prefs.defaultNoteId = null,
          control: SettingsMenuButton(
            label: _defaultNoteLabel,
            onPressed: _chooseDefaultNote,
          ),
          onTap: _chooseDefaultNote,
        ),
        _toggle(
          'ready-to-type-on-open-toggle',
          'Ready to type on open',
          'Put the cursor back where you left it',
          value: prefs.readyToTypeOnOpen,
          onChanged: (value) => prefs.readyToTypeOnOpen = value,
          byDefault: true,
          keywords: ['cursor', 'caret', 'focus', 'keyboard', 'resume'],
        ),
      ]),
      _Group(
        'Typing and calculations',
        [
          _toggle(
            'markdown-toggle',
            'Markdown',
            '# for a heading, - for a list, [] for a checkbox',
            value: prefs.markdownEnabled,
            onChanged: (value) => prefs.markdownEnabled = value,
            byDefault: true,
            keywords: ['md', 'syntax', 'headings', 'bold', 'lists', 'checkbox'],
          ),
          if (LayoutPrefs.supportsSpellCheck)
            _toggle(
              'spell-check-toggle',
              'Check spelling',
              'Underline words that may be misspelled',
              value: prefs.spellCheckEnabled,
              onChanged: (value) => prefs.spellCheckEnabled = value,
              byDefault: true,
              keywords: ['spellcheck', 'spell check', 'typos', 'dictionary'],
            ),
          _toggle(
            'daily-separators-toggle',
            'Daily separators',
            'Add a dated line when a new day begins',
            value: prefs.dailySeparatorsEnabled,
            onChanged: (value) => prefs.dailySeparatorsEnabled = value,
            byDefault: true,
            keywords: ['date', 'day', 'dated line', 'divider'],
          ),
          if (widget.namer case final namer?)
            _toggle(
              'auto-titles-toggle',
              'Name new notes automatically',
              namer.available
                  ? 'Replaces “New Note” with a title, made on this device'
                  : namer.unavailableReason ??
                        'Looking for a model on this device',
              value: namer.isOn,
              onChanged: namer.available
                  ? (value) => prefs.autoTitlesEnabled = value
                  : null,
              byDefault: namer.available
                  ? LayoutPrefs.autoTitlesByDefault
                  : null,
              keywords: [
                'title',
                'name',
                'rename',
                'apple intelligence',
                'gemini',
                'on-device',
                'ai',
              ],
            ),
          _Setting(
            'time-zone-setting',
            'Time zone for dates',
            subtitle: 'Used by separators and “Edited” times',
            keywords: ['timezone', 'clock', 'utc', 'gmt', 'offset'],
            value: AppTimeZones.displayName(prefs.timeZoneId),
            changed: prefs.timeZoneId != null,
            onReset: () => prefs.timeZoneId = null,
            control: SettingsMenuButton(
              label: zone,
              onPressed: _chooseTimeZone,
            ),
            onTap: _chooseTimeZone,
          ),
          _choice<NumberSystem>(
            'number-format-setting',
            'Number format',
            rates.refreshedDate.isEmpty
                ? 'Exchange rates refresh on their own'
                : 'Exchange rates updated ${rates.refreshedDate}',
            options: NumberSystem.values,
            selected: prefs.numberSystem,
            label: (system) => system.label,
            onSelected: (system) => prefs.numberSystem = system,
            byDefault: NumberSystem.auto,
            keyPrefix: 'number-system',
            keywords: [
              'digits',
              'grouping',
              'commas',
              'lakh',
              'exchange rates',
              'currency',
            ],
          ),
        ],
        after: [_RatesCredit(label: rates.attributionLabel, onTap: _openRates)],
      ),
      _Group('Backup', [
        _Setting(
          'export-notes',
          'Export all notes',
          subtitle: 'One Markdown .zip. It isn’t encrypted once saved',
          keywords: ['backup', 'download', 'save', 'zip', 'markdown'],
          control: SettingsRowButton(
            key: const ValueKey('export-notes-button'),
            label: 'Export…',
            onPressed: () => unawaited(_exportNotes()),
          ),
        ),
        _Setting(
          'import-notes',
          'Import from an export',
          subtitle: 'Shows what changes before anything is imported',
          keywords: ['restore', 'upload', 'zip', 'markdown'],
          control: SettingsRowButton(
            key: const ValueKey('import-notes-button'),
            label: 'Import…',
            onPressed: () => unawaited(runImport(context, widget.notes)),
          ),
        ),
      ]),
      _Group('Deleting', [
        _toggle(
          'ask-before-deleting-toggle',
          'Ask before deleting notes',
          'Deleting several notes at once always asks',
          value: prefs.askBeforeDeleting,
          onChanged: (value) => prefs.askBeforeDeleting = value,
          byDefault: true,
          keywords: [
            'delete',
            'confirm',
            'confirmation',
            'warning',
            'don’t ask again',
            'remove',
          ],
        ),
      ]),
      if (AppPlatform.isDesktop || _usesPin)
        _Group('Hidden Notes', [
          if (AppPlatform.isDesktop)
            _toggle(
              'hidden-notes-sidebar-toggle',
              'Show Hidden in the notes filter',
              hiddenKeys.isEmpty
                  ? 'Hidden stays out of the notes filter while this is off'
                  : '$hiddenKeys opens Hidden either way',
              value: widget.layoutPrefs.hiddenFolderVisible,
              onChanged: (value) =>
                  widget.layoutPrefs.hiddenFolderVisible = value,
              byDefault: true,
              keywords: ['hidden', 'private', 'protected', 'folder', 'filter'],
            ),
          if (_usesPin)
            _Setting(
              'change-pin',
              'Change PIN',
              subtitle: 'The PIN that unlocks Hidden Notes on this computer',
              keywords: ['hidden', 'private', 'lock', 'password', 'passcode'],
              control: SettingsRowButton(
                key: const ValueKey('change-pin-button'),
                label: 'Change PIN…',
                onPressed: () => unawaited(_changePin()),
              ),
            ),
        ]),
      if ((widget.tags, widget.listedTags) case (final store?, final listed?))
        _Group('Tags', [
          _Setting(
            'tags-setting',
            'Your tags',
            keywords: ['tag', 'label', 'colour', 'color', 'order'],
            row: TagSettings(store: store, listed: listed),
          ),
        ]),
    ];
  }

  List<_Group> _voiceGroups() {
    final prefs = widget.voicePrefs;
    if (prefs == null) return const [];
    final signedIn = widget.account?.speech != null;
    final access = widget.cloudAccess;
    final store = widget.localModels;
    final speechModel = store?.catalogue
        .whereType<LocalSpeechModel>()
        .firstOrNull;
    final summaryModel = store?.catalogue
        .whereType<LocalSummaryModel>()
        .firstOrNull;
    final builtInSpeech = _deviceTranscriptState == TranscriberReadiness.ready;
    final builtInSummary = _deviceSummaryState == SummarizerReadiness.ready;
    final consented = _speechConsent?.isAccepted ?? false;
    final transcription = access?.transcription;
    final summaries = access?.summaries;
    // What runs, said as the choice: the plan's answer where there is one,
    // and the device wherever the cloud cannot run yet — signed out, or
    // before consent.
    final cloudTranscribes =
        signedIn &&
        consented &&
        (transcription?.engine ?? prefs.transcriptEngine) ==
            TranscriptEngine.cloud;
    final cloudSummarises =
        signedIn &&
        (summaries?.engine ?? prefs.summaryEngine) == SummaryEngine.cloud;
    String engineLabel(Enum engine) =>
        engine.name == 'cloud' ? 'Cloud' : 'This device';
    return [
      _Group('Voice notes', [
        _toggle(
          'voice-summary-toggle',
          'Make a summary',
          'A title and key points after each recording',
          value: prefs.summarize,
          onChanged: (value) => prefs.summarize = value,
          byDefault: true,
          keywords: ['summarise', 'summarize', 'recording', 'voice note'],
        ),
        _Setting(
          'voice-language-row',
          'Language',
          subtitle: 'The language you speak in recordings',
          keywords: ['speech', 'transcription language', 'detect'],
          value: _languageName(prefs.language),
          changed: prefs.language != null,
          onReset: () => prefs.language = null,
          control: SettingsMenuButton(
            key: const ValueKey('voice-language-menu'),
            label: _languageName(prefs.language),
            onPressed: () => unawaited(_pickSpeechLanguage(prefs)),
          ),
          onTap: () => unawaited(_pickSpeechLanguage(prefs)),
        ),
      ]),
      _Group(
        'Transcription',
        [
          _Setting(
            'transcribe-with',
            'Transcribe with',
            subtitle:
                transcription?.note ??
                (signedIn
                    ? 'Cloud is quicker. This device works offline'
                    : 'Cloud needs you signed in. This device works offline'),
            keywords: [
              'transcribe',
              'transcript',
              'speech to text',
              'dictation',
              'cloud',
              'offline',
              'local',
            ],
            value: cloudTranscribes ? 'Cloud' : 'This device',
            wide: true,
            control: SettingsSegmented<TranscriptEngine>(
              options: TranscriptEngine.values,
              selected: cloudTranscribes
                  ? TranscriptEngine.cloud
                  : TranscriptEngine.device,
              labelFor: engineLabel,
              keyFor: (engine) => ValueKey('transcribe-with-${engine.name}'),
              enabledFor: (engine) => engine == TranscriptEngine.cloud
                  ? signedIn &&
                        !_speechBusy &&
                        (transcription?.cloudSelectable ?? true)
                  : _deviceReady(speechModel, builtIn: builtInSpeech),
              onSelected: (engine) {
                if (engine == TranscriptEngine.cloud) {
                  unawaited(_selectCloudTranscription(prefs));
                  return;
                }
                prefs.transcriptEngine = TranscriptEngine.device;
                widget.onTranscriptionReady?.call();
              },
            ),
            below: builtInSpeech
                ? null
                : _DeviceEngineLine(
                    key: const ValueKey('local-transcription-line'),
                    store: store,
                    model: speechModel,
                    unavailableNote: switch (_deviceTranscriptState) {
                      TranscriberReadiness.preparing =>
                        'Preparing language support',
                      TranscriberReadiness.needsSystemFeature =>
                        'Allow Speech Recognition in system settings',
                      _ => null,
                    },
                    onDownload: speechModel == null || store == null
                        ? null
                        : () => unawaited(_startDownload(store, speechModel)),
                  ),
          ),
        ],
        after: [
          if (consented && signedIn)
            _ConsentNote(
              busy: _speechBusy,
              onWithdraw: () => unawaited(_setTranscription(false)),
            ),
          if (_speechError case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
              child: Text(
                error,
                style: TextStyle(
                  fontSize: AppTypeScale.small,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      _Group(
        'Summaries',
        [
          if (deviceSummariesPossible)
            _Setting(
              'summarise-with',
              'Summarise with',
              subtitle:
                  summaries?.note ??
                  ((AppPlatform.isMacOS || AppPlatform.isIOS)
                      ? 'This device uses Apple Intelligence or a downloaded model'
                      : 'This device uses a downloaded model'),
              keywords: ['summary', 'apple intelligence', 'offline', 'local'],
              value: cloudSummarises ? 'Cloud' : 'This device',
              wide: true,
              control: SettingsSegmented<SummaryEngine>(
                options: SummaryEngine.values,
                selected: cloudSummarises
                    ? SummaryEngine.cloud
                    : SummaryEngine.device,
                labelFor: engineLabel,
                keyFor: (engine) => ValueKey('summarise-with-${engine.name}'),
                enabledFor: (engine) => engine == SummaryEngine.cloud
                    ? signedIn && (summaries?.cloudSelectable ?? true)
                    : _deviceReady(summaryModel, builtIn: builtInSummary),
                onSelected: (engine) => prefs.summaryEngine = engine,
              ),
              below: builtInSummary
                  ? null
                  : _DeviceEngineLine(
                      key: const ValueKey('local-summary-line'),
                      store: store,
                      model: summaryModel,
                      blockedReason: summaryModel == null
                          ? null
                          : _downloadBlockedReason(summaryModel),
                      unavailableNote: switch (_deviceSummaryState) {
                        SummarizerReadiness.needsSystemFeature =>
                          'Turn on Apple Intelligence in System Settings',
                        SummarizerReadiness.preparing =>
                          'Apple Intelligence is still preparing',
                        _ => null,
                      },
                      onDownload: summaryModel == null || store == null
                          ? null
                          : () =>
                                unawaited(_startDownload(store, summaryModel)),
                    ),
            )
          else
            _Setting(
              'summarise-with',
              'Summarise with',
              subtitle:
                  summaries?.note ??
                  (signedIn
                      ? 'This computer has no model of its own for summaries'
                      : 'Made in the cloud once you sign in'),
              keywords: ['summary', 'cloud'],
              value: 'Cloud',
              control: const SettingsValue('Cloud'),
            ),
          _Setting(
            'summary-instructions',
            'Summary instructions',
            subtitle: 'What a summary should focus on',
            keywords: ['prompt', 'instructions', 'focus', 'summary style'],
            value: prefs.summaryInstruction == null ? 'Default' : 'Your own',
            changed: prefs.summaryInstruction != null,
            onReset: () => prefs.summaryInstruction = null,
            control: SettingsValue(
              prefs.summaryInstruction == null ? 'Default' : 'Your own',
            ),
            onTap: () => unawaited(_editSummaryInstruction(prefs)),
          ),
        ],
        after: [
          if (_localModelCredits.isNotEmpty)
            _ModelCredits(models: _localModelCredits),
        ],
      ),
      ..._kapyAiGroups(),
    ];
  }

  /// Kapy AI, only where the build carries it.
  KapyAi? get _kapyAi => kapyAiAvailable ? widget.kapyAi : null;

  /// What ⌘K is called: it also asks Kapy AI while that is on.
  String _shortcutLabel(ShortcutAction action) =>
      action == ShortcutAction.findNotes && (_kapyAi?.enabled ?? false)
      ? 'Search or Ask Kapy AI'
      : action.label;

  List<_Group> _kapyAiGroups() {
    final ai = _kapyAi;
    if (ai == null) return const [];
    final word = kapyDeviceWord;
    final keys = widget.shortcuts
        .bindingFor(ShortcutAction.toggleKapyAi)
        ?.keycapLabel;
    final deviceLine = kapyDeviceModelLine(ai.device);
    // What Kapy AI does, which stays true even when nothing on this device can
    // answer: the note then says what would make it work.
    final blurb = [
      'Answers from your notes in a panel beside the page',
      if (keys != null && AppPlatform.isDesktop) '$keys opens it',
    ].join('. ');
    final accounts = [...ai.accounts]
      ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return [
      _Group('Kapy AI', [
        _toggle(
          'kapy-ai-toggle',
          'Kapy AI',
          switch (ai.device.note) {
            final note? => '$blurb. $note',
            null when ai.device.status == DeviceModelStatus.unavailable =>
              'No model on this device. Kapy AI Cloud on Pro still answers, '
                  'and so does a key you add',
            null => blurb,
          },
          value: ai.enabled,
          onChanged: (value) => ai.enabled = value,
          byDefault: true,
          keywords: ['ai', 'assistant', 'ask', 'chat', 'questions', 'answers'],
        ),
        _Setting(
          'kapy-ai-default-model',
          'Default model',
          subtitle: ai.isPro
              ? 'Used for new chats. Each chat can switch in the panel'
              : 'Kapy AI Cloud is part of Pro',
          keywords: ['model', 'cloud', 'on this device', 'new chats'],
          value: kapyDefaultModelLabel(ai.defaultModel),
          control: KapyDefaultModelButton(kapyAi: ai),
        ),
        if (deviceLine != null)
          _Setting(
            'kapy-ai-device-model',
            'On-device model',
            subtitle: deviceLine,
            keywords: [
              'gemma',
              'apple intelligence',
              'offline',
              'local',
              'download',
            ],
            control: kapyDeviceModelControl(ai),
          ),
        _Setting(
          'kapy-ai-clear-history',
          'Clear chat history',
          subtitle: ai.chatsSync
              ? 'Deletes every Kapy AI chat on all your devices'
              : 'Deletes every Kapy AI chat on this $word',
          keywords: ['delete chats', 'history', 'conversations'],
          control: SettingsRowButton(
            key: const ValueKey('kapy-ai-clear'),
            label: 'Clear…',
            destructive: true,
            onPressed: () => unawaited(_clearKapyHistory(ai)),
          ),
        ),
      ]),
      if (accounts.isNotEmpty)
        _Group(
          'Your accounts',
          [
            for (final account in accounts)
              _Setting(
                kapyAccountRowId(account.kind),
                kapyAccountName(account.kind),
                subtitle: kapyAccountLine(account),
                keywords: switch (account.kind) {
                  KapyAccountKind.codex => ['openai', 'gpt', 'codex cli'],
                  KapyAccountKind.claudeCode => ['anthropic', 'claude'],
                  KapyAccountKind.openRouter => ['api key', 'key', 'gemini'],
                },
                row: KapyAccountRow(kapyAi: ai, account: account),
              ),
          ],
          caption:
              'Models from a plan or key you already have. Hidden notes never '
              'go to them',
        ),
    ];
  }

  /// Asks once: where chats sync this reaches every device.
  Future<void> _clearKapyHistory(KapyAi ai) async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: Text(
          ai.chatsSync
              ? 'Every Kapy AI chat is deleted on all your devices. This '
                    'can’t be undone.'
              : 'Every Kapy AI chat on this $kapyDeviceWord is deleted. This '
                    'can’t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('kapy-ai-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (clear == true) await ai.clearHistory();
  }

  List<_Group> _windowGroups() {
    final prefs = widget.layoutPrefs;
    final integration = widget.desktopIntegration;
    String withKeys(String line, ShortcutAction action) {
      final keys = _keycaps(action);
      return keys.isEmpty ? line : '$line · $keys';
    }

    return [
      _Group('In the window', [
        _toggle(
          'sidebar-toggle',
          'Show the notes list',
          withKeys('Your notes beside the page', ShortcutAction.toggleSidebar),
          value: prefs.sidebarVisible,
          onChanged: (_) => prefs.toggleSidebar(),
          keywords: ['sidebar', 'notes list', 'show', 'hide'],
        ),
        _toggle(
          'always-on-top-toggle',
          'Keep window on top',
          withKeys(
            'Above every other window',
            ShortcutAction.toggleAlwaysOnTop,
          ),
          value: prefs.alwaysOnTop,
          onChanged: (value) => prefs.alwaysOnTop = value,
          byDefault: false,
          keywords: ['pin', 'float', 'always on top', 'above'],
        ),
      ]),
      _Group(
        'Running',
        [
          if (integration?.canKeepRunningInBackground ?? true)
            _toggle(
              'keep-running-toggle',
              AppPlatform.isMacOS
                  ? 'Keep running in the menu bar'
                  : 'Keep running in the tray',
              AppPlatform.isMacOS
                  ? switch (widget.shortcuts.bindingFor(
                      ShortcutAction.openMenuBarPanel,
                    )) {
                      final keys? =>
                        'Click the icon or press ${keys.keycapLabel} for quick '
                            'notes and tasks',
                      null => 'Click the icon for quick notes and tasks',
                    }
                  : 'Shortcuts keep working after the window closes',
              value: prefs.keepRunningInBackground,
              onChanged: _setKeepRunning,
              byDefault: true,
              keywords: ['background', 'menu bar', 'tray', 'close', 'quit'],
            ),
          // Absent rather than disabled where the OS has no mechanism this
          // app is allowed to use: macOS 12 predates the one the sandbox
          // permits.
          if (integration != null && integration.loginItemSupported)
            _toggle(
              'login-item-toggle',
              'Open at login',
              'Start when you sign in to this computer',
              value: integration.loginItemEnabled,
              onChanged: (value) => unawaited(_setLoginItem(value)),
              byDefault: true,
              keywords: ['startup', 'launch at login', 'login item', 'boot'],
            ),
          _Setting(
            'panel-widths-setting',
            'Panel widths',
            subtitle: 'Put the notes list back to its first width',
            keywords: ['reset', 'resize', 'sidebar width'],
            control: SettingsRowButton(
              key: const ValueKey('reset-panel-widths'),
              label: 'Reset',
              onPressed: prefs.resetPanelWidths,
            ),
          ),
        ],
        after: [
          if (_loginItemError case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
              child: Text(
                error,
                key: const ValueKey('login-item-error'),
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    ];
  }

  /// Every key, under what it acts on. The system-wide pair leads: they are
  /// the ones that reach the app from outside it, the ones another app can
  /// refuse, and what people come here to change.
  List<_Group> _shortcutGroups({bool filtered = true}) {
    final filter = filtered ? _shortcutFilter.text.trim().toLowerCase() : '';
    bool shows(ShortcutAction action) =>
        (action != ShortcutAction.toggleKapyAi || kapyAiAvailable) &&
        (action != ShortcutAction.openMenuBarPanel || AppPlatform.isMacOS) &&
        (filter.isEmpty ||
            _shortcutLabel(action).toLowerCase().contains(filter) ||
            _keys(action).toLowerCase() == filter);
    final systemShortcuts =
        widget.desktopIntegration?.systemShortcutsSupported ?? true;
    return [
      for (final group in _ShortcutGroup.values)
        if (group == _ShortcutGroup.fromAnywhere && !systemShortcuts) ...[
          if (filter.isEmpty) _Group(group.title, [_systemShortcut()]),
        ] else if (ShortcutAction.values
                .where((action) => action.group == group && shows(action))
                .toList()
            case final actions when actions.isNotEmpty)
          _Group(
            group.title,
            [for (final action in actions) _shortcut(action)],
            detail: group == _ShortcutGroup.fromAnywhere
                ? 'Work even when another app is in front'
                : null,
          ),
    ];
  }

  /// Wayland keeps keys pressed in other apps for the desktop itself, so the
  /// shortcuts that work from anywhere are the desktop's own, set to run the
  /// app. A launch while it is running hands over to the running copy.
  _Setting _systemShortcut() {
    final command = LinuxDesktop.shortcutCommand();
    return _Setting(
      'system-shortcut-setting',
      'Use a system shortcut',
      subtitle:
          'Add one in your system’s keyboard settings that runs $command, '
          'or $command --new-note for a new note',
      keywords: ['shortcut', 'hotkey', 'keyboard', 'wayland', 'global'],
      control: SettingsRowButton(
        key: const ValueKey('copy-system-shortcut'),
        label: 'Copy',
        onPressed: () {
          unawaited(
            Clipboard.setData(ClipboardData(text: '$command --new-note')),
          );
          Toast.show(
            context,
            'Copied the new note command',
            icon: KapyIcons.checkRounded,
          );
        },
      ),
    );
  }

  _Setting _shortcut(ShortcutAction action) {
    final binding = widget.shortcuts.bindingFor(action);
    final standard = ShortcutPrefs.defaultFor(action);
    final changed = binding != standard;
    final recording = _recording == action;
    final swap = recording ? _swap : null;
    void reset() => unawaited(_applyShortcuts({action: standard}));
    final panelOff =
        action == ShortcutAction.openMenuBarPanel &&
        !widget.layoutPrefs.keepRunningInBackground;
    return _Setting(
      'shortcut-row-${action.name}',
      _shortcutLabel(action),
      subtitle: action.description,
      keywords: ['shortcut', 'hotkey', 'keyboard', ?binding?.displayLabel],
      value: binding?.displayLabel ?? 'None',
      changed: changed,
      onReset: reset,
      row: _ShortcutRow(
        action: action,
        label: _shortcutLabel(action),
        binding: swap?.binding ?? binding,
        recording: recording,
        changed: changed,
        onReset: reset,
        onPressed: panelOff
            ? null
            : () => recording ? _stopRecording() : _startRecording(action),
        notice: panelOff
            ? 'Needs Keep running in the menu bar'
            : !(widget.desktopIntegration?.isTaken(action) ?? false)
            ? null
            : AppPlatform.isLinux
            ? 'Taken by your desktop or another app.'
            : 'Taken by another app. The panel still opens from the menu bar '
                  'icon.',
        onKey: _onRecordingKey,
        focusNode: _recordingFocus,
        swap: swap == null
            ? null
            : (
                keys: swap.binding.displayLabel,
                holder: _shortcutLabel(swap.holder),
                given: binding?.displayLabel,
              ),
        error: recording ? _recordError : null,
      ),
    );
  }

  List<_Group> _aboutGroups() {
    final updates = widget.updates;
    if (updates == null) return const [];
    return [
      _Group(
        'Kapy Notes',
        [
          _Setting(
            'app-version',
            'Version',
            keywords: ['build', 'about', 'release'],
            value: updates.currentVersion,
            row: _VersionRow(updates: updates),
          ),
          if (!AppPlatform.isFlatpak)
            _Setting(
              'update-row',
              'Check for updates',
              keywords: ['update', 'upgrade', 'new version'],
              row: _UpdateRow(updates: updates),
            ),
          if (AppPlatform.hasAutoUpdate)
            _toggle(
              'update-auto-download',
              'Download updates automatically',
              'So updating takes one click',
              value: updates.autoDownload,
              onChanged: (value) => updates.autoDownload = value,
              byDefault: true,
              keywords: ['auto update', 'automatic', 'background', 'restart'],
            ),
        ],
        after: [SettingsNote(_updatesNote(updates))],
      ),
    ];
  }

  /// When the update actually happens, which is not the same on the two
  /// platforms: Sparkle installs a downloaded release whenever the app quits,
  /// and the Windows installer only runs when asked.
  static String _updatesNote(UpdateChecker updates) {
    if (AppPlatform.isFlatpak) {
      return 'Flatpak keeps Kapy Notes up to date, through your software '
          'center or flatpak update.';
    }
    if (AppPlatform.isLinux) {
      return 'Checks for updates daily. Download opens the new version in '
          'your browser, to install the same way as this one.';
    }
    if (!updates.autoDownload) {
      return 'Checks for updates daily. Nothing downloads until you choose '
          'Download.';
    }
    return AppPlatform.isMacOS
        ? 'Checks for updates daily and downloads them in the background. A '
              'downloaded update installs when you restart or quit.'
        : 'Checks for updates daily and downloads them in the background. A '
              'downloaded update installs when you choose Update and restart.';
  }

  // ---------------------------------------------------------------------------
  // The search, and what has changed

  SettingsSearchEntry<SettingsSection> _entry(
    SettingsSection section,
    String? group,
    _Setting setting,
  ) => SettingsSearchEntry(
    section: section,
    sectionLabel: section.label,
    title: setting.title,
    icon: section.icon,
    target: setting.id,
    group: group,
    keywords: setting.keywords,
    description: setting.subtitle,
    value: setting.value,
    changed: setting.changed,
  );

  /// Everything a search can reach: every row of every pane, read from the
  /// same settings the panes draw, so a row can never be on screen and not
  /// findable, or findable and gone. A test opens every entry and checks its
  /// row is there.
  List<SettingsSearchEntry<SettingsSection>> _searchIndex() {
    final sections = _sections;
    final results = _keys(ShortcutAction.toggleResults);
    return [
      // The categories themselves, for somebody who types the name of one.
      for (final section in sections)
        SettingsSearchEntry(
          section: section,
          sectionLabel: section.label,
          title: section.label,
          icon: section.icon,
          description: section.summary,
        ),
      for (final section in sections)
        for (final group
            in section == SettingsSection.shortcuts
                ? _shortcutGroups(filtered: false)
                : _groupsFor(section))
          for (final setting in group.settings)
            _entry(section, group.title, setting),
      if (sections.contains(SettingsSection.shortcuts))
        SettingsSearchEntry(
          section: SettingsSection.shortcuts,
          sectionLabel: SettingsSection.shortcuts.label,
          title: 'Restore all shortcuts',
          icon: SettingsSection.shortcuts.icon,
          target: 'restore-shortcut-defaults',
          keywords: const ['reset', 'defaults', 'keys', 'hotkeys'],
        ),
      if (sections.contains(SettingsSection.about))
        SettingsSearchEntry(
          section: SettingsSection.about,
          sectionLabel: SettingsSection.about.label,
          title: AppPlatform.isMobile ? "What's new" : 'Release notes',
          icon: SettingsSection.about.icon,
          target: 'changelog',
          keywords: const ['changelog', 'what’s new', 'versions', 'history'],
        ),
      if (sections.contains(SettingsSection.account))
        ..._accountSearchEntries(widget.account!),
      if (sections.contains(SettingsSection.sharing))
        ..._sharingSearchEntries(widget.account!),
      ...mcpSearchEntries(McpScope.maybeOf(context)),
      // Settings that live where they are used. Found here, and said where.
      SettingsSearchEntry(
        section: SettingsSection.notes,
        sectionLabel: SettingsSection.notes.label,
        title: 'Calculation results',
        icon: SettingsSection.notes.icon,
        keywords: const ['answers', 'results column', 'show results', 'hide'],
        elsewhere: results.isEmpty
            ? 'From the page’s More menu'
            : 'Press $results on the page',
      ),
      SettingsSearchEntry(
        section: SettingsSection.notes,
        sectionLabel: SettingsSection.notes.label,
        title: 'Notes as cards or a list',
        icon: SettingsSection.notes.icon,
        keywords: const ['cards', 'list view', 'rows', 'layout'],
        elsewhere: 'The view button above your notes',
      ),
      if (widget.voicePrefs != null)
        SettingsSearchEntry(
          section: SettingsSection.voice,
          sectionLabel: SettingsSection.voice.label,
          title: 'Playback speed',
          icon: SettingsSection.voice.icon,
          keywords: const ['speed', 'faster', 'slower', 'play', 'voice note'],
          elsewhere: 'In a voice note’s player, which remembers it',
        ),
    ];
  }

  /// Sharing's rows are there only once the account can share; until then
  /// the category itself is the place, and it says what is missing.
  List<SettingsSearchEntry<SettingsSection>> _sharingSearchEntries(
    Account account,
  ) {
    const section = SettingsSection.sharing;
    final sharing = account.sharing;
    if (sharing == null) return const [];
    SettingsSearchEntry<SettingsSection> entry(
      String title,
      String target,
      List<String> keywords,
    ) => SettingsSearchEntry(
      section: section,
      sectionLabel: section.label,
      title: title,
      icon: section.icon,
      target: target,
      keywords: keywords,
    );
    return [
      if (sharing.invites.isNotEmpty)
        entry('Invitations waiting for you', 'sharing-invites', const [
          'accept',
          'decline',
          'invited',
        ]),
      entry('People you share with', 'sharing-people', const [
        'share',
        'collaborate',
        'shared notes',
        'access',
        'stop sharing',
      ]),
      entry('Share with someone', 'share-with-someone', const [
        'invite',
        'add person',
        'email',
      ]),
      if (sharing.teams.any(
        (space) => space.isOwner && space.invites.isNotEmpty,
      ))
        entry('Invitations you sent', 'sharing-sent', const [
          'pending',
          'cancel invitation',
          'invite link',
        ]),
      entry('Join with a link or code', 'join-row', const [
        'invite',
        'invitation',
        'link',
        'code',
        'join',
      ]),
      entry('Blocked people', 'blocked-people', const ['unblock', 'block']),
    ];
  }

  /// The account's rows change with where the account stands, so its
  /// entries do too: a signed-out account has a form, not a Sign out button.
  List<SettingsSearchEntry<SettingsSection>> _accountSearchEntries(
    Account account,
  ) {
    const section = SettingsSection.account;
    SettingsSearchEntry<SettingsSection> entry(
      String title, {
      String? target,
      String? group,
      List<String> keywords = const [],
    }) => SettingsSearchEntry(
      section: section,
      sectionLabel: section.label,
      title: title,
      icon: section.icon,
      target: target,
      group: group,
      keywords: keywords,
    );
    return switch (account.state) {
      AccountState.ready => [
        entry(
          'Your name and picture',
          target: 'profile-card',
          keywords: ['profile', 'display name', 'photo', 'avatar', 'email'],
        ),
        entry(
          'Password',
          target: 'password-row',
          keywords: ['sign in', 'log in', 'login'],
        ),
        entry(
          'Sync',
          target: 'sync-status',
          keywords: ['sync now', 'status', 'devices', 'cloud'],
        ),
        entry(
          'Plan',
          target: 'plan-current',
          group: 'Plan',
          keywords: ['pro', 'free', 'trial', 'subscription', 'upgrade'],
        ),
        entry(
          'Storage',
          target: 'plan-storage-usage',
          group: 'Plan',
          keywords: ['space', 'attachments', 'usage', 'quota', 'limit'],
        ),
        entry(
          'Sign out',
          target: 'sign-out-row',
          group: 'Sign out or delete',
          keywords: ['log out', 'logout', 'account'],
        ),
        entry(
          'Delete account',
          target: 'delete-account',
          group: 'Sign out or delete',
          keywords: ['remove account', 'close account', 'erase'],
        ),
      ],
      // The form that signs in is the whole pane, so the pane is the place.
      AccountState.signedOut => [
        entry(
          'Sign in',
          keywords: ['log in', 'login', 'create account', 'sign up', 'sync'],
        ),
      ],
      _ => [
        entry('Account', keywords: ['passphrase', 'unlock', 'profile', 'sync']),
      ],
    };
  }

  // ---------------------------------------------------------------------------
  // Layout

  @override
  Widget build(BuildContext context) => widget.onIndex != null
      ? const SizedBox.shrink()
      : ListenableBuilder(
          listenable: Listenable.merge([
            widget.layoutPrefs,
            widget.shortcuts,
            ?widget.voicePrefs,
            ?widget.cloudAccess,
            ?widget.localModels,
            ?widget.updates,
            ?_kapyAi,
            ?widget.namer,
          ]),
          builder: (context, _) =>
              widget.asSheet ? _buildSheet(context) : _buildDialog(context),
        );

  Widget _buildDialog(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final palette = context.palette;
    // A fixed size keeps the dialog from resizing under the pointer as
    // sections of different lengths are selected; a small window takes all
    // but a margin of itself.
    final width = math.min(_dialogWidth, media.width - 48);
    final height = math.min(_dialogHeight, media.height - 48);
    // The rail needs the room a wide dialog has; a Windows window resized
    // narrow stacks its sections like any other.
    final paned = width >= _railBreakpoint;
    const corners = BorderRadius.all(Radius.circular(AppRadii.dialog));

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: Container(
        key: const ValueKey('settings-dialog-content'),
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        foregroundDecoration: BoxDecoration(
          borderRadius: corners,
          border: Border.all(color: palette.separator),
        ),
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: corners,
          boxShadow: [
            BoxShadow(
              color: palette.shadowAt(0x80),
              offset: const Offset(0, 30),
              blurRadius: 60,
              spreadRadius: -24,
            ),
            BoxShadow(
              color: palette.shadowAt(0x59),
              offset: const Offset(0, 2),
              blurRadius: 8,
            ),
          ],
        ),
        // Line heights here are the design's, which centre a line's
        // leading the way CSS does.
        child: DefaultTextHeightBehavior(
          textHeightBehavior: const TextHeightBehavior(
            leadingDistribution: TextLeadingDistribution.even,
          ),
          child: paned ? _buildPaned(context) : _buildStacked(context),
        ),
      ),
    );
  }

  /// The pane's heading: what is on show, a line on what is in it, and the
  /// way out.
  Widget _paneHeader({required String title, required String summary}) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 22, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  key: const ValueKey('settings-pane-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Shantell Sans',
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 26 / 20,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 16 / 12.5,
                    color: palette.textDescription,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          TonalButton(
            key: const ValueKey('settings-done'),
            label: 'Done',
            shortcut: 'esc',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// [pane] under the pane's heading, fading out at its foot so the last
  /// row reads as more to scroll to rather than as cut off, over a [footer]
  /// that stays put.
  Widget _paneColumn({
    required String title,
    required String summary,
    required Widget pane,
    Widget? footer,
  }) {
    final palette = context.palette;
    final surface = palette.surfaceBackground;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paneHeader(title: title, summary: summary),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: pane),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 64,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.85],
                        colors: [surface.withValues(alpha: 0), surface],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (footer != null)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: palette.paneEdge)),
            ),
            child: footer,
          ),
      ],
    );
  }

  /// The phone shape: a sheet that opens on its categories and pushes one
  /// pane at a time, so a screen only ever holds what its title says it does.
  Widget _buildSheet(BuildContext context) {
    final media = MediaQuery.of(context);
    final palette = context.palette;
    // Leave enough of the note showing to remember what this is covering, and
    // the status bar alone.
    final topGap = math.max(media.padding.top, 24.0) + 8;
    // Sign-in is in here, so a keyboard is not a hypothetical: give it the
    // bottom of the screen rather than letting it cover the field being
    // typed into.
    final keyboard = media.viewInsets.bottom;
    final section = _sheetSection;
    final bottomInset = keyboard > 0 ? 0.0 : media.padding.bottom;

    return Padding(
      // Lifted clear of the keyboard, and shortened by the same amount so the
      // top edge stays where it was rather than climbing the screen.
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        key: const ValueKey('settings-sheet'),
        height: media.size.height - topGap - keyboard,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            borderRadius: _sheetCorners,
            border: Border.all(
              color: palette.controlBorder,
              width: AppHairline.of(context),
            ),
          ),
          child: ClipRRect(
            borderRadius: _sheetCorners,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetGrabber(),
                Expanded(
                  // The pages below are their own stack, so a back gesture
                  // steps out of a category before it closes the sheet. The
                  // hero controller above belongs to the app's navigator and
                  // cannot be shared with this one.
                  child: HeroControllerScope.none(
                    child: NavigatorPopHandler(
                      onPopWithResult: (_) =>
                          _sheetNavigator.currentState?.pop(),
                      child: Navigator(
                        key: _sheetNavigator,
                        onDidRemovePage: (page) {
                          if (page.key != _sheetIndexKey) _closeSheetSection();
                        },
                        pages: [
                          MaterialPage<void>(
                            key: _sheetIndexKey,
                            // Nothing here is worth keeping alive under a
                            // pane, and one live page at a time keeps 'Done'
                            // meaning one button.
                            maintainState: false,
                            child: _SheetPage(
                              title: 'Settings',
                              bottomInset: bottomInset,
                              children: [
                                if (!_searching)
                                  SettingsWhatsNewRow(prefs: widget.layoutPrefs),
                                // No autofocus: a keyboard that rises the
                                // moment settings opens would cover the very
                                // list it is there to search.
                                _searchField(autofocus: false),
                                const SizedBox(height: 14),
                                if (_searching)
                                  _searchResults()
                                else
                                  _CategoryList(
                                    sections: _sections,
                                    changed: _changedSections,
                                    account: widget.account,
                                    onSelect: _openSheetSection,
                                  ),
                              ],
                            ),
                          ),
                          if (section != null)
                            MaterialPage<void>(
                              key: ValueKey('settings-sheet-${section.name}'),
                              child: _SheetPage(
                                title: section.label,
                                onBack: _closeSheetSection,
                                bottomInset: bottomInset,
                                flashTarget: _flashTarget,
                                flash: _flash,
                                children: _paneFor(section),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Every entry that is off its default.
  List<SettingsSearchEntry<SettingsSection>> get _changedEntries => [
    for (final entry in _searchIndex())
      if (entry.changed) entry,
  ];

  Set<SettingsSection> get _changedSections => {
    for (final entry in _changedEntries) entry.section,
  };

  static String _count(int count, String one) => switch (count) {
    0 => 'No ${one}s',
    1 => '1 $one',
    _ => '$count ${one}s',
  };

  /// The search sits over the rail, where a list of categories is looked
  /// down for something and a field that finds it saves the looking. Its
  /// results take the pane's place, so the rail stays a way back out.
  Widget _buildPaned(BuildContext context) {
    final palette = context.palette;
    final section = _section;
    final (title, summary) = _searching
        ? (
            '${_count(_results.length, 'setting')} for “$_query”',
            'Found by name, by everyday words and by what each one changes',
          )
        : (section.label, section.summary);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: _navWidth,
          padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
          decoration: BoxDecoration(
            color: palette.sidebarBackground,
            border: Border(right: BorderSide(color: palette.paneEdge)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 26,
                padding: const EdgeInsets.only(left: 10),
                alignment: Alignment.centerLeft,
                child: Text(
                  'Settings',
                  style: TextStyle(
                    fontFamily: 'Shantell Sans',
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    height: 22 / 18,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Settings opened on purpose, sent to one pane, leaves the
              // keyboard to whatever that pane wanted it for.
              _searchField(autofocus: widget.section == null),
              const SizedBox(height: 14),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final updates = widget.updates;
                    // Every category stays in view, so the card gets only
                    // what the rail leaves: its rows, a gap and the version.
                    final left =
                        constraints.maxHeight -
                        _sections.length * _SettingsRail.itemHeight -
                        (updates == null ? 0 : 28);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _SettingsRail(
                            sections: _sections,
                            changed: _changedSections,
                            // No category is the one on show while results
                            // are.
                            selected: _searching ? null : section,
                            onSelect: _selectFromRail,
                          ),
                        ),
                        if (updates != null) ...[
                          SettingsUpdateCard(
                            updates: updates,
                            layoutPrefs: widget.layoutPrefs,
                            maxHeight: left,
                          ),
                          const SizedBox(height: 10),
                          _VersionStatus(updates: updates),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _paneColumn(
            title: title,
            summary: summary,
            pane: _ScrollingPane(
              key: _paneKey,
              controller: _scrollController,
              flashTarget: _flashTarget,
              flash: _flash,
              children: _searching ? [_searchResults()] : _paneFor(section),
            ),
            footer: _searching
                ? const _SearchHints()
                : section == SettingsSection.shortcuts
                ? _shortcutsFooter()
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildStacked(BuildContext context) {
    return _paneColumn(
      title: 'Settings',
      summary: 'Everything in one list',
      pane: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 24, 12),
            child: _searchField(autofocus: widget.section == null),
          ),
          Expanded(
            child: _ScrollingPane(
              key: _paneKey,
              controller: _scrollController,
              flashTarget: _flashTarget,
              flash: _flash,
              children: _searching
                  ? [_searchResults()]
                  : [
                      for (final section in _sections) ...[
                        if (section != _sections.first)
                          const SizedBox(height: 28),
                        ..._paneFor(section),
                        if (section == SettingsSection.shortcuts) ...[
                          const SizedBox(height: 12),
                          _shortcutsFooter(),
                        ],
                      ],
                    ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _fromGroups(List<_Group> groups) => [
    for (final group in groups) ...[
      if (group != groups.first) SizedBox(height: SettingsMetrics.groupGap),
      SettingsLabel(group.title, detail: group.detail, caption: group.caption),
      SettingsGroup(
        children: [for (final setting in group.settings) setting.build()],
      ),
      ...group.after,
    ],
  ];

  List<Widget> _paneFor(SettingsSection section) => switch (section) {
    SettingsSection.appearance => [
      _AppearancePreview(prefs: widget.layoutPrefs),
      SizedBox(height: SettingsMetrics.groupGap),
      ..._fromGroups(_appearanceGroups()),
    ],
    SettingsSection.shortcuts => _shortcutsPane(),
    SettingsSection.mcp => const [McpPane()],
    SettingsSection.account => [
      SyncPane(
        account: widget.account!,
        middle: [
          PlanGroup(account: widget.account!, cloudAccess: widget.cloudAccess),
        ],
      ),
    ],
    SettingsSection.sharing => [
      SharingSection(
        account: widget.account!,
        notes: widget.notes,
        displayTime: widget.layoutPrefs.displayTime,
        start: widget.section == SettingsSection.sharing
            ? widget.sharingStart
            : null,
        onOpenNote: widget.onOpenNote == null ? null : _openNote,
        onShowPlan: _showPlan,
      ),
    ],
    SettingsSection.about => widget.updates == null
        ? const [_QuietWhatsNewRow()]
        : [
            ..._fromGroups(_aboutGroups()),
            SizedBox(height: SettingsMetrics.groupGap),
            // Keyed here rather than on the group below it: a search result
            // scrolls to what it lands on and lights it, and the group is
            // taller than the window by a dozen releases.
            SettingsLabel(
              widget.updates!.hasUpdate ? "What's new" : 'Release notes',
              key: const ValueKey('changelog'),
            ),
            _ChangelogGroup(updates: widget.updates!),
          ],
    _ => _fromGroups(_groupsFor(section)),
  };

  List<Widget> _shortcutsPane() {
    final groups = _shortcutGroups();
    return [
      _ShortcutFilter(
        controller: _shortcutFilter,
        focusNode: _shortcutFilterFocus,
        pressing: _pressingKeys,
        onPressKeys: () {
          setState(() => _pressingKeys = !_pressingKeys);
          if (_pressingKeys) _shortcutFilterFocus.requestFocus();
        },
        onKey: _onPressKeys,
      ),
      const SizedBox(height: 14),
      if (groups.isEmpty)
        SettingsNote(
          'No shortcut is called or set to “${_shortcutFilter.text}”.',
        )
      else
        ..._fromGroups(groups),
      if (_shortcutError case final error?)
        Padding(
          padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
          child: Text(
            error,
            key: const ValueKey('shortcut-error'),
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
    ];
  }

  Widget _shortcutsFooter() {
    final changed = _changedShortcuts;
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          Expanded(
            child: Text(
              changed == 0
                  ? 'Every shortcut is as it came'
                  : '${_count(changed, 'shortcut')} changed',
              style: TextStyle(
                fontSize: 12.5,
                color: context.palette.textDescription,
              ),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(0, box.maxWidth - 12),
            ),
            child: SettingsRowButton(
              key: const ValueKey('restore-shortcut-defaults'),
              label: 'Restore all shortcuts…',
              onPressed: changed == 0
                  ? null
                  : () => unawaited(_restoreShortcutDefaults()),
            ),
          ),
        ],
      ),
    );
  }
}

/// The keys, by what they act on.
enum _ShortcutGroup {
  fromAnywhere('From anywhere'),
  notesAndSearch('Notes and search'),
  tabsAndPanes('Tabs and panes'),
  window('Window'),
  writing('Writing'),
  formatting('Formatting');

  const _ShortcutGroup(this.title);

  final String title;
}

extension on ShortcutAction {
  /// Exhaustive on purpose: a new action does not compile until it has been
  /// given a place here.
  _ShortcutGroup get group => switch (this) {
    ShortcutAction.openApp ||
    ShortcutAction.newNoteAnywhere ||
    ShortcutAction.openMenuBarPanel => _ShortcutGroup.fromAnywhere,
    ShortcutAction.newNote ||
    ShortcutAction.findNotes ||
    ShortcutAction.newTask ||
    ShortcutAction.newDrawing ||
    ShortcutAction.nextNote ||
    ShortcutAction.previousNote ||
    ShortcutAction.deleteNote ||
    ShortcutAction.toggleKapyAi => _ShortcutGroup.notesAndSearch,
    ShortcutAction.goBack ||
    ShortcutAction.goForward ||
    ShortcutAction.closeTab ||
    ShortcutAction.reopenTab ||
    ShortcutAction.splitEditor ||
    ShortcutAction.focusFirstPane ||
    ShortcutAction.focusSecondPane ||
    ShortcutAction.focusThirdPane => _ShortcutGroup.tabsAndPanes,
    ShortcutAction.showNotes ||
    ShortcutAction.showTasks ||
    ShortcutAction.showDrawings ||
    ShortcutAction.showShared ||
    ShortcutAction.showArchive ||
    ShortcutAction.toggleSidebar ||
    ShortcutAction.toggleHiddenFolder ||
    ShortcutAction.toggleResults ||
    ShortcutAction.toggleAlwaysOnTop ||
    ShortcutAction.openSettings => _ShortcutGroup.window,
    ShortcutAction.increaseEditorTextSize ||
    ShortcutAction.decreaseEditorTextSize ||
    ShortcutAction.resetEditorTextSize ||
    ShortcutAction.pasteAsPlainText ||
    ShortcutAction.insertImage ||
    ShortcutAction.insertVideo ||
    ShortcutAction.insertFile ||
    ShortcutAction.recordVoiceNote => _ShortcutGroup.writing,
    ShortcutAction.cycleTextStyle ||
    ShortcutAction.formatBold ||
    ShortcutAction.formatItalic ||
    ShortcutAction.formatStrikethrough ||
    ShortcutAction.formatCode ||
    ShortcutAction.formatLink ||
    ShortcutAction.formatBullets ||
    ShortcutAction.formatChecklist => _ShortcutGroup.formatting,
  };
}

/// A note as it would look with what is chosen: the theme, the paper, the
/// writing font, the note text size and the number format, changing as each
/// is chosen.
class _AppearancePreview extends StatelessWidget {
  const _AppearancePreview({required this.prefs});

  final LayoutPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final font = prefs.writingFont;
    final scale = prefs.editorTextScale;
    final body = TextStyle(
      fontFamily: font.fontFamily,
      fontFamilyFallback: font.fontFamilyFallback,
      fontVariations: font.fontVariations,
      fontSize: 14 * scale,
      height: 1.45,
      color: palette.textPrimary,
    );
    final heading = font == WritingFont.clean || font == WritingFont.monospace
        ? font
        : WritingFont.handwritten;
    final caption = TextStyle(fontSize: 11, color: palette.textTertiary);
    return Container(
      key: const ValueKey('appearance-preview'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.wellBackground,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(color: palette.controlBorder),
      ),
      child: NotebookPaper(
        style: prefs.paperStyle,
        lineHeight: body.fontSize! * body.height!,
        topInset: 18,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Trip budget',
                        style: body.copyWith(
                          fontFamily: heading.fontFamily,
                          fontFamilyFallback: heading.fontFamilyFallback,
                          fontVariations: heading.fontVariations,
                          fontSize: 20 * scale,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Flights are booked. The hotel is still open.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: body,
                      ),
                      const SizedBox(height: 4),
                      LayoutBuilder(
                        builder: (context, line) => Row(
                          children: [
                            Flexible(
                              child: Text(
                                'saved = 12345678',
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: body,
                              ),
                            ),
                            const SizedBox(width: 10),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.max(0, line.maxWidth - 10),
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.tonalBackground,
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.compact,
                                  ),
                                ),
                                child: Text(
                                  ResultFormatter.sample(prefs.digitGrouping),
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily:
                                        AppPlatform.monoFontFallback.first,
                                    fontFamilyFallback:
                                        AppPlatform.monoFontFallback,
                                    fontSize: 12.5,
                                    color: palette.tonalForeground,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // A phone is too narrow to label the preview beside the note.
                if (AppPlatform.hasPointer && box.maxWidth >= 360) ...[
                  const SizedBox(width: 24),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Preview', style: caption),
                      const SizedBox(height: 2),
                      Text(
                        'Changes as you choose',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textDescription,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Transparency as one slider whose left end is Off.
class _TransparencySlider extends StatelessWidget {
  const _TransparencySlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final end = TextStyle(fontSize: 12, color: palette.textTertiary);
    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        inactiveTrackColor: palette.switchTrackOff,
        thumbColor: palette.switchThumb,
        overlayColor: Colors.transparent,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 8,
          elevation: 1.5,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: Slider(
        key: const ValueKey('transparency-slider'),
        value: value,
        onChanged: onChanged,
        semanticFormatterCallback: (value) =>
            value <= 0 ? 'Off' : '${(value * 100).round()}%',
      ),
    );
    return Row(
      mainAxisSize: AppPlatform.hasPointer
          ? MainAxisSize.min
          : MainAxisSize.max,
      children: [
        Text('Off', style: end),
        const SizedBox(width: 4),
        if (AppPlatform.hasPointer)
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: slider,
            ),
          )
        else
          Expanded(child: slider),
        const SizedBox(width: 4),
        Text('More', style: end),
      ],
    );
  }
}

/// What the device half of an engine needs before it can be chosen — a
/// download, a permission, more memory — said under the choice, with the
/// button that gets it. Says nothing once the device is ready and there is
/// nothing to manage.
class _DeviceEngineLine extends StatelessWidget {
  const _DeviceEngineLine({
    super.key,
    required this.store,
    required this.model,
    required this.unavailableNote,
    required this.onDownload,
    this.blockedReason,
  });

  final LocalModelStore? store;
  final DownloadableModel? model;

  /// What is in the way of the platform's own engine, if anything is.
  final String? unavailableNote;
  final VoidCallback? onDownload;

  /// Why this machine cannot take the download, if it cannot.
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final store = this.store;
    final model = this.model;
    final palette = context.palette;
    final style = TextStyle(
      fontSize: SettingsMetrics.subtitleSize,
      color: palette.textDescription,
    );
    if (store == null || model == null) {
      return Text(
        unavailableNote ?? 'Not available on this device',
        style: style,
      );
    }
    final state = store.stateOf(model);
    final here = state.status == LocalModelStatus.ready;
    final blocked = blockedReason;
    final Widget? action = here
        ? SettingsRowButton(
            key: ValueKey('local-remove-${model.id}'),
            label: 'Remove',
            onPressed: () => unawaited(store.remove(model)),
          )
        : blocked != null
        ? null
        : switch (state.status) {
            LocalModelStatus.fetchingRuntime ||
            LocalModelStatus.downloading ||
            LocalModelStatus.waitingForWifi => SettingsRowButton(
              key: ValueKey('local-cancel-${model.id}'),
              label: 'Cancel',
              onPressed: () => store.cancel(model),
            ),
            // Nothing to press while the hashes are checked: it takes
            // seconds, and stopping halfway would leave files nothing has
            // vouched for.
            LocalModelStatus.verifying => null,
            LocalModelStatus.failed => SettingsRowButton(
              key: ValueKey('local-download-${model.id}'),
              label: 'Try again',
              onPressed: onDownload,
            ),
            _ => SettingsRowButton(
              key: ValueKey('local-download-${model.id}'),
              label: state.receivedBytes > 0 ? 'Resume' : 'Download',
              onPressed: onDownload,
            ),
          };
    // A copy downloaded under an older, lower gate stays removable, but the
    // line says why nothing uses it.
    final line =
        blocked ??
        (here
            ? '${model.name} · on this device'
            : state.status == LocalModelStatus.waitingForWifi
            ? '${model.name} · waiting for Wi-Fi'
            : '${model.name} · ${fileSize(model.bytes)} download');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(line, style: style)),
            ?action,
          ],
        ),
        if (state.isBusy || state.error != null) ...[
          const SizedBox(height: 8),
          _ModelProgress(state: state),
        ],
      ],
    );
  }
}

/// The agreement to send recordings to the cloud, and the way to take it
/// back: quiet, under the choice it is about.
class _ConsentNote extends StatelessWidget {
  const _ConsentNote({required this.busy, required this.onWithdraw});

  final bool busy;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: SettingsMetrics.noteSize,
      height: 1.4,
      color: context.palette.textTertiary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 6, 3, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('You agreed to cloud transcription. ', style: style),
          _NoteLink(
            key: const ValueKey('voice-transcription-off'),
            label: 'Withdraw',
            style: style,
            onTap: busy ? null : onWithdraw,
          ),
        ],
      ),
    );
  }
}

/// Who supplies the exchange rates, which their terms ask to be named and
/// linked.
class _RatesCredit extends StatelessWidget {
  const _RatesCredit({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 6, 3, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: _NoteLink(
        key: const ValueKey('rate-attribution'),
        label: label,
        style: TextStyle(
          fontSize: SettingsMetrics.noteSize,
          height: 1.4,
          color: context.palette.textTertiary,
        ),
        onTap: onTap,
      ),
    ),
  );
}

/// A few words in a note that open something, in the sage a link in a note
/// is drawn in. Nothing in this app is underlined.
class _NoteLink extends StatelessWidget {
  const _NoteLink({
    super.key,
    required this.label,
    required this.style,
    required this.onTap,
  });

  final String label;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    child: MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: style.copyWith(color: context.palette.accentText),
        ),
      ),
    ),
  );
}

/// The foot of the search results: the keys that work in them.
class _SearchHints extends StatelessWidget {
  const _SearchHints();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget hint(String keys, String what) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Keycap(keys),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            what,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: palette.textDescription),
          ),
        ),
      ],
    );
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        hint('↵', 'Go to the setting'),
        hint('↑↓', 'Move'),
        hint('esc', 'Clear search'),
      ],
    );
  }
}

/// Keys, as a key cap.
class _Keycap extends StatelessWidget {
  const _Keycap(this.keys, {this.recording = false});

  final String keys;
  final bool recording;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      height: recording ? 26 : 24,
      constraints: const BoxConstraints(minWidth: 28),
      padding: EdgeInsets.symmetric(horizontal: recording ? 9 : 8),
      decoration: BoxDecoration(
        color: recording ? null : palette.surfaceBackground,
        borderRadius: BorderRadius.circular(AppRadii.compact),
        border: Border.all(
          color: recording
              ? Theme.of(context).colorScheme.primary
              : palette.switchTrackOff,
          width: recording ? 1.5 : 1,
        ),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          keys,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: AppPlatform.monoFontFallback.first,
            fontFamilyFallback: AppPlatform.monoFontFallback,
            fontSize: 12,
            height: 1.2,
            color: keys.isEmpty ? palette.textTertiary : palette.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// The shortcuts pane's own search: a name, or — after Press keys — the keys
/// somebody remembers.
class _ShortcutFilter extends StatelessWidget {
  const _ShortcutFilter({
    required this.controller,
    required this.focusNode,
    required this.pressing,
    required this.onPressKeys,
    required this.onKey,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool pressing;
  final VoidCallback onPressKeys;
  final FocusOnKeyEventCallback onKey;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: onKey,
            child: SizedBox(
              height: 34,
              child: TextField(
                key: const ValueKey('shortcut-filter'),
                controller: controller,
                focusNode: focusNode,
                readOnly: pressing,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontSize: 13, color: palette.textPrimary),
                decoration: kapyFieldDecoration(
                  context,
                  hintText: pressing
                      ? 'Press the keys…'
                      : 'Search by name, or press the keys you remember',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: palette.textTertiary,
                  ),
                  fillColor: palette.surfaceBackground,
                  borderWidth: 1.5,
                  radius: AppRadii.control,
                  neutralFocus: !pressing,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 8),
                    child: KapyIcon(
                      KapyIcons.searchRounded,
                      size: 15,
                      color: palette.textSecondary,
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(minHeight: 31),
                  contentPadding: const EdgeInsets.only(
                    right: 10,
                    top: 8.5,
                    bottom: 8.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          key: const ValueKey('shortcut-press-keys'),
          onPressed: onPressKeys,
          icon: const KapyIcon(KapyIcons.keyboardOutlined, size: 15),
          label: const Text('Press keys', style: TextStyle(fontSize: 12.5)),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            backgroundColor: pressing
                ? palette.tonalBackground
                : palette.controlBackground,
            foregroundColor: pressing
                ? palette.tonalForeground
                : palette.textPrimary,
            side: BorderSide(color: palette.controlBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
          ),
        ),
      ],
    );
  }
}

/// One shortcut: its name, and its keys, which listen for new ones when
/// clicked. A clash is settled right here, in a line under the row.
class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.label,
    required this.binding,
    required this.recording,
    required this.changed,
    required this.onReset,
    required this.onPressed,
    required this.onKey,
    required this.focusNode,
    required this.swap,
    required this.error,
    this.notice,
  });

  final ShortcutAction action;
  final String label;

  /// Null where the user has cleared it. The row stays, because it is also
  /// how the shortcut is given back.
  final ShortcutBinding? binding;
  final bool recording;
  final bool changed;
  final VoidCallback onReset;

  /// Null while the shortcut cannot be used, which dims its keys.
  final VoidCallback? onPressed;
  final FocusOnKeyEventCallback onKey;
  final FocusNode focusNode;

  /// The keys pressed, who has them now, and what that one would get.
  final ({String keys, String holder, String? given})? swap;
  final String? error;

  /// Why the shortcut is not answering, under the row while not recording.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final swap = this.swap;
    final note = TextStyle(fontSize: 12, color: palette.textDescription);
    final keys = Semantics(
      button: true,
      label: 'Change $label shortcut',
      child: InkWell(
        key: ValueKey('shortcut-${action.name}'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadii.compact),
        child: Opacity(
          opacity: onPressed == null ? 0.45 : 1,
          child: _Keycap(
            binding?.displayLabel ?? (recording ? 'Press keys' : 'None'),
            recording: recording,
          ),
        ),
      ),
    );
    return Container(
      color: recording
          ? Color.alphaBlend(
              palette.tonalBackground.withValues(alpha: 0.7),
              palette.cardBackground,
            )
          : null,
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(
                  child: SettingsRowCopy(title: label, changed: changed),
                ),
                if (changed && !recording) ...[
                  SettingsResetButton(onPressed: onReset),
                  const SizedBox(width: 4),
                ],
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, box.maxWidth - 40),
                  ),
                  child: recording
                      ? Focus(
                          focusNode: focusNode,
                          onKeyEvent: onKey,
                          child: keys,
                        )
                      : keys,
                ),
              ],
            ),
          ),
          if (notice case final notice? when !recording) ...[
            const SizedBox(height: 4),
            Text(
              notice,
              key: ValueKey('shortcut-note-${action.name}'),
              style: TextStyle(fontSize: 12, color: palette.textDescription),
            ),
          ],
          if (recording) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (swap != null || error != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 8),
                    child: KapyIcon(
                      KapyIcons.warningRounded,
                      size: 14,
                      color: palette.clay,
                    ),
                  ),
                ],
                Expanded(
                  child: swap == null
                      ? Text(
                          error ??
                              'Press the new keys. ⌫ takes it away, esc keeps '
                                  'it as it was.',
                          key: const ValueKey('shortcut-recording-note'),
                          style: note,
                        )
                      : Text.rich(
                          key: const ValueKey('shortcut-swap-note'),
                          TextSpan(
                            children: [
                              TextSpan(text: '${swap.keys} is already '),
                              TextSpan(
                                text: swap.holder,
                                style: TextStyle(color: palette.textPrimary),
                              ),
                              TextSpan(
                                text: swap.given == null
                                    ? '. ↵ swaps them, so ${swap.holder} has no '
                                          'keys. esc keeps both as they were.'
                                    : '. ↵ swaps them, so ${swap.holder} gets '
                                          '${swap.given}. esc keeps both as '
                                          'they were.',
                              ),
                            ],
                          ),
                          style: note,
                        ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The handle that says the sheet can be pulled back down.
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.palette.textTertiary.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: const SizedBox(width: 38, height: 4),
      ),
    ),
  );
}

/// The list the sheet opens on: every category, what is inside it, and the
/// chevron that goes there.
class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.sections,
    required this.changed,
    required this.account,
    required this.onSelect,
  });

  final List<SettingsSection> sections;

  /// The categories holding a setting off its default.
  final Set<SettingsSection> changed;
  final Account? account;
  final ValueChanged<SettingsSection> onSelect;

  /// The account is the one category whose contents depend on where you
  /// already stand in it, so its line answers that before it is opened.
  String _summaryFor(SettingsSection section) {
    final account = this.account;
    if (section != SettingsSection.account || account == null) {
      return section.summary;
    }
    return switch (account.state) {
      AccountState.restoring => 'Checking your account',
      AccountState.signedOut => 'Sign in to sync and share notes',
      AccountState.needsProfile => 'Choose the name people will see',
      AccountState.needsPassphrase => 'Save your passphrase to start syncing',
      AccountState.locked => 'Unlock to read these notes here',
      AccountState.keysChanged => 'Waiting for your new passphrase',
      AccountState.needsAccountDecision => 'Choose what happens to local notes',
      AccountState.ready => account.user?.displayName ?? 'Signed in',
    };
  }

  Widget _card() => SettingsGroup(
    children: [
      for (final section in sections)
        _CategoryRow(
          key: ValueKey('settings-section-${section.name}'),
          section: section,
          summary: _summaryFor(section),
          changed: changed.contains(section),
          onTap: () => onSelect(section),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return _card();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => _card(),
    );
  }
}

/// One category on that list.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    super.key,
    required this.section,
    required this.summary,
    required this.changed,
    required this.onTap,
  });

  final SettingsSection section;
  final String summary;
  final bool changed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          child: Row(
            children: [
              // A tinted tile: on the way back, a category is found by shape
              // and colour long before its label is read again.
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: KapyIcon(section.icon, size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SettingsRowCopy(
                  title: section.label,
                  subtitle: summary,
                  changed: changed,
                ),
              ),
              const SizedBox(width: 8),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: SettingsMetrics.chevronSize,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The category list down the left of the wide dialog.
class _SettingsRail extends StatelessWidget {
  const _SettingsRail({
    required this.sections,
    required this.changed,
    required this.selected,
    required this.onSelect,
  });

  final List<SettingsSection> sections;

  /// The categories holding a setting off its default, each marked with a
  /// dot so what was changed can be found again.
  final Set<SettingsSection> changed;

  /// Null while the pane is showing search results instead of a category.
  final SettingsSection? selected;
  final ValueChanged<SettingsSection> onSelect;

  /// One row and the gap under it.
  static const double itemHeight = 34;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections)
          _RailItem(
            key: ValueKey('settings-section-${section.name}'),
            icon: section.icon,
            label: section.label,
            changed: changed.contains(section),
            selected: section == selected,
            onTap: () => onSelect(section),
          ),
      ],
    ),
  );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.changed = false,
  });

  final KapyIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    const corners = BorderRadius.all(Radius.circular(AppRadii.control));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? palette.tonalBackground : Colors.transparent,
          borderRadius: corners,
          child: InkWell(
            onTap: onTap,
            borderRadius: corners,
            hoverColor: palette.hover,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  KapyIcon(
                    icon,
                    size: 16,
                    strokeWidth: 1.7,
                    color: selected
                        ? palette.tonalForeground
                        : palette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 16 / 13.5,
                        color: selected
                            ? palette.tonalForeground
                            : palette.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (changed) const SettingsChangedDot(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Names the build that is actually running: the first thing a bug report
/// asks for, and the only line in this pane that never depends on the
/// network.
class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.updates});

  final UpdateChecker updates;

  @override
  Widget build(BuildContext context) {
    final version = updates.currentVersion;
    final build = updates.currentBuild;
    return SettingsRow(
      title: version.isEmpty ? 'Kapy Notes' : 'Kapy Notes $version',
      subtitle: build.isEmpty
          ? 'Reading the installed version'
          : 'Build $build',
    );
  }
}

/// One screen of the sheet: a bar saying where you are, and the pane under it.
class _SheetPage extends StatelessWidget {
  const _SheetPage({
    required this.title,
    required this.bottomInset,
    required this.children,
    this.onBack,
    this.flashTarget,
    this.flash,
  });

  final String title;

  /// The home indicator, which the sheet reaches under but nothing scrolls
  /// beneath.
  final double bottomInset;
  final List<Widget> children;

  /// Null on the list of categories, which has nothing to go back to.
  final VoidCallback? onBack;

  /// The row a search result led to, lit over the page. Only a category's
  /// page has one: the list of categories is never where a result lands.
  final ValueListenable<RenderBox?>? flashTarget;
  final Animation<double>? flash;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final back = onBack;
    // Opaque, because these pages slide over one another.
    return ColoredBox(
      color: palette.surfaceBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(back == null ? 20 : 4, 0, 10, 6),
            child: Row(
              children: [
                if (back != null)
                  IconButton(
                    key: const ValueKey('settings-sheet-back'),
                    onPressed: back,
                    tooltip: 'Back',
                    color: palette.textSecondary,
                    icon: const KapyIcon(KapyIcons.arrowBackRounded, size: 17),
                  ),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      letterSpacing: -0.2,
                      color: palette.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  key: const ValueKey('settings-sheet-done'),
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          Divider(
            height: AppHairline.of(context),
            thickness: AppHairline.of(context),
            color: palette.separator,
          ),
          Expanded(
            child: _withFlash(
              SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomInset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
              flashTarget,
              flash,
            ),
          ),
        ],
      ),
    );
  }
}

/// The scrolling half of the dialog, whichever layout is in use.
class _ScrollingPane extends StatelessWidget {
  const _ScrollingPane({
    super.key,
    required this.controller,
    required this.children,
    this.flashTarget,
    this.flash,
  });

  final ScrollController controller;
  final List<Widget> children;

  /// The row a search result led to, lit over the pane. See
  /// [SettingsFlashLayer].
  final ValueListenable<RenderBox?>? flashTarget;
  final Animation<double>? flash;

  @override
  Widget build(BuildContext context) {
    final pane = Scrollbar(
      controller: controller,
      thumbVisibility: AppPlatform.hasPointer,
      thickness: 3,
      radius: const Radius.circular(AppRadii.pill),
      child: SingleChildScrollView(
        controller: controller,
        padding: AppPlatform.hasPointer
            ? const EdgeInsets.fromLTRB(28, 0, 24, 24)
            : const EdgeInsets.only(right: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
    return _withFlash(pane, flashTarget, flash);
  }
}

/// [child] with the search's light laid over it, where there is one.
Widget _withFlash(
  Widget child,
  ValueListenable<RenderBox?>? target,
  Animation<double>? progress,
) {
  if (target == null || progress == null) return child;
  return Stack(
    children: [
      Positioned.fill(child: child),
      Positioned.fill(
        child: IgnorePointer(
          child: SettingsFlashLayer(target: target, progress: progress),
        ),
      ),
    ],
  );
}

/// The installed version at the foot of the rail, with a dot that says
/// whether there is a newer one.
class _VersionStatus extends StatelessWidget {
  const _VersionStatus({required this.updates});

  final UpdateChecker updates;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final version = updates.currentVersion;
    if (version.isEmpty) return const SizedBox.shrink();
    final shown = version.endsWith('.0')
        ? version.substring(0, version.length - 2)
        : version;
    final pending = updates.hasUpdate;
    return Container(
      key: const ValueKey('settings-version-status'),
      height: 18,
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: pending
                  ? palette.keyword
                  : Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: const SizedBox.square(dimension: 6),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              'Version $shown · ${pending ? 'Update available' : 'Up to date'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 14 / 11.5,
                color: palette.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who made the models on offer, and under what licence.
///
/// Kept when the cards went, because it is the one part of them that was not
/// only informative: CC-BY wants the creator named and the licence reachable,
/// and a row with a switch on it is no place for either.
class _ModelCredits extends StatelessWidget {
  const _ModelCredits({required this.models});

  final List<DownloadableModel> models;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      fontSize: AppTypeScale.micro,
      height: 1.35,
      color: palette.textSecondary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 8, 3, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final model in models)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(model.credit, style: style),
                  InkWell(
                    key: ValueKey('voice-local-model-licence-${model.id}'),
                    onTap: () => unawaited(_openLicence(context, model)),
                    // Colour says it opens something, the way a link in a
                    // note does. Nothing in this app is underlined.
                    child: Text(
                      model.license,
                      style: style.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openLicence(
    BuildContext context,
    DownloadableModel model,
  ) async {
    final url = Uri.tryParse(model.licenseUrl);
    if (url == null) return;
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    Toast.show(
      context,
      'Could not open ${url.host}',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }
}

/// How far along a download is, or why it stopped.
class _ModelProgress extends StatelessWidget {
  const _ModelProgress({required this.state});

  final LocalModelState state;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final error = state.error;
    if (error != null) {
      return Text(
        error,
        key: const ValueKey('voice-local-model-error'),
        style: TextStyle(
          fontSize: AppPlatform.isWindows ? AppTypeScale.caption : 11,
          color: scheme.error,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: SizedBox(
            height: 4,
            child: Stack(
              children: [
                ColoredBox(
                  color: palette.separator,
                  child: const SizedBox.expand(),
                ),
                // Checking has no percentage of its own — the bytes are all
                // here — so the bar stays full rather than pretending.
                FractionallySizedBox(
                  widthFactor: state.status == LocalModelStatus.verifying
                      ? 1
                      : state.progress,
                  child: ColoredBox(
                    color: scheme.primary,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          switch (state.status) {
            LocalModelStatus.verifying => 'Checking the download',
            // The engine comes from Google Play, ahead of the model, and its
            // size is Play's to announce; until it has, there is no number
            // worth showing.
            LocalModelStatus.fetchingRuntime when state.totalBytes <= 0 =>
              'Getting this phone ready',
            LocalModelStatus.fetchingRuntime =>
              'Getting this phone ready: '
                  '${fileSize(state.receivedBytes)} of '
                  '${fileSize(state.totalBytes)}',
            _ =>
              '${fileSize(state.receivedBytes)} of '
                  '${fileSize(state.totalBytes)}',
          },
          key: const ValueKey('voice-local-model-progress-line'),
          style: TextStyle(
            fontSize: AppPlatform.isWindows ? AppTypeScale.caption : 10.5,
            color: palette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The only place the update state is spelled out: what the daily check
/// found, how far the download has got, and the button for whatever is next
/// — a check, a download, or the restart that installs it.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow({required this.updates});

  final UpdateChecker updates;

  /// A check that has never reached the manifest may not claim anything, so
  /// the untouched state offers the check instead of asserting a verdict.
  String _title() {
    final staged = updates.staged;
    if (staged != null) return 'Version ${staged.version} is ready';
    final available = updates.available;
    if (available != null) {
      return updates.isDownloading
          ? 'Downloading version ${available.version}'
          : 'Version ${available.version} available';
    }
    if (updates.isChecking) return 'Checking for updates';
    return updates.lastChecked == null ? 'Check for updates' : 'Up to date';
  }

  String _subtitle() {
    if (updates.isInstalling) return 'Restarting…';
    final current = updates.currentVersion;
    final installed = current.isEmpty ? '' : ' · Current $current';
    // The version row above already names the build that is running, and the
    // button beside this one is long enough to squeeze it out.
    if (updates.staged != null) {
      return updates.downloadError ?? 'Ready to install';
    }
    if (updates.available != null) {
      if (updates.isDownloading) {
        final progress = updates.downloadProgress;
        return progress == null
            ? 'In the background$installed'
            : '${(progress * 100).floor()}%$installed';
      }
      final error = updates.downloadError;
      if (error != null) return error;
      return current.isEmpty ? 'Not downloaded yet' : 'Current $current';
    }
    final checked = updates.lastChecked;
    if (checked == null) return 'Checks once a day';
    return 'Checked ${_relativeDay(checked)}';
  }

  /// Deliberately coarse. The exact minute of a background check is noise,
  /// and a stale clock reading "3 minutes ago" invites more doubt than trust.
  static String _relativeDay(DateTime checked) {
    final days = DateTime.now().difference(checked).inDays;
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      _ => '$days days ago',
    };
  }

  Future<void> _openLink(BuildContext context, String raw) async {
    final url = Uri.tryParse(raw);
    if (url == null || raw.isEmpty) return;
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    Toast.show(
      context,
      'Could not open ${url.host}',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  /// The row reports a download and a restart itself, so only the check —
  /// the one action whose whole result is a verdict — gets a toast.
  Future<void> _runAction(BuildContext context) async {
    if (updates.staged != null) {
      await updates.installAndRestart();
      return;
    }
    if (updates.available case final available?) {
      if (AppPlatform.isLinux) {
        await _openLink(context, available.downloadPage);
        return;
      }
      await updates.download();
      return;
    }
    final progress = Toast.showProgress(context, 'Checking for updates…');
    final succeeded = await updates.check();
    if (!context.mounted) {
      progress.dismiss();
      return;
    }
    if (!succeeded) {
      progress.error('Could not check for updates');
      return;
    }
    progress.success(
      updates.hasUpdate ? 'Update available' : 'Kapy Notes is up to date',
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final available = updates.available;
        final ready = updates.staged != null;
        final busy =
            updates.isChecking || updates.isDownloading || updates.isInstalling;
        final label = ready
            ? 'Update and restart'
            : available != null
            ? 'Download'
            : 'Check';
        return Padding(
          padding: SettingsMetrics.padding,
          child: Row(
            children: [
              Expanded(
                child: SettingsRowCopy(title: _title(), subtitle: _subtitle()),
              ),
              if (available != null && available.notesUrl.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('update-release-notes'),
                  onPressed: () => _openLink(context, available.notesUrl),
                  icon: const KapyIcon(KapyIcons.openExternalRounded, size: 15),
                  color: palette.textTertiary,
                  tooltip: "What's new",
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('update-action'),
                onPressed: busy ? null : () => unawaited(_runAction(context)),
                style: TextButton.styleFrom(
                  minimumSize: const Size(78, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  backgroundColor: available != null || ready
                      ? palette.selectedBackground
                      : palette.controlBackground,
                  foregroundColor: palette.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.compact),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(fontSize: AppTypeScale.caption),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The pending release, or the full history when the app is up to date.
///
/// Read from the site rather than built in: see [ReleaseHistory]. A pending
/// update is deliberately a one-release view. Someone deciding whether to
/// install 1.2.0 should see what 1.2.0 changes, not the entire history below
/// it. Without a pending update this remains the browsable release index.
class _ChangelogGroup extends StatefulWidget {
  const _ChangelogGroup({required this.updates});

  final UpdateChecker updates;

  @override
  State<_ChangelogGroup> createState() => _ChangelogGroupState();
}

class _ChangelogGroupState extends State<_ChangelogGroup> {
  /// Both, because the list marks the running build: the version comes from
  /// the checker and the releases from its history.
  late final Listenable _listenable = Listenable.merge([
    widget.updates,
    widget.updates.history,
  ]);

  /// The versions whose notes are open, or null until somebody has opened or
  /// closed one — which is when the newest is showing on its own. Kept as a
  /// nullable rather than seeded from the list, because the list arrives
  /// after the first build and state must not be invented during one.
  Set<String>? _open;
  bool _requestedHistory = false;
  String? _requestedVersion;

  @override
  void initState() {
    super.initState();
    widget.updates.addListener(_updateRequestedRelease);
    _loadRelevantHistory();
  }

  /// The manifest and changelog are cached independently. If the manifest
  /// discovers a release after this pane opens, ask for that exact entry and
  /// open it rather than leaving the previously cached history on screen.
  void _updateRequestedRelease() {
    final version = widget.updates.available?.version;
    if (_requestedHistory && version == _requestedVersion) return;
    _open = null;
    _loadRelevantHistory();
  }

  void _loadRelevantHistory() {
    final version = widget.updates.available?.version;
    _requestedHistory = true;
    _requestedVersion = version;
    unawaited(
      version == null
          ? widget.updates.history.load()
          : widget.updates.history.loadForVersion(version),
    );
  }

  Set<String> _openIn(List<ReleaseNote> releases) =>
      _open ?? {if (releases.isNotEmpty) releases.first.version};

  void _toggle(ReleaseNote release, Set<String> open) => setState(() {
    _open = open.contains(release.version)
        ? (Set.of(open)..remove(release.version))
        : (Set.of(open)..add(release.version));
  });

  @override
  void dispose() {
    widget.updates.removeListener(_updateRequestedRelease);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _listenable,
    builder: (context, _) {
      final history = widget.updates.history;
      final pendingVersion = widget.updates.available?.version;
      final releases = pendingVersion == null
          ? history.releases
          : history.releases
                .where((release) => release.version == pendingVersion)
                .take(1)
                .toList(growable: false);
      final open = _openIn(releases);
      return SettingsGroup(
        children: [
          if (releases.isEmpty)
            _ChangelogStatusRow(history: history)
          else
            for (final release in releases)
              _ReleaseRow(
                release: release,
                installed: release.version == widget.updates.currentVersion,
                compact: pendingVersion != null,
                open: open.contains(release.version),
                onToggle: () => _toggle(release, open),
              ),
          // The public history is useful while browsing past releases, but
          // would turn the focused update view back into the long changelog
          // it intentionally replaces.
          if (pendingVersion == null) const _ChangelogLinkRow(),
        ],
      );
    },
  );
}

/// What the pane says while it has no releases to show: that it is reading
/// them, or that it could not.
class _ChangelogStatusRow extends StatelessWidget {
  const _ChangelogStatusRow({required this.history});

  final ReleaseHistory history;

  @override
  Widget build(BuildContext context) => SettingsRow(
    title: history.hasFailed
        ? 'Could not read the changelog'
        : 'Reading the release notes',
    subtitle: history.hasFailed
        ? 'Could not reach kapynotes.com'
        : 'Updated daily from kapynotes.com',
    trailing: history.isLoading
        ? null
        : SettingsRowButton(
            key: const ValueKey('changelog-retry'),
            label: 'Try again',
            onPressed: () => unawaited(history.refresh()),
          ),
  );
}

/// One release: its version and the day it published, over the notes it
/// shipped with once the row is opened.
class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.installed,
    required this.compact,
    required this.open,
    required this.onToggle,
  });

  final ReleaseNote release;

  /// Whether this is the build that is running, which is the one thing this
  /// list can say that the website's copy of it cannot.
  final bool installed;

  /// Update prompts use the concise highlights. Browsing history keeps every
  /// detail, so shortening the prompt never removes the full release notes.
  final bool compact;

  final bool open;
  final VoidCallback onToggle;

  /// The day, as the rest of the app writes one. Borrowed from the note list
  /// rather than counting out a ninth table of month names; a date the
  /// changelog wrote in some other shape is simply left out.
  static String? _day(String date) {
    final parsed = DateTime.tryParse(date);
    return parsed == null ? null : SidebarTimestamp.formatDay(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final changes = compact ? release.updateHighlights : release.changes;
    final body = TextStyle(
      fontSize: SettingsMetrics.subtitleSize,
      height: 1.45,
      color: palette.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            key: ValueKey('release-${release.version}'),
            onTap: onToggle,
            child: Padding(
              padding: SettingsMetrics.padding,
              child: Row(
                children: [
                  SizedBox(
                    width: SettingsMetrics.chevronSize,
                    child: AnimatedRotation(
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      turns: open ? 0.25 : 0,
                      child: KapyIcon(
                        KapyIcons.chevronRightRounded,
                        size: SettingsMetrics.chevronSize,
                        color: palette.textTertiary,
                      ),
                    ),
                  ),
                  SizedBox(width: SettingsMetrics.gap),
                  Expanded(
                    child: SettingsRowCopy(
                      title: release.version,
                      subtitle: _day(release.date),
                    ),
                  ),
                  if (installed) ...[
                    const SizedBox(width: 10),
                    Text(
                      'Installed',
                      style: TextStyle(
                        fontSize: SettingsMetrics.subtitleSize,
                        color: palette.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: EdgeInsets.only(
              left: SettingsMetrics.chevronSize + SettingsMetrics.gap,
              right: SettingsMetrics.padding.right,
              bottom: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (release.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      release.summary,
                      style: body.copyWith(color: palette.textPrimary),
                    ),
                  ),
                for (final change in changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('•', style: body),
                        const SizedBox(width: 7),
                        Expanded(child: Text(change, style: body)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The phone's lasting way to the notes. The notice at the top of Settings
/// can be closed; this row cannot, and it lives in About, where a computer
/// keeps the same route.
class _QuietWhatsNewRow extends StatelessWidget {
  const _QuietWhatsNewRow();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SettingsGroup(
      children: [
        Semantics(
          link: true,
          child: InkWell(
            key: const ValueKey('changelog'),
            onTap: () => unawaited(openChangelogPage(context)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: SettingsMetrics.padding,
                child: Row(
                  children: [
                    const Expanded(
                      child: SettingsRowCopy(
                        title: "What's new",
                        subtitle: 'See what changed',
                      ),
                    ),
                    const SizedBox(width: 8),
                    KapyIcon(
                      KapyIcons.openExternalRounded,
                      size: 15,
                      color: palette.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens the changelog page itself.
class _ChangelogLinkRow extends StatelessWidget {
  const _ChangelogLinkRow();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      link: true,
      child: InkWell(
        key: const ValueKey('changelog-page'),
        onTap: () => unawaited(openChangelogPage(context)),
        child: Padding(
          padding: SettingsMetrics.padding,
          child: Row(
            children: [
              const Expanded(
                child: SettingsRowCopy(
                  title: 'Changelog',
                  subtitle: 'View every release on kapynotes.com',
                ),
              ),
              const SizedBox(width: 8),
              KapyIcon(
                KapyIcons.openExternalRounded,
                size: 15,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A theme's accent as a ring, beside its name where a theme is chosen.
class _AccentRing extends StatelessWidget {
  const _AccentRing(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 3),
    ),
  );
}

/// One of a short list, opened from a row's menu button with the current
/// choice in view: the night theme, an hour.
class _ListPickerDialog<T> extends StatefulWidget {
  const _ListPickerDialog({
    required this.title,
    required this.options,
    required this.selected,
    required this.label,
    required this.keyFor,
    this.leading,
  });

  final String title;
  final List<T> options;
  final T selected;
  final String Function(T option) label;
  final String Function(T option) keyFor;
  final Widget Function(T option)? leading;

  @override
  State<_ListPickerDialog<T>> createState() => _ListPickerDialogState<T>();
}

class _ListPickerDialogState<T> extends State<_ListPickerDialog<T>> {
  static const double _rowHeight = 44;
  static const double _maxHeight = 352;

  late final double _height = math.min(
    _maxHeight,
    _rowHeight * widget.options.length,
  );

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset:
        ((widget.options.indexOf(widget.selected) + 0.5) * _rowHeight -
                _height / 2)
            .clamp(0.0, _rowHeight * widget.options.length - _height),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      content: SizedBox(
        width: math.min(320, MediaQuery.sizeOf(context).width - 80),
        height: _height,
        child: ListView.builder(
          controller: _scroll,
          itemExtent: _rowHeight,
          itemCount: widget.options.length,
          itemBuilder: (context, index) {
            final option = widget.options[index];
            final selected = option == widget.selected;
            final leading = widget.leading;
            return Semantics(
              selected: selected,
              button: true,
              child: ListTile(
                key: ValueKey(widget.keyFor(option)),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                leading: leading?.call(option),
                minLeadingWidth: 12,
                title: Text(widget.label(option)),
                trailing: KapyIcon(
                  selected
                      ? KapyIcons.checkCircleRounded
                      : KapyIcons.circleOutlined,
                  size: 18,
                  color: selected ? palette.accent : palette.textTertiary,
                ),
                onTap: () => Navigator.of(context).pop(option),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _DefaultNotePickerDialog extends StatelessWidget {
  const _DefaultNotePickerDialog({
    required this.notes,
    required this.selectedId,
  });

  final List<Note> notes;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('Note opened at launch'),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      content: SizedBox(
        width: math.min(410, media.width - 80),
        height: math.min(380, 54.0 * (notes.length + 1)),
        child: ListView.separated(
          itemCount: notes.length + 1,
          separatorBuilder: (_, _) => Divider(
            height: AppHairline.of(context),
            thickness: AppHairline.of(context),
            color: context.palette.separator,
          ),
          itemBuilder: (context, index) {
            final note = index == 0 ? null : notes[index - 1];
            final selected =
                note?.id == selectedId || (note == null && selectedId == null);
            return Semantics(
              selected: selected,
              button: true,
              child: ListTile(
                key: ValueKey(
                  note == null
                      ? 'default-note-option-last-opened'
                      : 'default-note-option-${note.id}',
                ),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                title: Text(note?.title ?? 'Last opened note'),
                subtitle: note == null
                    ? const Text('Continue where you left off')
                    : null,
                trailing: KapyIcon(
                  selected
                      ? KapyIcons.checkCircleRounded
                      : KapyIcons.circleOutlined,
                  size: 18,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : context.palette.textTertiary,
                ),
                onTap: () => Navigator.of(context).pop(note?.id ?? ''),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _TimeZonePickerDialog extends StatefulWidget {
  const _TimeZonePickerDialog({required this.selectedId});

  final String? selectedId;

  @override
  State<_TimeZonePickerDialog> createState() => _TimeZonePickerDialogState();
}

class _TimeZonePickerDialogState extends State<_TimeZonePickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final matches = AppTimeZones.locationIds
        .where((id) => AppTimeZones.matches(id, _query))
        .toList(growable: false);
    final systemMatches =
        AppTimeZones.matches(null, _query) ||
        'follow this device'.contains(_query.trim().toLowerCase());
    final options = <String?>[if (systemMatches) null, ...matches];

    return AlertDialog(
      title: const Text('Time zone'),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      content: SizedBox(
        width: math.min(410, media.width - 80),
        height: (media.height - 220).clamp(240.0, 520.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('time-zone-search'),
              style: TextStyle(
                fontSize: AppPlatform.isWindows ? AppTypeScale.control : 13,
              ),
              decoration: InputDecoration(
                hintText: 'Search cities or regions',
                prefixIcon: const KapyIcon(KapyIcons.searchRounded, size: 16),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 34,
                  minHeight: 32,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: options.isEmpty
                  ? Center(
                      child: Text(
                        'No matching time zones',
                        style: TextStyle(color: context.palette.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: options.length,
                      separatorBuilder: (_, _) => Divider(
                        height: AppHairline.of(context),
                        thickness: AppHairline.of(context),
                        color: context.palette.separator,
                      ),
                      itemBuilder: (context, index) {
                        final id = options[index];
                        return _TimeZoneOption(
                          key: ValueKey(
                            id == null
                                ? 'time-zone-option-system'
                                : 'time-zone-option-$id',
                          ),
                          locationId: id,
                          selected: widget.selectedId == id,
                          onTap: () => Navigator.of(context).pop(id ?? ''),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _TimeZoneOption extends StatelessWidget {
  const _TimeZoneOption({
    super.key,
    required this.locationId,
    required this.selected,
    required this.onTap,
  });

  final String? locationId;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: SettingsRowCopy(
                  title: AppTimeZones.displayName(locationId),
                  subtitle: locationId == null
                      ? 'Follow this device · ${AppTimeZones.offsetLabel(null)}'
                      : AppTimeZones.offsetLabel(locationId),
                ),
              ),
              const SizedBox(width: 10),
              KapyIcon(
                selected
                    ? KapyIcons.checkCircleRounded
                    : KapyIcons.circleOutlined,
                size: 17,
                color: selected ? accent : palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
