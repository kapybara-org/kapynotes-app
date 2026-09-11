import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../data/update_checker.dart';
import '../data/time_zones.dart';

/// The groups of settings, one per rail entry.
///
/// Adding a section is meant to be the whole job of adding a category of
/// options: name it here, give it a pane in [_SettingsDialogState], and all
/// three layouts pick it up.
enum SettingsSection { general, sync, appearance, voice, shortcuts, updates }

const _sheetCorners = BorderRadius.vertical(top: Radius.circular(22));
const _sheetIndexKey = ValueKey('settings-sheet-index');

const _settingsRegularWeight = FontWeight.w400;
const _settingsMediumWeight = FontWeight.w500;
const _settingsSemiboldWeight = FontWeight.w500;

/// How big a settings row is allowed to be.
///
/// A pointer can hit an eight-pixel gap and read eleven-point type; a thumb
/// can do neither. This is the same split [AppControlMetrics] already makes
/// for icon buttons, applied to the rows those buttons sit beside.
class _RowMetrics {
  const _RowMetrics._();

  static bool get _touch => !AppPlatform.hasPointer;

  static EdgeInsets get padding => _touch
      ? const EdgeInsets.fromLTRB(14, 12, 13, 12)
      : const EdgeInsets.fromLTRB(11, 8, 10, 8);

  /// A radio sits closer to its own edge than a switch does.
  static EdgeInsets get choicePadding => _touch
      ? const EdgeInsets.fromLTRB(14, 12, 14, 12)
      : const EdgeInsets.fromLTRB(11, 8, 11, 8);
  static double get iconSize => _touch ? 19 : 16;
  static double get iconSlot => _touch ? 30 : 25;
  static double get gap => _touch ? 11 : 9;
  static double get titleSize => _touch ? 14.5 : 12.5;
  static double get subtitleSize => _touch ? 12.25 : 10.75;
  static double get chevronSize => _touch ? 21 : 18;

  /// Lines the dividers up under the copy rather than under the icons.
  static double get dividerIndent => _touch ? 58 : 48;
}

extension SettingsSectionCopy on SettingsSection {
  String get label => switch (this) {
    SettingsSection.general => 'General',
    SettingsSection.sync => 'Profile & sync',
    SettingsSection.voice => 'Voice notes',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.updates => 'Updates',
  };

  IconData get icon => switch (this) {
    SettingsSection.general => Icons.tune_rounded,
    SettingsSection.sync => Icons.account_circle_outlined,
    SettingsSection.voice => Icons.mic_none_rounded,
    SettingsSection.appearance => Icons.auto_stories_outlined,
    SettingsSection.shortcuts => Icons.keyboard_outlined,
    SettingsSection.updates => Icons.system_update_alt_rounded,
  };

  /// What is behind the label, for the layouts that show a list of categories
  /// instead of the categories themselves. Names the contents rather than
  /// selling them: this line is read while looking for something.
  String get summary => switch (this) {
    SettingsSection.general => 'Notes, spelling, export and import, time zone',
    SettingsSection.sync =>
      'Your name, picture, account, and the notes you sync and share',
    SettingsSection.voice => 'Transcription, language, minutes',
    SettingsSection.appearance => 'Theme, writing font, paper, number format',
    SettingsSection.shortcuts => 'System-wide and in-app keys',
    SettingsSection.updates => 'This build, and whether a newer one exists',
  };
}

/// Opens settings in the shape the platform wants.
///
/// A pointer gets the dialog: a rail beside a pane, everything one click
/// away. A thumb gets a sheet that opens on a list of categories and pushes
/// into one at a time, because six panes stacked into one phone-width column
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
  VoidCallback? onOpenWelcomeNote,
  VoicePrefs? voicePrefs,
  LocalModelStore? localModels,
  Summarizer? deviceSummarizer,
  Transcriber? deviceTranscriber,
  SettingsSection? section,
}) {
  SettingsDialog build({required bool asSheet}) => SettingsDialog(
    layoutPrefs: layoutPrefs,
    shortcuts: shortcuts,
    rates: rates,
    notes: notes,
    account: account,
    updates: updates,
    desktopIntegration: desktopIntegration,
    onOpenWelcomeNote: onOpenWelcomeNote,
    voicePrefs: voicePrefs,
    localModels: localModels,
    deviceSummarizer: deviceSummarizer,
    deviceTranscriber: deviceTranscriber,
    section: section,
    asSheet: asSheet,
  );

  if (!AppPlatform.isMobile) {
    return showDialog<void>(
      context: context,
      builder: (context) => build(asSheet: false),
    );
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
    this.onOpenWelcomeNote,
    this.voicePrefs,
    this.localModels,
    this.deviceSummarizer,
    this.deviceTranscriber,
    this.section,
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
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;

  /// Reopens the note a first launch starts on. Null where there is no note
  /// list to open it into — the export tests mount this dialog on its own.
  final VoidCallback? onOpenWelcomeNote;

  /// The pane to open on, when something outside sent the user here to do one
  /// thing. Null starts where settings always starts.
  final SettingsSection? section;

  /// Present as the phone sheet — a list of categories you push through —
  /// instead of the rail dialog. Set by [showSettings]. Both shapes are the
  /// same widget so that a new section still only has to be written once.
  final bool asSheet;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// Below this the rail costs more width than it earns, and every section
  /// stacks into one scrolling column instead.
  static const double _railBreakpoint = 520;
  static const double _railWidth = 152;
  static const double _panedWidth = 544;
  static const double _stackedWidth = 410;

  String? _shortcutError;
  String? _loginItemError;
  SettingsSection _section = SettingsSection.general;

  /// Which section the sheet has pushed, or null while it is showing the
  /// list of categories. Kept apart from [_section] because the dialog always
  /// has one selected and the sheet deliberately starts with none.
  SettingsSection? _sheetSection;
  final GlobalKey<NavigatorState> _sheetNavigator = GlobalKey<NavigatorState>();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _shortcutError = widget.desktopIntegration?.registrationError;
    _loadSpeechState();
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
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
  SpeechUsage? _speechUsage;
  bool _speechBusy = false;
  String? _speechError;

  /// Asks the server what this account agreed to and how much it has used.
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
    speech
        .usage()
        .then((value) {
          if (mounted) setState(() => _speechUsage = value);
        })
        .catchError((Object _) {});
  }

  Future<void> _setTranscription(bool on) async {
    final speech = widget.account?.speech;
    if (speech == null || _speechBusy) return;

    if (on) {
      final accepted = await showSpeechConsentSheet(context);
      if (!accepted) {
        widget.voicePrefs?.transcriptionDeclinedVersion = speechConsentVersion;
        return;
      }
      if (!mounted) return;
    }
    setState(() {
      _speechBusy = true;
      _speechError = null;
    });
    final progress = Toast.showProgress(
      context,
      on ? 'Turning on transcription…' : 'Turning off transcription…',
    );
    try {
      // Version 0 withdraws.
      final status = await speech.acceptConsent(on ? speechConsentVersion : 0);
      if (on) widget.voicePrefs?.transcriptionDeclinedVersion = null;
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

  String _speechMinutesLine() {
    final usage = _speechUsage;
    if (usage == null) {
      return widget.account?.speech == null
          ? 'Sign in to see how much transcription you have used'
          : 'Checking…';
    }
    final used = (usage.usedSeconds / 60).floor();
    final quota = (usage.quotaSeconds / 60).round();
    return '$used of $quota minutes used · resets ${_shortMonthDay(usage.resetsAt)}';
  }

  static String _shortMonthDay(DateTime at) {
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
    return '${at.day} ${months[at.month - 1]}';
  }

  /// What happens to a recording, and where.
  ///
  /// Two headings, not four. The engines that run here used to have a shelf
  /// each — one for the recogniser, one for the language model — and a
  /// "where is this done" picker apiece somewhere further up the pane, which
  /// asked the same question in three places and answered it in none of them
  /// visibly. A switch beside the download says it once.
  List<Widget> _voicePane() {
    final prefs = widget.voicePrefs;
    final signedIn = widget.account?.speech != null;
    return [
      const _SectionLabel('RECORDINGS'),
      _SettingsGroup(
        children: [
          if (signedIn)
            _ToggleRow(
              key: const ValueKey('voice-transcription-toggle'),
              icon: Icons.mic_none_rounded,
              title: 'Transcription',
              subtitle: 'Turn recordings into text and a summary',
              value: _speechConsent?.isAccepted ?? false,
              onChanged: _speechBusy
                  ? (_) {}
                  : (value) => unawaited(_setTranscription(value)),
            )
          else
            _NavigationRow(
              key: const ValueKey('voice-sign-in-row'),
              icon: Icons.mic_none_rounded,
              title: 'Transcription',
              // Signing in stopped being the only way to get a transcript the
              // day the device engine landed. Saying so only when this machine
              // can actually do it keeps the row honest on the ones that
              // cannot.
              subtitle: _deviceTranscriptState == TranscriberReadiness.ready
                  ? 'Sign in, or switch this device on below'
                  : 'Sign in to turn recordings into text',
              onTap: () => _goToSection(SettingsSection.sync),
            ),
          if (prefs != null)
            _ToggleRow(
              key: const ValueKey('voice-summary-toggle'),
              icon: Icons.subject_rounded,
              title: 'Make a summary',
              subtitle: 'A title and a few points, after the transcript',
              value: prefs.summarize,
              onChanged: (value) => setState(() => prefs.summarize = value),
            ),
          if (prefs != null)
            _NavigationRow(
              key: const ValueKey('voice-language-row'),
              icon: Icons.translate_rounded,
              title: 'Language',
              subtitle:
                  _speechLanguages[prefs.language] ?? 'Detect automatically',
              onTap: () => unawaited(_pickSpeechLanguage(prefs)),
            ),
          // Metering is the cloud's, so it sits under the switch that sends
          // things there rather than under a heading of its own. Nothing to
          // meter without an account, and the row said as much in a sentence
          // that only ever pointed at the one above it.
          if (signedIn)
            _NavigationRow(
              key: const ValueKey('voice-minutes-row'),
              icon: Icons.schedule_rounded,
              title: 'Minutes this month',
              subtitle: _speechMinutesLine(),
              onTap: _loadSpeechState,
            ),
        ],
      ),
      if (_speechError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            _speechError!,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 18),
      const _SectionLabel('LOCAL'),
      ..._localPane(prefs),
    ];
  }

  /// The engines that can run on this machine, and the whole of the choice
  /// about them.
  ///
  /// A switch that is on is the engine that runs; everything else goes to the
  /// cloud. That is the same decision the two engine pickers used to ask
  /// separately, in a place where the answer could not be seen — and it only
  /// ever has two answers, which is a switch.
  List<Widget> _localPane(VoicePrefs? prefs) {
    final store = widget.localModels;
    final speech = store?.catalogue.whereType<LocalSpeechModel>().firstOrNull;
    final summary = store?.catalogue.whereType<LocalSummaryModel>().firstOrNull;
    final credits = <DownloadableModel>[?speech, ?summary];

    return [
      _SettingsGroup(
        children: [
          _LocalEngineRow(
            key: const ValueKey('local-transcription-row'),
            icon: Icons.graphic_eq_rounded,
            title: 'Transcription',
            store: store,
            model: speech,
            // Ready without a download of ours: the platform's own
            // recogniser, which is the ordinary case on Apple. A downloaded
            // model is caught by the row itself, and says its own name.
            builtIn: _deviceTranscriptState == TranscriberReadiness.ready,
            builtInNote: 'Built into this device, and never uploaded',
            unavailableNote: switch (_deviceTranscriptState) {
              TranscriberReadiness.preparing =>
                'Still fetching the language it needs',
              TranscriberReadiness.needsSystemFeature =>
                'Allow speech recognition for Kapy Notes in Privacy settings',
              _ => 'Not something this device can do yet',
            },
            blockedReason: speech == null
                ? null
                : _downloadBlockedReason(speech),
            on: prefs?.transcriptEngine == TranscriptEngine.device,
            onChanged: prefs == null
                ? null
                : (value) => setState(() {
                    prefs.transcriptEngine = value
                        ? TranscriptEngine.device
                        : TranscriptEngine.cloud;
                  }),
            onDownload: speech == null || store == null
                ? null
                : () => unawaited(_startDownload(store, speech)),
          ),
          _LocalEngineRow(
            key: const ValueKey('local-summary-row'),
            icon: Icons.auto_awesome_outlined,
            title: 'Summaries',
            store: store,
            model: summary,
            builtIn: _deviceSummaryState == SummarizerReadiness.ready,
            builtInNote: 'Written here by Apple Intelligence, never uploaded',
            unavailableNote: switch (_deviceSummaryState) {
              SummarizerReadiness.needsSystemFeature =>
                'Turn on Apple Intelligence in System Settings first',
              SummarizerReadiness.preparing =>
                'Apple Intelligence is still downloading its model',
              _ => 'Not something this device can do yet',
            },
            blockedReason: summary == null
                ? null
                : _downloadBlockedReason(summary),
            on: prefs?.summaryEngine == SummaryEngine.device,
            onChanged: prefs == null
                ? null
                : (value) => setState(() {
                    prefs.summaryEngine = value
                        ? SummaryEngine.device
                        : SummaryEngine.cloud;
                  }),
            onDownload: summary == null || store == null
                ? null
                : () => unawaited(_startDownload(store, summary)),
          ),
        ],
      ),
      const _PaneNote(
        'Anything switched on here runs on this device: no account, no '
        'minutes, and the recording never leaves.',
      ),
      if (credits.isNotEmpty) _ModelCredits(models: credits),
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
    return 'Needs about ${fileSize(model.minimumMemoryBytes)} of memory; '
        'this device has ${fileSize(total)}.';
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

  /// Sends the user to another category, from inside one.
  ///
  /// The two layouts move differently — the sheet pushes, the rail selects —
  /// and a row that wants to hand over should not have to know which is up.
  void _goToSection(SettingsSection section) {
    if (!_isAvailable(section)) return;
    if (widget.asSheet) {
      _openSheetSection(section);
    } else {
      _showSection(section);
    }
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
      icon: Icons.check_rounded,
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
      builder: (context) =>
          _TimeZonePickerDialog(selectedId: widget.layoutPrefs.timeZoneId),
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
    return note == null || note.isArchived ? 'Last opened note' : note.title;
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
    final paned = available >= _railBreakpoint;
    final width = math.min(paned ? _panedWidth : _stackedWidth, available);
    // A fixed height keeps the dialog from resizing under the pointer
    // as sections of different lengths are selected.
    final height = (media.height - 170).clamp(260.0, 470.0);

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: EdgeInsets.fromLTRB(paned ? 14 : 20, 14, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      title: const Text(
        'Settings',
        style: TextStyle(fontWeight: _settingsSemiboldWeight),
      ),
      content: SizedBox(
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

  Widget _buildPaned(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _railWidth,
          child: _SettingsRail(
            sections: _sections,
            selected: _section,
            onSelect: _showSection,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _ScrollingPane(
            controller: _scrollController,
            children: _paneFor(_section),
          ),
        ),
      ],
    );
  }

  Widget _buildStacked(BuildContext context) {
    return _ScrollingPane(
      controller: _scrollController,
      children: [
        for (final section in _sections) ...[
          if (section != _sections.first) const SizedBox(height: 20),
          ..._paneFor(section),
        ],
      ],
    );
  }

  List<Widget> _paneFor(SettingsSection section) => switch (section) {
    SettingsSection.general => _generalPane(),
    SettingsSection.sync => [
      ..._proPane(),
      SyncPane(account: widget.account!),
      // The gap between two panes, borrowed from the stacked layout: the
      // panel titles do the separating, and a rule between them would only
      // put back the boundary this section exists to remove.
      const SizedBox(height: 20),
      SharingPane(account: widget.account!),
    ],
    SettingsSection.voice => _voicePane(),
    SettingsSection.appearance => _appearancePane(),
    SettingsSection.shortcuts => _shortcutsPane(),
    SettingsSection.updates => _updatesPane(),
  };

  /// The plan, first in the account's pane, which is where somebody wondering
  /// what their account has would look. Only where this build can sell
  /// something: a row opening onto nothing to buy would be a dead end.
  List<Widget> _proPane() {
    final billing = widget.account?.billing;
    if (billing == null || !billing.canPurchase) return const [];
    return [
      const _SectionLabel('PLAN'),
      ListenableBuilder(
        listenable: billing,
        builder: (context, _) => _SettingsGroup(
          children: [
            _NavigationRow(
              key: const ValueKey('pro-row'),
              icon: Icons.workspace_premium_outlined,
              title: 'Kapy Notes Pro',
              subtitle: _proSummary(billing),
              onTap: () => showProSheet(context, billing: billing),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
    ];
  }

  static String _proSummary(Billing billing) {
    if (!billing.isSignedIn) return 'What Pro adds, for one payment';
    final now = billing.entitlements;
    if (now == null) return 'Checking your plan…';
    if (now.isPro) return 'Pro Lifetime';
    return switch (billing.trialDaysLeft) {
      null => 'Free · see what Pro adds',
      1 => 'Pro trial · last day',
      final days => 'Pro trial · $days days left',
    };
  }

  List<Widget> _generalPane() => [
    const _SectionLabel('NOTES'),
    _SettingsGroup(
      children: [
        _ToggleRow(
          key: const ValueKey('ready-to-type-on-open-toggle'),
          icon: Icons.keyboard_alt_outlined,
          title: 'Ready to type on open',
          subtitle:
              'Put the cursor back where you left it, or on a new line on a '
              'new day',
          value: widget.layoutPrefs.readyToTypeOnOpen,
          onChanged: (value) => widget.layoutPrefs.readyToTypeOnOpen = value,
        ),
        _NavigationRow(
          key: const ValueKey('default-note-setting'),
          icon: Icons.note_alt_outlined,
          title: 'Note opened at launch',
          subtitle: _defaultNoteLabel,
          onTap: _chooseDefaultNote,
        ),
        _ToggleRow(
          key: const ValueKey('daily-separators-toggle'),
          icon: Icons.calendar_today_outlined,
          title: 'Daily separators',
          subtitle: 'Start each session and new day on a dated line',
          value: widget.layoutPrefs.dailySeparatorsEnabled,
          onChanged: (value) =>
              widget.layoutPrefs.dailySeparatorsEnabled = value,
        ),
        _ToggleRow(
          key: const ValueKey('spell-check-toggle'),
          icon: Icons.spellcheck_rounded,
          title: 'Check spelling',
          subtitle: 'Underline possible misspellings without changing text',
          value: widget.layoutPrefs.spellCheckEnabled,
          onChanged: (value) => widget.layoutPrefs.spellCheckEnabled = value,
        ),
        if (AppPlatform.isDesktop)
          _ToggleRow(
            key: const ValueKey('sidebar-toggle'),
            icon: Icons.view_sidebar_outlined,
            title: 'Desktop sidebar',
            subtitle: 'Show notes beside wider editor windows',
            value: widget.layoutPrefs.sidebarVisible,
            onChanged: (_) => widget.layoutPrefs.toggleSidebar(),
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('YOUR NOTES'),
    _SettingsGroup(
      children: [
        _NavigationRow(
          key: const ValueKey('export-notes'),
          icon: Icons.ios_share_rounded,
          title: 'Export all notes',
          // The one-line warning the plaintext deserves, at the moment it
          // matters. Not called a backup, because nothing here runs on its own.
          subtitle: 'Markdown in one .zip · not encrypted once it is saved',
          onTap: () => unawaited(runExport(context, widget.notes)),
        ),
        _NavigationRow(
          key: const ValueKey('import-notes'),
          icon: Icons.download_rounded,
          title: 'Import from an export',
          subtitle: 'Read a .zip back in, and see what it changes first',
          onTap: () => unawaited(runImport(context, widget.notes)),
        ),
        if (widget.onOpenWelcomeNote case final openWelcome?)
          _NavigationRow(
            key: const ValueKey('open-welcome-note'),
            icon: Icons.waving_hand_outlined,
            title: 'Welcome note',
            subtitle: 'Open the note a new install starts on',
            onTap: () {
              Navigator.of(context).pop();
              openWelcome();
            },
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('TIME ZONE'),
    _SettingsGroup(
      children: [
        _NavigationRow(
          key: const ValueKey('time-zone-setting'),
          icon: Icons.public_rounded,
          title: AppTimeZones.displayName(widget.layoutPrefs.timeZoneId),
          subtitle:
              'New separators · ${AppTimeZones.offsetLabel(widget.layoutPrefs.timeZoneId)}',
          onTap: _chooseTimeZone,
        ),
      ],
    ),
    if (AppPlatform.isDesktop) ...[
      const SizedBox(height: 18),
      // One heading, because both switches answer the same question — how
      // this behaves as an app rather than as a window — and a heading over
      // a single row is a heading that earns nothing.
      const _SectionLabel('WINDOW'),
      _SettingsGroup(
        children: [
          _ToggleRow(
            key: const ValueKey('keep-running-toggle'),
            icon: Icons.close_fullscreen_rounded,
            title: AppPlatform.isMacOS
                ? 'Keep running in the menu bar'
                : 'Keep running in the tray',
            subtitle: AppPlatform.isMacOS
                ? 'Adds a menu bar icon to open, write and quit from'
                : 'Closing the window hides it there instead of quitting, so '
                      'your shortcuts keep working',
            value: widget.layoutPrefs.keepRunningInBackground,
            onChanged: _setKeepRunning,
          ),
          // Absent rather than disabled where the OS has no mechanism this
          // app is allowed to use: macOS 12 predates the one the sandbox
          // permits.
          if (widget.desktopIntegration?.loginItemSupported ?? false)
            _ToggleRow(
              key: const ValueKey('login-item-toggle'),
              icon: Icons.login_rounded,
              title: 'Open at login',
              subtitle: 'Start Kapy Notes when you sign in to this computer',
              value: widget.desktopIntegration!.loginItemEnabled,
              onChanged: (value) => unawaited(_setLoginItem(value)),
            ),
        ],
      ),
      if (_loginItemError != null) ...[
        const SizedBox(height: 8),
        Text(
          _loginItemError!,
          key: const ValueKey('login-item-error'),
          style: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 10),
      _WideButton(
        onPressed: widget.layoutPrefs.resetPanelWidths,
        icon: Icons.restart_alt_rounded,
        label: 'Reset panel widths',
      ),
    ],
  ];

  /// Everything that decides how the app looks and how what is in it reads.
  ///
  /// Numbers used to be a rail item of its own, holding one choice and an
  /// attribution line. How a thousand is punctuated is a display choice like
  /// any other here, and a category somebody visits once is a category that
  /// costs a click every time they are looking for something else.
  List<Widget> _appearancePane() => [
    const _SectionLabel('THEME'),
    _SettingsGroup(
      children: [
        for (final mode in AppearanceMode.values)
          _ChoiceRow(
            key: ValueKey('appearance-${mode.name}'),
            title: mode.label,
            subtitle: mode.description,
            trailing: '',
            selected: widget.layoutPrefs.appearance == mode,
            onTap: () => widget.layoutPrefs.appearance = mode,
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('WRITING FONT'),
    Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 8),
      child: Text(
        'Changes the note itself. Controls stay crisp and familiar.',
        style: TextStyle(fontSize: 11.5, color: context.palette.textTertiary),
      ),
    ),
    _SettingsGroup(
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
    if (LayoutPrefs.supportsTransparency) ...[
      const SizedBox(height: 18),
      const _SectionLabel('WINDOW'),
      _SettingsGroup(
        children: [
          _ToggleRow(
            key: const ValueKey('transparency-toggle'),
            icon: Icons.blur_on_rounded,
            title: 'Transparency',
            subtitle:
                'Let the desktop show through the window, blurred so the '
                'notes stay easy to read.',
            value: widget.layoutPrefs.transparencyEnabled,
            onChanged: (value) =>
                widget.layoutPrefs.transparencyEnabled = value,
          ),
          if (widget.layoutPrefs.transparencyEnabled)
            _SliderRow(
              key: const ValueKey('transparency-amount'),
              icon: Icons.opacity_rounded,
              title: 'Amount',
              subtitle: 'How much of the desktop shows through.',
              minLabel: 'Subtle',
              maxLabel: 'Clear',
              value: widget.layoutPrefs.transparencyAmount,
              onChanged: (value) =>
                  widget.layoutPrefs.transparencyAmount = value,
            ),
        ],
      ),
    ],
    const SizedBox(height: 18),
    const _SectionLabel('PAPER'),
    _SettingsGroup(
      children: [
        for (final paper in PaperStyle.values)
          _ChoiceRow(
            key: ValueKey('paper-style-${paper.name}'),
            title: paper.label,
            subtitle: paper.description,
            trailing: '',
            selected: widget.layoutPrefs.paperStyle == paper,
            onTap: () => widget.layoutPrefs.paperStyle = paper,
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('NUMBER FORMAT'),
    _SettingsGroup(
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
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('EXCHANGE RATES'),
    _SettingsGroup(children: [_RateAttributionRow(rates: widget.rates)]),
  ];

  /// The system-wide pair leads: they are the ones that reach the app from
  /// outside it, they are the ones another app can refuse, and they are what
  /// people come here to change. Then the in-app keys, then formatting, which
  /// every footer button already spells out.
  List<Widget> _shortcutsPane() => [
    Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 9),
      child: Text(
        'Select a shortcut, then press a new combination. Menus and footer hints update immediately.',
        style: TextStyle(fontSize: 11.5, color: context.palette.textTertiary),
      ),
    ),
    const _SectionLabel('SYSTEM-WIDE'),
    _SettingsGroup(
      children: [
        for (final action in ShortcutAction.values.where(
          (action) => action.isGlobal,
        ))
          _ShortcutRow(
            action: action,
            binding: widget.shortcuts.bindingFor(action),
            onPressed: () => _recordShortcut(action),
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('APP'),
    _SettingsGroup(
      children: [
        for (final action in ShortcutAction.values.where(
          (action) => !action.isFormatting && !action.isGlobal,
        ))
          _ShortcutRow(
            action: action,
            binding: widget.shortcuts.bindingFor(action),
            onPressed: () => _recordShortcut(action),
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('FORMATTING'),
    _SettingsGroup(
      children: [
        for (final action in ShortcutAction.values.where(
          (action) => action.isFormatting,
        ))
          _ShortcutRow(
            action: action,
            binding: widget.shortcuts.bindingFor(action),
            onPressed: () => _recordShortcut(action),
          ),
      ],
    ),
    if (_shortcutError != null) ...[
      const SizedBox(height: 8),
      Text(
        _shortcutError!,
        key: const ValueKey('shortcut-error'),
        style: TextStyle(
          fontSize: 11.5,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    ],
    const SizedBox(height: 10),
    _WideButton(
      onPressed: _restoreShortcutDefaults,
      icon: Icons.settings_backup_restore_rounded,
      label: 'Restore shortcut defaults',
    ),
  ];

  /// Everything the app knows about its own release, in the one place a
  /// person would look for it: which build is running, whether a newer one
  /// exists, and the button that goes and finds out.
  List<Widget> _updatesPane() {
    final updates = widget.updates!;
    return [
      const _SectionLabel('VERSION'),
      _SettingsGroup(children: [_VersionRow(updates: updates)]),
      const SizedBox(height: 18),
      const _SectionLabel('SOFTWARE UPDATE'),
      Padding(
        padding: const EdgeInsets.only(left: 3, bottom: 8),
        child: Text(
          'Kapy Notes looks for a new release once a day. Nothing is downloaded until you ask for it.',
          style: TextStyle(fontSize: 11.5, color: context.palette.textTertiary),
        ),
      ),
      _SettingsGroup(
        children: [
          _UpdateRow(updates: updates, desktop: widget.desktopIntegration),
        ],
      ),
    ];
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
  });

  final String title;

  /// The home indicator, which the sheet reaches under but nothing scrolls
  /// beneath.
  final double bottomInset;
  final List<Widget> children;

  /// Null on the list of categories, which has nothing to go back to.
  final VoidCallback? onBack;

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
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 17,
                    ),
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
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomInset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
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
      AccountState.needsPassphrase => 'Choose a passphrase to start syncing',
      AccountState.locked => 'Unlock to read these notes here',
      AccountState.needsAccountDecision => 'Waiting on what this device does',
      AccountState.ready => account.user?.displayName ?? 'Signed in',
    };
  }

  Widget _card() => _SettingsGroup(
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
                child: Icon(section.icon, size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _RowCopy(title: section.label, subtitle: summary),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: _RowMetrics.chevronSize,
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
  const _ScrollingPane({required this.controller, required this.children});

  final ScrollController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scrollbar(
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
}

/// The category list down the left of the wide dialog.
class _SettingsRail extends StatelessWidget {
  const _SettingsRail({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final SettingsSection selected;
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
                Icon(
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

/// A sentence under a group, explaining what it is for.
class _PaneNote extends StatelessWidget {
  const _PaneNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 2, 3, 0),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: context.palette.textTertiary),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 3, bottom: 7),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: _settingsMediumWeight,
        letterSpacing: 0.65,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: _RowMetrics.dividerIndent,
                  color: palette.separator,
                ),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

/// A full-width, low-emphasis action at the foot of a pane.
class _WideButton extends StatelessWidget {
  const _WideButton({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
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

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      toggled: value,
      button: true,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: _RowMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  icon,
                  size: _RowMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
              ),
              const SizedBox(width: 10),
              ExcludeSemantics(child: _CompactSwitchIndicator(value: value)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One engine that could run on this machine: not here yet, on its way, or
/// here and switched on.
///
/// The switch is the whole of the choice. There is no separate "where is this
/// done" question any more — an engine that is here and switched on is the
/// one that runs, and anything else goes to the cloud. Two settings became
/// one, and the one is visible without opening anything: a switch you can see
/// is off is a question already answered.
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
  });

  final IconData icon;
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
      padding: _RowMetrics.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  icon,
                  size: _RowMetrics.iconSize,
                  color: context.palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(
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

    if (!usable || onChanged == null) return row;
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
            _RowButton(
              key: ValueKey('local-remove-${model!.id}'),
              label: 'Remove',
              onPressed: () => unawaited(store.remove(model)),
            ),
            const SizedBox(width: 8),
          ],
          ExcludeSemantics(child: _CompactSwitchIndicator(value: on)),
        ],
      );
    }
    if (model == null || store == null || blockedReason != null) return null;
    final state = store.stateOf(model);
    return switch (state.status) {
      LocalModelStatus.fetchingRuntime ||
      LocalModelStatus.downloading => _RowButton(
        key: ValueKey('local-cancel-${model.id}'),
        label: 'Cancel',
        onPressed: () => store.cancel(model),
      ),
      // Nothing to press while the hashes are checked: it takes seconds, and
      // stopping halfway would leave files nothing has vouched for.
      LocalModelStatus.verifying => null,
      LocalModelStatus.failed => _RowButton(
        key: ValueKey('local-download-${model.id}'),
        label: 'Try again',
        prominent: true,
        onPressed: onDownload,
      ),
      _ => _RowButton(
        key: ValueKey('local-download-${model.id}'),
        label: state.receivedBytes > 0 ? 'Resume' : 'Download',
        prominent: true,
        onPressed: onDownload,
      ),
    };
  }
}

/// The small button at the end of a row.
class _RowButton extends StatelessWidget {
  const _RowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: prominent ? scheme.primary : palette.controlBackground,
        foregroundColor: prominent ? scheme.onPrimary : palette.textSecondary,
        disabledForegroundColor: palette.textTertiary,
        side: prominent
            ? null
            : BorderSide(color: palette.controlBorder, width: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: _settingsMediumWeight),
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
    final style = TextStyle(fontSize: 10.5, color: palette.textTertiary);
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
      icon: Icons.error_outline_rounded,
      isError: true,
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

  final IconData icon;
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
      padding: _RowMetrics.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  icon,
                  size: _RowMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(
              left: _RowMetrics.iconSlot + _RowMetrics.gap,
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

class _CompactSwitchIndicator extends StatelessWidget {
  const _CompactSwitchIndicator({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      key: const ValueKey('compact-switch-indicator'),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      width: AppPlatform.hasPointer ? 34 : 44,
      height: AppPlatform.hasPointer ? 18 : 25,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: value ? scheme.primary : palette.controlBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: value ? Colors.transparent : palette.controlBorder,
          width: 0.5,
        ),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: value ? scheme.onPrimary : palette.textTertiary,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(dimension: AppPlatform.hasPointer ? 14 : 21),
        ),
      ),
    );
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: _RowMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  icon,
                  size: _RowMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: _RowMetrics.chevronSize,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
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
        style: TextStyle(fontSize: 11, color: scheme.error),
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
          style: TextStyle(fontSize: 10.5, color: palette.textTertiary),
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
          padding: _RowMetrics.choicePadding,
          child: Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: _RowMetrics.iconSize,
                  color: selected ? accent : palette.textTertiary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
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
                              fontSize: 11.5,
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
      icon: Icons.error_outline_rounded,
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
              padding: _RowMetrics.padding,
              child: Row(
                children: [
                  SizedBox(
                    width: _RowMetrics.iconSlot,
                    child: Icon(
                      Icons.currency_exchange_rounded,
                      size: _RowMetrics.iconSize,
                      color: palette.textSecondary,
                    ),
                  ),
                  SizedBox(width: _RowMetrics.gap),
                  Expanded(
                    child: _RowCopy(
                      title: rates.attributionLabel,
                      subtitle: date.isEmpty
                          ? 'Currency rates refresh automatically'
                          : 'Currency rates refreshed $date',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new_rounded,
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
          padding: _RowMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  Icons.info_outline_rounded,
                  size: _RowMetrics.iconSize,
                  color: palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(
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

/// The only place the update state is spelled out.
///
/// Nothing here downloads anything: the row reports what the daily manifest
/// check found, and the button is the click that hands over to Sparkle or
/// WinSparkle. Until it is pressed, no release has been fetched.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow({required this.updates, this.desktop});

  final UpdateChecker updates;

  /// Null on the platforms with no window to speak of. Only the pin is wanted
  /// from it: see [_runAction].
  final DesktopIntegration? desktop;

  /// A check that has never reached the manifest may not claim anything, so
  /// the untouched state offers the check instead of asserting a verdict.
  String _title() {
    final available = updates.available;
    if (available != null) return 'Version ${available.version} available';
    if (updates.isChecking) return 'Checking for updates';
    return updates.lastChecked == null ? 'Check for updates' : 'Up to date';
  }

  String _subtitle() {
    if (updates.isInstalling) return 'Opening the updater';
    final available = updates.available;
    if (available != null) {
      final current = updates.currentVersion;
      return current.isEmpty
          ? 'Ready to install'
          : 'Ready to install · you have $current';
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
      icon: Icons.error_outline_rounded,
      isError: true,
    );
  }

  Future<void> _runAction(BuildContext context) async {
    final installing = updates.available != null;
    // Sparkle and WinSparkle both put their panel up at the ordinary window
    // level, so a window kept on top covers it: the button would report an
    // updater the user never sees. Give the pin up first — and say so, since
    // the toolbar button that would otherwise show it is behind this sheet.
    // Only for the install; a check opens nothing and touches no window.
    final unpinned =
        installing && (await desktop?.releaseAlwaysOnTop() ?? false);
    if (!context.mounted) return;
    final progress = Toast.showProgress(
      context,
      installing ? 'Opening the updater…' : 'Checking for updates…',
    );
    final succeeded = installing
        ? await updates.startInstall()
        : await updates.check();
    if (!context.mounted) {
      progress.dismiss();
      return;
    }
    if (!succeeded) {
      progress.error(
        installing
            ? 'Could not open the updater'
            : 'Could not check for updates',
      );
      return;
    }
    progress.success(
      installing
          ? unpinned
                ? 'Updater opened · window no longer on top'
                : 'Updater opened'
          : updates.hasUpdate
          ? 'Update available'
          : 'Kapy Notes is up to date',
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final available = updates.available;
        final busy = updates.isChecking || updates.isInstalling;
        return Padding(
          padding: _RowMetrics.padding,
          child: Row(
            children: [
              SizedBox(
                width: _RowMetrics.iconSlot,
                child: Icon(
                  available != null
                      ? Icons.system_update_alt_rounded
                      : Icons.verified_outlined,
                  size: _RowMetrics.iconSize,
                  color: available != null
                      ? palette.chipCurrency
                      : palette.textSecondary,
                ),
              ),
              SizedBox(width: _RowMetrics.gap),
              Expanded(
                child: _RowCopy(title: _title(), subtitle: _subtitle()),
              ),
              if (available != null && available.notesUrl.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('update-release-notes'),
                  onPressed: () => _openNotes(context),
                  icon: const Icon(Icons.open_in_new_rounded, size: 15),
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
                  backgroundColor: available != null
                      ? palette.selectedBackground
                      : palette.controlBackground,
                  foregroundColor: palette.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                child: Text(
                  available != null ? 'Update' : 'Check',
                  style: const TextStyle(
                    fontSize: 11.5,
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

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.action,
    required this.binding,
    required this.onPressed,
  });

  final ShortcutAction action;

  /// Null where the user has cleared it. The row stays, because it is also
  /// how the shortcut is given back.
  final ShortcutBinding? binding;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 8, 9, 8),
      child: Row(
        children: [
          Expanded(
            child: _RowCopy(title: action.label, subtitle: action.description),
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
                fontSize: 11.5,
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

class _RowCopy extends StatelessWidget {
  const _RowCopy({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: _RowMetrics.titleSize,
            fontWeight: _settingsMediumWeight,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: _RowMetrics.subtitleSize,
            color: palette.textSecondary,
          ),
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
                trailing: Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
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
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search cities or regions',
                prefixIcon: const Icon(Icons.search_rounded, size: 16),
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
                child: _RowCopy(
                  title: AppTimeZones.displayName(locationId),
                  subtitle: locationId == null
                      ? 'Follow this device · ${AppTimeZones.offsetLabel(null)}'
                      : AppTimeZones.offsetLabel(locationId),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
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
                    Icon(
                      Icons.keyboard_rounded,
                      size: 21,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      'Press your new shortcut',
                      style: TextStyle(
                        fontSize: 13,
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
                        fontSize: 11.5,
                        color: palette.textTertiary,
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
                    fontSize: 11.5,
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
