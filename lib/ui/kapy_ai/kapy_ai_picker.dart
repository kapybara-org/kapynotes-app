import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/theme.dart';
import 'kapy_ai_parts.dart';

/// The model picker over the composer (kapy-ai-5/6): On this device, Kapy AI
/// and Your accounts. The pick sticks to the chat.
class KapyAiPicker extends StatelessWidget {
  const KapyAiPicker({
    super.key,
    required this.kapyAi,
    required this.onPick,
    required this.onManageAccounts,
  });

  final KapyAi kapyAi;
  final ValueChanged<KapyModel> onPick;

  /// Settings › Voice & AI at Your accounts: where an OpenRouter key goes
  /// in, and where every account is looked after.
  final VoidCallback onManageAccounts;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final ai = kapyAi;
    final word = kapyDeviceWord;
    final selected = ai.model;
    final device = ai.device;
    final deviceModel = device.model;
    final usage = ai.cloudUsage;
    final accounts = [...ai.accounts]
      ..sort((a, b) => a.kind.index.compareTo(b.kind.index));

    _Row modelRow(KapyModel model, String subline) => _Row(
      key: ValueKey('kapy-ai-model-${model.kind.name}-${model.id}'),
      icon: kapyModelIcon(model.kind),
      title: model.label,
      subline: subline,
      selected: model == selected,
      onTap: () => onPick(model),
    );

    final accountRows = <_Row>[];
    var connectRows = 0;
    for (final account in accounts) {
      final kind = account.kind;
      if (account.status == KapyAccountStatus.connected) {
        if (kind != KapyAccountKind.openRouter && !account.enabled) continue;
        for (final model in account.models) {
          accountRows.add(modelRow(model, model.whereItRuns(word)));
        }
        continue;
      }
      connectRows++;
      accountRows.add(
        _Row(
          key: ValueKey('kapy-ai-connect-${kind.name}'),
          icon: kapyAccountIcon(kind),
          title: switch (kind) {
            KapyAccountKind.openRouter => 'Add an OpenRouter key',
            _ => 'Use ${kapyAccountName(kind)}',
          },
          subline: switch (kind) {
            KapyAccountKind.openRouter => 'Any model, billed to your key',
            _ => 'Install it and sign in there first',
          },
          chevron: true,
          onTap: onManageAccounts,
        ),
      );
    }

    final groups = <List<Widget>>[
      [
        const _Label('On this device'),
        switch (device.status) {
          _
              when deviceModel == null ||
                  device.status == DeviceModelStatus.unavailable =>
            _Row(
              key: const ValueKey('kapy-ai-model-device-none'),
              icon: KapyIcons.computerOutlined,
              title: 'On-device model',
              subline: 'This $word can’t run one',
            ),
          DeviceModelStatus.needsSystemFeature => _Row(
            key: ValueKey('kapy-ai-model-device-${deviceModel.id}'),
            icon: KapyIcons.computerOutlined,
            title: deviceModel.label,
            subline: 'Turn it on in System Settings first',
          ),
          _ => modelRow(deviceModel, deviceModel.whereItRuns(word)),
        },
      ],
      [
        const _Label('Kapy AI'),
        ai.isPro
            ? modelRow(
                KapyModel.cloud,
                usage == null
                    ? 'Answers through Kapy’s server'
                    : '${usage.remaining} of ${usage.limit} answers left this month',
              )
            : _Row(
                key: const ValueKey('kapy-ai-model-cloud-cloud'),
                icon: KapyIcons.cloudRounded,
                title: KapyModel.cloud.label,
                trailing: 'Part of Pro',
              ),
      ],
      if (accountRows.isNotEmpty)
        [const _Label('Your accounts'), ...accountRows],
      // Only once every account is connected: until then each connect row
      // is already the way in.
      if (accounts.isNotEmpty && connectRows == 0)
        [
          _Row(
            key: const ValueKey('kapy-ai-manage-accounts'),
            title: 'Manage accounts…',
            chevron: true,
            compact: true,
            onTap: onManageAccounts,
          ),
        ],
    ];

    return Container(
      key: const ValueKey('kapy-ai-picker'),
      decoration: BoxDecoration(
        color: palette.kapyMenu,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: palette.shadowAt(0x80),
            offset: const Offset(0, 16),
            blurRadius: 32,
            spreadRadius: -16,
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in groups) ...[
              if (group != groups.first)
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  color: palette.separator,
                ),
              for (final row in group)
                Padding(padding: const EdgeInsets.only(bottom: 1), child: row),
            ],
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 3),
    child: Text(
      text.toUpperCase(),
      style: kapyText(
        11,
        14,
        context.palette.textTertiary,
        weight: FontWeight.w600,
      ).copyWith(letterSpacing: 0.44),
    ),
  );
}

/// One row: a model to pick, a dimmed one that cannot be, or a way in.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.title,
    this.icon,
    this.subline,
    this.trailing,
    this.selected = false,
    this.chevron = false,
    this.compact = false,
    this.onTap,
  });

  final KapyIconData? icon;
  final String title;
  final String? subline;

  /// Said quietly at the end of a dimmed row: "Part of Pro".
  final String? trailing;
  final bool selected;
  final bool chevron;
  final bool compact;

  /// Null dims the row: there is nothing to pick.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = onTap != null;
    final icon = this.icon;
    final subline = this.subline;
    final trailing = this.trailing;
    return Material(
      color: selected ? palette.kapyHighlight : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        hoverColor: palette.kapyHighlight,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: compact ? 32 : 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                if (icon != null) ...[
                  KapyIcon(
                    icon,
                    size: 15,
                    strokeWidth: 1.8,
                    color: enabled
                        ? palette.textSecondary
                        : palette.textTertiary,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kapyText(
                          13,
                          16,
                          enabled ? palette.textPrimary : palette.textTertiary,
                          weight: FontWeight.w600,
                        ),
                      ),
                      if (subline != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          subline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kapyText(11.5, 16, palette.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing,
                    style: kapyText(
                      12,
                      16,
                      palette.textTertiary,
                      weight: FontWeight.w500,
                    ),
                  ),
                if (selected)
                  KapyIcon(
                    KapyIcons.checkRounded,
                    size: 14,
                    strokeWidth: 1.8,
                    color: palette.accentText,
                  ),
                if (chevron)
                  KapyIcon(
                    KapyIcons.chevronRightRounded,
                    size: 13,
                    strokeWidth: 1.8,
                    color: palette.textTertiary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer's model button: the model this chat answers with, and the
/// way to the picker.
class KapyAiModelButton extends StatelessWidget {
  const KapyAiModelButton({
    super.key,
    required this.kapyAi,
    required this.open,
    required this.onPressed,
  });

  final KapyAi kapyAi;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final model = kapyAi.model;
    final spent =
        model.kind == KapyModelKind.cloud && kapyAi.cloudUsage?.remaining == 0;
    return Material(
      color: open ? palette.kapyHighlight : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('kapy-ai-model-button'),
        hoverColor: palette.kapyHighlight,
        onTap: onPressed,
        child: SizedBox(
          height: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KapyIcon(
                  kapyModelIcon(model.kind),
                  size: 14,
                  strokeWidth: 1.8,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    spent ? '${model.label} · 0 left' : model.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kapyText(
                      12.5,
                      16,
                      palette.textSecondary,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                KapyIcon(
                  KapyIcons.chevronDownRounded,
                  size: 12,
                  strokeWidth: 1.8,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
