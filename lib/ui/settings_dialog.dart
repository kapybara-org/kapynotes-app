import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/desktop_integration.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/layout_prefs.dart';
import '../data/shortcut_prefs.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.layoutPrefs,
    required this.shortcuts,
    this.desktopIntegration,
  });

  final LayoutPrefs layoutPrefs;
  final ShortcutPrefs shortcuts;
  final DesktopIntegration? desktopIntegration;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  String? _shortcutError;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _shortcutError = widget.desktopIntegration?.registrationError;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.layoutPrefs,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.shortcuts,
        builder: (context, _) {
          final availableHeight = MediaQuery.sizeOf(context).height - 170;
          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
            contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            title: const Text('Settings'),
            content: SizedBox(
              width: 410,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: availableHeight.clamp(260, 520),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: AppPlatform.hasPointer,
                  thickness: 3,
                  radius: const Radius.circular(999),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(right: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SectionLabel('NOTES'),
                        _SettingsGroup(
                          children: [
                            _ToggleRow(
                              key: const ValueKey('daily-separators-toggle'),
                              icon: Icons.calendar_today_outlined,
                              title: 'Daily separators',
                              subtitle:
                                  'Start each session and new day on a dated line',
                              value: widget.layoutPrefs.dailySeparatorsEnabled,
                              onChanged: (value) =>
                                  widget.layoutPrefs.dailySeparatorsEnabled =
                                      value,
                            ),
                            if (AppPlatform.isDesktop)
                              _ToggleRow(
                                key: const ValueKey('sidebar-toggle'),
                                icon: Icons.view_sidebar_outlined,
                                title: 'Desktop sidebar',
                                subtitle:
                                    'Show notes beside wider editor windows',
                                value: widget.layoutPrefs.sidebarVisible,
                                onChanged: (_) =>
                                    widget.layoutPrefs.toggleSidebar(),
                              ),
                          ],
                        ),
                        if (AppPlatform.isDesktop) ...[
                          const SizedBox(height: 18),
                          const _SectionLabel('KEYBOARD SHORTCUTS'),
                          Text(
                            'Select a shortcut, then press a new combination.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: context.palette.textTertiary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _SettingsGroup(
                            children: [
                              for (final action in ShortcutAction.values)
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _restoreShortcutDefaults,
                              child: const Text('Restore shortcut defaults'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            onPressed: widget.layoutPrefs.resetPanelWidths,
                            icon: const Icon(
                              Icons.restart_alt_rounded,
                              size: 17,
                            ),
                            label: const Text('Reset panel widths'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size.fromHeight(40),
                              backgroundColor:
                                  context.palette.controlBackground,
                              foregroundColor: context.palette.textSecondary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
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
        fontWeight: FontWeight.w600,
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
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 9, 10),
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
          Switch(value: value, onChanged: onChanged),
        ],
      ),
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
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(
              binding.displayLabel,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
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
            fontWeight: FontWeight.w600,
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
        title: Text('Set ${widget.action.label.toLowerCase()}'),
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
                  borderRadius: BorderRadius.circular(14),
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
                        fontWeight: FontWeight.w600,
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
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
