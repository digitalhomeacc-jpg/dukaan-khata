import 'package:sqlite_async/sqlite_async.dart';

import '../core/ids.dart';
import '../core/money.dart';
import '../shared/statement_parser.dart';
import 'models.dart';
import 'voucher_service.dart';

class BankLine {
  final String id;
  final String bankLedgerId;
  final String date;
  final String description;
  final String ref;
  final int debit;
  final int credit;
  final int? balance;
  final String? voucherId;
  final String status; // open | matched | ignored
  final String? partyName; // of the matched voucher
  BankLine.fromRow(Map<String, Object?> r)
      : id = r['id'] as String,
        bankLedgerId = r['bank_ledger_id'] as String,
        date = r['tdate'] as String,
        description = (r['description'] as String?) ?? '',
        ref = (r['ref'] as String?) ?? '',
        debit = (r['debit'] as int?) ?? 0,
        credit = (r['credit'] as int?) ?? 0,
        balance = r['balance'] as int?,
        voucherId = r['voucher_id'] as String?,
        status = (r['status'] as String?) ?? 'open',
        partyName = r['party_name'] as String?;
  int get amount => credit > 0 ? credit : debit;
  bool get isIn => credit > 0;
}

class ImportResult {
  final int added;
  final int duplicates;
  final int autoMatched;
  ImportResult(this.added, this.duplicates, this.autoMatched);
}

/// Bank statement upload + reconciliation against the books.
class BankRepo {
  final SqliteConnection db;
  final String businessId;
  final VoucherService vouchers;
  BankRepo(this.db, this.businessId, this.vouchers);

  Future<ImportResult> import(String bankLedgerId, List<StatementLine> lines) async {
    var added = 0, dup = 0;
    final importId = newId();
    await db.writeTransaction((tx) async {
      final seen = <String>{};
      for (final l in lines) {
        final fp = '$bankLedgerId|${l.date}|${l.debit}|${l.credit}|${l.balance ?? ''}|${l.description.trim()}';
        // identical rows inside one file (e.g. two ₹500 UPI on the same day) are kept apart by their order
        var key = fp;
        var n = 1;
        while (!seen.add(key)) {
          key = '$fp#${++n}';
        }
        if (await tx.getOptional('SELECT id FROM bank_lines WHERE fingerprint = ? AND business_id = ?', [key, businessId]) != null) {
          dup++;
          continue;
        }
        await tx.execute(
          'INSERT INTO bank_lines (id, business_id, bank_ledger_id, import_id, tdate, description, ref, debit, credit, balance, '
          "fingerprint, voucher_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'open', ?)",
          [newId(), businessId, bankLedgerId, importId, l.date, l.description, l.ref, l.debit, l.credit, l.balance, key, nowIso()],
        );
        added++;
      }
    });
    final matched = await autoMatch(bankLedgerId);
    return ImportResult(added, dup, matched);
  }

  Future<List<BankLine>> list(String bankLedgerId, String status) async => (await db.getAll(
        'SELECT b.*, p.name AS party_name FROM bank_lines b LEFT JOIN vouchers v ON v.id = b.voucher_id '
        'LEFT JOIN ledgers p ON p.id = v.party_id WHERE b.bank_ledger_id = ? AND b.status = ? ORDER BY b.tdate DESC, b.created_at',
        [bankLedgerId, status],
      ))
          .map(BankLine.fromRow)
          .toList();

  Future<Map<String, int>> counts(String bankLedgerId) async {
    final rows = await db.getAll('SELECT status, COUNT(*) AS n FROM bank_lines WHERE bank_ledger_id = ? GROUP BY status', [bankLedgerId]);
    return {for (final r in rows) r['status'] as String: r['n'] as int};
  }

  /// Latest balance printed on the statement (for comparing with the books).
  Future<(String, int)?> statementBalance(String bankLedgerId) async {
    final r = await db.getOptional(
        'SELECT tdate, balance FROM bank_lines WHERE bank_ledger_id = ? AND balance IS NOT NULL ORDER BY tdate DESC, created_at DESC LIMIT 1',
        [bankLedgerId]);
    return r == null ? null : (r['tdate'] as String, r['balance'] as int);
  }

  /// Matches open statement lines with entries already in the books
  /// (same bank account, same amount and direction, date within 3 days).
  Future<int> autoMatch(String bankLedgerId) async {
    final open = await list(bankLedgerId, 'open');
    var n = 0;
    for (final l in open) {
      final from = isoDate(parseIso(l.date).subtract(const Duration(days: 3)));
      final to = isoDate(parseIso(l.date).add(const Duration(days: 3)));
      final cand = await db.getOptional(
        'SELECT vl.voucher_id, vl.vdate FROM voucher_lines vl WHERE vl.ledger_id = ? AND vl.deleted = 0 '
        'AND vl.vdate BETWEEN ? AND ? AND ${l.isIn ? 'vl.debit' : 'vl.credit'} = ? '
        'AND NOT EXISTS (SELECT 1 FROM bank_lines b WHERE b.voucher_id = vl.voucher_id AND b.bank_ledger_id = vl.ledger_id) '
        'ORDER BY ABS(julianday(vl.vdate) - julianday(?)) LIMIT 1',
        [bankLedgerId, from, to, l.amount, l.date],
      );
      if (cand != null) {
        await db.execute("UPDATE bank_lines SET voucher_id = ?, status = 'matched' WHERE id = ?", [cand['voucher_id'], l.id]);
        n++;
      }
    }
    return n;
  }

  static const _noise = {
    'NEFT', 'RTGS', 'IMPS', 'UPI', 'IFSC', 'BANK', 'TRANSFER', 'PAYMENT', 'FROM', 'CASH', 'DEPOSIT', 'WITHDRAWAL',
    'CHQ', 'CHEQUE', 'CLG', 'ATM', 'POS', 'REF', 'TXN', 'INB', 'MOB', 'NET', 'BANKING', 'LTD', 'PVT', 'THE', 'AND',
    'SBIN', 'HDFC', 'ICIC', 'UTIB', 'BARB', 'BKID', 'MAHB', 'KKBK', 'PUNB', 'CNRB', 'UBIN', 'YESB', 'IDIB',
    'PAYTM', 'PHONEPE', 'GPAY', 'YBL', 'OKSBI', 'OKAXIS', 'OKHDFCBANK', 'OKICICI', 'IBL', 'AXL', 'SHRI', 'SHREE',
  };

  static Set<String> tokens(String s) => s
      .toUpperCase()
      .split(RegExp(r'[^A-Z]+'))
      .where((t) => t.length >= 3 && !_noise.contains(t))
      .toSet();

  /// Best-guess parties for a statement line, from names / phone numbers in the narration.
  Future<List<Ledger>> suggest(String description, {int limit = 3}) async {
    final rows = await db.getAll(
      "SELECT * FROM ledgers WHERE business_id = ? AND COALESCE(archived,0) = 0 AND grp IN "
      "('customer','supplier','transporter','expense','direct_expense','income','loan','capital','gst')",
      [businessId],
    );
    final descTokens = tokens(description);
    final digits = RegExp(r'\d{10}').allMatches(description.replaceAll(RegExp(r'\D'), ' ')).map((m) => m[0]!).toSet();
    final scored = <(Ledger, int)>[];
    for (final r in rows) {
      final l = Ledger.fromRow(r);
      var score = 0;
      final phone = l.phone?.replaceAll(RegExp(r'\D'), '');
      if (phone != null && phone.length >= 10 && digits.contains(phone.substring(phone.length - 10))) score += 10;
      final nameTokens = tokens('${l.nameEn ?? ''} ${l.name}');
      for (final t in nameTokens) {
        if (descTokens.contains(t)) score += 3;
        // partial match only for longer names ("MANOHA" ~ "SURESH"), never "RAM" ~ "RAMESH"
        else if (t.length >= 5 && descTokens.any((d) => d.length >= 5 && (d.startsWith(t) || t.startsWith(d)))) score += 1;
      }
      if (score > 0) scored.add((l, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).map((e) => e.$1).toList();
  }

  /// Creates the receipt / payment / contra for a statement line and links it.
  Future<String> assign(BankLine line, Ledger party, Actor actor) async {
    final VoucherType type;
    String? partyId = party.id;
    String payId = line.bankLedgerId;
    if (party.group.isMoney) {
      // money moved between our own accounts
      type = VoucherType.contra;
      if (line.isIn) {
        partyId = line.bankLedgerId;
        payId = party.id;
      }
    } else {
      type = line.isIn ? VoucherType.receipt : VoucherType.payment;
    }
    final desc = line.description.length > 120 ? line.description.substring(0, 120) : line.description;
    final id = await vouchers.save(
      VoucherInput(
        type: type,
        date: line.date,
        partyId: partyId,
        payLedgerId: payId,
        amount: line.amount,
        narration: desc,
        refNo: line.ref.isEmpty ? null : line.ref,
      ),
      actor,
    );
    await db.execute("UPDATE bank_lines SET voucher_id = ?, status = 'matched' WHERE id = ?", [id, line.id]);
    return id;
  }

  Future<void> setStatus(BankLine line, String status) => db.execute(
      'UPDATE bank_lines SET status = ?, voucher_id = ${status == 'open' ? 'NULL' : 'voucher_id'} WHERE id = ?', [status, line.id]);
}
