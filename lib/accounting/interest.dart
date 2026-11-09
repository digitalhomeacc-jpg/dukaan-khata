import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import 'models.dart';
import 'voucher_service.dart';

/// One stretch of days on the same balance.
class InterestSlab {
  final String from;
  final String to;
  final int balance; // paise, + = party owes us
  final int days;
  final double interest; // paise
  InterestSlab(this.from, this.to, this.balance, this.days, this.interest);
}

class InterestCalc {
  final String partyId;
  final String from;
  final String to;
  final int rate; // % per month × 100
  final List<InterestSlab> slabs;
  InterestCalc(this.partyId, this.from, this.to, this.rate, this.slabs);

  /// Rounded to whole rupees, as written in the khata.
  int get interest => ((slabs.fold<double>(0, (s, x) => s + x.interest)) / 100).round() * 100;
  int get days => slabs.fold(0, (s, x) => s + x.days);
}

/// व्याज: simple interest on what a party owes, day by day.
///
/// * rate is per month (1.5 % दरमहा), a month counted as 30 days;
/// * only days on which the party owes us count (advance / zero = no interest);
/// * earlier interest entries are left out of the balance, so interest is never
///   charged on interest;
/// * the next calculation starts the day after the last interest entry.
class InterestService {
  final SqliteConnection db;
  final String businessId;
  InterestService(this.db, this.businessId);

  /// Date of the last interest entry for a party, if any.
  Future<String?> lastCharged(String partyId) async {
    final r = await db.get(
      "SELECT MAX(vdate) AS d FROM vouchers WHERE party_id = ? AND vtype = 'interest' AND deleted = 0",
      [partyId],
    );
    return r['d'] as String?;
  }

  /// Where the next calculation starts: the day after the last interest entry,
  /// else the start of this month (never before the books start).
  Future<String> defaultFrom(String partyId, String to) async {
    final last = await lastCharged(partyId);
    if (last != null) return isoDate(parseIso(last).add(const Duration(days: 1)));
    final t = parseIso(to);
    final monthStart = isoDate(DateTime(t.year, t.month, 1));
    return monthStart.compareTo(Books.start) < 0 ? Books.start : monthStart;
  }

  Future<InterestCalc> calculate(String partyId, {required String from, required String to, required int rate}) async {
    if (to.compareTo(from) < 0 || rate <= 0) return InterestCalc(partyId, from, to, rate, []);
    // balance at the start of [from], without earlier interest entries
    final o = await db.get(
      'SELECT l.opening_balance + COALESCE((SELECT SUM(vl.debit - vl.credit) FROM voucher_lines vl '
      'JOIN vouchers v ON v.id = vl.voucher_id WHERE vl.ledger_id = l.id AND vl.deleted = 0 '
      "AND v.vtype <> 'interest' AND vl.vdate < ?), 0) AS b FROM ledgers l WHERE l.id = ?",
      [from, partyId],
    );
    var bal = (o['b'] as num).toInt();
    final moves = await db.getAll(
      'SELECT vl.vdate AS d, SUM(vl.debit - vl.credit) AS m FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
      "WHERE vl.ledger_id = ? AND vl.deleted = 0 AND v.vtype <> 'interest' AND vl.vdate BETWEEN ? AND ? "
      'GROUP BY vl.vdate ORDER BY vl.vdate',
      [partyId, from, to],
    );
    final slabs = <InterestSlab>[];
    var start = parseIso(from);
    final end = parseIso(to);
    void close(DateTime until) {
      // days start..until inclusive on balance [bal]
      final days = until.difference(start).inDays + 1;
      if (days <= 0) return;
      final owed = bal > 0 ? bal : 0;
      slabs.add(InterestSlab(isoDate(start), isoDate(until), bal, days, owed * rate / 10000 * days / 30));
    }

    for (final m in moves) {
      final d = parseIso(m['d'] as String);
      // the day's entries apply from that day on
      close(d.subtract(const Duration(days: 1)));
      bal += (m['m'] as num).toInt();
      start = d;
    }
    close(end);
    return InterestCalc(partyId, from, to, rate, slabs.where((s) => s.days > 0).toList());
  }

  /// Puts the interest on the party's khata (owner only).
  Future<String?> post(VoucherService vs, Actor actor, InterestCalc c, {required String note}) async {
    if (c.interest <= 0) return null;
    return vs.save(
      VoucherInput(type: VoucherType.interest, date: c.to, partyId: c.partyId, amount: c.interest, narration: note),
      actor,
    );
  }
}

/// "1.5" → 150; "" → 0.
int parseRate(String s) => ((double.tryParse(normalizeDigits(s.trim())) ?? 0) * 100).round();
String fmtRate(int r) => r % 100 == 0 ? '${r ~/ 100}' : (r / 100).toString();
