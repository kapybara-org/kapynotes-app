import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../billing/entitlements.dart';
import '../billing/billing.dart';
import '../core/appearance.dart';
import '../core/desktop_integration.dart';
import '../core/device_memory.dart';
import '../core/editor_font.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/layout_prefs.dart';
import '../data/note.dart';
import '../data/voice_prefs.dart';
import 'voice_consent_sheet.dart';
import '../speech/local_model_store.dart';
import '../speech/summarizer.dart';
import '../speech/transcriber.dart';
import 'model_terms_sheet.dart';
import 'settings_rows.dart';
import 'settings_search.dart';
import 'sidebar_timestamp.dart';
import '../speech/local_models.dart';
import '../speech/speech_errors.dart';
import '../speech/speech_api.dart';
import '../data/notes_store.dart';
import '../sync/account.dart';
import 'account/sharing_pane.dart';
import 'account/sync_pane.dart';
import 'billing/pro_sheet.dart';
import 'export_import.dart';
import '../data/rates.dart';
import '../data/shortcut_prefs.dart';
import '../data/release_history.dart';
import '../data/update_checker.dart';
import '../data/time_zones.dart';

/// The groups of settings, one per rail entry.
///
/// Adding a section is meant to be the whole job of adding a category of
/// options: name it here, give it a pane in [_SettingsDialogState], and all
/// three layouts pick it up.
enum SettingsSection {
  general,
  sync,
  plan,
  appearance,
  voice,
  shortcuts,
  updates,
}

const _sheetCorners = BorderRadius.vertical(top: Radius.circular(22));
const _sheetIndexKey = ValueKey('settings-sheet-index');

/// Wide enough for the full desktop dialog, its insets, and the Windows frame.
const double _windowsSettingsWindowWidth = 720;

const _settingsRegularWeight = FontWeight.w400;
const _settingsMediumWeight = FontWeight.w400;
const _settingsSemiboldWeight = FontWeight.w400;

extension SettingsSectionCopy on SettingsSection {
  String get label => switch (this) {
    SettingsSection.general => 'General',
    SettingsSection.sync => 'Profile & sync',
    SettingsSection.plan => 'Plan & usage',
    SettingsSection.voice => 'Voice notes',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.updates => 'Updates',
  };

  KapyIconData get icon => switch (this) {
    SettingsSection.general => KapyIcons.tuneRounded,
    SettingsSection.sync => KapyIcons.accountCircleOutlined,
    SettingsSection.plan => KapyIcons.verifiedOutlined,
    SettingsSection.voice => KapyIcons.micRounded,
    SettingsSection.appearance => KapyIcons.storiesOutlined,
    SettingsSection.shortcuts => KapyIcons.keyboardOutlined,
    SettingsSection.updates => KapyIcons.systemUpdateRounded,
  };

  /// What is behind the label, for the layouts that show a list of categories
  /// instead of the categories themselves. Names the contents rather than
  /// selling them: this line is read while looking for something.
  String get summary => switch (this) {
    SettingsSection.general => 'Writing, notes, imports, and window',
    SettingsSection.sync => 'Profile, sync, and sharing',
    SettingsSection.plan => 'Plan, cloud usage, and storage',
    SettingsSection.voice => 'Transcription and summaries',
    SettingsSection.appearance => 'Theme, text size, paper, fonts, and numbers',
    SettingsSection.shortcuts => 'Global and in-app shortcuts',
    SettingsSection.updates => 'Version and release notes',
  };
}

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
  Future<bool> Function(BuildContext context)? authorizeHiddenNotes,
  SettingsSection? section,
  String? notice,
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
    authorizeHiddenNotes: authorizeHiddenNotes,
    section: section,
    notice: notice,
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
    this.authorizeHiddenNotes,
    this.section,
    this.notice,
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

  /// Required before an export can include protected notes. Null is only for
  /// isolated settings tests and still refuses an export containing them.
  final Future<bool> Function(BuildContext context)? authorizeHiddenNotes;
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;

  /// The pane to open on, when something outside sent the user here to do one
  /// thing. Null starts where settings always starts.
  final SettingsSection? section;

  /// Why whatever sent the user here did so — "Sign in first to share this
  /// note" — said as a toast once this is on screen. Raised here rather than
  /// by the caller: on Windows this opens only after the window has widened,
  /// and a toast shown before it would be drawn underneath.
  final String? notice;

  /// Present as the phone sheet — a list of categories you push through —
  /// instead of the rail dialog. Set by [showSettings]. Both shapes are the
  /// same widget so that a new section still only has to be written once.
  final bool asSheet;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  /// Other desktop platforms may still stack at their narrowest. Windows
  /// borrows enough host-window width before opening, and always keeps the
  /// section rail visible while that resize reaches Flutter.
  static const double _railBreakpoint = 520;
  static const double _railWidth = 164;
  static const double _panedWidth = 600;
  static const double _stackedWidth = 440;

  String? _shortcutError;
  String? _loginItemError;
  SettingsSection _section = SettingsSection.general;

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

  bool get _searching => _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    if (!widget.asSheet) HardwareKeyboard.instance.addHandler(_onFindKey);
    _shortcutError = widget.desktopIntegration?.registrationError;
    _loadSpeechState();
    unawaited(widget.account?.billing?.refresh());
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
      _section = SettingsSection.updates;
      _sheetSection = SettingsSection.updates;
    }
    // An explicit destination wins over both: whoever asked for this pane knew
    // what the user was trying to do.
    final wanted = widget.section;
    if (wanted != null && _isAvailable(wanted)) {
      _section = wanted;
      _sheetSection = wanted;
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
    _flash.dispose();
    _flashTarget.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _exportNotes() async {
    if (widget.notes.hiddenNotes.isNotEmpty) {
      final authorize = widget.authorizeHiddenNotes;
      if (authorize == null) {
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
      if (!await authorize(context) || !mounted) return;
    }
    if (!mounted) return;
    await runExport(context, widget.notes);
  }

  void _onSearchChanged() {
    final query = _search.text.trim();
    if (query == _query) return;
    final wasSearching = _searching;
    setState(() => _query = query);
    // Results and a pane share the scroll; whichever takes over starts at
    // the top rather than wherever the other was left.
    if (wasSearching != _searching && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  /// ⌘F or Ctrl+F, from anywhere in the dialog, goes to the search field —
  /// the same chord that finds things everywhere else. Only while this is
  /// the route on top: a dialog opened over settings keeps its own keys.
  bool _onFindKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyF) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final chord = AppPlatform.isMacOS
        ? keyboard.isMetaPressed && !keyboard.isControlPressed
        : keyboard.isControlPressed && !keyboard.isMetaPressed;
    if (!chord || keyboard.isAltPressed || keyboard.isShiftPressed) {
      return false;
    }
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  /// A section appears only where its subject does: shortcuts are a
  /// desktop-only idea, and updates need the checker that only a platform
  /// which can update itself is given.
  bool _isAvailable(SettingsSection section) => switch (section) {
    SettingsSection.shortcuts => AppPlatform.isDesktop,
    SettingsSection.updates => widget.updates != null,
    // Absent until the app is built with a server to talk to. Sharing lives
    // inside it: an account is the thing both halves need, and reading about
    // one straight after the other is how somebody actually meets them.
    SettingsSection.sync => widget.account != null,
    SettingsSection.plan => widget.account != null,
    // Present even signed out, and even with no transcription configured:
    // recording works without an account, and the pane says so rather than
    // hiding and leaving the user to wonder where the setting went.
    SettingsSection.voice => widget.voicePrefs != null,
    _ => true,
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
  /// rather than merely hiding the toggle.
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

    if (on) {
      final accepted = await showSpeechConsentSheet(context);
      if (!accepted) {
        widget.voicePrefs?.transcriptionDeclinedVersion = speechConsentVersion;
        return false;
      }
      if (!mounted) return false;
    }
    setState(() {
      _speechBusy = true;
      _speechError = null;
    });
    final progress = Toast.showProgress(
      context,
      on ? 'Turning on transcription…' : 'Turning off transcription…',
    );
    var changed = false;
    try {
      // Version 0 withdraws.
      final status = await speech.acceptConsent(on ? speechConsentVersion : 0);
      if (on) widget.voicePrefs?.transcriptionDeclinedVersion = null;
      changed = on ? status.isAccepted : !status.isAccepted;
      if (mounted) {
        setState(() => _speechConsent = status);
        progress.success(
          on ? 'Transcription turned on' : 'Transcription turned off',
        );
      } else {
        progress.dismiss();
      }
    } catch (error) {
      final message = describeSpeechError(error);
      if (mounted) {
        setState(() => _speechError = message);
        progress.error(message);
      } else {
        progress.dismiss();
      }
    } finally {
      if (mounted) setState(() => _speechBusy = false);
    }
    return changed;
  }

  Future<void> _selectCloudTranscription(VoicePrefs prefs) async {
    if (_speechBusy || widget.account?.speech == null) return;
    if (_speechConsent?.isAccepted ?? false) {
      setState(() => prefs.transcriptEngine = TranscriptEngine.cloud);
      widget.onTranscriptionReady?.call();
      return;
    }
    if (await _setTranscription(true) && mounted) {
      setState(() => prefs.transcriptEngine = TranscriptEngine.cloud);
      widget.onTranscriptionReady?.call();
    }
  }

  Future<void> _turnOffCloudTranscription() async {
    await _setTranscription(false);
  }

  /// The languages worth offering: the ones a provider detects least reliably
  /// are the ones somebody will want to state once and forget.
  static const Map<String?, String> _speechLanguages = {
    null: 'Detect automatically',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'hi': 'Hindi',
    'pt': 'Portuguese',
    'it': 'Italian',
    'nl': 'Dutch',
    'ja': 'Japanese',
    'zh': 'Chinese',
  };

  Future<void> _pickSpeechLanguage(VoicePrefs prefs) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Transcription language'),
        children: [
          for (final entry in _speechLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(entry.key ?? ''),
              child: Text(entry.value),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => prefs.language = chosen.isEmpty ? null : chosen);
  }

  /// What happens to a recording, and where.
  ///
  /// Cloud and local transcription are one decision, so they sit together as
  /// mutually exclusive choices. The shared recording options follow, then
  /// the separate local summary engine.
  List<Widget> _voicePane() {
    final prefs = widget.voicePrefs;
    if (prefs == null) return const [];
    final signedIn = widget.account?.speech != null;
    final cloudSelected =
        signedIn &&
        (_speechConsent?.isAccepted ?? false) &&
        prefs.transcriptEngine == TranscriptEngine.cloud;
    return [
      const SettingsLabel('TRANSCRIPTION'),
      SettingsGroup(
        children: [
          _EngineChoiceRow(
            key: const ValueKey('cloud-transcription-row'),
            icon: KapyIcons.micRounded,
            title: 'Cloud transcription',
            subtitle: signedIn
                ? 'Send audio for transcription and summaries'
                : 'Sign in for cloud transcription and summaries',
            selected: cloudSelected,
            enabled: signedIn && !_speechBusy,
            onSelect: cloudSelected
                ? null
                : () => unawaited(_selectCloudTranscription(prefs)),
            action: cloudSelected
                ? SettingsRowButton(
                    key: const ValueKey('voice-transcription-off'),
                    label: 'Turn off',
                    onPressed: _speechBusy
                        ? null
                        : () => unawaited(_turnOffCloudTranscription()),
                  )
                : null,
          ),
          _cloudTranscriptionModelRow(prefs),
          _localTranscriptionRow(prefs),
        ],
      ),
      const SettingsNote(
        'The model choice applies only to cloud transcription. All three '
        'cloud models support multilingual audio. Local transcription is '
        'free, unlimited, and stays on this device.',
      ),
      if (_speechError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            _speechError!,
            style: TextStyle(
              fontSize: AppTypeScale.small,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 18),
      const SettingsLabel('RECORDINGS & SUMMARIES'),
      SettingsGroup(
        children: [
          SettingsToggleRow(
            key: const ValueKey('voice-summary-toggle'),
            icon: KapyIcons.subjectRounded,
            title: 'Make a summary',
            subtitle: !signedIn && prefs.summaryEngine == SummaryEngine.cloud
                ? 'Choose local summaries or sign in for cloud'
                : 'Add a title and key points after transcription',
            value: prefs.summarize,
            onChanged: (value) => setState(() => prefs.summarize = value),
          ),
          SettingsNavigationRow(
            key: const ValueKey('voice-language-row'),
            icon: KapyIcons.translateRounded,
            title: 'Language',
            subtitle:
                _speechLanguages[prefs.language] ?? 'Detect automatically',
            onTap: () => unawaited(_pickSpeechLanguage(prefs)),
          ),
          _localSummaryRow(prefs),
        ],
      ),
      const SettingsNote(
        'Summaries run automatically with the selected engine. Local '
        'summaries stay on this device.',
      ),
      if (_localModelCredits.isNotEmpty)
        _ModelCredits(models: _localModelCredits),
    ];
  }

  Widget _cloudTranscriptionModelRow(VoicePrefs prefs) {
    final selected = prefs.cloudTranscriptionModel;
    return SettingsRow(
      key: const ValueKey('voice-transcription-model-row'),
      icon: KapyIcons.magicOutlined,
      title: 'Transcription model',
      subtitle: '${selected.title} · ${selected.route}',
      trailing: PopupMenuButton<CloudTranscriptionModel>(
        key: const ValueKey('voice-transcription-model-dropdown'),
        tooltip: 'Choose transcription model',
        initialValue: selected,
        onSelected: (model) => setState(() {
          prefs.cloudTranscriptionModel = model;
        }),
        itemBuilder: (context) => [
          for (final model in CloudTranscriptionModel.values)
            PopupMenuItem<CloudTranscriptionModel>(
              key: ValueKey('voice-transcription-model-${model.name}'),
              value: model,
              height: 58,
              child: Row(
                children: [
                  KapyIcon(
                    model == selected
                        ? KapyIcons.radioCheckedRounded
                        : KapyIcons.radioUncheckedRounded,
                    size: 17,
                    color: model == selected
                        ? Theme.of(context).colorScheme.primary
                        : context.palette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(model.title),
                        const SizedBox(height: 2),
                        Text(
                          model.route,
                          style: TextStyle(
                            fontSize: AppTypeScale.caption,
                            color: context.palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
        icon: KapyIcon(
          KapyIcons.chevronDownRounded,
          size: SettingsMetrics.chevronSize,
          color: context.palette.textTertiary,
        ),
      ),
    );
  }

  Widget _localTranscriptionRow(VoicePrefs prefs) {
    final store = widget.localModels;
    final speech = store?.catalogue.whereType<LocalSpeechModel>().firstOrNull;
    return _LocalEngineRow(
      key: const ValueKey('local-transcription-row'),
      icon: KapyIcons.audioWaveRounded,
      title: 'Local transcription',
      store: store,
      model: speech,
      // Ready without a download of ours: the platform's own recogniser,
      // which is the ordinary case on Apple.
      builtIn: _deviceTranscriptState == TranscriberReadiness.ready,
      builtInNote: 'Built in and processed only on this device',
      unavailableNote: switch (_deviceTranscriptState) {
        TranscriberReadiness.preparing => 'Preparing language support',
        TranscriberReadiness.needsSystemFeature =>
          'Allow Speech Recognition in system settings',
        _ => 'Unavailable on this device',
      },
      blockedReason: speech == null ? null : _downloadBlockedReason(speech),
      on: prefs.transcriptEngine == TranscriptEngine.device,
      exclusive: true,
      onChanged: (value) {
        if (!value || prefs.transcriptEngine == TranscriptEngine.device) {
          return;
        }
        setState(() => prefs.transcriptEngine = TranscriptEngine.device);
        widget.onTranscriptionReady?.call();
      },
      onDownload: speech == null || store == null
          ? null
          : () => unawaited(_startDownload(store, speech)),
    );
  }

  /// The local alternative sits with the recording choices it affects, so a
  /// user can decide how a recording is handled without jumping sections.
  Widget _localSummaryRow(VoicePrefs prefs) {
    final store = widget.localModels;
    final summary = store?.catalogue.whereType<LocalSummaryModel>().firstOrNull;
    return _LocalEngineRow(
      key: const ValueKey('local-summary-row'),
      icon: KapyIcons.magicOutlined,
      title: 'Local summaries',
      store: store,
      model: summary,
      builtIn: _deviceSummaryState == SummarizerReadiness.ready,
      builtInNote: 'Processed here with Apple Intelligence',
      unavailableNote: switch (_deviceSummaryState) {
        SummarizerReadiness.needsSystemFeature =>
          'Turn on Apple Intelligence in System Settings',
        SummarizerReadiness.preparing =>
          'Apple Intelligence is still preparing',
        _ => 'Unavailable on this device',
      },
      blockedReason: summary == null ? null : _downloadBlockedReason(summary),
      on: prefs.summaryEngine == SummaryEngine.device,
      onChanged: (value) => setState(() {
        prefs.summaryEngine = value
            ? SummaryEngine.device
            : SummaryEngine.cloud;
      }),
      onDownload: summary == null || store == null
          ? null
          : () => unawaited(_startDownload(store, summary)),
    );
  }

  List<DownloadableModel> get _localModelCredits {
    final catalogue = widget.localModels?.catalogue;
    if (catalogue == null) return const [];
    return <DownloadableModel>[
      ?catalogue.whereType<LocalSpeechModel>().firstOrNull,
      ?catalogue.whereType<LocalSummaryModel>().firstOrNull,
    ];
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

  /// Asks the device recogniser whether it could work here.
  ///
  /// Every time this opens rather than once at launch, for the same reason as
  /// the summariser: a model can be downloaded, and a locale fetched, while
  /// the app is running.
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
    unawaited(store.download(model));
  }

  void _openSheetSection(SettingsSection section) =>
      setState(() => _sheetSection = section);

  /// Back to the list of categories, whether that came from the button, the
  /// system back gesture, or a swipe from the edge.
  void _closeSheetSection() {
    if (_sheetSection != null) setState(() => _sheetSection = null);
  }

  void _showSection(SettingsSection section) {
    if (section == _section) return;
    setState(() => _section = section);
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

  void _openFirstResult() {
    final results = searchSettings(_searchIndex(), _query);
    if (results.isNotEmpty) _openResult(results.first);
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
  /// test's `find.byKey` does, done once, on a tap.
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
    onSubmitted: widget.asSheet ? _searchFocus.unfocus : _openFirstResult,
  );

  Widget _searchResults() => SettingsSearchResults<SettingsSection>(
    key: const ValueKey('settings-search-results'),
    query: _query,
    results: searchSettings(_searchIndex(), _query),
    onOpen: _openResult,
  );

  Future<void> _recordShortcut(ShortcutAction action) async {
    final current = widget.shortcuts.bindingFor(action);
    final choice = await showDialog<ShortcutChoice>(
      context: context,
      builder: (context) =>
          _ShortcutRecorderDialog(action: action, current: current),
    );
    // Nothing came back at all: the dialog was dismissed.
    if (!mounted || choice == null) return;
    final candidate = choice.binding;
    // Or it came back with what the action already had.
    if (candidate == current) return;

    // Nothing can collide with a shortcut that is being taken away.
    if (candidate != null) {
      final conflict = widget.shortcuts.conflictFor(action, candidate);
      if (conflict != null) {
        setState(() {
          _shortcutError =
              '${candidate.displayLabel} is already used for ${conflict.label.toLowerCase()}.';
        });
        return;
      }
    }

    // Told to the OS first either way: a system-wide chord has to be handed
    // back before the preference forgets which one it was.
    if (action.isGlobal && widget.desktopIntegration != null) {
      final progress = Toast.showProgress(context, 'Updating shortcut…');
      final error = await widget.desktopIntegration!.trySystemShortcut(
        action,
        candidate,
      );
      if (!mounted) {
        progress.dismiss();
        return;
      }
      if (error != null) {
        setState(() => _shortcutError = error);
        progress.error(error);
        return;
      }
      progress.success('Shortcut updated');
    }

    if (candidate == null) {
      widget.shortcuts.clear(action);
    } else {
      widget.shortcuts.update(action, candidate);
    }
    if (mounted) setState(() => _shortcutError = null);
  }

  Future<void> _restoreShortcutDefaults() async {
    final integration = widget.desktopIntegration;
    final progress = integration == null
        ? null
        : Toast.showProgress(context, 'Restoring shortcuts…');
    if (integration != null) {
      final restored = <ShortcutAction>[];
      for (final action in ShortcutAction.values.where(
        (action) => action.isGlobal,
      )) {
        final error = await integration.trySystemShortcut(
          action,
          ShortcutPrefs.defaultFor(action),
        );
        if (error == null) {
          restored.add(action);
          continue;
        }
        // Nothing is restored unless everything is. Whatever went back before
        // the refusal has to come forward again, or this pane would name one
        // shortcut while the system answered another.
        for (final done in restored) {
          await integration.trySystemShortcut(
            done,
            widget.shortcuts.bindingFor(done),
          );
        }
        if (!mounted) {
          progress?.dismiss();
          return;
        }
        setState(() => _shortcutError = error);
        progress?.error(error);
        return;
      }
    }
    widget.shortcuts.resetAll();
    if (mounted) {
      setState(() => _shortcutError = null);
      if (progress == null) {
        Toast.show(context, 'Shortcuts restored');
      } else {
        progress.success('Shortcuts restored');
      }
    } else {
      progress?.dismiss();
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

  String get _defaultNoteLabel {
    final id = widget.layoutPrefs.defaultNoteId;
    final note = id == null ? null : widget.notes.byId(id);
    return note == null || note.isArchived || note.isHidden
        ? 'Last opened note'
        : note.title;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.layoutPrefs,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.shortcuts,
        builder: (context, _) =>
            widget.asSheet ? _buildSheet(context) : _buildDialog(context),
      ),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final available = media.width - 80;
    final paned = AppPlatform.isWindows || available >= _railBreakpoint;
    final width = math.min(paned ? _panedWidth : _stackedWidth, available);
    // A fixed height keeps the dialog from resizing under the pointer
    // as sections of different lengths are selected.
    final height = (media.height - 140).clamp(260.0, 520.0);

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: EdgeInsets.fromLTRB(paned ? 18 : 22, 18, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
      title: const Text(
        'Settings',
        style: TextStyle(fontWeight: _settingsSemiboldWeight),
      ),
      content: SizedBox(
        key: const ValueKey('settings-dialog-content'),
        width: width,
        height: height,
        child: paned ? _buildPaned(context) : _buildStacked(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Done',
            style: TextStyle(fontWeight: _settingsMediumWeight),
          ),
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
            border: Border.all(color: palette.controlBorder, width: 0.5),
          ),
          child: ClipRRect(
            borderRadius: _sheetCorners,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetGrabber(),
                Expanded(
                  // The pages below are their own stack, so a back gesture steps
                  // out of a category before it closes the sheet. The hero
                  // controller above belongs to the app's navigator and cannot
                  // be shared with this one.
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
                            // Nothing here is worth keeping alive under a pane,
                            // and one live page at a time keeps 'Done' meaning
                            // one button.
                            maintainState: false,
                            child: _SheetPage(
                              title: 'Settings',
                              bottomInset: keyboard > 0
                                  ? 0
                                  : media.padding.bottom,
                              children: [
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
                                bottomInset: keyboard > 0
                                    ? 0
                                    : media.padding.bottom,
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

  /// The search sits over the rail, where a list of categories is looked
  /// down for something and a field that finds it saves the looking. Its
  /// results take the pane's place, so the rail stays a way back out.
  Widget _buildPaned(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _railWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Settings opened on purpose, sent to one pane, leaves the
              // keyboard to whatever that pane wanted it for.
              _searchField(autofocus: widget.section == null),
              const SizedBox(height: 8),
              Expanded(
                child: _SettingsRail(
                  sections: _sections,
                  // No category is the one on show while results are.
                  selected: _searching ? null : _section,
                  onSelect: _selectFromRail,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _ScrollingPane(
            key: _paneKey,
            controller: _scrollController,
            flashTarget: _flashTarget,
            flash: _flash,
            children: _searching ? [_searchResults()] : _paneFor(_section),
          ),
        ),
      ],
    );
  }

  Widget _buildStacked(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(autofocus: widget.section == null),
        const SizedBox(height: 12),
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
                        const SizedBox(height: 20),
                      ..._paneFor(section),
                    ],
                  ],
          ),
        ),
      ],
    );
  }

  List<Widget> _paneFor(SettingsSection section) => switch (section) {
    SettingsSection.general => _generalPane(),
    SettingsSection.sync => [
      SyncPane(account: widget.account!, includeDeleteAccount: false),
      // The gap between two panes, borrowed from the stacked layout: the
      // panel titles do the separating, and a rule between them would only
      // put back the boundary this section exists to remove.
      const SizedBox(height: 20),
      SharingPane(account: widget.account!),
      const SizedBox(height: 20),
      DeleteAccountSettings(account: widget.account!),
    ],
    SettingsSection.plan => [_PlanUsagePane(account: widget.account!)],
    SettingsSection.voice => _voicePane(),
    SettingsSection.appearance => _appearancePane(),
    SettingsSection.shortcuts => _shortcutsPane(),
    SettingsSection.updates => _updatesPane(),
  };

  /// Everything a search can reach, written beside the panes that draw it.
  ///
  /// An entry finds its row by the key the row already carries, and names it
  /// the way the row does, plus the other words people reach for — nobody
  /// searching for "dark mode" should need to know it is filed under Theme.
  /// Entries follow the same conditions as their rows, so a search never
  /// offers what this build or this account does not have. A test opens
  /// every entry and checks its row is there, so a row renamed or removed
  /// without its entry fails there rather than in somebody's hands.
  List<SettingsSearchEntry<SettingsSection>> _searchIndex() {
    SettingsSearchEntry<SettingsSection> entry(
      SettingsSection section,
      String title, {
      required KapyIconData icon,
      String? target,
      String? group,
      List<String> keywords = const [],
      String? description,
    }) => SettingsSearchEntry(
      section: section,
      sectionLabel: section.label,
      title: title,
      icon: icon,
      target: target,
      group: group,
      keywords: keywords,
      description: description,
    );

    const general = SettingsSection.general;
    const plan = SettingsSection.plan;
    const appearance = SettingsSection.appearance;
    const voice = SettingsSection.voice;
    const shortcuts = SettingsSection.shortcuts;
    const updates = SettingsSection.updates;
    final prefs = widget.layoutPrefs;
    final account = widget.account;

    final entries = [
      // The categories themselves, for somebody who types the name of one.
      for (final section in _sections)
        entry(
          section,
          section.label,
          icon: section.icon,
          description: section.summary,
        ),

      entry(
        general,
        'Note opened at launch',
        group: 'Opening',
        icon: KapyIcons.noteOutlined,
        target: 'default-note-setting',
        keywords: ['default note', 'startup', 'start'],
      ),
      entry(
        general,
        'Ready to type on open',
        group: 'Opening',
        icon: KapyIcons.keyboardOutlined,
        target: 'ready-to-type-on-open-toggle',
        keywords: ['cursor', 'caret', 'focus', 'keyboard', 'resume'],
      ),
      entry(
        general,
        'Daily separators',
        group: 'Writing',
        icon: KapyIcons.calendarOutlined,
        target: 'daily-separators-toggle',
        keywords: ['date', 'day', 'dated line', 'divider', 'session'],
      ),
      entry(
        general,
        'Time zone',
        group: 'Writing',
        icon: KapyIcons.publicRounded,
        target: 'time-zone-setting',
        keywords: ['timezone', 'clock', 'utc', 'gmt', 'offset'],
      ),
      entry(
        general,
        'Check spelling',
        group: 'Writing',
        icon: KapyIcons.spellcheckRounded,
        target: 'spell-check-toggle',
        keywords: ['spellcheck', 'spell check', 'typos', 'dictionary'],
        description: 'Underline possible misspellings',
      ),
      entry(
        general,
        'Markdown in notes',
        group: 'Writing',
        icon: KapyIcons.tagRounded,
        target: 'markdown-toggle',
        keywords: [
          'markdown',
          'md',
          'commonmark',
          'syntax',
          'headings',
          'bold',
          'code',
          'formatting',
          'lists',
          'checkbox',
          'tables',
        ],
        description: 'Type # for a heading, - for a list, [] for a checkbox',
      ),
      entry(
        general,
        'Export all notes',
        group: 'Your notes',
        icon: KapyIcons.shareRounded,
        target: 'export-notes',
        keywords: ['backup', 'download', 'save', 'zip', 'markdown'],
      ),
      entry(
        general,
        'Import from an export',
        group: 'Your notes',
        icon: KapyIcons.downloadRounded,
        target: 'import-notes',
        keywords: ['restore', 'upload', 'zip', 'markdown'],
      ),
      if (AppPlatform.isDesktop) ...[
        entry(
          general,
          'Notes list',
          group: 'Window',
          icon: KapyIcons.viewSidebarOutlined,
          target: 'sidebar-toggle',
          keywords: ['sidebar', 'show', 'hide'],
        ),
        entry(
          general,
          'Hidden Notes',
          group: 'Window',
          icon: KapyIcons.lockRounded,
          target: 'hidden-notes-sidebar-toggle',
          keywords: [
            'hidden',
            'private',
            'protected',
            'sidebar',
            'show',
            'hide',
            'cmd h',
            'ctrl h',
          ],
          description: 'Show or hide the protected folder in the notes list',
        ),
        entry(
          general,
          AppPlatform.isMacOS
              ? 'Keep running in the menu bar'
              : 'Keep running in the tray',
          group: 'Window',
          icon: KapyIcons.closeFullscreenRounded,
          target: 'keep-running-toggle',
          keywords: ['background', 'menu bar', 'tray', 'close', 'quit'],
        ),
        if (widget.desktopIntegration?.loginItemSupported ?? false)
          entry(
            general,
            'Open at login',
            group: 'Window',
            icon: KapyIcons.loginRounded,
            target: 'login-item-toggle',
            keywords: ['startup', 'launch at login', 'login item', 'boot'],
          ),
        entry(
          general,
          'Panel widths',
          group: 'Window',
          icon: KapyIcons.viewColumnOutlined,
          target: 'panel-widths-setting',
          keywords: ['reset', 'resize', 'sidebar width', 'results column'],
        ),
      ],

      entry(
        appearance,
        'Theme',
        group: 'Theme',
        icon: KapyIcons.appearanceOutlined,
        target: 'theme-setting',
        keywords: ['dark mode', 'light mode', 'night', 'colour', 'color'],
      ),
      entry(
        appearance,
        'Paper',
        group: 'Theme',
        icon: KapyIcons.textureRounded,
        target: 'paper-setting',
        keywords: ['ruled', 'lined', 'notepad', 'plain', 'grain', 'texture'],
      ),
      entry(
        appearance,
        'App text size',
        group: 'Theme',
        icon: KapyIcons.textFieldsRounded,
        target: 'app-text-size-setting',
        keywords: ['font size', 'interface size', 'ui scale', 'zoom', 'larger'],
        description: prefs.appTextSize.description,
      ),
      if (LayoutPrefs.supportsTransparency) ...[
        entry(
          appearance,
          'Transparency',
          group: 'Theme',
          icon: KapyIcons.blurRounded,
          target: 'transparency-toggle',
          keywords: ['blur', 'glass', 'translucent', 'see-through'],
        ),
        if (prefs.transparencyEnabled)
          entry(
            appearance,
            'Transparency amount',
            group: 'Theme',
            icon: KapyIcons.opacityRounded,
            target: 'transparency-amount',
            keywords: ['blur', 'opacity'],
          ),
      ],
      for (final font in WritingFont.values)
        entry(
          appearance,
          font.label,
          group: 'Writing font',
          icon: KapyIcons.textFieldsRounded,
          target: 'writing-font-${font.name}',
          keywords: ['font', 'typeface', 'writing font'],
          description: font.description,
        ),
      for (final system in NumberSystem.values)
        entry(
          appearance,
          system.label,
          group: 'Numbers',
          icon: KapyIcons.numbersRounded,
          target: 'number-system-${system.name}',
          keywords: ['number format', 'digits', 'grouping', 'commas'],
          description: system.description,
        ),
      entry(
        appearance,
        'Exchange rates',
        group: 'Numbers',
        icon: KapyIcons.currencyExchangeRounded,
        target: 'rate-attribution',
        keywords: ['currency', 'conversion', 'forex'],
      ),

      if (account != null) ...[
        entry(
          plan,
          'Current plan',
          group: 'Plan',
          icon: KapyIcons.verifiedOutlined,
          target: 'plan-current',
          keywords: ['pro', 'free', 'subscription', 'account plan'],
        ),
        entry(
          plan,
          'Transcription minutes',
          group: 'Usage',
          icon: KapyIcons.scheduleRounded,
          target: 'plan-transcription-usage',
          keywords: ['voice', 'cloud', 'usage', 'quota', 'limit'],
        ),
        entry(
          plan,
          'AI summaries',
          group: 'Usage',
          icon: KapyIcons.magicOutlined,
          target: 'plan-summary-usage',
          keywords: ['rewrite', 'cloud', 'usage', 'quota', 'limit'],
        ),
        entry(
          plan,
          'Storage',
          group: 'Usage',
          icon: KapyIcons.backupRestoreRounded,
          target: 'plan-storage-usage',
          keywords: ['space', 'attachments', 'usage', 'quota', 'limit'],
        ),
      ],

      if (widget.voicePrefs != null) ...[
        entry(
          voice,
          'Cloud transcription',
          group: 'Transcription',
          icon: KapyIcons.micRounded,
          target: 'cloud-transcription-row',
          keywords: ['transcribe', 'transcript', 'speech to text', 'dictation'],
        ),
        entry(
          voice,
          'Transcription model',
          group: 'Transcription',
          icon: KapyIcons.magicOutlined,
          target: 'voice-transcription-model-row',
          keywords: [
            'soniox',
            'stt-async-v5',
            'microsoft',
            'mai transcribe',
            'nvidia',
            'nemotron',
            'openrouter',
          ],
          description: widget.voicePrefs!.cloudTranscriptionModel.title,
        ),
        entry(
          voice,
          'Local transcription',
          group: 'Transcription',
          icon: KapyIcons.audioWaveRounded,
          target: 'local-transcription-row',
          keywords: ['offline', 'local', 'private', 'model', 'download'],
        ),
        entry(
          voice,
          'Make a summary',
          group: 'Recordings & summaries',
          icon: KapyIcons.subjectRounded,
          target: 'voice-summary-toggle',
          keywords: ['summarise', 'summarize', 'recording', 'voice note'],
        ),
        entry(
          voice,
          'Language',
          group: 'Recordings & summaries',
          icon: KapyIcons.translateRounded,
          target: 'voice-language-row',
          keywords: ['speech', 'transcription language', 'detect'],
        ),
        entry(
          voice,
          'Local summaries',
          group: 'Recordings & summaries',
          icon: KapyIcons.magicOutlined,
          target: 'local-summary-row',
          keywords: ['offline', 'local', 'private', 'apple intelligence'],
        ),
      ],

      for (final action in ShortcutAction.values)
        entry(
          shortcuts,
          action.label,
          group: switch (action.group) {
            null => 'System-wide',
            final group => group.title,
          },
          icon: KapyIcons.keyboardOutlined,
          target: 'shortcut-row-${action.name}',
          keywords: [
            'shortcut',
            'hotkey',
            'keyboard',
            ?widget.shortcuts.bindingFor(action)?.displayLabel,
          ],
          description: action.description,
        ),
      entry(
        shortcuts,
        'Restore shortcut defaults',
        icon: KapyIcons.backupRestoreRounded,
        target: 'restore-shortcut-defaults',
        keywords: ['reset', 'shortcuts'],
      ),

      entry(
        updates,
        'Version',
        icon: KapyIcons.infoOutlined,
        target: 'app-version',
        keywords: ['build', 'about', 'release'],
      ),
      entry(
        updates,
        'Check for updates',
        icon: KapyIcons.systemUpdateRounded,
        target: 'update-row',
        keywords: ['update', 'upgrade', 'new version', 'release notes'],
      ),
      entry(
        updates,
        'Download updates automatically',
        icon: KapyIcons.downloadRounded,
        target: 'update-auto-download',
        keywords: ['auto update', 'automatic', 'background', 'restart'],
      ),
      entry(
        updates,
        'Release notes',
        icon: KapyIcons.historyRounded,
        target: 'changelog',
        keywords: ['changelog', "what's new", 'versions', 'history', 'changes'],
      ),

      if (account != null) ..._accountSearchEntries(account, entry),
    ];
    return [
      for (final candidate in entries)
        if (_isAvailable(candidate.section)) candidate,
    ];
  }

  /// The account's rows change with where the account stands, so its
  /// entries do too: a signed-out account has a form, not a Sign out button.
  List<SettingsSearchEntry<SettingsSection>> _accountSearchEntries(
    Account account,
    SettingsSearchEntry<SettingsSection> Function(
      SettingsSection section,
      String title, {
      required KapyIconData icon,
      String? target,
      String? group,
      List<String> keywords,
      String? description,
    })
    entry,
  ) {
    const sync = SettingsSection.sync;
    final sharing = account.sharing;
    return switch (account.state) {
      AccountState.ready => [
        entry(
          sync,
          'Your name and picture',
          group: 'Profile',
          icon: KapyIcons.accountCircleOutlined,
          target: 'profile-card',
          keywords: ['profile', 'display name', 'photo', 'avatar'],
        ),
        entry(
          sync,
          'Sync',
          group: 'Account',
          icon: KapyIcons.syncRounded,
          target: 'sync-status',
          keywords: ['sync now', 'status', 'devices', 'cloud'],
        ),
        entry(
          sync,
          'Sign out',
          group: 'Account',
          icon: KapyIcons.logoutRounded,
          target: 'sign-out-row',
          keywords: ['log out', 'logout', 'account', 'email'],
        ),
        entry(
          sync,
          'Delete account',
          group: 'Account',
          icon: KapyIcons.deleteForeverOutlined,
          target: 'delete-account',
          keywords: ['remove account', 'close account', 'erase'],
        ),
        if (sharing != null) ...[
          entry(
            sync,
            'Shared spaces',
            group: 'Sharing',
            icon: KapyIcons.peopleOutlined,
            target: 'sharing-group',
            keywords: ['sharing', 'share', 'collaborate', 'invitations'],
          ),
          entry(
            sync,
            'Join with an invitation',
            group: 'Sharing',
            icon: KapyIcons.linkRounded,
            target: 'join-code',
            keywords: ['invite', 'invitation', 'link', 'code', 'join'],
          ),
          if (sharing.blocks.isNotEmpty)
            entry(
              sync,
              'Blocked people',
              group: 'Blocked',
              icon: KapyIcons.blockedRounded,
              target: 'block-${sharing.blocks.first.email}',
              keywords: ['unblock', 'block'],
            ),
        ],
      ],
      // The form that signs in is the whole pane, so the pane is the place.
      AccountState.signedOut => [
        entry(
          sync,
          'Sign in',
          icon: KapyIcons.loginRounded,
          keywords: ['log in', 'login', 'create account', 'sign up', 'sync'],
        ),
      ],
      _ => [
        entry(
          sync,
          'Account',
          icon: KapyIcons.accountCircleOutlined,
          keywords: ['passphrase', 'unlock', 'profile', 'sync'],
        ),
      ],
    };
  }

  /// Grouped by the question somebody comes here with: what happens when a
  /// note opens, how writing behaves, what can be done with the notes, and —
  /// on a desktop — how the window behaves.
  ///
  /// It used to be one "Notes" card holding five switches that had little to
  /// do with each other, a time zone that went by its value instead of its
  /// name, and a button loose under the last card. Now every row says what it
  /// is, next to the rows it is read with.
  List<Widget> _generalPane() => [
    const SettingsLabel('OPENING'),
    SettingsGroup(
      children: [
        SettingsNavigationRow(
          key: const ValueKey('default-note-setting'),
          icon: KapyIcons.noteOutlined,
          title: 'Note opened at launch',
          subtitle: _defaultNoteLabel,
          onTap: _chooseDefaultNote,
        ),
        SettingsToggleRow(
          key: const ValueKey('ready-to-type-on-open-toggle'),
          icon: KapyIcons.keyboardOutlined,
          title: 'Ready to type on open',
          subtitle: 'Restore your cursor or start a new dated line',
          value: widget.layoutPrefs.readyToTypeOnOpen,
          onChanged: (value) => widget.layoutPrefs.readyToTypeOnOpen = value,
        ),
      ],
    ),
    const SizedBox(height: 18),
    // The time zone sits under the separators because they are what it
    // dates: a row further down, under a heading of its own, read as a
    // setting for the whole computer.
    const SettingsLabel('WRITING'),
    SettingsGroup(
      children: [
        SettingsToggleRow(
          key: const ValueKey('daily-separators-toggle'),
          icon: KapyIcons.calendarOutlined,
          title: 'Daily separators',
          subtitle: 'Add a dated line when a new day begins',
          value: widget.layoutPrefs.dailySeparatorsEnabled,
          onChanged: (value) =>
              widget.layoutPrefs.dailySeparatorsEnabled = value,
        ),
        SettingsNavigationRow(
          key: const ValueKey('time-zone-setting'),
          icon: KapyIcons.publicRounded,
          title: 'Time zone',
          subtitle:
              '${AppTimeZones.displayName(widget.layoutPrefs.timeZoneId)} · '
              '${AppTimeZones.offsetLabel(widget.layoutPrefs.timeZoneId)}',
          onTap: _chooseTimeZone,
        ),
        SettingsToggleRow(
          key: const ValueKey('spell-check-toggle'),
          icon: KapyIcons.spellcheckRounded,
          title: 'Check spelling',
          subtitle: 'Underline possible misspellings',
          value: widget.layoutPrefs.spellCheckEnabled,
          onChanged: (value) => widget.layoutPrefs.spellCheckEnabled = value,
        ),
        // Beside spelling because both are about how the words are read as
        // they are typed. Nothing in a note is converted either way.
        SettingsToggleRow(
          key: const ValueKey('markdown-toggle'),
          icon: KapyIcons.tagRounded,
          title: 'Markdown in notes',
          subtitle: 'Use # headings, - lists, and [] checkboxes',
          value: widget.layoutPrefs.markdownEnabled,
          onChanged: (value) => widget.layoutPrefs.markdownEnabled = value,
        ),
      ],
    ),
    const SizedBox(height: 18),
    const SettingsLabel('YOUR NOTES'),
    SettingsGroup(
      children: [
        SettingsNavigationRow(
          key: const ValueKey('export-notes'),
          icon: KapyIcons.shareRounded,
          title: 'Export all notes',
          // The one-line warning the plaintext deserves, at the moment it
          // matters. Not called a backup, because nothing here runs on its own.
          subtitle: 'One Markdown .zip · Unencrypted after export',
          onTap: () => unawaited(_exportNotes()),
        ),
        SettingsNavigationRow(
          key: const ValueKey('import-notes'),
          icon: KapyIcons.downloadRounded,
          title: 'Import from an export',
          subtitle: 'Preview changes before importing a .zip',
          onTap: () => unawaited(runImport(context, widget.notes)),
        ),
      ],
    ),
    if (AppPlatform.isDesktop) ...[
      const SizedBox(height: 18),
      // Everything about the window as a thing on the desktop: what is in it,
      // whether it outlives being closed, and the one reset. The reset is a
      // row like the others rather than a button under the card, which read
      // as belonging to the whole pane.
      const SettingsLabel('WINDOW'),
      SettingsGroup(
        children: [
          SettingsToggleRow(
            key: const ValueKey('sidebar-toggle'),
            icon: KapyIcons.viewSidebarOutlined,
            // Named the way the shortcut that toggles it is named.
            title: 'Notes list',
            subtitle: 'Show the notes list beside your editor',
            value: widget.layoutPrefs.sidebarVisible,
            onChanged: (_) => widget.layoutPrefs.toggleSidebar(),
          ),
          SettingsToggleRow(
            key: const ValueKey('hidden-notes-sidebar-toggle'),
            icon: KapyIcons.lockRounded,
            title: 'Hidden Notes',
            subtitle:
                'Show the protected folder · '
                '${widget.shortcuts.bindingFor(ShortcutAction.toggleHiddenFolder)?.displayLabel ?? 'Settings only'}',
            value: widget.layoutPrefs.hiddenFolderVisible,
            onChanged: (value) =>
                widget.layoutPrefs.hiddenFolderVisible = value,
          ),
          SettingsToggleRow(
            key: const ValueKey('keep-running-toggle'),
            icon: KapyIcons.closeFullscreenRounded,
            title: AppPlatform.isMacOS
                ? 'Keep running in the menu bar'
                : 'Keep running in the tray',
            subtitle: AppPlatform.isMacOS
                ? 'Open, write, or quit from the menu bar'
                : 'Keep shortcuts active after closing the window',
            value: widget.layoutPrefs.keepRunningInBackground,
            onChanged: _setKeepRunning,
          ),
          // Absent rather than disabled where the OS has no mechanism this
          // app is allowed to use: macOS 12 predates the one the sandbox
          // permits.
          if (widget.desktopIntegration?.loginItemSupported ?? false)
            SettingsToggleRow(
              key: const ValueKey('login-item-toggle'),
              icon: KapyIcons.loginRounded,
              title: 'Open at login',
              subtitle: 'Launch when you sign in to this computer',
              value: widget.desktopIntegration!.loginItemEnabled,
              onChanged: (value) => unawaited(_setLoginItem(value)),
            ),
          SettingsRow(
            key: const ValueKey('panel-widths-setting'),
            icon: KapyIcons.viewColumnOutlined,
            title: 'Panel widths',
            subtitle: 'Reset the notes and results columns',
            trailing: SettingsRowButton(
              key: const ValueKey('reset-panel-widths'),
              label: 'Reset',
              onPressed: widget.layoutPrefs.resetPanelWidths,
            ),
          ),
        ],
      ),
      if (_loginItemError != null) ...[
        const SizedBox(height: 8),
        Text(
          _loginItemError!,
          key: const ValueKey('login-item-error'),
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    ],
  ];

  /// Everything that decides how the app looks and how what is in it reads.
  ///
  /// Numbers used to be a rail item of its own, holding one choice and an
  /// attribution line. How a thousand is punctuated is a display choice like
  /// any other here, and a category somebody visits once is a category that
  /// costs a click every time they are looking for something else.
  ///
  /// Three groups: the look of the window and the page, the font written in,
  /// and numbers. Theme and paper are a word each, so they are segmented rows
  /// rather than a radio list apiece — six rows and six sentences that told
  /// the reader nothing the word had not. The writing fonts keep their list,
  /// because each one is shown in itself, and that is the point of it.
  List<Widget> _appearancePane() => [
    const SettingsLabel('THEME'),
    SettingsGroup(
      children: [
        _SegmentedRow<AppearanceMode>(
          key: const ValueKey('theme-setting'),
          icon: KapyIcons.appearanceOutlined,
          title: 'Theme',
          subtitle: widget.layoutPrefs.appearance.description,
          options: AppearanceMode.values,
          selected: widget.layoutPrefs.appearance,
          labelFor: (mode) => switch (mode) {
            AppearanceMode.system => 'System',
            AppearanceMode.light => 'Light',
            AppearanceMode.dark => 'Dark',
          },
          keyFor: (mode) => ValueKey('appearance-${mode.name}'),
          onSelected: (mode) => widget.layoutPrefs.appearance = mode,
        ),
        _SegmentedRow<PaperStyle>(
          key: const ValueKey('paper-setting'),
          icon: KapyIcons.textureRounded,
          title: 'Paper',
          subtitle: widget.layoutPrefs.paperStyle.description,
          options: PaperStyle.values,
          selected: widget.layoutPrefs.paperStyle,
          labelFor: (paper) => paper.label,
          keyFor: (paper) => ValueKey('paper-style-${paper.name}'),
          onSelected: (paper) => widget.layoutPrefs.paperStyle = paper,
        ),
        _SegmentedRow<AppTextSize>(
          key: const ValueKey('app-text-size-setting'),
          icon: KapyIcons.textFieldsRounded,
          title: 'App text size',
          subtitle: widget.layoutPrefs.appTextSize.description,
          options: AppTextSize.values,
          selected: widget.layoutPrefs.appTextSize,
          labelFor: (size) => size.label,
          keyFor: (size) => ValueKey('app-text-size-${size.name}'),
          onSelected: (size) => widget.layoutPrefs.appTextSize = size,
        ),
        if (LayoutPrefs.supportsTransparency) ...[
          SettingsToggleRow(
            key: const ValueKey('transparency-toggle'),
            icon: KapyIcons.blurRounded,
            title: 'Transparency',
            subtitle: 'Blur the desktop behind your notes',
            value: widget.layoutPrefs.transparencyEnabled,
            onChanged: (value) =>
                widget.layoutPrefs.transparencyEnabled = value,
          ),
          if (widget.layoutPrefs.transparencyEnabled)
            _SliderRow(
              key: const ValueKey('transparency-amount'),
              icon: KapyIcons.opacityRounded,
              title: 'Amount',
              subtitle: 'Choose how much desktop shows through',
              minLabel: 'Subtle',
              maxLabel: 'Clear',
              value: widget.layoutPrefs.transparencyAmount,
              onChanged: (value) =>
                  widget.layoutPrefs.transparencyAmount = value,
            ),
        ],
      ],
    ),
    const SizedBox(height: 18),
    const SettingsLabel('WRITING FONT'),
    SettingsGroup(
      children: [
        for (final font in WritingFont.values)
          _ChoiceRow(
            key: ValueKey('writing-font-${font.name}'),
            title: font.label,
            subtitle: font.description,
            trailing: font.preview,
            trailingStyle: TextStyle(
              fontFamily: font.fontFamily,
              fontFamilyFallback: font.fontFamilyFallback,
              fontVariations: font.fontVariations,
              fontSize: font == WritingFont.handwritten ? 16 : 12.5,
              height: 1,
              letterSpacing: 0,
            ),
            trailingSpans: font == WritingFont.mixed
                ? [
                    TextSpan(
                      text: 'Ideas',
                      style: TextStyle(
                        fontFamily: WritingFont.handwritten.fontFamily,
                        fontFamilyFallback:
                            WritingFont.handwritten.fontFamilyFallback,
                        fontVariations: WritingFont.handwritten.fontVariations,
                        fontSize: 16,
                      ),
                    ),
                    const TextSpan(text: ' 42'),
                  ]
                : null,
            selected: widget.layoutPrefs.writingFont == font,
            onTap: () => widget.layoutPrefs.writingFont = font,
          ),
      ],
    ),
    const SettingsNote(
      'Applies only to notes. Menus and controls use the system font.',
    ),
    const SizedBox(height: 18),
    // How numbers are written and where the currency rates behind them come
    // from, together: the credit used to be a heading of its own over one row,
    // which read as one more thing to set.
    const SettingsLabel('NUMBERS'),
    SettingsGroup(
      children: [
        for (final system in NumberSystem.values)
          _ChoiceRow(
            key: ValueKey('number-system-${system.name}'),
            title: system.label,
            subtitle: system.description,
            trailing: widget.layoutPrefs.exampleFor(system),
            selected: widget.layoutPrefs.numberSystem == system,
            onTap: () => widget.layoutPrefs.numberSystem = system,
          ),
        _RateAttributionRow(rates: widget.rates),
      ],
    ),
  ];

  /// The system-wide pair leads: they are the ones that reach the app from
  /// outside it, they are the ones another app can refuse, and they are what
  /// people come here to change. Then the in-app keys, grouped by what they
  /// act on — the list of notes, the window, what goes into a note and how it
  /// is formatted — where most of them used to be one long card of eleven.
  ///
  /// Only the system-wide pair keeps a line of explanation. An in-app row
  /// that says "New note" over "Create and focus a blank note" says it twice.
  List<Widget> _shortcutsPane() => [
    // The one thing to know before anything here is useful, so it leads.
    Padding(
      padding: const EdgeInsets.fromLTRB(3, 0, 3, 12),
      child: Text(
        'Click a shortcut, then press the keys you want instead.',
        style: TextStyle(
          fontSize: AppTypeScale.caption,
          height: AppPlatform.isWindows ? 1.4 : null,
          color: AppPlatform.isWindows
              ? context.palette.textSecondary
              : context.palette.textTertiary,
        ),
      ),
    ),
    const SettingsLabel('SYSTEM-WIDE'),
    SettingsGroup(
      children: [
        for (final action in ShortcutAction.values.where(
          (action) => action.isGlobal,
        ))
          _ShortcutRow(
            key: ValueKey('shortcut-row-${action.name}'),
            action: action,
            binding: widget.shortcuts.bindingFor(action),
            onPressed: () => _recordShortcut(action),
            detailed: true,
          ),
      ],
    ),
    for (final group in _ShortcutGroup.values) ...[
      const SizedBox(height: 18),
      SettingsLabel(group.label),
      SettingsGroup(
        children: [
          for (final action in ShortcutAction.values.where(
            (action) => action.group == group,
          ))
            _ShortcutRow(
              key: ValueKey('shortcut-row-${action.name}'),
              action: action,
              binding: widget.shortcuts.bindingFor(action),
              onPressed: () => _recordShortcut(action),
            ),
        ],
      ),
    ],
    if (_shortcutError != null) ...[
      const SizedBox(height: 8),
      Text(
        _shortcutError!,
        key: const ValueKey('shortcut-error'),
        style: TextStyle(
          fontSize: AppTypeScale.caption,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    ],
    const SizedBox(height: 12),
    _WideButton(
      key: const ValueKey('restore-shortcut-defaults'),
      onPressed: _restoreShortcutDefaults,
      icon: KapyIcons.backupRestoreRounded,
      label: 'Restore shortcut defaults',
    ),
  ];

  /// Everything the app knows about its own release, in the one place a
  /// person would look for it: which build is running, whether a newer one
  /// exists, how far its download has got, and the button for whatever comes
  /// next. One card: two headings over one row each said less than the rows
  /// did.
  List<Widget> _updatesPane() {
    final updates = widget.updates!;
    return [
      const SettingsLabel('KAPY NOTES'),
      ListenableBuilder(
        listenable: updates,
        builder: (context, _) => SettingsGroup(
          children: [
            _VersionRow(updates: updates),
            _UpdateRow(key: const ValueKey('update-row'), updates: updates),
            SettingsToggleRow(
              key: const ValueKey('update-auto-download'),
              icon: KapyIcons.downloadRounded,
              title: 'Download updates automatically',
              subtitle: 'So updating takes one click',
              value: updates.autoDownload,
              onChanged: (value) => updates.autoDownload = value,
            ),
          ],
        ),
      ),
      ListenableBuilder(
        listenable: updates,
        builder: (context, _) => SettingsNote(_updatesNote(updates)),
      ),
      const SizedBox(height: 18),
      // Keyed here rather than on the group below it: a search result scrolls
      // to what it lands on and lights it, and the group is taller than the
      // window by a dozen releases.
      ListenableBuilder(
        listenable: updates,
        builder: (context, _) => SettingsLabel(
          updates.hasUpdate ? "WHAT'S NEW" : 'RELEASE NOTES',
          key: const ValueKey('changelog'),
        ),
      ),
      _ChangelogGroup(updates: updates),
    ];
  }

  /// When the update actually happens, which is not the same on the two
  /// platforms: Sparkle installs a downloaded release whenever the app quits,
  /// and the Windows installer only runs when asked.
  static String _updatesNote(UpdateChecker updates) {
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
}

/// The in-app shortcuts, by what they act on.
enum _ShortcutGroup {
  notes('NOTES'),
  splitView('SPLIT VIEW'),
  window('WINDOW'),
  editor('EDITOR'),
  insert('INSERT'),
  formatting('FORMATTING');

  const _ShortcutGroup(this.label);

  final String label;

  /// The heading as a search result names it: in words, not small capitals.
  String get title => label[0] + label.substring(1).toLowerCase();
}

extension on ShortcutAction {
  /// Null for the system-wide pair, which have their own group at the top.
  /// Exhaustive on purpose: a new action does not compile until it has been
  /// given a place here.
  _ShortcutGroup? get group => switch (this) {
    ShortcutAction.openApp || ShortcutAction.newNoteAnywhere => null,
    ShortcutAction.newNote ||
    ShortcutAction.findNotes ||
    ShortcutAction.nextNote ||
    ShortcutAction.previousNote ||
    ShortcutAction.deleteNote => _ShortcutGroup.notes,
    ShortcutAction.splitEditor ||
    ShortcutAction.closePane ||
    ShortcutAction.focusFirstPane ||
    ShortcutAction.focusSecondPane ||
    ShortcutAction.focusThirdPane => _ShortcutGroup.splitView,
    ShortcutAction.toggleSidebar ||
    ShortcutAction.toggleHiddenFolder ||
    ShortcutAction.toggleResults ||
    ShortcutAction.toggleAlwaysOnTop ||
    ShortcutAction.openSettings => _ShortcutGroup.window,
    ShortcutAction.increaseEditorTextSize ||
    ShortcutAction.decreaseEditorTextSize ||
    ShortcutAction.resetEditorTextSize => _ShortcutGroup.editor,
    ShortcutAction.insertImage ||
    ShortcutAction.recordVoiceNote => _ShortcutGroup.insert,
    ShortcutAction.cycleTextStyle ||
    ShortcutAction.formatBold ||
    ShortcutAction.formatItalic ||
    ShortcutAction.formatBullets ||
    ShortcutAction.formatChecklist => _ShortcutGroup.formatting,
  };
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
          borderRadius: BorderRadius.circular(999),
        ),
        child: const SizedBox(width: 38, height: 4),
      ),
    ),
  );
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
                      fontWeight: _settingsSemiboldWeight,
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
                  child: const Text(
                    'Done',
                    style: TextStyle(fontWeight: _settingsMediumWeight),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 0.5, thickness: 0.5, color: palette.separator),
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

/// The account's plan and all server-metered usage in one place.
///
/// This listens to both the account and its billing controller. A sign-in made
/// from the neighbouring pane therefore replaces the free-plan preview with
/// the real account answer without settings needing to be reopened.
class _PlanUsagePane extends StatelessWidget {
  const _PlanUsagePane({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      final billing = account.billing;
      if (billing == null) {
        return _contents(context, null);
      }
      return ListenableBuilder(
        listenable: billing,
        builder: (context, _) => _contents(context, billing),
      );
    },
  );

  Widget _contents(BuildContext context, Billing? billing) {
    final signedIn = billing?.isSignedIn ?? account.user != null;
    final current = billing?.entitlements;
    final shown = current ?? (!signedIn ? Entitlements.freePreview : null);
    final initialLoad =
        signedIn && current == null && !(billing?.refreshFailed ?? false);
    final failed = signedIn && (billing?.refreshFailed ?? false);

    final planTitle = switch ((signedIn, current, billing?.trialRunning)) {
      (false, _, _) => 'Free plan',
      (true, _, true) => 'Pro trial',
      (true, final Entitlements value, _) =>
        value.isPro ? 'Pro plan' : 'Free plan',
      _ when failed => 'Plan unavailable',
      _ => 'Checking your plan',
    };
    final planSubtitle = switch ((signedIn, current, billing?.trialDaysLeft)) {
      (false, _, _) => 'Sign in to see your plan and usage',
      (true, _, 1) => 'Pro trial ends today',
      (true, _, final int days) => 'Pro trial ends in $days days',
      (true, final Entitlements value, _) =>
        value.isPro
            ? 'Lifetime access with expanded cloud limits'
            : 'Your plan and included cloud limits',
      _ when failed => 'Showing your last saved plan',
      _ => 'Loading plan and usage',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsLabel('PLAN'),
        SettingsGroup(
          children: [
            SettingsRow(
              key: const ValueKey('plan-current'),
              icon: KapyIcons.verifiedOutlined,
              title: planTitle,
              subtitle: planSubtitle,
              onTap: billing != null && billing.canPurchase
                  ? () => unawaited(showProSheet(context, billing: billing))
                  : null,
              trailing: signedIn && billing != null
                  ? billing.refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        : SettingsRowButton(
                            key: const ValueKey('plan-refresh'),
                            label: 'Refresh',
                            onPressed: () => unawaited(billing.refresh()),
                          )
                  : null,
            ),
          ],
        ),
        if (failed && current != null)
          const SettingsNote(
            'Showing last saved totals. Refresh when you are online.',
            icon: KapyIcons.warningRounded,
          ),
        const SizedBox(height: 18),
        SettingsLabel(signedIn ? 'USAGE' : 'FREE PLAN LIMITS'),
        SettingsGroup(
          children: [
            _PlanUsageRow(
              key: const ValueKey('plan-transcription-usage'),
              icon: KapyIcons.scheduleRounded,
              title: 'Transcription minutes',
              subtitle: shown == null
                  ? _unavailableLine(initialLoad)
                  : '${_minutes(shown.speechSecondsUsedThisMonth)} of '
                        '${_minutes(shown.speechSecondsPerMonth)} minutes used'
                        '${_creditLine(shown.speechCreditSeconds)}',
              progress: _progress(
                shown?.speechSecondsUsedThisMonth,
                shown?.speechSecondsPerMonth,
              ),
              loading: initialLoad,
            ),
            _PlanUsageRow(
              key: const ValueKey('plan-summary-usage'),
              icon: KapyIcons.magicOutlined,
              title: 'AI summaries',
              subtitle: shown == null
                  ? _unavailableLine(initialLoad)
                  : '${shown.summaryGenerationsUsedThisMonth} of '
                        '${shown.summaryGenerationsPerMonth} used',
              progress: _progress(
                shown?.summaryGenerationsUsedThisMonth,
                shown?.summaryGenerationsPerMonth,
              ),
              loading: initialLoad,
            ),
            _PlanUsageRow(
              key: const ValueKey('plan-storage-usage'),
              icon: KapyIcons.backupRestoreRounded,
              title: 'Storage',
              subtitle: shown == null
                  ? _unavailableLine(initialLoad)
                  : '${_bytes(shown.storageUsedBytes)} of '
                        '${_bytes(shown.storageBytes)} used',
              progress: _progress(shown?.storageUsedBytes, shown?.storageBytes),
              loading: initialLoad,
            ),
          ],
        ),
        SettingsNote(
          signedIn && shown != null
              ? 'Cloud limits reset ${_resetLine(shown.speechResetsAt)}. '
                    'Summaries and rewrites share one limit. Local processing '
                    'is unlimited.'
              : 'Sign in for cloud transcription and summaries. Local '
                    'processing is unlimited and stays on this device.',
        ),
      ],
    );
  }

  static String _unavailableLine(bool loading) =>
      loading ? 'Loading usage…' : 'Usage unavailable';

  static double _progress(int? used, int? limit) {
    if (used == null || limit == null || limit <= 0) return 0;
    return (used / limit).clamp(0.0, 1.0);
  }

  static String _minutes(int seconds) {
    final minutes = seconds / 60;
    return minutes == minutes.roundToDouble()
        ? '${minutes.round()}'
        : minutes.toStringAsFixed(1);
  }

  static String _creditLine(int seconds) =>
      seconds <= 0 ? '' : ' · ${_minutes(seconds)} extra';

  static String _bytes(int bytes) {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes < kb) return '$bytes B';
    if (bytes < mb) return '${_compact(bytes / kb)} KB';
    if (bytes < gb) return '${_compact(bytes / mb)} MB';
    return '${_compact(bytes / gb)} GB';
  }

  static String _compact(double value) {
    if (value >= 100 || value == value.roundToDouble()) {
      return '${value.round()}';
    }
    return value.toStringAsFixed(1);
  }

  static String _resetLine(DateTime? at) {
    if (at == null) return 'each month';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return 'on ${at.day} ${months[at.month - 1]}';
  }
}

/// One usage total, with the number and the proportion visible at a glance.
class _PlanUsageRow extends StatelessWidget {
  const _PlanUsageRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.loading,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final double progress;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: '$title, $subtitle',
      child: Padding(
        padding: SettingsMetrics.padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: SettingsMetrics.iconSlot,
              child: KapyIcon(
                icon,
                size: SettingsMetrics.iconSize,
                color: palette.textSecondary,
              ),
            ),
            SizedBox(width: SettingsMetrics.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsRowCopy(title: title, subtitle: subtitle),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value: loading ? null : progress,
                      backgroundColor: palette.separator,
                      color: accent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The list the sheet opens on: every category, what is inside it, and the
/// chevron that goes there.
class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.sections,
    required this.account,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final Account? account;
  final ValueChanged<SettingsSection> onSelect;

  /// Sync is the one category whose contents depend on where you already
  /// stand in it, so its line answers that before it is opened.
  String _summaryFor(SettingsSection section) {
    final account = this.account;
    if (section != SettingsSection.sync || account == null) {
      return section.summary;
    }
    return switch (account.state) {
      AccountState.restoring => 'Checking your account',
      AccountState.signedOut => 'Sign in to sync and share notes',
      AccountState.needsProfile => 'Choose the name people will see',
      AccountState.needsPassphrase => 'Save your passphrase to start syncing',
      AccountState.locked => 'Unlock to read these notes here',
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
    required this.onTap,
  });

  final SettingsSection section;
  final String summary;
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
                  borderRadius: BorderRadius.circular(9),
                ),
                child: KapyIcon(section.icon, size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SettingsRowCopy(title: section.label, subtitle: summary),
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
      radius: const Radius.circular(999),
      child: SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.only(right: 7),
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

/// The category list down the left of the wide dialog.
class _SettingsRail extends StatelessWidget {
  const _SettingsRail({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final List<SettingsSection> sections;

  /// Null while the pane is showing search results instead of a category.
  final SettingsSection? selected;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in sections)
              _RailItem(
                section: section,
                selected: section == selected,
                onTap: () => onSelect(section),
              ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: ValueKey('settings-section-${section.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? palette.selectedBackground : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                KapyIcon(
                  section.icon,
                  size: 15,
                  color: selected ? accent : palette.textTertiary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    section.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected
                          ? _settingsSemiboldWeight
                          : _settingsRegularWeight,
                      color: selected
                          ? palette.textPrimary
                          : palette.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A full-width, low-emphasis action at the foot of a pane.
class _WideButton extends StatelessWidget {
  const _WideButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final KapyIconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: KapyIcon(icon, size: 15),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: _settingsMediumWeight,
          ),
        ),
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: palette.controlBackground,
          foregroundColor: palette.textSecondary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

/// One of the two places that can transcribe a recording.
class _EngineChoiceRow extends StatelessWidget {
  const _EngineChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    this.action,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback? onSelect;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    final row = Padding(
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          SizedBox(
            width: SettingsMetrics.iconSlot,
            child: KapyIcon(
              icon,
              size: SettingsMetrics.iconSize,
              color: enabled
                  ? context.palette.textSecondary
                  : context.palette.textTertiary,
            ),
          ),
          SizedBox(width: SettingsMetrics.gap),
          Expanded(
            child: SettingsRowCopy(title: title, subtitle: subtitle),
          ),
          if (action != null) ...[const SizedBox(width: 10), action],
          const SizedBox(width: 10),
          _EngineChoiceIndicator(selected: selected, enabled: enabled),
        ],
      ),
    );
    final onSelect = enabled ? this.onSelect : null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: onSelect == null ? row : InkWell(onTap: onSelect, child: row),
    );
  }
}

class _EngineChoiceIndicator extends StatelessWidget {
  const _EngineChoiceIndicator({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => KapyIcon(
    selected ? KapyIcons.radioCheckedRounded : KapyIcons.radioUncheckedRounded,
    key: const ValueKey('engine-choice-indicator'),
    size: SettingsMetrics.iconSize,
    color: selected
        ? Theme.of(context).colorScheme.primary
        : context.palette.textTertiary.withValues(alpha: enabled ? 1 : 0.45),
  );
}

/// One local engine that could run on this machine: not here yet, on its way,
/// or ready to choose.
class _LocalEngineRow extends StatelessWidget {
  const _LocalEngineRow({
    super.key,
    required this.icon,
    required this.title,
    required this.store,
    required this.model,
    required this.builtIn,
    required this.builtInNote,
    required this.unavailableNote,
    required this.blockedReason,
    required this.on,
    required this.onChanged,
    required this.onDownload,
    this.exclusive = false,
  });

  final KapyIconData icon;
  final String title;

  /// Null in a build carrying nothing to download for this job — which on
  /// Apple is the ordinary case for speech, where the OS has a recogniser of
  /// its own and the 670 MB one is not offered.
  final LocalModelStore? store;
  final DownloadableModel? model;

  /// Whether the platform's own engine is ready and needs no download.
  final bool builtIn;
  final String builtInNote;

  /// What to say when neither is true, which is where the reason goes: a
  /// locale still coming down, a permission not given, or nothing at all.
  final String unavailableNote;

  /// Why this machine cannot take the download, if it cannot. Replaces the
  /// button, because a download that will be killed on load is not an offer.
  final String? blockedReason;

  /// The preference: whether this engine is the one that runs.
  final bool on;

  /// Transcription is a choice between cloud and local, so its ready state is
  /// a radio. Summary remains an independent on-device switch.
  final bool exclusive;

  /// Null where there is nothing to remember the answer in.
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final store = this.store;
    final model = this.model;
    // Without a model there is no download to watch, so nothing to listen to.
    if (store == null || model == null) return _shell(context, null);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => _shell(context, store.stateOf(model)),
    );
  }

  Widget _shell(BuildContext context, LocalModelState? state) {
    final here = state?.status == LocalModelStatus.ready;
    final usable = here || builtIn;
    final onChanged = this.onChanged;
    final shows = state != null && (state.isBusy || state.error != null);

    final row = Padding(
      padding: SettingsMetrics.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  icon,
                  size: SettingsMetrics.iconSize,
                  color: context.palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(
                  title: title,
                  subtitle: _subtitle(here: here),
                ),
              ),
              if (_trailing(here: here, usable: usable)
                  case final trailing?) ...[
                const SizedBox(width: 10),
                trailing,
              ],
            ],
          ),
          // The bar carries the numbers, so the subtitle goes on saying what
          // is being downloaded rather than repeating how far along it is.
          if (shows) ...[
            const SizedBox(height: 10),
            _ModelProgress(state: state),
          ],
        ],
      ),
    );

    if (!usable || onChanged == null) {
      final offersDownload =
          model != null && store != null && blockedReason == null;
      if (!exclusive || offersDownload) return row;
      return Semantics(
        button: true,
        enabled: false,
        selected: false,
        inMutuallyExclusiveGroup: true,
        child: row,
      );
    }
    if (exclusive) {
      return Semantics(
        button: true,
        enabled: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        child: InkWell(onTap: () => onChanged(true), child: row),
      );
    }
    return Semantics(
      toggled: on,
      button: true,
      child: InkWell(onTap: () => onChanged(!on), child: row),
    );
  }

  String _subtitle({required bool here}) {
    final model = this.model;
    if (here) return '${model!.name} · never leaves this device';
    if (builtIn) return builtInNote;
    if (model == null) return unavailableNote;
    if (blockedReason case final blocked?) return blocked;
    // What it is and what it costs. The cards that used to stand here also
    // carried four benchmark figures and a paragraph; a row that has to sit
    // beside a switch has room for the name and the download size, which are
    // the two anybody weighs.
    return '${model.name} · ${fileSize(model.bytes)}';
  }

  Widget? _trailing({required bool here, required bool usable}) {
    final model = this.model;
    final store = this.store;
    if (usable) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Six hundred megabytes deserves a way back that is not a menu.
          if (here && store != null) ...[
            SettingsRowButton(
              key: ValueKey('local-remove-${model!.id}'),
              label: 'Remove',
              onPressed: () => unawaited(store.remove(model)),
            ),
            const SizedBox(width: 8),
          ],
          ExcludeSemantics(
            child: exclusive
                ? _EngineChoiceIndicator(selected: on, enabled: true)
                : SettingsSwitch(value: on),
          ),
        ],
      );
    }
    if (model == null || store == null || blockedReason != null) {
      return exclusive
          ? const _EngineChoiceIndicator(selected: false, enabled: false)
          : null;
    }
    final state = store.stateOf(model);
    return switch (state.status) {
      LocalModelStatus.fetchingRuntime ||
      LocalModelStatus.downloading => SettingsRowButton(
        key: ValueKey('local-cancel-${model.id}'),
        label: 'Cancel',
        onPressed: () => store.cancel(model),
      ),
      // Nothing to press while the hashes are checked: it takes seconds, and
      // stopping halfway would leave files nothing has vouched for.
      LocalModelStatus.verifying => null,
      LocalModelStatus.failed => SettingsRowButton(
        key: ValueKey('local-download-${model.id}'),
        label: 'Try again',
        prominent: true,
        onPressed: onDownload,
      ),
      _ => SettingsRowButton(
        key: ValueKey('local-download-${model.id}'),
        label: state.receivedBytes > 0 ? 'Resume' : 'Download',
        prominent: true,
        onPressed: onDownload,
      ),
    };
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

/// A choice between a few options a word can name — Light or Dark, Plain or
/// Ruled — set side by side under the row's copy.
///
/// A radio list spent a row and a sentence on each of these, which made the
/// pane long without making the choice any clearer. The chosen option's
/// sentence is kept: it is the row's subtitle, and changes with the choice.
class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.options,
    required this.selected,
    required this.labelFor,
    required this.keyFor,
    required this.onSelected,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final List<T> options;
  final T selected;
  final String Function(T option) labelFor;

  /// Each option gets a key of its own, so a test can pick one by name the
  /// way it could pick the radio row it replaced.
  final Key Function(T option) keyFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: SettingsMetrics.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  icon,
                  size: SettingsMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(title: title, subtitle: subtitle),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.only(
              left: SettingsMetrics.iconSlot + SettingsMetrics.gap,
            ),
            child: Container(
              height: AppPlatform.hasPointer ? 26 : 34,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: palette.surfaceBackground,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.controlBorder, width: 0.5),
              ),
              child: Row(
                children: [
                  for (final option in options)
                    Expanded(
                      child: _Segment(
                        key: keyFor(option),
                        label: labelFor(option),
                        selected: option == selected,
                        accent: accent,
                        onTap: () => onSelected(option),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    accent.withValues(alpha: 0.16),
                    palette.controlBackground,
                  )
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: SettingsMetrics.titleSize - 1,
              fontWeight: selected
                  ? _settingsMediumWeight
                  : _settingsRegularWeight,
              color: selected ? accent : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row whose control is a slider under the copy rather than a switch
/// beside it: the track needs the width, and a label at each end says which
/// way is which without a number nobody would read as anything.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.minLabel,
    required this.maxLabel,
    required this.value,
    required this.onChanged,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final String minLabel;
  final String maxLabel;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final endLabel = TextStyle(
      fontSize: AppTypeScale.caption,
      color: palette.textTertiary,
    );
    return Padding(
      padding: SettingsMetrics.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  icon,
                  size: SettingsMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(title: title, subtitle: subtitle),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(
              left: SettingsMetrics.iconSlot + SettingsMetrics.gap,
              top: 2,
            ),
            child: Row(
              children: [
                Text(minLabel, style: endLabel),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: scheme.primary,
                      inactiveTrackColor: palette.controlBorder,
                      thumbColor: scheme.primary,
                      overlayColor: scheme.primary.withValues(alpha: 0.12),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      value: value,
                      onChanged: onChanged,
                      label: title,
                    ),
                  ),
                ),
                Text(maxLabel, style: endLabel),
              ],
            ),
          ),
        ],
      ),
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
          borderRadius: BorderRadius.circular(999),
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
              'Adding the on-device engine from Google Play',
            LocalModelStatus.fetchingRuntime =>
              'Adding the on-device engine: '
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

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.trailingStyle,
    this.trailingSpans,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final TextStyle? trailingStyle;
  final List<InlineSpan>? trailingSpans;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: SettingsMetrics.choicePadding,
          child: Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  selected
                      ? KapyIcons.radioCheckedRounded
                      : KapyIcons.radioUncheckedRounded,
                  size: SettingsMetrics.iconSize,
                  color: selected ? accent : palette.textTertiary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(title: title, subtitle: subtitle),
              ),
              const SizedBox(width: 10),
              Text.rich(
                TextSpan(
                  text: trailingSpans == null ? trailing : null,
                  children: trailingSpans,
                ),
                style:
                    (trailingStyle ??
                            TextStyle(
                              fontFamily: AppPlatform.monoFontFallback.first,
                              fontFamilyFallback: AppPlatform.monoFontFallback,
                              fontSize: AppTypeScale.caption,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ))
                        .copyWith(
                          color: selected ? accent : palette.textTertiary,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Credits the service that supplied the active exchange-rate snapshot.
///
/// Before the first download this points to the primary provider. Persisting
/// the source with each snapshot keeps fallback and legacy cache attribution
/// accurate while the app is offline.
class _RateAttributionRow extends StatelessWidget {
  const _RateAttributionRow({required this.rates});

  final RatesRepository rates;

  Future<void> _open(BuildContext context) async {
    final url = rates.attributionUrl;
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: rates,
      builder: (context, _) {
        final date = rates.refreshedDate;
        return Semantics(
          link: true,
          child: InkWell(
            key: const ValueKey('rate-attribution'),
            onTap: () => _open(context),
            child: Padding(
              padding: SettingsMetrics.padding,
              child: Row(
                children: [
                  SizedBox(
                    width: SettingsMetrics.iconSlot,
                    child: KapyIcon(
                      KapyIcons.currencyExchangeRounded,
                      size: SettingsMetrics.iconSize,
                      color: palette.textSecondary,
                    ),
                  ),
                  SizedBox(width: SettingsMetrics.gap),
                  Expanded(
                    child: SettingsRowCopy(
                      title: rates.attributionLabel,
                      subtitle: date.isEmpty
                          ? 'Currency rates refresh automatically'
                          : 'Currency rates refreshed $date',
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
      },
    );
  }
}

/// Names the build that is actually running.
///
/// Worth a row of its own: it is the first thing a bug report asks for, and
/// the only line in this pane that never depends on the network.
class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.updates});

  final UpdateChecker updates;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final version = updates.currentVersion;
        final build = updates.currentBuild;
        return Padding(
          key: const ValueKey('app-version'),
          padding: SettingsMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  KapyIcons.infoOutlined,
                  size: SettingsMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(
                  title: version.isEmpty ? 'Kapy Notes' : 'Kapy Notes $version',
                  subtitle: build.isEmpty
                      ? 'Reading the installed version'
                      : 'Build $build',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The only place the update state is spelled out: what the daily check
/// found, how far the download has got, and the button for whatever is next
/// — a check, a download, or the restart that installs it.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow({super.key, required this.updates});

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

  Future<void> _openNotes(BuildContext context) async {
    final raw = updates.available?.notesUrl ?? '';
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
    if (updates.available != null) {
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
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  available != null || ready
                      ? KapyIcons.systemUpdateRounded
                      : KapyIcons.verifiedOutlined,
                  size: SettingsMetrics.iconSize,
                  color: available != null || ready
                      ? palette.chipCurrency
                      : palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
              Expanded(
                child: SettingsRowCopy(title: _title(), subtitle: _subtitle()),
              ),
              if (available != null && available.notesUrl.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('update-release-notes'),
                  onPressed: () => _openNotes(context),
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
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    fontWeight: _settingsMediumWeight,
                  ),
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
    icon: history.hasFailed
        ? KapyIcons.cloudOffRounded
        : KapyIcons.historyOffRounded,
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
                    width: SettingsMetrics.iconSlot,
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
                        fontWeight: _settingsMediumWeight,
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
              left: SettingsMetrics.iconSlot + SettingsMetrics.gap,
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

/// Opens the changelog page itself.
class _ChangelogLinkRow extends StatelessWidget {
  const _ChangelogLinkRow();

  static final Uri _url = Uri.parse('https://kapynotes.com/changelog');

  Future<void> _open(BuildContext context) async {
    var opened = false;
    try {
      opened = await launchUrl(_url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    Toast.show(
      context,
      'Could not open ${_url.host}',
      icon: KapyIcons.errorOutlined,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      link: true,
      child: InkWell(
        key: const ValueKey('changelog-page'),
        onTap: () => _open(context),
        child: Padding(
          padding: SettingsMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: SettingsMetrics.iconSlot,
                child: KapyIcon(
                  KapyIcons.articleOutlined,
                  size: SettingsMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: SettingsMetrics.gap),
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

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    super.key,
    required this.action,
    required this.binding,
    required this.onPressed,
    this.detailed = false,
  });

  final ShortcutAction action;

  /// Null where the user has cleared it. The row stays, because it is also
  /// how the shortcut is given back.
  final ShortcutBinding? binding;
  final VoidCallback onPressed;

  /// Whether the row carries its line of explanation. Only the system-wide
  /// shortcuts need one; the rest are named for what they do.
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: detailed
          ? const EdgeInsets.fromLTRB(13, 8, 9, 8)
          : const EdgeInsets.fromLTRB(13, 5, 9, 5),
      child: Row(
        children: [
          Expanded(
            child: SettingsRowCopy(
              title: action.label,
              subtitle: detailed ? action.description : null,
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            key: ValueKey('shortcut-${action.name}'),
            onPressed: onPressed,
            style: TextButton.styleFrom(
              minimumSize: const Size(88, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              backgroundColor: palette.selectedBackground,
              foregroundColor: palette.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            child: Text(
              binding?.displayLabel ?? 'None',
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                fontWeight: _settingsMediumWeight,
                // Dimmed rather than absent: an empty button would look
                // broken, and this one still opens the recorder.
                color: binding == null ? palette.textTertiary : null,
              ),
            ),
          ),
        ],
      ),
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
      title: const Text(
        'Note opened at launch',
        style: TextStyle(fontWeight: _settingsSemiboldWeight),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      content: SizedBox(
        width: math.min(410, media.width - 80),
        height: math.min(380, 54.0 * (notes.length + 1)),
        child: ListView.separated(
          itemCount: notes.length + 1,
          separatorBuilder: (_, _) => Divider(
            height: 0.5,
            thickness: 0.5,
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
          child: const Text(
            'Cancel',
            style: TextStyle(fontWeight: _settingsMediumWeight),
          ),
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
      title: const Text(
        'Time zone',
        style: TextStyle(fontWeight: _settingsSemiboldWeight),
      ),
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
                  borderRadius: BorderRadius.circular(8),
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
                        height: 0.5,
                        thickness: 0.5,
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
          child: const Text(
            'Cancel',
            style: TextStyle(fontWeight: _settingsMediumWeight),
          ),
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

/// What the recorder came back with.
///
/// A record rather than a bare binding because there are three answers, not
/// two: bind this chord, leave the action with no key at all, or nothing —
/// the dialog was dismissed. Only the last is a null result.
typedef ShortcutChoice = ({ShortcutBinding? binding});

class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog({required this.action, required this.current});

  final ShortcutAction action;

  /// Null when the action has already been cleared.
  final ShortcutBinding? current;

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog> {
  String? _error;

  void _clear() => Navigator.of(context).pop<ShortcutChoice>((binding: null));

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_isModifier(event.logicalKey)) return KeyEventResult.handled;

    final keyboard = HardwareKeyboard.instance;
    // Backspace on its own takes the shortcut away, which is what the same
    // key does in macOS's own shortcut editor. Nothing is lost by spending it
    // here: a chord that binds must carry a modifier, so a bare Backspace
    // could never have been recorded anyway.
    if (!_hasModifier(keyboard) &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      _clear();
      return KeyEventResult.handled;
    }

    final binding = ShortcutBinding(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
      meta: keyboard.isMetaPressed,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
    if (!binding.hasModifier) {
      setState(() {
        _error = AppPlatform.isMacOS
            ? 'Include Command, Control, Option, or Shift.'
            : 'Include Ctrl, Alt, Shift, or Windows.';
      });
      return KeyEventResult.handled;
    }

    Navigator.of(context).pop<ShortcutChoice>((binding: binding));
    return KeyEventResult.handled;
  }

  static bool _hasModifier(HardwareKeyboard keyboard) =>
      keyboard.isMetaPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isShiftPressed;

  static bool _isModifier(LogicalKeyboardKey key) => {
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  }.contains(key);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: AlertDialog(
        title: Text(
          'Set ${widget.action.label.toLowerCase()}',
          style: const TextStyle(fontWeight: _settingsSemiboldWeight),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: palette.controlBackground,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.controlBorder, width: 0.5),
                ),
                child: Column(
                  children: [
                    KapyIcon(
                      KapyIcons.keyboardOutlined,
                      size: 21,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      'Press your new shortcut',
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        fontWeight: _settingsMediumWeight,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.current == null
                          ? 'Currently not set'
                          : 'Current: ${widget.current!.displayLabel}',
                      style: TextStyle(
                        fontSize: AppTypeScale.caption,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          // Only where there is something to take away. Offering it against
          // an action that already has no key would be a button that does
          // nothing, which is worse than no button.
          if (widget.current != null)
            TextButton(
              key: const ValueKey('shortcut-remove'),
              onPressed: _clear,
              // Styled like Cancel rather than in the error colour. The light
              // theme's accent is a terracotta a shade off that red, so the
              // emphasis would only read in the dark one — and taking a
              // shortcut away is a click to undo, not a deletion.
              child: const Text(
                'Remove',
                style: TextStyle(fontWeight: _settingsMediumWeight),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(fontWeight: _settingsMediumWeight),
            ),
          ),
        ],
      ),
    );
  }
}
