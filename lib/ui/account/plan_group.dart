import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../billing/billing.dart';
import '../../billing/entitlements.dart';
import '../../core/theme.dart';
import '../../speech/cloud_access.dart';
import '../../sync/account.dart';
import '../billing/pro_sheet.dart';
import '../settings_rows.dart';

/// The plan, and what of it is used: one row for the plan with the way to Pro,
/// and one per allowance this account can spend.
///
/// The cloud allowances show only where the cloud is open to this account, so
/// a free plan that runs everything on the device is not shown minutes it
/// cannot use.
class PlanGroup extends StatelessWidget {
  const PlanGroup({super.key, required this.account, this.cloudAccess});

  final Account account;
  final CloudAccess? cloudAccess;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: account,
    builder: (context, _) {
      final billing = account.billing;
      return ListenableBuilder(
        listenable: Listenable.merge([billing, cloudAccess]),
        builder: (context, _) => _contents(context, billing),
      );
    },
  );

  Widget _contents(BuildContext context, Billing? billing) {
    final current = billing?.entitlements;
    final failed = billing?.refreshFailed ?? false;
    final trialDays = (billing?.trialRunning ?? false)
        ? billing?.trialDaysLeft
        : null;
    final (title, subtitle) = switch ((current, trialDays)) {
      (_, 1) => (
        'Pro trial',
        'Ends today. Then sync, sharing and cloud voice stop',
      ),
      (_, final int days) => (
        'Pro trial',
        'Ends in $days days. Then sync, sharing and cloud voice stop',
      ),
      (final Entitlements value, _) when value.isPro => (
        'Pro',
        'Lifetime. Voice notes and summaries can run in the cloud',
      ),
      (Entitlements(), _) => (
        'Free plan',
        'Voice notes run on this device. Pro runs them in the cloud',
      ),
      _ when failed => ('Plan unavailable', 'Could not reach the server'),
      _ => ('Checking your plan', 'Loading plan and usage'),
    };
    final buysPro =
        billing != null &&
        billing.canPurchase &&
        current != null &&
        (!current.isPro || trialDays != null);
    final usage = current == null
        ? const <Widget>[]
        : [
            if (cloudAccess?.cloudTranscriptionAllowed ?? true)
              SettingsRow(
                key: const ValueKey('plan-transcription-usage'),
                title: 'Cloud transcription',
                subtitle: current.speechCreditSeconds > 0
                    ? '${_resetLine(current.speechResetsAt)} · '
                          '${_minutes(current.speechCreditSeconds)} min extra'
                    : _resetLine(current.speechResetsAt),
                trailing: _Usage(
                  used: current.speechSecondsUsedThisMonth,
                  limit: current.speechSecondsPerMonth,
                  label:
                      '${_minutes(current.speechSecondsUsedThisMonth)} / '
                      '${_minutes(current.speechSecondsPerMonth)} min',
                ),
              ),
            if (cloudAccess?.cloudSummariesAllowed ?? true)
              SettingsRow(
                key: const ValueKey('plan-summary-usage'),
                title: 'Cloud summaries',
                subtitle:
                    '${_resetLine(current.speechResetsAt)}. '
                    'Rewrites count too',
                trailing: _Usage(
                  used: current.summaryGenerationsUsedThisMonth,
                  limit: current.summaryGenerationsPerMonth,
                  label:
                      '${_count(current.summaryGenerationsUsedThisMonth)} / '
                      '${_count(current.summaryGenerationsPerMonth)}',
                ),
              ),
            SettingsRow(
              key: const ValueKey('plan-storage-usage'),
              title: 'Storage',
              subtitle: 'Synced notes, pictures and recordings',
              trailing: _Usage(
                used: current.storageUsedBytes,
                limit: current.storageBytes,
                label: _bytes(current.storageUsedBytes, current.storageBytes),
              ),
            ),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsLabel('Plan'),
        SettingsGroup(
          children: [
            SettingsRow(
              key: const ValueKey('plan-current'),
              title: title,
              subtitle: failed && current != null
                  ? 'Showing your last saved plan'
                  : subtitle,
              trailing: failed
                  ? SettingsRowButton(
                      key: const ValueKey('plan-refresh'),
                      label: 'Try again',
                      onPressed: billing!.refreshing
                          ? null
                          : () => unawaited(billing.refresh()),
                    )
                  : buysPro
                  ? SettingsRowButton(
                      key: const ValueKey('plan-get-pro'),
                      label: 'Get Pro',
                      prominent: true,
                      onPressed: () =>
                          unawaited(showProSheet(context, billing: billing)),
                    )
                  : null,
            ),
            ...usage,
          ],
        ),
      ],
    );
  }

  static String _minutes(int seconds) {
    final minutes = seconds / 60;
    return minutes == minutes.roundToDouble()
        ? '${minutes.round()}'
        : minutes.toStringAsFixed(1);
  }

  static String _count(int value) => value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );

  /// Both sides in the limit's unit, said once: "1.2 / 5 GB".
  static String _bytes(int used, int limit) {
    const mb = 1024 * 1024;
    const gb = mb * 1024;
    final (unit, name) = limit >= gb ? (gb, 'GB') : (mb, 'MB');
    String compact(double value) =>
        value >= 100 || value == value.roundToDouble()
        ? '${value.round()}'
        : value.toStringAsFixed(1);
    return '${compact(used / unit)} / ${compact(limit / unit)} $name';
  }

  static String _resetLine(DateTime? at) {
    if (at == null) return 'Resets each month';
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
    return 'Resets on ${at.day} ${months[at.month - 1]}';
  }
}

/// How much of an allowance is gone: the pie, then the numbers.
class _Usage extends StatelessWidget {
  const _Usage({required this.used, required this.limit, required this.label});

  final int used;
  final int limit;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SettingsPie(fraction: limit <= 0 ? null : used / limit),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          fontSize: SettingsMetrics.subtitleSize,
          color: context.palette.textSecondary,
        ),
      ),
    ],
  );
}
