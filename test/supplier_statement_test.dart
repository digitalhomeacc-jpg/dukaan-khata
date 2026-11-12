import 'dart:convert';

import 'package:dukaan_khata/shared/supplier_statement.dart';
import 'package:flutter_test/flutter_test.dart';

/// A made-up statement in the layout of a cement company's account PDF:
/// each record's middle line has S.N., date, narration, item, qty, amount, balance;
/// wrapped voucher / invoice numbers sit on the lines above and below.
String sample() {
  final items = <List>[];
  var y = 900.0;
  void row(int sn, String date, {String? narration, String? item, required String qty, required String amt, required String bal, bool credit = false}) {
    items.add([1, 151, y + 5, 40, 'DHL27INV001']);
    items.add([1, 18, y, 5, '$sn']);
    items.add([1, 35, y, 40, date]);
    if (narration != null) items.add([1, 230, y, 120, narration]);
    if (item != null) items.add([1, 553, y, 20, item]);
    items.add([1, 596, y, 20, qty]);
    items.add([1, credit ? 689 : 641, y, 40, amt]);
    items.add([1, 763, y, 40, bal]);
    items.add([1, 171, y - 5, 12, '20$sn']);
    y -= 22;
  }

  items.add([1, 47, 1015, 20, 'Date']);
  items.add([1, 266, 992, 60, 'Opening Balance']);
  items.add([1, 776, 992, 20, '0.00']);
  row(1, '09-04-2026', item: 'PPC', qty: '21.00', amt: '133489.00', bal: '133489.00');
  row(2, '10-04-2026', narration: 'Fund Received on Date 10-Apr-2026', qty: '0.00', amt: '-500000.00', bal: '-366511.00', credit: true);
  row(3, '11-04-2026', item: 'PLUS', qty: '5.00', amt: '34549.00', bal: '-331962.00');
  row(4, '30-04-2026', narration: 'Trade Discount for Apr 26', qty: '0.00', amt: '-183772.00', bal: '-515734.00', credit: true);
  row(5, '30-04-2026', narration: 'Trf to Security Ledger', qty: '0.00', amt: '13140.00', bal: '-502594.00');
  return jsonEncode(items);
}

void main() {
  test('reads a company statement: dates, sides, kinds and the running balance', () {
    final l = SupplierStatement.parsePdfJson(sample());
    expect(l.length, 5);
    expect(SupplierStatement.misread(l), 0);
    expect(l.map((x) => x.kind), ['invoice', 'payment', 'invoice', 'discount', 'charge']);
    expect(l.first.date, '2026-04-09');
    expect(l.first.debit, 13348900);
    expect(l.first.qty, 21);
    expect(l[1].credit, 50000000);
    expect(l[3].text, contains('Trade Discount'));
    expect(l.last.balance, -50259400);
  });

  test('matches statement lines with khata entries by side, amount and nearest date', () {
    final l = SupplierStatement.parsePdfJson(sample());
    final ours = [
      KhataEntry('v1', '2026-04-10', 'purchase', 13348900, 0), // invoice, entered a day later
      KhataEntry('v2', '2026-04-10', 'payment', 0, 50000000),
      KhataEntry('v3', '2026-04-12', 'purchase', 3454900 + 100, 0), // typed ₹1 off → does not match
      KhataEntry('v4', '2026-06-01', 'payment', 0, 18377200), // right amount, a month away → not the same
    ];
    final m = SupplierMatch.match(l, ours);
    expect(m.matched, 2);
    expect(m.missing.map((x) => x.kind), ['invoice', 'discount', 'charge']);
    expect(m.extra.map((e) => e.voucherId), ['v3', 'v4']);
    expect(m.stBilled, 13348900 + 3454900 + 1314000);
    expect(m.ourPaid, 50000000 + 18377200);
  });

  test('invoice dated before the books start, goods entered after: matched as in transit', () {
    final l = SupplierStatement.parsePdfJson(sample());
    final inv = l.first; // 09-04-2026 invoice ₹1,33,489
    final ours = [KhataEntry('p1', '2026-04-10', 'purchase', 13348900 - 50, 0)]; // next day, 50 paise rounding
    final m = SupplierMatch.match(const [], ours, early: [inv]);
    expect(m.transit, [inv]);
    expect(m.extra, isEmpty);
    expect(m.missing, isEmpty);
    // an invoice with no purchase after the start stays an old entry
    final m2 = SupplierMatch.match(const [], const [], early: [inv]);
    expect(m2.transit, isEmpty);
  });
}
