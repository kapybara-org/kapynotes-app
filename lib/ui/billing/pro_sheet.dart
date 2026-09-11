import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../billing/billing.dart';
import '../../billing/entitlements.dart';
import '../../billing/purchase_store.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../safety_dialogs.dart' show unawaitedLaunch;

/// Opens what Pro is and the way to buy it: a dialog on desktop, a sheet on a
/// phone, the same split every other panel in the app follows.
Future<void> showProSheet(BuildContext context, {required Billing billing}) {
  Widget build({required bool asSheet}) =>
      ProSheet(billing: billing, asSheet: asSheet);

  if (!AppPlatform.isMobile) {
    return showDialog<void>(
      context: context,
      builder: (context) => build(asSheet: false),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => build(asSheet: true),
  );
}

/// The one plan, what it adds today, and the packs that top it up.
///
/// Says what Pro changes *now*, in this build, rather than what it will change
/// one day. Until plans are enforced every account syncs, shares and keeps as
/// many notes as it likes, and a sheet promising those as if they were locked
/// would be selling something already given away — so that line reads from
/// the server's answer instead of from a script.
class ProSheet extends StatefulWidget {
  const ProSheet({super.key, required this.billing, this.asSheet = false});

  final Billing billing;
  final bool asSheet;

  @override
  State<ProSheet> createState() => _ProSheetState();
}

class _ProSheetState extends State<ProSheet> {
  Billing get _billing => widget.billing;

  @override
  void initState() {
    super.initState();
    // After the frame: both of these notify, and a notification during the
    // build that opened this would rebuild the settings row mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _billing.clearNotice();
      unawaited(_billing.refresh());
      unawaited(_billing.loadOffers());
    });
  }

  Future<void> _buy(Sku sku) async {
    final outcome = await _billing.buy(sku);
    if (!mounted) return;
    switch (outcome) {
      case PurchaseCompleted() when _billing.notice == null:
        Toast.show(context, switch (sku) {
          Sku.proLifetime => 'Pro Lifetime is yours. Thank you.',
          Sku.storage5gb => '5 GB added to your storage.',
          Sku.voice1000 => '1,000 minutes added.',
        });
      case PurchaseFailed(:final message):
        Toast.show(context, message, isError: true);
      case PurchaseCompleted() || PurchaseCancelled() || PurchasePending():
        // Completed-but-not-arrived and pending both leave a notice in the
        // sheet, which outlasts a toast; a cancel needs no comment at all.
        break;
    }
  }

  Future<void> _restore() async {
    final result = await _billing.restore();
    if (!mounted) return;
    switch (result) {
      case RestoreResult.restored:
        Toast.show(context, 'Pro Lifetime is on this account.');
      case RestoreResult.nothingFound:
        Toast.show(
          context,
          'This Apple ID has no Pro Lifetime to restore.',
          icon: Icons.info_outline_rounded,
        );
      case RestoreResult.belongsToAnotherAccount:
        Toast.show(
          context,
          'This Apple ID bought Pro Lifetime for a different Kapy Notes '
          'account. Sign in to that account to use it.',
          icon: Icons.info_outline_rounded,
        );
      case RestoreResult.failed:
        Toast.show(
          context,
          'Could not reach the App Store. Try again in a moment.',
          isError: true,
        );
      case RestoreResult.signedOut:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final body = ListenableBuilder(
      listenable: _billing,
      builder: (context, _) => _content(context),
    );

    if (widget.asSheet) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(top: false, child: body),
        ),
      );
    }
    return Dialog(
      backgroundColor: palette.surfaceBackground,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 680),
        child: body,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final palette = context.palette;
    final billing = _billing;
    final now = billing.entitlements;
    final isPro = now?.isPro ?? false;
    final trialEnds = billing.trialRunning ? now?.trialEndsAt : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(onClose: () => Navigator.of(context).maybePop()),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isPro)
                  const _Owned()
                else if (trialEnds != null)
                  _Trying(
                    endsAt: trialEnds.toLocal(),
                    daysLeft: billing.trialDaysLeft ?? 1,
                  )
                else
                  Text(
                    'Pay once and it is yours for good. No subscription, '
                    'nothing to cancel.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: palette.textPrimary,
                    ),
                  ),
                const SizedBox(height: 14),
                const _Benefit(
                  icon: Icons.cloud_outlined,
                  title: '1 GB of encrypted storage',
                  detail:
                      'For the pictures and files in your notes, on every '
                      'device you sign in on.',
                ),
                const _Benefit(
                  icon: Icons.graphic_eq_rounded,
                  title: 'Two hours of transcription a month',
                  detail:
                      'Voice notes turned into text in the cloud. Free '
                      'accounts have 15 minutes.',
                ),
                _Benefit(
                  icon: Icons.devices_rounded,
                  title: 'Sync, sharing and unlimited notes',
                  detail: _syncDetail(now),
                ),
                const _Benefit(
                  icon: Icons.add_circle_outline_rounded,
                  title: 'Room to grow',
                  detail:
                      'More storage or more minutes whenever you need them, '
                      'as one-off packs.',
                ),
                const SizedBox(height: 18),
                if (!billing.isSignedIn)
                  _signInFirst(context)
                else if (isPro)
                  _packs(context)
                else
                  _buyPro(context),
                if (billing.notice case final String notice) ...[
                  const SizedBox(height: 12),
                  _Notice(text: notice),
                ],
                const SizedBox(height: 18),
                _finePrint(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _syncDetail(Entitlements? now) {
    if (now == null) {
      return 'On every device you sign in on, and with the people you invite.';
    }
    if (now.isPro) return 'Yours for good, on every device you sign in on.';
    if (_billing.trialRunning) {
      return 'Yours while you try Pro. Pro Lifetime is how you keep them '
          'after it ends.';
    }
    if (now.sync) {
      return 'Every account has these while Kapy Notes is in beta. Pro '
          'Lifetime is how you keep them after it.';
    }
    return 'Sync and sharing come with Pro, and so does editing more than '
        'five notes.';
  }

  Widget _signInFirst(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: const ValueKey('pro-sign-in'),
          // Settings is right behind this sheet, on the pane with the
          // sign-in form in it.
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Sign in to get Pro'),
        ),
        const SizedBox(height: 8),
        Text(
          'Pro belongs to your Kapy Notes account, so it works on every '
          'device you sign in on.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
      ],
    );
  }

  Widget _buyPro(BuildContext context) {
    final palette = context.palette;
    final billing = _billing;
    final offer = billing.offerFor(Sku.proLifetime);
    final busy = billing.activity != BillingActivity.idle;

    final String label;
    if (billing.activity == BillingActivity.buying) {
      label = 'Waiting for the App Store…';
    } else if (billing.activity == BillingActivity.confirming) {
      label = 'Adding Pro to your account…';
    } else if (billing.activity == BillingActivity.restoring) {
      label = 'Checking your purchases…';
    } else if (offer != null) {
      label = 'Get Pro Lifetime · ${offer.price}';
    } else {
      label = 'Get Pro Lifetime';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: const ValueKey('pro-buy'),
          onPressed: offer == null || busy
              ? null
              : () => _buy(Sku.proLifetime),
          child: Text(label),
        ),
        if (offer == null && billing.offersLoading) ...[
          const SizedBox(height: 8),
          Text(
            'Asking the App Store for the price…',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: palette.textSecondary),
          ),
        ] else if (offer == null && billing.offersFailed) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  'The App Store did not answer.',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ),
              TextButton(
                key: const ValueKey('pro-offers-retry'),
                onPressed: billing.loadOffers,
                child: const Text('Try again'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _packs(BuildContext context) {
    final palette = context.palette;
    final billing = _billing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'ADD TO IT',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w500,
            color: palette.textTertiary,
          ),
        ),
        const SizedBox(height: 6),
        _Pack(
          sku: Sku.storage5gb,
          title: '5 GB more storage',
          detail: billing.canAddStorage
              ? 'Added to what you have, for good.'
              : 'Your account holds the most extra storage it can.',
          offer: billing.offerFor(Sku.storage5gb),
          enabled:
              billing.canAddStorage &&
              billing.activity == BillingActivity.idle,
          busy: billing.activeSku == Sku.storage5gb,
          onBuy: () => _buy(Sku.storage5gb),
        ),
        _Pack(
          sku: Sku.voice1000,
          title: '1,000 transcription minutes',
          detail:
              'Used once the month’s two hours run out. They never expire.',
          offer: billing.offerFor(Sku.voice1000),
          enabled: billing.activity == BillingActivity.idle,
          busy: billing.activeSku == Sku.voice1000,
          onBuy: () => _buy(Sku.voice1000),
        ),
        if (billing.offersFailed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('pro-offers-retry'),
              onPressed: billing.loadOffers,
              child: const Text('Prices did not load. Try again'),
            ),
          ),
      ],
    );
  }

  Widget _finePrint(BuildContext context) {
    final palette = context.palette;
    final billing = _billing;
    final style = TextStyle(fontSize: 11.5, color: palette.textTertiary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (billing.isSignedIn)
          Align(
            child: TextButton(
              key: const ValueKey('pro-restore'),
              onPressed: billing.activity == BillingActivity.idle
                  ? _restore
                  : null,
              child: const Text('Restore purchases'),
            ),
          ),
        Text(
          'Paid once through your Apple ID. It is not a subscription, and it '
          'belongs to the Kapy Notes account you are signed in to.',
          textAlign: TextAlign.center,
          style: style.copyWith(height: 1.4),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => unawaitedLaunch('https://kapynotes.com/terms'),
              child: Text('Terms', style: style),
            ),
            Text('·', style: style),
            TextButton(
              onPressed: () => unawaitedLaunch('https://kapynotes.com/privacy'),
              child: Text('Privacy', style: style),
            ),
          ],
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          Icon(
            Icons.workspace_premium_outlined,
            size: 22,
            color: palette.textPrimary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Kapy Notes Pro',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: Icon(Icons.close_rounded, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Owned extends StatelessWidget {
  const _Owned();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.selectedBackground,
        border: Border.all(color: palette.selectedBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: palette.textPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Pro Lifetime is on this account. Thank you for backing Kapy '
              'Notes.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a trial is, said while it runs: how long is left, and that it ends by
/// itself with nothing charged and nothing lost — the three things somebody
/// trying Pro needs to know, and the ones the trial's terms promise.
class _Trying extends StatelessWidget {
  const _Trying({required this.endsAt, required this.daysLeft});

  final DateTime endsAt;
  final int daysLeft;

  static const _months = [
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final left = daysLeft == 1
        ? 'This is the last day of your Pro trial.'
        : 'You are trying Pro, with $daysLeft days left.';
    final on = '${endsAt.day} ${_months[endsAt.month - 1]}';
    return Container(
      key: const ValueKey('pro-trial'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.selectedBackground,
        border: Border.all(color: palette.selectedBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.hourglass_bottom_rounded,
              size: 18,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$left On $on this account moves to Free by itself. Nothing '
              'is charged, and nothing is deleted.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: palette.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pack extends StatelessWidget {
  const _Pack({
    required this.sku,
    required this.title,
    required this.detail,
    required this.offer,
    required this.enabled,
    required this.busy,
    required this.onBuy,
  });

  final Sku sku;
  final String title;
  final String detail;
  final StoreOffer? offer;
  final bool enabled;
  final bool busy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final price = offer?.price;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: ValueKey('pro-pack-${sku.id}'),
            onPressed: enabled && price != null ? onBuy : null,
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(price ?? '—'),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border.all(color: palette.controlBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.textPrimary),
      ),
    );
  }
}
