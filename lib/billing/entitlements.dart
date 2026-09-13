/// The current plan and usage totals returned by the server.
///
/// The app renders this answer and never derives a signed-in account's plan
/// from local state. Purchases can happen on another device or on the web,
/// while storage and cloud usage are enforced by the server itself.
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.storageBytes,
    required this.storageUsedBytes,
    required this.speechSecondsPerMonth,
    required this.speechSecondsUsedThisMonth,
    required this.speechCreditSeconds,
    required this.summaryGenerationsPerMonth,
    required this.summaryGenerationsUsedThisMonth,
    required this.speechResetsAt,
    required this.sync,
    required this.sharing,
  });

  final String plan;
  final int storageBytes;
  final int storageUsedBytes;
  final int speechSecondsPerMonth;
  final int speechSecondsUsedThisMonth;
  final int speechCreditSeconds;
  final int summaryGenerationsPerMonth;
  final int summaryGenerationsUsedThisMonth;
  final DateTime? speechResetsAt;
  final bool sync;
  final bool sharing;

  bool get isPro => plan == 'pro';

  static const int freeSummaryGenerationsPerMonth = 100;
  static const int proSummaryGenerationsPerMonth = 1000;

  /// What Settings can explain before there is an account to ask.
  ///
  /// These are the published free-plan limits mirrored from the wire contract,
  /// not an entitlement decision. Once signed in, only the server response is
  /// shown.
  static const freePreview = Entitlements(
    plan: 'free',
    storageBytes: 100 * 1024 * 1024,
    storageUsedBytes: 0,
    speechSecondsPerMonth: 15 * 60,
    speechSecondsUsedThisMonth: 0,
    speechCreditSeconds: 0,
    summaryGenerationsPerMonth: freeSummaryGenerationsPerMonth,
    summaryGenerationsUsedThisMonth: 0,
    speechResetsAt: null,
    sync: false,
    sharing: false,
  );

  static Entitlements fromJson(Map<String, Object?> raw) {
    int count(String key) => switch (raw[key]) {
      final int value when value >= 0 => value,
      final double value when value >= 0 => value.round(),
      _ => 0,
    };

    final plan = raw['plan'] == 'pro' ? 'pro' : 'free';
    // During a rolling deploy an updated app can briefly reach the previous
    // endpoint shape. New accounting begins at zero, so the published plan
    // limit and zero usage are the truthful bridge until the server catches up.
    final summaryLimit = raw.containsKey('summaryGenerationsPerMonth')
        ? count('summaryGenerationsPerMonth')
        : plan == 'pro'
        ? proSummaryGenerationsPerMonth
        : freeSummaryGenerationsPerMonth;

    return Entitlements(
      plan: plan,
      storageBytes: count('storageBytes'),
      storageUsedBytes: count('storageUsedBytes'),
      speechSecondsPerMonth: count('speechSecondsPerMonth'),
      speechSecondsUsedThisMonth: count('speechSecondsUsedThisMonth'),
      speechCreditSeconds: count('speechCreditSeconds'),
      summaryGenerationsPerMonth: summaryLimit,
      summaryGenerationsUsedThisMonth: count('summaryGenerationsUsedThisMonth'),
      speechResetsAt: switch (raw['speechResetsAt']) {
        final String value => DateTime.tryParse(value)?.toLocal(),
        _ => null,
      },
      sync: raw['sync'] == true,
      sharing: raw['sharing'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'plan': plan,
    'storageBytes': storageBytes,
    'storageUsedBytes': storageUsedBytes,
    'speechSecondsPerMonth': speechSecondsPerMonth,
    'speechSecondsUsedThisMonth': speechSecondsUsedThisMonth,
    'speechCreditSeconds': speechCreditSeconds,
    'summaryGenerationsPerMonth': summaryGenerationsPerMonth,
    'summaryGenerationsUsedThisMonth': summaryGenerationsUsedThisMonth,
    'speechResetsAt': speechResetsAt?.toUtc().toIso8601String(),
    'sync': sync,
    'sharing': sharing,
  };
}
