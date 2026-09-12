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
    elevation: 0,
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
          'This $storeAccountName has no Pro Lifetime to restore.',
          icon: Icons.info_outline_rounded,
        );
      case RestoreResult.belongsToAnotherAccount:
        Toast.show(
          context,
          'This $storeAccountName bought Pro Lifetime for a different Kapy '
          'Notes account. Sign in to that account to use it.',
          icon: Icons.info_outline_rounded,
        );
      case RestoreResult.failed:
        Toast.show(
          context,
          'Could not reach $storeName. Try again in a moment.',
          isError: true,
        );
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
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.92,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            border: Border(top: BorderSide(color: palette.controlBorder)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(top: false, child: body),
        ),
      );
    }
    return Dialog(
      backgroundColor: palette.surfaceBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 760),
        child: body,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final billing = _billing;
    final now = billing.entitlements;
    final isPro = now?.isPro ?? false;
    final trialEnds = billing.trialRunning ? now?.trialEndsAt : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          asSheet: widget.asSheet,
          onClose: () => Navigator.of(context).maybePop(),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              AppPlatform.hasPointer ? 28 : 24,
              0,
              AppPlatform.hasPointer ? 28 : 24,
              AppPlatform.hasPointer ? 24 : 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hero(isPro: isPro),
                const SizedBox(height: 24),
                if (isPro)
                  const _Owned()
                else ...[
                  if (trialEnds != null) ...[
                    _Trying(
                      endsAt: trialEnds.toLocal(),
                      daysLeft: billing.trialDaysLeft ?? 1,
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (!billing.isSignedIn)
                    _signedOut(context)
                  else
                    _buyPro(context),
                ],
                if (billing.notice case final String notice) ...[
                  const SizedBox(height: 12),
                  _Notice(text: notice),
                ],
                const SizedBox(height: 28),
                const _SectionLabel('Everything included'),
                const SizedBox(height: 10),
                _Benefits(detail: _syncDetail(now)),
                const SizedBox(height: 12),
                const _GrowthNote(),
                if (isPro) ...[const SizedBox(height: 28), _packs(context)],
                const SizedBox(height: 24),
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
      return 'Keep every note on every device, and invite others in.';
    }
    if (now.isPro) return 'Yours for good, on every device you sign in on.';
    if (_billing.trialRunning) {
      return 'Yours while you try Pro. Pro Lifetime keeps them after it ends.';
    }
    if (now.sync) {
      return 'Included for everyone for now. Pro keeps them for good.';
    }
    return 'Write past five notes, keep them in sync, and invite others in.';
  }

  /// Buying with no account, which is allowed because one part of Pro works
  /// without one: writing past five notes.
  ///
  /// What the rest of it needs is said before the money, not discovered after
  /// it, and signing in later is offered rather than demanded.
  Widget _signedOut(BuildContext context) {
    final palette = context.palette;
    final owned = _billing.proOnThisDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (owned) const _OwnedHere() else _buyPro(context),
        const SizedBox(height: 10),
        Text(
          owned
              ? 'Sign in to use it on your other devices, and to turn on sync, '
                    'sharing, storage and transcription.'
              : 'Unlimited notes unlock on this device straight away. Sync, '
                    'sharing, storage and transcription belong to an account, '
                    'so sign in whenever you like and this purchase comes '
                    'with you.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            height: 1.45,
            color: palette.textSecondary,
          ),
        ),
        const SizedBox(height: 2),
        Align(
          child: TextButton(
            key: const ValueKey('pro-sign-in'),
            style: _quietButtonStyle(context),
            // Settings is right behind this sheet, on the pane with the
            // sign-in form in it.
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(owned ? 'Sign in' : 'Sign in first'),
          ),
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
      label = 'Waiting for $storeName…';
    } else if (billing.activity == BillingActivity.confirming) {
      label = 'Adding Pro to your account…';
    } else if (billing.activity == BillingActivity.restoring) {
      label = 'Checking your purchases…';
    } else if (offer != null) {
      label = 'Get Pro Lifetime';
    } else if (billing.offersLoading) {
      label = 'Checking the price…';
    } else if (billing.offersFailed) {
      label = 'Price unavailable';
    } else {
      label = 'Get Pro Lifetime';
    }

    return Container(
      key: const ValueKey('pro-offer'),
      padding: const EdgeInsets.all(18),
      decoration: _panelDecoration(palette),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pro Lifetime',
                      style: TextStyle(
                        fontSize: AppTypeScale.title,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.15,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'One-time purchase',
                      style: TextStyle(
                        fontSize: AppTypeScale.caption,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (offer != null)
                Text(
                  offer.price,
                  key: const ValueKey('pro-price'),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: AppPlatform.hasPointer ? 25 : 28,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.6,
                    color: palette.textPrimary,
                  ),
                )
              else
                Text(
                  billing.offersFailed ? 'Unavailable' : 'Checking…',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    color: palette.textTertiary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('pro-buy'),
            style: _primaryActionStyle(context),
            onPressed: offer == null || busy
                ? null
                : () => _buy(Sku.proLifetime),
            child: Text(label),
          ),
          if (offer == null && billing.offersFailed) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    'No answer from $storeName.',
                    style: TextStyle(
                      fontSize: AppTypeScale.caption,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('pro-offers-retry'),
                  style: _quietButtonStyle(context),
                  onPressed: billing.loadOffers,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              'No subscription. Lifetime updates included.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                color: palette.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _packs(BuildContext context) {
    final palette = context.palette;
    final billing = _billing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('Add to Pro'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: _panelDecoration(palette),
          child: Column(
            children: [
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
              Divider(height: 1, color: palette.separator),
              _Pack(
                sku: Sku.voice1000,
                title: '1,000 transcription minutes',
                detail: 'Used after the monthly two hours. They never expire.',
                offer: billing.offerFor(Sku.voice1000),
                enabled: billing.activity == BillingActivity.idle,
                busy: billing.activeSku == Sku.voice1000,
                onBuy: () => _buy(Sku.voice1000),
              ),
            ],
          ),
        ),
        if (billing.offersFailed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('pro-offers-retry'),
              style: _quietButtonStyle(context),
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
    final style = TextStyle(
      fontSize: AppTypeScale.caption,
      fontWeight: FontWeight.w400,
      color: palette.textTertiary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          billing.isSignedIn
              ? 'Paid once through your $storeAccountName. Not a subscription, '
                    'and it belongs to this Kapy Notes account.'
              : 'Paid once through your $storeAccountName. Not a '
                    'subscription, and it joins your account when you sign in.',
          textAlign: TextAlign.center,
          style: style.copyWith(height: 1.4),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 2,
          children: [
            // Offered signed out too: restoring is how a wiped device, or a
            // second phone on the same store account, unlocks its notes again.
            if (billing.canPurchase)
              TextButton(
                key: const ValueKey('pro-restore'),
                style: _quietButtonStyle(context),
                onPressed: billing.activity == BillingActivity.idle
                    ? _restore
                    : null,
                child: Text('Restore purchases', style: style),
              ),
            TextButton(
              style: _quietButtonStyle(context),
              onPressed: () => unawaitedLaunch('https://kapynotes.com/terms'),
              child: Text('Terms', style: style),
            ),
            TextButton(
              style: _quietButtonStyle(context),
              onPressed: () => unawaitedLaunch('https://kapynotes.com/privacy'),
              child: Text('Privacy', style: style),
            ),
          ],
        ),
      ],
    );
  }
}

BoxDecoration _panelDecoration(CalcPalette palette) => BoxDecoration(
  color: palette.controlBackground,
  border: Border.all(color: palette.controlBorder, width: 0.5),
  borderRadius: BorderRadius.circular(18),
);

ButtonStyle _primaryActionStyle(BuildContext context) => FilledButton.styleFrom(
  minimumSize: Size(0, AppPlatform.hasPointer ? 44 : 52),
  elevation: 0,
  shadowColor: Colors.transparent,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
    fontSize: AppTypeScale.control,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
  ),
);

ButtonStyle _quietButtonStyle(BuildContext context) => TextButton.styleFrom(
  minimumSize: Size(0, AppControlMetrics.buttonHeight),
  padding: const EdgeInsets.symmetric(horizontal: 9),
  tapTargetSize: AppControlMetrics.iconButtonTapTargetSize,
  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
    fontSize: AppTypeScale.caption,
    fontWeight: FontWeight.w400,
  ),
);

class _Header extends StatelessWidget {
  const _Header({required this.asSheet, required this.onClose});

  final bool asSheet;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final closeExtent = AppPlatform.hasPointer ? 30.0 : 44.0;
    return SizedBox(
      height: asSheet ? 66 : 52,
      child: Stack(
        children: [
          if (asSheet)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: palette.textTertiary.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          PositionedDirectional(
            top: asSheet ? 18 : 12,
            end: 16,
            child: IconButton(
              tooltip: 'Close',
              style: IconButton.styleFrom(
                fixedSize: Size.square(closeExtent),
                minimumSize: Size.square(closeExtent),
                maximumSize: Size.square(closeExtent),
                padding: EdgeInsets.zero,
                backgroundColor: palette.selectedBackground,
                shape: const CircleBorder(),
              ),
              onPressed: onClose,
              icon: Icon(
                Icons.close_rounded,
                size: AppPlatform.hasPointer ? 16 : 19,
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.isPro});

  final bool isPro;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            border: Border.all(color: accent.withValues(alpha: 0.18)),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPro ? Icons.check_rounded : Icons.all_inclusive_rounded,
            size: 25,
            color: accent,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Kapy Notes Pro',
          style: TextStyle(
            fontSize: AppTypeScale.control,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.1,
            color: accent,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          isPro ? 'Pro is yours.' : 'Write without limits.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppPlatform.hasPointer ? 28 : 32,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.8,
            height: 1.1,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 9),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Text(
            isPro
                ? 'Your complete notebook is available on every device you '
                      'sign in on.'
                : 'One purchase unlocks the complete notebook on every '
                      'device.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.body,
              height: 1.45,
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _Owned extends StatelessWidget {
  const _Owned();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('pro-owned'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        border: Border.all(color: accent.withValues(alpha: 0.22), width: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 22, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pro Lifetime is on this account',
                  style: TextStyle(
                    fontSize: AppTypeScale.title,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Thank you for backing Kapy Notes.',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
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

/// What a trial is, said while it runs: how long is left, and that it ends by
/// itself with nothing charged and nothing lost.
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
    final accent = Theme.of(context).colorScheme.primary;
    final left = daysLeft == 1
        ? 'Last day of your Pro trial'
        : '$daysLeft days left of your Pro trial';
    return Container(
      key: const ValueKey('pro-trial'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        border: Border.all(color: accent.withValues(alpha: 0.22), width: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.hourglass_bottom_rounded, size: 22, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  left,
                  style: TextStyle(
                    fontSize: AppTypeScale.title,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'On ${endsAt.day} ${_months[endsAt.month - 1]} this account '
                  'moves to Free by itself. Nothing is charged, and nothing '
                  'is deleted.',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
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

/// Bought here, with no account to put it on yet.
class _OwnedHere extends StatelessWidget {
  const _OwnedHere();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('pro-owned-here'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.07),
        border: Border.all(color: accent.withValues(alpha: 0.22), width: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 22, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pro Lifetime is on this device',
                  style: TextStyle(
                    fontSize: AppTypeScale.title,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Your notes have no limit here.',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: AppTypeScale.caption,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.15,
      color: context.palette.textTertiary,
    ),
  );
}

class _Benefits extends StatelessWidget {
  const _Benefits({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      decoration: _panelDecoration(palette),
      child: Column(
        children: [
          _BenefitRow(
            icon: Icons.note_alt_outlined,
            title: 'Unlimited notes, sync and sharing',
            detail: detail,
          ),
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: palette.separator,
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _Allowance(
                      value: '1 GB',
                      label: 'Encrypted storage',
                      comparison: '10× the free plan',
                    ),
                  ),
                  VerticalDivider(width: 25, thickness: 1),
                  Expanded(
                    child: _Allowance(
                      value: '2 hours',
                      label: 'Monthly transcription',
                      comparison: '8× the free plan',
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

class _BenefitRow extends StatelessWidget {
  const _BenefitRow({
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
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTypeScale.body,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.1,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
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

class _Allowance extends StatelessWidget {
  const _Allowance({
    required this.value,
    required this.label,
    required this.comparison,
  });

  final String value;
  final String label;
  final String comparison;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: AppPlatform.hasPointer ? 22 : 24,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.5,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            height: 1.25,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          comparison,
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            height: 1.25,
            color: palette.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _GrowthNote extends StatelessWidget {
  const _GrowthNote();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.add_circle_outline_rounded,
              size: 17,
              color: palette.textTertiary,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              'Need more later? Add storage or transcription with one-time '
              'packs.',
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                height: 1.4,
                color: palette.textSecondary,
              ),
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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTypeScale.body,
                    fontWeight: FontWeight.w400,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    height: 1.4,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: ValueKey('pro-pack-${sku.id}'),
            style: OutlinedButton.styleFrom(
              minimumSize: Size(0, AppPlatform.hasPointer ? 36 : 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: AppTypeScale.control,
                fontWeight: FontWeight.w400,
              ),
            ),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border.all(color: palette.controlBorder, width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTypeScale.caption,
          height: 1.4,
          color: palette.textPrimary,
        ),
      ),
    );
  }
}
