import '../models.dart';

/// Two payments that may be one: same amount and direction, same account (or one without), close in time.
class DuplicatePair {
  DuplicatePair(this.a, this.b, {required this.sameRef, required this.days});

  final Txn a, b;

  /// Both carry the same UPI / bank reference: almost certainly the same payment.
  final bool sameRef;

  /// Days apart (statement lines have no time).
  final int days;

  String get key => pairKey(a.id, b.id);
}

String pairKey(String x, String y) => x.compareTo(y) < 0 ? '$x|$y' : '$y|$x';

final _ref = RegExp(r'(?<![0-9])([0-9]{12})(?![0-9])');
Set<String> refsOf(Txn t) => {for (final m in _ref.allMatches('${t.details ?? ''} ${t.emailBody ?? ''}')) m.group(1)!};

/// Likely duplicates, the surest first. Leaves out pairs you said are not duplicates, different references
/// (two real payments), moves between your own accounts paired on purpose, and two lines of the same
/// statement (a statement never lists one payment twice).
List<DuplicatePair> suspectedDuplicates(Iterable<Txn> txns, {Set<String> notDuplicates = const {}, int maxDays = 2}) {
  final byAmount = <String, List<Txn>>{};
  for (final t in txns) {
    if (t.amount <= 0) continue;
    byAmount.putIfAbsent('${t.isDebit}|${t.amount.toStringAsFixed(2)}', () => []).add(t);
  }
  final out = <DuplicatePair>[];
  for (final group in byAmount.values) {
    if (group.length < 2) continue;
    group.sort((x, y) => x.txnAt.compareTo(y.txnAt));
    for (var i = 0; i < group.length; i++) {
      for (var j = i + 1; j < group.length; j++) {
        final a = group[i], b = group[j];
        final days = DateTime(
          b.txnAt.year,
          b.txnAt.month,
          b.txnAt.day,
        ).difference(DateTime(a.txnAt.year, a.txnAt.month, a.txnAt.day)).inDays;
        if (days > maxDays) break;
        if (notDuplicates.contains(pairKey(a.id, b.id))) continue;
        if (a.accountId != null && b.accountId != null && a.accountId != b.accountId) continue;
        if (a.source == 'statement' && b.source == 'statement') continue;
        final ra = refsOf(a), rb = refsOf(b);
        final sameRef = ra.isNotEmpty && rb.isNotEmpty && ra.intersection(rb).isNotEmpty;
        if (ra.isNotEmpty && rb.isNotEmpty && !sameRef) continue;
        // Two bank emails at different times of the same day are two payments (an email has the real time).
        if (!sameRef && a.source == 'email' && b.source == 'email' && b.txnAt.difference(a.txnAt).inMinutes.abs() > 5) {
          continue;
        }
        out.add(DuplicatePair(a, b, sameRef: sameRef, days: days));
      }
    }
  }
  out.sort((x, y) {
    if (x.sameRef != y.sameRef) return x.sameRef ? -1 : 1;
    return y.a.txnAt.compareTo(x.a.txnAt);
  });
  return out;
}
