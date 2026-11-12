import 'dart:convert';

import '../core/money.dart';

/// One line of a supplier's account statement (e.g. the cement company's
/// "Customer Account Statement" PDF).
class SupplierLine {
  final String date; // YYYY-MM-DD
  final String text; // narration / item / reference, as printed
  final double qty;
  final int debit; // paise – billed to us (invoice, charge)
  final int credit; // paise – credited to us (our payment, discount, credit note)
  final int balance; // paise – their running balance (+ = we owe them)
  SupplierLine(this.date, this.text, this.qty, this.debit, this.credit, this.balance);

  /// invoice (goods billed) · payment (money they received from us) ·
  /// discount (credit note / scheme) · charge (any other debit)
  String get kind => debit > 0
      ? (qty > 0 ? 'invoice' : 'charge')
      : RegExp(r'fund|receiv|payment|rtgs|neft|imps|cheque|chq', caseSensitive: false).hasMatch(text)
          ? 'payment'
          : 'discount';
  int get amount => debit > 0 ? debit : credit;
}

class SupplierStatement {
  /// Reads the positioned text of a statement PDF (JSON from extractPdfText:
  /// `[[page, x, y, width, text], …]`). A statement line is any printed row
  /// with a date and at least two money figures; the last figure is the
  /// running balance, the one before it the amount (negative = credited).
  static List<SupplierLine> parsePdfJson(String json) {
    final items = (jsonDecode(json) as List).cast<List>();
    final rows = <String, List<List>>{};
    for (final it in items) {
      (rows['${it[0]}|${(it[2] as num).round()}'] ??= []).add(it);
    }
    final dateRe = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$');
    final numRe = RegExp(r'^-?[\d,]+\.\d{2}$');
    final out = <(int, double, SupplierLine)>[];
    for (final e in rows.entries) {
      final cells = e.value..sort((a, b) => (a[1] as num).compareTo(b[1] as num));
      final texts = [for (final c in cells) (c[4] as String).trim()];
      final di = texts.indexWhere(dateRe.hasMatch);
      if (di < 0) continue;
      final nums = [for (final t in texts) if (numRe.hasMatch(t)) t];
      if (nums.length < 2) continue;
      final m = dateRe.firstMatch(texts[di])!;
      final date = '${m[3]}-${m[2]!.padLeft(2, '0')}-${m[1]!.padLeft(2, '0')}';
      int p(String s) => Money.parse(s) ?? 0;
      final balance = p(nums.last), amt = p(nums[nums.length - 2]);
      final qty = nums.length >= 3 ? (double.tryParse(nums[nums.length - 3].replaceAll(',', '')) ?? 0) : 0.0;
      final words = [
        for (var i = 0; i < texts.length; i++)
          if (i != di && !numRe.hasMatch(texts[i]) && !(i < di && RegExp(r'^\d+$').hasMatch(texts[i]))) texts[i]
      ].join(' ');
      final page = int.parse(e.key.split('|')[0]);
      final y = (cells.first[2] as num).toDouble();
      out.add((page, -y, SupplierLine(date, words, qty, amt > 0 ? amt : 0, amt < 0 ? -amt : 0, balance)));
    }
    // as printed: page by page, top to bottom
    out.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final o in out) o.$3];
  }

  /// Lines whose running balance does not follow from the line before –
  /// a sign the file was not read correctly (should be empty).
  static int misread(List<SupplierLine> lines) {
    var bad = 0;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].balance != lines[i - 1].balance + lines[i].debit - lines[i].credit) bad++;
    }
    return bad;
  }
}

/// A khata entry to match against (from the supplier's ledger statement).
class KhataEntry {
  final String voucherId;
  final String date;
  final String text;
  final int bought; // credit to the supplier – goods we bought
  final int paid; // debit – money we paid / discount received
  KhataEntry(this.voucherId, this.date, this.text, this.bought, this.paid);
}

class SupplierMatch {
  final List<SupplierLine> missing = []; // on the statement, not in the khata
  /// Invoices dated just before the books start whose goods were entered as a
  /// purchase after it (invoice 7/11, truck 8/11): matched, not old entries.
  final List<SupplierLine> transit = [];
  final List<KhataEntry> extra = []; // in the khata, not on the statement
  int matched = 0;
  int stBilled = 0, stCredited = 0, ourBought = 0, ourPaid = 0;

  /// Pairs statement lines with khata entries of the same amount and side,
  /// nearest date first (within [days]).
  ///
  /// [early]: invoices from the days before the books start; each one that
  /// pairs with a purchase after the start counts as [transit], the rest are
  /// left alone (they are old entries).
  static SupplierMatch match(List<SupplierLine> st, List<KhataEntry> ours, {int days = 7, List<SupplierLine> early = const []}) {
    final r = SupplierMatch();
    final used = <int>{};
    for (final o in ours) {
      r.ourBought += o.bought;
      r.ourPaid += o.paid;
    }
    // amounts may differ by a rupee of rounding
    bool same(int a, int b) => (a - b).abs() < 100; // paise of rounding, not a rupee
    int? find(SupplierLine l) {
      final d = parseIso(l.date);
      int? best;
      var bestGap = days + 1;
      for (var i = 0; i < ours.length; i++) {
        if (used.contains(i)) continue;
        final o = ours[i];
        if (!same(l.debit > 0 ? o.bought : o.paid, l.amount) || (l.debit > 0 ? o.bought : o.paid) == 0) continue;
        final gap = parseIso(o.date).difference(d).inDays.abs();
        if (gap < bestGap) {
          bestGap = gap;
          best = i;
        }
      }
      return best;
    }

    for (final l in st) {
      r.stBilled += l.debit;
      r.stCredited += l.credit;
      final best = find(l);
      if (best == null) {
        r.missing.add(l);
      } else {
        used.add(best);
        r.matched++;
      }
    }
    for (final l in early.where((x) => x.kind == 'invoice')) {
      final best = find(l);
      if (best != null) {
        used.add(best);
        r.transit.add(l);
        r.stBilled += l.debit;
      }
    }
    for (var i = 0; i < ours.length; i++) {
      if (!used.contains(i)) r.extra.add(ours[i]);
    }
    return r;
  }


}

/// Statement lines before the books start → old entries (जुन्या नोंदी) on the
/// supplier's khata. Old entries are reference only: no balance, stock or
/// cash changes. Lines already imported (same date, kind and amount) are
/// skipped, so importing the same PDF twice adds nothing.
class StatementImport {
  /// Old-entry kind for a statement line, seen from our side.
  static String kindOf(SupplierLine l) => l.debit > 0 ? 'purchase' : 'paid';

  static String keyOf(String date, String kind, int amount) => '$date|$kind|$amount';
}
