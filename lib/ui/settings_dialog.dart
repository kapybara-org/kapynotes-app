import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/desktop_integration.dart';
import '../core/editor_font.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/layout_prefs.dart';
import '../data/rates.dart';
import '../data/shortcut_prefs.dart';
import '../data/update_checker.dart';
import '../data/time_zones.dart';

/// The groups of settings, one per rail entry.
///
/// Adding a section is meant to be the whole job of adding a category of
/// options: name it here, give it a pane in [_SettingsDialogState], and both
/// layouts pick it up.
enum SettingsSection { general, appearance, numbers, shortcuts, updates }

const _settingsRowPadding = EdgeInsets.fromLTRB(11, 8, 10, 8);
const _settingsRegularWeight = FontWeight.w400;
const _settingsMediumWeight = FontWeight.w500;
const _settingsSemiboldWeight = FontWeight.w600;

extension SettingsSectionCopy on SettingsSection {
  String get label => switch (this) {
    SettingsSection.general => 'General',
    SettingsSection.appearance => 'Appearance',
    SettingsSection.numbers => 'Numbers',
    SettingsSection.shortcuts => 'Shortcuts',
    SettingsSection.updates => 'Updates',
  };

  IconData get icon => switch (this) {
    SettingsSection.general => Icons.tune_rounded,
    SettingsSection.appearance => Icons.auto_stories_outlined,
    SettingsSection.numbers => Icons.numbers_rounded,
    SettingsSection.shortcuts => Icons.keyboard_outlined,
    SettingsSection.updates => Icons.system_update_alt_rounded,
  };
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.layoutPrefs,
    required this.shortcuts,
    required this.rates,
    this.updates,
    this.desktopIntegration,
  });

  final LayoutPrefs layoutPrefs;
  final ShortcutPrefs shortcuts;
  final RatesRepository rates;
  final UpdateChecker? updates;
  final DesktopIntegration? desktopIntegration;

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
  SettingsSection _section = SettingsSection.general;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _shortcutError = widget.desktopIntegration?.registrationError;
    // The gear that opened this is badged when a release is waiting, so open
    // on the pane that badge is about rather than making it be hunted for.
    if (widget.updates?.hasUpdate ?? false) _section = SettingsSection.updates;
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
    _ => true,
  };

  List<SettingsSection> get _sections =>
      SettingsSection.values.where(_isAvailable).toList();

  void _showSection(SettingsSection section) {
    if (section == _section) return;
    setState(() => _section = section);
    // A pane the user has not seen should start at its top, not wherever the
    // previous one was scrolled to.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Future<void> _recordShortcut(ShortcutAction action) async {
    final candidate = await showDialog<ShortcutBinding>(
      context: context,
      builder: (context) => _ShortcutRecorderDialog(
        action: action,
        current: widget.shortcuts.bindingFor(action),
      ),
    );
    if (candidate == null || candidate == widget.shortcuts.bindingFor(action)) {
      return;
    }

    final conflict = widget.shortcuts.conflictFor(action, candidate);
    if (conflict != null) {
      setState(() {
        _shortcutError =
            '${candidate.displayLabel} is already used for ${conflict.label.toLowerCase()}.';
      });
      return;
    }

    if (action == ShortcutAction.openApp && widget.desktopIntegration != null) {
      final error = await widget.desktopIntegration!.tryOpenShortcut(candidate);
      if (!mounted) return;
      if (error != null) {
        setState(() => _shortcutError = error);
        return;
      }
    }

    widget.shortcuts.update(action, candidate);
    if (mounted) setState(() => _shortcutError = null);
  }

  Future<void> _restoreShortcutDefaults() async {
    final openDefault = ShortcutPrefs.defaultFor(ShortcutAction.openApp);
    if (widget.desktopIntegration != null) {
      final error = await widget.desktopIntegration!.tryOpenShortcut(
        openDefault,
      );
      if (!mounted) return;
      if (error != null) {
        setState(() => _shortcutError = error);
        return;
      }
    }
    widget.shortcuts.resetAll();
    if (mounted) setState(() => _shortcutError = null);
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.layoutPrefs,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.shortcuts,
        builder: (context, _) {
          final media = MediaQuery.sizeOf(context);
          final available = media.width - 80;
          final paned = available >= _railBreakpoint;
          final width = math.min(
            paned ? _panedWidth : _stackedWidth,
            available,
          );
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
        },
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
    SettingsSection.appearance => _appearancePane(),
    SettingsSection.numbers => _numbersPane(),
    SettingsSection.shortcuts => _shortcutsPane(),
    SettingsSection.updates => _updatesPane(),
  };

  List<Widget> _generalPane() => [
    const _SectionLabel('NOTES'),
    _SettingsGroup(
      children: [
        _ToggleRow(
          key: const ValueKey('daily-separators-toggle'),
          icon: Icons.calendar_today_outlined,
          title: 'Daily separators',
          subtitle: 'Start each session and new day on a dated line',
          value: widget.layoutPrefs.dailySeparatorsEnabled,
          onChanged: (value) =>
              widget.layoutPrefs.dailySeparatorsEnabled = value,
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
      const _SectionLabel('WINDOW'),
      _WideButton(
        onPressed: widget.layoutPrefs.resetPanelWidths,
        icon: Icons.restart_alt_rounded,
        label: 'Reset panel widths',
      ),
    ],
  ];

  List<Widget> _appearancePane() => [
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
            selected: widget.layoutPrefs.writingFont == font,
            onTap: () => widget.layoutPrefs.writingFont = font,
          ),
      ],
    ),
    const SizedBox(height: 18),
    const _SectionLabel('PAPER'),
    _PaperDescription(),
  ];

  List<Widget> _numbersPane() => [
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

  /// App shortcuts lead: they reach the window from anywhere and are the ones
  /// people come here to change. The formatting keys below them are already
  /// spelled out on every footer button.
  List<Widget> _shortcutsPane() => [
    Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 9),
      child: Text(
        'Select a shortcut, then press a new combination. Menus and footer hints update immediately.',
        style: TextStyle(fontSize: 11.5, color: context.palette.textTertiary),
      ),
    ),
    const _SectionLabel('APP'),
    _SettingsGroup(
      children: [
        for (final action in ShortcutAction.values.where(
          (action) => !action.isFormatting,
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
      _SettingsGroup(children: [_UpdateRow(updates: updates)]),
    ];
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
                  indent: 48,
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
          padding: _settingsRowPadding,
          child: Row(
            children: [
              SizedBox(
                width: 25,
                child: Icon(icon, size: 16, color: palette.textSecondary),
              ),
              const SizedBox(width: 9),
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
      width: 34,
      height: 18,
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
          child: const SizedBox.square(dimension: 14),
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
          padding: _settingsRowPadding,
          child: Row(
            children: [
              SizedBox(
                width: 25,
                child: Icon(icon, size: 16, color: palette.textSecondary),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: palette.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One option in a mutually exclusive group, with a live sample of what
/// picking it does.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.trailingStyle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final TextStyle? trailingStyle;
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
          padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
          child: Row(
            children: [
              SizedBox(
                width: 25,
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: selected ? accent : palette.textTertiary,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: _RowCopy(title: title, subtitle: subtitle),
              ),
              const SizedBox(width: 10),
              Text(
                trailing,
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

class _PaperDescription extends StatelessWidget {
  const _PaperDescription();

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
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
        child: Row(
          children: [
            SizedBox(
              width: 25,
              child: Icon(
                Icons.texture_rounded,
                size: 16,
                color: palette.textSecondary,
              ),
            ),
            const SizedBox(width: 9),
            const Expanded(
              child: _RowCopy(
                title: 'Notepad paper',
                subtitle: 'Warm paper grain with a quiet ink-like palette',
              ),
            ),
          ],
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
              padding: _settingsRowPadding,
              child: Row(
                children: [
                  SizedBox(
                    width: 25,
                    child: Icon(
                      Icons.currency_exchange_rounded,
                      size: 16,
                      color: palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 9),
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
          padding: _settingsRowPadding,
          child: Row(
            children: [
              SizedBox(
                width: 25,
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(width: 9),
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
  const _UpdateRow({required this.updates});

  final UpdateChecker updates;

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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final available = updates.available;
        final busy = updates.isChecking || updates.isInstalling;
        return Padding(
          padding: _settingsRowPadding,
          child: Row(
            children: [
              SizedBox(
                width: 25,
                child: Icon(
                  available != null
                      ? Icons.system_update_alt_rounded
                      : Icons.verified_outlined,
                  size: 16,
                  color: available != null
                      ? palette.chipCurrency
                      : palette.textSecondary,
                ),
              ),
              const SizedBox(width: 9),
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
                onPressed: busy
                    ? null
                    : available != null
                    ? updates.startInstall
                    : updates.check,
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
  final ShortcutBinding binding;
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
              binding.displayLabel,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: _settingsMediumWeight,
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
            fontSize: 12.5,
            fontWeight: _settingsMediumWeight,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(fontSize: 10.75, color: palette.textSecondary),
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

class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog({required this.action, required this.current});

  final ShortcutAction action;
  final ShortcutBinding current;

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog> {
  String? _error;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_isModifier(event.logicalKey)) return KeyEventResult.handled;

    final keyboard = HardwareKeyboard.instance;
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

    Navigator.of(context).pop(binding);
    return KeyEventResult.handled;
  }

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
                      'Current: ${widget.current.displayLabel}',
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
