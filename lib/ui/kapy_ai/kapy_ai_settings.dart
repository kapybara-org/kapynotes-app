import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/theme.dart';
import '../context_menu.dart';
import '../settings_rows.dart';
import 'kapy_ai_parts.dart';

/// The rows of Settings › Voice & AI that are more than a title and a button:
/// the default model's menu and each of Your accounts (kapy-ai-9/10/11).

/// The key of an account's row, which "Manage accounts…" scrolls to.
String kapyAccountRowId(KapyAccountKind kind) => 'kapy-account-${kind.name}';

/// What the default model is called in Settings: the on-device one is "On
/// this device", whichever model that is here.
String kapyDefaultModelLabel(KapyModel model) => model.plainLabel;

/// What a new chat can start with: this device's model, Kapy AI Cloud on
/// Pro, and every model of a connected account Kapy may use.
List<KapyModel> kapyDefaultModelOptions(KapyAi kapyAi) => [
  if (kapyAi.device case DeviceModelState(
    :final model?,
    status: != DeviceModelStatus.unavailable,
  ))
    model,
  if (kapyAi.isPro) KapyModel.cloud,
  for (final account in kapyAi.accounts)
    if (account.status == KapyAccountStatus.connected &&
        (account.enabled || account.kind == KapyAccountKind.openRouter))
      ...account.models,
];

/// The on-device row's line: which model, and where its download stands.
String? kapyDeviceModelLine(DeviceModelState device) {
  final model = device.model;
  if (model == null) return null;
  final word = kapyDeviceWord;
  final size = kapyGigabytes(device.totalBytes);
  return switch (device.status) {
    DeviceModelStatus.builtIn => '${model.plainLabel} · built in',
    DeviceModelStatus.ready =>
      '$size GB on this $word. Answers stay on this $word',
    DeviceModelStatus.notDownloaded =>
      'A one-time $size GB download. Answers stay on this $word',
    DeviceModelStatus.downloading =>
      '${kapyGigabytes(device.receivedBytes)} of $size GB',
    DeviceModelStatus.needsSystemFeature =>
      '${model.plainLabel} · turn it on in System Settings',
    DeviceModelStatus.unavailable => null,
  };
}

/// The on-device row's control: Download, Remove, or Cancel beside the pie.
Widget? kapyDeviceModelControl(KapyAi kapyAi) {
  final device = kapyAi.device;
  return switch (device.status) {
    DeviceModelStatus.notDownloaded => SettingsRowButton(
      key: const ValueKey('kapy-device-download'),
      label: 'Download',
      onPressed: kapyAi.downloadDeviceModel,
    ),
    DeviceModelStatus.ready => SettingsRowButton(
      key: const ValueKey('kapy-device-remove'),
      label: 'Remove',
      onPressed: () => unawaited(kapyAi.removeDeviceModel()),
    ),
    DeviceModelStatus.downloading => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsPie(
          fraction: device.totalBytes == 0
              ? null
              : device.receivedBytes / device.totalBytes,
        ),
        const SizedBox(width: 8),
        SettingsRowButton(
          key: const ValueKey('kapy-device-cancel'),
          label: 'Cancel',
          onPressed: kapyAi.cancelDeviceDownload,
        ),
      ],
    ),
    _ => null,
  };
}

/// The default model, and the menu of what else a new chat could start with.
class KapyDefaultModelButton extends StatelessWidget {
  const KapyDefaultModelButton({super.key, required this.kapyAi});

  final KapyAi kapyAi;

  Future<void> _choose(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final options = kapyDefaultModelOptions(kapyAi);
    if (box == null || options.isEmpty) return;
    final palette = context.palette;
    final chosen = await showKapyContextMenu<KapyModel>(
      context: context,
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
      items: [
        for (final model in options)
          PopupMenuItem(
            key: ValueKey('kapy-default-${model.kind.name}-${model.id}'),
            value: model,
            height: 34,
            child: Row(
              children: [
                KapyIcon(
                  kapyModelIcon(model.kind),
                  size: 14,
                  strokeWidth: 1.8,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    kapyChoiceLabel(model, options),
                    style: kapyText(13, 16, palette.textPrimary),
                  ),
                ),
                if (model == kapyAi.defaultModel)
                  KapyIcon(
                    KapyIcons.checkRounded,
                    size: 14,
                    strokeWidth: 1.8,
                    color: palette.accentText,
                  ),
              ],
            ),
          ),
      ],
    );
    if (chosen != null) kapyAi.defaultModel = chosen;
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (buttonContext) => SettingsMenuButton(
      key: const ValueKey('kapy-default-model-menu'),
      label: kapyDefaultModelLabel(kapyAi.defaultModel),
      onPressed: () => unawaited(_choose(buttonContext)),
    ),
  );
}

/// An account's line in Settings, said the same in the row and in a search.
String kapyAccountLine(KapyAccountState account) {
  final word = kapyDeviceWord;
  final name = kapyAccountName(account.kind);
  final models = [
    for (final model in account.models) kapyChoiceLabel(model, account.models),
  ].join(', ');
  return switch ((account.kind, account.status)) {
    (KapyAccountKind.openRouter, KapyAccountStatus.connected) =>
      'Key ending ${_lastFour(account.detail)}, kept on this $word',
    (KapyAccountKind.openRouter, KapyAccountStatus.error) =>
      'This key was rejected',
    (KapyAccountKind.openRouter, _) =>
      'Your own key, for answers you already pay for',
    (_, KapyAccountStatus.connected) => [
      'Found on this $word',
      if (models.isNotEmpty) models,
    ].join(' · '),
    (_, KapyAccountStatus.error) =>
      'Signed out. Sign in inside $name, then check again',
    _ => 'Install $name and sign in there. Kapy finds it',
  };
}

/// Only ever the end of a key, whatever was handed over.
String _lastFour(String? detail) {
  final end = detail ?? '';
  return end.substring(math.max(0, end.length - 4));
}

/// One of Your accounts, in each of its states.
///
/// Codex and Claude Code are found rather than signed in to: Kapy runs the
/// copy already installed and signed in on this computer, never sees a
/// password or a token, and its switch only says whether Kapy may use it.
/// OpenRouter takes a key, typed into a masked field that is emptied as soon
/// as Save has handed it over, and is only ever shown again as its last four
/// characters.
class KapyAccountRow extends StatefulWidget {
  const KapyAccountRow({
    super.key,
    required this.kapyAi,
    required this.account,
  });

  final KapyAi kapyAi;
  final KapyAccountState account;

  @override
  State<KapyAccountRow> createState() => _KapyAccountRowState();
}

class _KapyAccountRowState extends State<KapyAccountRow> {
  final _key = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  /// OpenRouter turned the last key down, until another is tried.
  bool _rejected = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    if (key.isEmpty || _saving) return;
    setState(() => _saving = true);
    final saved = await widget.kapyAi.saveOpenRouterKey(key);
    _key.clear();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = false;
      _rejected = !saved;
    });
  }

  void _edit() => setState(() {
    _editing = true;
    _rejected = false;
  });

  @override
  Widget build(BuildContext context) {
    final ai = widget.kapyAi;
    final account = widget.account;
    final kind = account.kind;
    final name = kapyAccountName(kind);
    if (_editing) return _keyField();
    final error = account.status == KapyAccountStatus.error || _rejected;
    final line = _rejected ? 'This key was rejected' : kapyAccountLine(account);

    if (kind != KapyAccountKind.openRouter &&
        account.status == KapyAccountStatus.connected) {
      return SettingsToggleRow(
        title: name,
        subtitle: line,
        value: account.enabled,
        onChanged: kind == KapyAccountKind.codex
            ? ai.allowCodex
            : ai.allowClaudeCode,
      );
    }

    final control = switch (kind) {
      KapyAccountKind.openRouter => switch (account.status) {
        _ when error => SettingsRowButton(
          label: 'Replace key',
          onPressed: _edit,
        ),
        KapyAccountStatus.connected => SettingsRowButton(
          label: 'Remove',
          onPressed: () => unawaited(ai.removeOpenRouterKey()),
        ),
        _ => SettingsRowButton(label: 'Add key', onPressed: _edit),
      },
      KapyAccountKind.codex => SettingsRowButton(
        label: 'Check again',
        onPressed: account.status == KapyAccountStatus.connecting
            ? null
            : () => unawaited(ai.checkCodex()),
      ),
      KapyAccountKind.claudeCode => SettingsRowButton(
        label: 'Check again',
        onPressed: account.status == KapyAccountStatus.connecting
            ? null
            : () => unawaited(ai.checkClaudeCode()),
      ),
    };
    if (!error) {
      return SettingsRow(title: name, subtitle: line, trailing: control);
    }
    final palette = context.palette;
    return Container(
      constraints: BoxConstraints(minHeight: SettingsMetrics.minRowHeight),
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SettingsRowCopy(title: name),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1, right: 6),
                      child: KapyIcon(
                        KapyIcons.warningRounded,
                        size: 13,
                        strokeWidth: 1.8,
                        color: palette.kapyRed,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        line,
                        style: TextStyle(
                          fontSize: SettingsMetrics.subtitleSize,
                          height: 16 / SettingsMetrics.subtitleSize,
                          color: palette.kapyRed,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: SettingsMetrics.gap),
          control,
        ],
      ),
    );
  }

  Widget _keyField() {
    final palette = context.palette;
    return Padding(
      key: const ValueKey('kapy-openrouter-key-form'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRowCopy(title: kapyAccountName(widget.account.kind)),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('kapy-openrouter-key-field'),
            controller: _key,
            autofocus: true,
            obscureText: true,
            obscuringCharacter: '•',
            enableSuggestions: false,
            autocorrect: false,
            enabled: !_saving,
            cursorColor: palette.selectedBorder,
            style: TextStyle(
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
              fontSize: 13,
              color: palette.textPrimary,
            ),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'sk-or-…',
              hintStyle: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 13,
                color: palette.textTertiary,
              ),
              filled: true,
              fillColor: palette.editorBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
                borderSide: BorderSide(color: palette.separator),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.control),
                borderSide: BorderSide(
                  color: palette.selectedBorder,
                  width: 1.5,
                ),
              ),
            ),
            onSubmitted: (_) => unawaited(_save()),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Kept in your Keychain on this device, never synced',
                  style: kapyText(12, 16, palette.textTertiary),
                ),
              ),
              const SizedBox(width: 10),
              KapyAiButton(
                'Cancel',
                onPressed: _saving
                    ? null
                    : () {
                        _key.clear();
                        setState(() => _editing = false);
                      },
              ),
              const SizedBox(width: 8),
              KapyAiButton(
                _saving ? 'Checking…' : 'Save',
                key: const ValueKey('kapy-openrouter-save'),
                filled: true,
                onPressed: _saving ? null : () => unawaited(_save()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
