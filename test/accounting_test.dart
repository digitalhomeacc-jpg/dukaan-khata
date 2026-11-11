import 'dart:convert';

import 'package:dukaan_khata/accounting/bookings.dart';
import 'package:dukaan_khata/accounting/interest.dart';
import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/recurring.dart';
import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/accounting/reports.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/audit.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/core/seed.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'test_db.dart';

const biz = 'biz1';
const owner = Actor(userId: 'u1', name: 'Owner', isOwner: true);
const staff = Actor(userId: 'u2', name: 'Staff', isOwner: false);
int rs(num r) => Money.fromRupees(r);

void main() {
  late SqliteDatabase db;
  late VoucherService vs;
  late LedgerRepo lr;
  late StockRepo sr;
  late Map<String, Item> items; // by short code

  setUp(() async {
    Books.start = '2000-01-01'; // these tests use dates from the paper registers
    db = await openTestDb(biz);
    vs = VoucherService(db, biz);
    lr = LedgerRepo(db, biz);
    sr = StockRepo(db, biz);
    items = {for (final i in await sr.list()) i.shortCode!: i};
  });
  tearDown(() => db.close());

  test('every voucher type produces balanced lines', () {
    for (final t in [
      VoucherType.sale,
      VoucherType.salesReturn,
      VoucherType.purchase,
      VoucherType.purchaseReturn,
      VoucherType.receipt,
      VoucherType.payment,
      VoucherType.contra,
    ]) {
      final lines = vs.buildLines(VoucherInput(
        type: t,
        date: '2026-11-05',
        partyId: 'party',
        payLedgerId: vs.sys('upi_h'),
        amount: rs(1000),
        paid: rs(400),
        discount: rs(10),
      ));
      final d = lines.fold<int>(0, (s, l) => s + l.debit);
      final c = lines.fold<int>(0, (s, l) => s + l.credit);
      expect(d, c, reason: t.code);
      expect(d, greaterThan(0), reason: t.code);
    }
    expect(
        () => vs.buildLines(VoucherInput(type: VoucherType.journal, date: '2026-11-05', journalLines: [
              MoneyLine('a', debit: 100),
              MoneyLine('b', credit: 90),
            ])),
        throwsArgumentError);
  });

  // A khata page worked through by hand (made-up customer): every running
  // balance must match the sum written on paper.
  test('a khata page adds up exactly like the paper register', () async {
    final id = await lr.create(
        name: 'सुरेश जाधव', nameEn: 'Suresh Jadhav', group: LedgerGroup.customer, pageNo: '29', openingBalance: rs(31250));
    final m = items['M']!;
    Future<void> sale(String d, double q, int rate) => vs.save(
        VoucherInput(type: VoucherType.sale, date: d, partyId: id, items: [ItemLine(m.id, q, rs(rate))]), owner);
    await sale('2026-09-14', 5, 273); // 1365
    await sale('2026-09-19', 10, 278); // 2780
    await sale('2026-09-21', 2, 278); // 556
    await sale('2026-09-23', 2, 278); // 556
    await sale('2026-09-24', 8, 278); // 2224
    await sale('2026-10-02', 10, 278); // 2780
    await sale('2026-10-04', 12, 275); // 3300
    await sale('2026-10-05', 7, 283); // 1981
    var bal = await lr.balanceAt(id);
    expect(bal, rs(31250 + 1365 + 2780 + 556 + 556 + 2224 + 2780 + 3300 + 1981)); // 46,792
    await vs.save(
        VoucherInput(type: VoucherType.receipt, date: '2026-10-06', partyId: id, payLedgerId: vs.sys('cash'), amount: rs(30000)),
        owner);
    await sale('2026-10-09', 10, 283);
    await sale('2026-10-11', 7, 283);
    await sale('2026-10-12', 4, 283);
    bal = await lr.balanceAt(id);
    expect(bal, rs(16792 + 2830 + 1981 + 1132));

    final st = await lr.statement(id);
    expect(st.opening, rs(31250));
    expect(st.rows.length, 12);
    expect(st.rows.first.details, 'M 5×273');
    expect(st.closing, rs(22735));

    // Stock moved out for M
    final mStock = await sr.stockAt(m.id, '2026-12-31');
    expect(mStock, -(5 + 10 + 2 + 2 + 8 + 10 + 12 + 7 + 10 + 7 + 4).toDouble());
  });

  test('sale paid by PhonePe hits the PhonePe rojmal and leaves zero due', () async {
    final cust = await lr.create(name: 'Ramesh', group: LedgerGroup.customer);
    final u = items['U']!;
    await vs.save(
      VoucherInput(
          type: VoucherType.sale,
          date: '2026-11-05',
          partyId: cust,
          payLedgerId: vs.sys('upi_h'),
          items: [ItemLine(u.id, 15, rs(275))],
          paid: rs(4125)),
      owner,
    );
    expect(await lr.balanceAt(cust), 0);
    final book = await lr.cashBook([vs.sys('upi_h')], '2026-11-05');
    expect(book.totalIn, rs(4125));
    expect(book.rows.single.particulars, 'Ramesh');
    expect(book.rows.single.code, 'H');
  });

  test('walk-in cash sale, expense and rojmal opening/closing carry forward', () async {
    final cash = vs.sys('cash');
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-04', amount: rs(5000)), owner);
    await vs.save(
        VoucherInput(type: VoucherType.payment, date: '2026-11-04', partyId: vs.sys('tea'), payLedgerId: cash, amount: rs(80)),
        owner);
    final d1 = await lr.cashBook([cash], '2026-11-04');
    expect(d1.opening, 0);
    expect(d1.closing, rs(4920));
    // contra: deposit 4000 cash into bank
    await vs.save(
        VoucherInput(type: VoucherType.contra, date: '2026-11-05', partyId: vs.sys('bank'), payLedgerId: cash, amount: rs(4000)),
        owner);
    final d2 = await lr.cashBook([cash], '2026-11-05');
    expect(d2.opening, rs(4920));
    expect(d2.closing, rs(920));
    expect(await lr.balanceAt(vs.sys('bank')), rs(4000));
  });

  test('purchase with part payment, supplier balance and weighted average cost', () async {
    final sup = await lr.create(name: 'Cement Agency', group: LedgerGroup.supplier);
    final a = items['A']!;
    await sr.save(id: a.id, name: a.name, category: a.category, unit: a.unit, shortCode: 'A', openingQty: 100, openingRate: rs(250));
    await vs.save(
      VoucherInput(
          type: VoucherType.purchase,
          date: '2026-11-01',
          partyId: sup,
          payLedgerId: vs.sys('bank'),
          items: [ItemLine(a.id, 100, rs(270))],
          paid: rs(20000),
          gstBillNeeded: true),
      owner,
    );
    expect(await lr.balanceAt(sup), -rs(7000)); // we owe 27000 − 20000
    expect(await sr.stockAt(a.id, '2026-11-30'), 200);
    final avg = await sr.averageCosts();
    expect(avg[a.id], closeTo(rs(260), 0.001));
  });

  test('edit keeps audit trail, delete is soft, staff restrictions', () async {
    final cust = await lr.create(name: 'Test', group: LedgerGroup.customer);
    final today = todayIso();
    final id = await vs.save(VoucherInput(type: VoucherType.sale, date: today, partyId: cust, amount: rs(100)), staff);
    await vs.save(VoucherInput(type: VoucherType.sale, date: today, partyId: cust, amount: rs(150)), staff, existingId: id);
    expect(await lr.balanceAt(cust), rs(150));
    expect(() => vs.delete(id, staff), throwsA(isA<PermissionDenied>()));
    expect(
        () => vs.save(VoucherInput(type: VoucherType.sale, date: '2020-01-01', partyId: cust, amount: rs(1)), staff),
        throwsA(isA<PermissionDenied>()));
    await vs.delete(id, owner);
    expect(await lr.balanceAt(cust), 0);
    final audit = await db.getAll('SELECT action FROM audit_log WHERE voucher_id = ? ORDER BY at', [id]);
    expect(audit.map((r) => r['action']), ['create', 'edit', 'delete']);
  });

  test('daily stock register shows opening, rows and closing', () async {
    final cust = await lr.create(name: 'Raju', group: LedgerGroup.customer, pageNo: '84');
    final u = items['U']!;
    final s8 = items['8']!;
    await sr.save(id: u.id, name: u.name, category: u.category, unit: u.unit, shortCode: 'U', openingQty: 222);
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-05', partyId: cust, items: [
          ItemLine(u.id, 15, rs(275)),
          ItemLine(s8.id, 120.5, rs(62)),
        ]),
        owner);
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-05', items: [ItemLine(u.id, 10, rs(280))]), owner);
    final reg = await sr.dailyRegister('2026-11-05');
    expect(reg.opening[u.id], 222);
    expect(reg.rows.length, 2);
    expect(reg.rows.first.pageNo, '84');
    expect(reg.totalOut(u.id), 25);
    expect(reg.closing(u.id), 197);
    expect(reg.closing(s8.id), -120.5);

    // printable / PDF version of the same day
    final rep = Reports(db, biz, (k) => k);
    final t = await rep.dailyRegister('2026-11-05');
    // #, party, moved items…, amount, paid-by
    expect(t.columns.first.title, '#');
    expect(t.columns.last.title, 'pay_mode');
    final itemCols = t.columns.length - 4;
    expect(itemCols, greaterThan(0));
    expect(t.rows.first[1], 'opening');
    expect(t.rows.length, 1 + 2 + 2); // opening, 2 bills, out, in
    expect(t.rows[1][1], contains('(84)'));
    expect(t.totals![1], 'closing');
    expect(t.rows.every((r) => r.length == t.columns.length), isTrue);
    expect(t.totals!.length, t.columns.length);
  });

  test('search by page number, Marathi and English name', () async {
    await lr.create(name: 'सुरेश जाधव', nameEn: 'Suresh Jadhav', group: LedgerGroup.customer, pageNo: '29');
    expect((await lr.search('29')).single.nameEn, 'Suresh Jadhav');
    expect((await lr.search('सुरेश')).single.pageNo, '29');
    expect((await lr.search('suresh')).single.pageNo, '29');
    expect((await lr.search('२९')).single.pageNo, '29');
  });

  test('उसना माल: bags lent and returned move stock, show as bags owed, never money', () async {
    final cust = await lr.create(name: 'Prakash', group: LedgerGroup.customer);
    final shop = await lr.create(name: 'Neighbour Shop', group: LedgerGroup.supplier);
    final w = items['W']!;
    const day = '2026-11-07';
    final stock0 = await sr.stockAt(w.id, day);
    final bal0 = await lr.balanceAt(cust);
    final cash0 = await lr.balanceAt(vs.sys('cash'));

    // 30 bags given on loan
    final out = await vs.save(VoucherInput(type: VoucherType.goodsOut, date: day, partyId: cust, items: [ItemLine(w.id, 30, rs(280))]), owner);
    expect(await sr.stockAt(w.id, day), stock0 - 30);
    expect(await lr.balanceAt(cust), bal0); // money untouched
    expect(await lr.balanceAt(vs.sys('cash')), cash0);
    var owed = await sr.goodsOwed(partyId: cust);
    expect(owed.single.item.id, w.id);
    expect(owed.single.qty, 30);
    // still ours for valuation: in-shop + lent stays the same
    expect(await sr.stockAt(w.id, day) + await sr.lentAt(w.id, day), stock0);
    final (ov, ol) = await vs.load(out);
    expect(ov.amount, 0);
    expect(ol.single.rate, 0);

    // 20 come back, then 10 more → nothing owed
    await vs.save(VoucherInput(type: VoucherType.goodsIn, date: day, partyId: cust, items: [ItemLine(w.id, 20, 0)]), owner);
    expect((await sr.goodsOwed(partyId: cust)).single.qty, 10);
    await vs.save(VoucherInput(type: VoucherType.goodsIn, date: day, partyId: cust, items: [ItemLine(w.id, 10, 0)]), owner);
    expect(await sr.goodsOwed(partyId: cust), isEmpty);
    expect(await sr.stockAt(w.id, day), stock0);
    expect((await sr.goodsMoves(cust)).length, 3);

    // we borrow 5 bags from the neighbour → we owe them
    await vs.save(VoucherInput(type: VoucherType.goodsIn, date: day, partyId: shop, items: [ItemLine(w.id, 5, 0)]), owner);
    owed = await sr.goodsOwed();
    expect(owed.single.partyId, shop);
    expect(owed.single.qty, -5);
    expect(await sr.lentAt(w.id, day), -5); // not ours

    expect(await lr.unbalanced(), isEmpty);
    expect(() => vs.save(VoucherInput(type: VoucherType.goodsOut, date: day, items: [ItemLine(w.id, 1, 0)]), owner), throwsArgumentError);
  });

  test('opening उसना माल: owed bags only – stock, money and profit untouched', () async {
    final cust = await lr.create(name: 'Deepak', group: LedgerGroup.customer, openingBalance: rs(5000));
    final w = items['W']!;
    const day = '2026-11-07';
    final start = Books.start;
    final stock0 = await sr.stockAt(w.id, day);
    final lent0 = await sr.lentAt(w.id, day);
    final lentBefore0 = await sr.lentAt(w.id, start, before: true);
    final cash0 = await lr.balanceAt(vs.sys('cash'));

    // 30 bags were lent before the books started
    VoucherInput opening(Actor a, String d) => VoucherInput(
        type: VoucherType.goodsOut, date: d, partyId: cust, payLedgerId: goodsOpeningMarker, items: [ItemLine(w.id, 30, 0)]);
    expect(() => vs.save(opening(staff, start), staff), throwsA(isA<PermissionDenied>()));
    expect(() => vs.save(opening(owner, day), owner), throwsArgumentError);
    await vs.save(opening(owner, start), owner);

    expect((await sr.goodsOwed(partyId: cust)).single.qty, 30);
    expect(await sr.stockAt(w.id, day), stock0); // shop stock unchanged
    expect(await lr.balanceAt(cust), rs(5000)); // money unchanged
    expect(await lr.balanceAt(vs.sys('cash')), cash0);
    final reg = await sr.dailyRegister(start);
    expect(reg.rows, isEmpty); // not in the stock register
    // counted in stock value on every date alike (opening and closing) → no profit effect
    expect(await sr.lentAt(w.id, day) - lent0, 30);
    expect(await sr.lentAt(w.id, start, before: true) - lentBefore0, 30);

    // they bring the bags back → into stock, nothing owed
    await vs.save(VoucherInput(type: VoucherType.goodsIn, date: day, partyId: cust, items: [ItemLine(w.id, 30, 0)]), owner);
    expect(await sr.goodsOwed(partyId: cust), isEmpty);
    expect(await sr.stockAt(w.id, day), stock0 + 30);
    expect(await sr.stockAt(w.id, day) + await sr.lentAt(w.id, day), stock0 + lent0 + 30);
    final moves = await sr.goodsMoves(cust);
    expect(moves.where((m) => m.$5).length, 1);
  });

  test('व्याज: simple interest on the daily balance, posted to the khata, never on interest', () async {
    final cust = await lr.create(name: 'Vilas', group: LedgerGroup.customer, openingBalance: rs(10000));
    final ins = InterestService(db, biz);
    // ₹10,000 for 30 days at 1.5 % a month = ₹150
    var c = await ins.calculate(cust, from: '2026-10-01', to: '2026-10-30', rate: 150);
    expect(c.days, 30);
    expect(c.interest, rs(150));

    // ₹5,000 paid on the 16th: 15 days on 10,000 (75) + 15 days on 5,000 (37.50) = 112.50 → ₹113
    await vs.save(VoucherInput(type: VoucherType.receipt, date: '2026-10-16', partyId: cust, payLedgerId: vs.sys('cash'), amount: rs(5000)), owner);
    c = await ins.calculate(cust, from: '2026-10-01', to: '2026-10-30', rate: 150);
    expect(c.slabs.length, 2);
    expect(c.slabs.first.days, 15);
    expect(c.interest, rs(113));

    // only the owner can charge it; it goes on the khata as व्याज
    expect(() => ins.post(vs, staff, c, note: 'x'), throwsA(isA<PermissionDenied>()));
    await ins.post(vs, owner, c, note: 'व्याज');
    expect(await lr.balanceAt(cust), rs(5000 + 113));
    expect(await lr.balanceAt(vs.sys('interest_income')), -rs(113));
    expect(await ins.lastCharged(cust), '2026-10-30');
    expect(await ins.defaultFrom(cust, '2026-11-30'), '2026-10-31');

    // next month: base is still ₹5,000 – no interest on the ₹113 interest
    c = await ins.calculate(cust, from: '2026-10-31', to: '2026-11-29', rate: 150);
    expect(c.interest, rs(75));

    // advance / zero balance → no interest
    await vs.save(VoucherInput(type: VoucherType.receipt, date: '2026-11-01', partyId: cust, payLedgerId: vs.sys('cash'), amount: rs(6000)), owner);
    c = await ins.calculate(cust, from: '2026-11-01', to: '2026-11-30', rate: 150);
    expect(c.interest, 0);
    expect(parseRate('1.5'), 150);
    expect(fmtRate(150), '1.5');
    expect(fmtRate(200), '2');
  });

  test('staff: advance, salary with deduction, balance carried forward', () async {
    final raju = await lr.create(name: 'Raju', group: LedgerGroup.staff);
    await lr.setStaffPay(raju, salary: rs(12000), cut: rs(3000));
    expect((await lr.byId(raju))!.salary, rs(12000));
    final cash0 = await lr.balanceAt(vs.sys('cash'));
    // ₹5,000 advance in the month
    await vs.save(VoucherInput(type: VoucherType.payment, date: '2026-11-05', partyId: raju, payLedgerId: vs.sys('cash'), amount: rs(5000)), owner);
    expect(await lr.balanceAt(raju), rs(5000)); // he owes the advance
    // month end: salary 12,000, recover 3,000, hand over 9,000
    VoucherInput pay(int paid) => VoucherInput(type: VoucherType.salary, date: '2026-11-30', partyId: raju, payLedgerId: vs.sys('cash'), amount: rs(12000), paid: paid, narration: 'पगार');
    expect(() => vs.save(pay(rs(9000)), staff), throwsA(isA<PermissionDenied>()));
    expect(() => vs.save(pay(rs(13000)), owner), throwsArgumentError);
    await vs.save(pay(rs(9000)), owner);
    expect(await lr.balanceAt(raju), rs(2000)); // advance left
    expect(await lr.balanceAt(vs.sys('salary')), rs(12000)); // full salary is the expense
    expect(await lr.balanceAt(vs.sys('cash')), cash0 - rs(5000) - rs(9000));
    expect(await lr.unbalanced(), isEmpty);
  });

  test('bookings: advance on the khata, deliveries counted oldest first, rate locked', () async {
    final bs = BookingService(db, biz);
    final cust = await lr.create(name: 'Builder', group: LedgerGroup.customer);
    final sup = await lr.create(name: 'Cement Co', group: LedgerGroup.supplier);
    final u = items['U']!;
    final m = items['M']!;
    final stock0 = await sr.stockAt(u.id, '2026-11-30');
    // customer books 200 U @ 275 and 50 M @ 280 with ₹30,000 advance in cash
    final b1 = await bs.save(vs, owner,
        date: '2026-11-01', partyId: cust, customer: true,
        items: [ItemLine(u.id, 200, rs(275)), ItemLine(m.id, 50, rs(280))], advance: rs(30000), advanceLedgerId: vs.sys('cash'));
    expect(await lr.balanceAt(cust), -rs(30000)); // advance with us
    expect(await sr.stockAt(u.id, '2026-11-30'), stock0); // no stock effect
    // a second booking later
    await bs.save(vs, owner, date: '2026-11-10', partyId: cust, customer: true, items: [ItemLine(u.id, 100, rs(285))]);
    // a sale before the booking does not count; later sales do, oldest booking first
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-10-30', partyId: cust, items: [ItemLine(u.id, 10, rs(290))]), owner);
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-05', partyId: cust, items: [ItemLine(u.id, 150, rs(275))]), owner);
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-12', partyId: cust, items: [ItemLine(u.id, 80, rs(275))]), owner);
    var list = await bs.list(customer: true);
    expect(list.length, 2);
    final first = list.firstWhere((b) => b.id == b1);
    expect(first.lines.firstWhere((l) => l.item.id == u.id).delivered, 200); // 150 + 50
    expect(first.lines.firstWhere((l) => l.item.id == m.id).remaining, 50);
    expect(first.open, isTrue);
    final second = list.firstWhere((b) => b.id != b1);
    expect(second.lines.single.delivered, 30);
    expect(second.lines.single.remaining, 70);
    expect(second.advance, 0);

    // closing the first booking: no longer offered on the bill
    await bs.setClosed(b1, true);
    final open = await bs.openFor(cust, customer: true);
    expect(open.single.id, second.id);
    // edits keep it closed
    await bs.save(vs, owner, existingId: b1, date: '2026-11-01', partyId: cust, customer: true, items: [ItemLine(u.id, 200, rs(275))]);
    expect((await bs.list(customer: true)).firstWhere((b) => b.id == b1).closed, isTrue);

    // supplier booking: we pay advance, purchases count against it
    await bs.save(vs, owner, date: '2026-11-02', partyId: sup, customer: false,
        items: [ItemLine(u.id, 500, rs(250))], advance: rs(50000), advanceLedgerId: vs.sys('bank'));
    expect(await lr.balanceAt(sup), rs(50000)); // advance paid to supplier
    await vs.save(VoucherInput(type: VoucherType.purchase, date: '2026-11-08', partyId: sup, items: [ItemLine(u.id, 300, rs(250))]), owner);
    final sb = (await bs.list(customer: false)).single;
    expect(sb.lines.single.delivered, 300);
    expect(sb.lines.single.remaining, 200);
    expect((await bs.list(customer: true)).length, 2);
    expect(await lr.unbalanced(), isEmpty);
  });

  test('booking before the books start is a note only: no receipt, no balance change', () async {
    final bs = BookingService(db, biz);
    final cust = await lr.create(name: 'Old Builder', group: LedgerGroup.customer, openingBalance: -rs(10000)); // advance in opening
    final u = items['U']!;
    final cash0 = await lr.balanceAt(vs.sys('cash'));
    const before = '1999-12-01'; // tests' books start is 2000-01-01
    expect(
        () => bs.save(vs, staff, date: before, partyId: cust, customer: true, items: [ItemLine(u.id, 80, rs(270))]),
        throwsA(isA<PermissionDenied>()));
    final id = await bs.save(vs, owner, date: before, partyId: cust, customer: true,
        items: [ItemLine(u.id, 80, rs(270))], advance: rs(10000), advanceLedgerId: vs.sys('cash'));
    expect(await lr.balanceAt(cust), -rs(10000)); // unchanged
    expect(await lr.balanceAt(vs.sys('cash')), cash0); // no receipt
    expect(await lr.unbalanced(), isEmpty);
    var b = (await bs.list(customer: true)).single;
    expect(b.id, id);
    expect(b.old, isTrue);
    expect(b.advance, rs(10000)); // shown for reference
    // bills after the books start count against it
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-05', partyId: cust, items: [ItemLine(u.id, 30, rs(270))]), owner);
    b = (await bs.list(customer: true)).single;
    expect(b.lines.single.delivered, 30);
    expect(b.lines.single.remaining, 50);
  });

  test('services: billed like items, no stock, income in सेवा उत्पन्न', () async {
    final cust = await lr.create(name: 'Home Owner', group: LedgerGroup.customer);
    final contractor = await lr.create(name: 'Paint Contractor', group: LedgerGroup.supplier);
    final work = await sr.save(name: 'Wall work', category: serviceCategory, unit: 'sqft', saleRate: rs(12));
    final w = items['W']!;
    const day = '2026-11-07';
    final stockW = await sr.stockAt(w.id, day);
    // one bill: 10 bags cement + 500 sq ft of work at ₹12
    final id = await vs.save(
        VoucherInput(type: VoucherType.sale, date: day, partyId: cust, items: [ItemLine(w.id, 10, rs(280)), ItemLine(work, 500, rs(12))]),
        owner);
    expect(await lr.balanceAt(cust), rs(2800 + 6000));
    expect(await lr.balanceAt(vs.sys('sales')), -rs(2800)); // goods only
    expect(await lr.balanceAt(vs.sys('service_income')), -rs(6000));
    expect(await sr.stockAt(w.id, day), stockW - 10);
    expect(await sr.stockAt(work, day), 0); // never in stock
    final reg = await sr.dailyRegister(day);
    expect(reg.items.any((i) => i.id == work), isFalse);
    expect(reg.rows.single.qty.containsKey(work), isFalse);
    // the bill still shows the service line when opened again
    final (_, lines) = await vs.load(id);
    expect(lines.map((l) => l.itemId), containsAll([w.id, work]));
    // work bought from a contractor → service cost, not purchases / stock
    await vs.save(VoucherInput(type: VoucherType.purchase, date: day, partyId: contractor, items: [ItemLine(work, 500, rs(8))]), owner);
    expect(await lr.balanceAt(vs.sys('service_cost')), rs(4000));
    expect(await sr.stockAt(work, day), 0);
    expect(await lr.unbalanced(), isEmpty);
    // tapping the service in Stock lists every bill it was on
    final rep = await Reports(db, biz, (k) => k).itemMovement(work, '2026-11-01', '2026-11-30');
    expect(rep.rows.length, 2);
    expect(rep.rows.first[1], contains('Home Owner'));
    expect(rep.totals![4], Money.fmt(rs(6000)));
    expect(rep.totals![5], Money.fmt(rs(4000)));
  });

  test('monthly charges: due from the 1st, charged as a credit bill, missed months caught up', () async {
    final rs_ = RecurringService(db, biz);
    final hotel = await lr.create(name: 'Hotel Annapurna', group: LedgerGroup.customer);
    final rent = await sr.save(name: 'Shop rent', category: serviceCategory, unit: 'job', saleRate: rs(8000));
    final water = await sr.save(name: 'Water', category: serviceCategory, unit: 'job');
    expect(
        () => rs_.save(vs, staff, partyId: hotel, startMonth: '2026-09', lines: [ItemLine(rent, 1, rs(8000))]),
        throwsA(isA<PermissionDenied>()));
    await rs_.save(vs, owner, partyId: hotel, startMonth: '2026-09', lines: [ItemLine(rent, 1, rs(8000)), ItemLine(water, 1, 0)], note: 'हॉटेल');
    expect(await lr.balanceAt(hotel), 0); // the template posts nothing
    expect(await lr.unbalanced(), isEmpty);
    // on 5 Nov: Sep, Oct and Nov are due
    var due = await rs_.due('2026-11-05');
    expect(due.map((d) => d.$2), ['2026-09', '2026-10', '2026-11']);
    final r = due.first.$1;
    expect(r.fixedTotal, rs(8000));
    // charge September with this month's water amount
    await rs_.charge(vs, owner, r, '2026-09', [ItemLine(rent, 1, rs(8000)), ItemLine(water, 1, rs(450))], narration: 'Sep');
    expect(await lr.balanceAt(hotel), rs(8450));
    expect(await lr.balanceAt(vs.sys('service_income')), -rs(8450));
    due = await rs_.due('2026-11-05');
    expect(due.map((d) => d.$2), ['2026-10', '2026-11']);
    // skip October (shop closed), charge November
    await rs_.skip(due.first.$1, '2026-10');
    due = await rs_.due('2026-11-05');
    await rs_.charge(vs, owner, due.single.$1, '2026-11', [ItemLine(rent, 1, rs(8000)), ItemLine(water, 1, rs(500))], narration: 'Nov');
    expect(await rs_.due('2026-11-30'), isEmpty);
    expect((await rs_.due('2026-12-01')).single.$2, '2026-12');
    // stopped: nothing due
    await rs_.setStopped(r.id, true);
    expect(await rs_.due('2027-02-01'), isEmpty);
    expect(await lr.balanceAt(hotel), rs(8450 + 8500));
  });

  test('monthly payments: loan interest reminded and paid from cash', () async {
    final rec = RecurringService(db, biz);
    final interestExp = await lr.create(name: 'Interest paid', group: LedgerGroup.expense);
    final cash0 = await lr.balanceAt(vs.sys('cash'));
    await rec.savePayment(vs, owner, ledgerId: interestExp, payFromId: vs.sys('cash'), startMonth: '2026-10', amount: rs(5000), note: 'Ramesh loan');
    expect(await lr.balanceAt(vs.sys('cash')), cash0); // template posts nothing
    expect(await lr.unbalanced(), isEmpty);
    var due = await rec.due('2026-11-03');
    expect(due.map((d) => d.$2), ['2026-10', '2026-11']);
    final r = due.first.$1;
    expect(r.payment, isTrue);
    expect(r.fixedTotal, rs(5000));
    await rec.pay(vs, owner, r, '2026-10', amount: rs(5000), payFromId: vs.sys('cash'), narration: 'Oct');
    await rec.pay(vs, owner, r, '2026-11', amount: rs(5000), payFromId: vs.sys('upi_h'), narration: 'Nov', date: '2026-11-03');
    expect(await lr.balanceAt(interestExp), rs(10000));
    expect(await lr.balanceAt(vs.sys('cash')), cash0 - rs(5000));
    expect(await rec.due('2026-11-30'), isEmpty);
    expect(() => rec.pay(vs, staff, r, '2026-12', amount: 1, payFromId: vs.sys('cash'), narration: 'x'), throwsA(isA<PermissionDenied>()));
  });

  test('rojmal: cash sale with hamali stays a cash sale; वराई is its own row', () async {
    final w = items['W']!;
    const day = '2026-11-08';
    // walk-in cash bill: 2,240 goods + 30 hamali = 2,270
    await vs.save(VoucherInput(type: VoucherType.sale, date: day, payLedgerId: vs.sys('cash'), items: [ItemLine(w.id, 8, rs(280))], hamali: rs(30)), owner);
    // company truck: paid 10,000 cash on the bill, driver gave 500 वराई
    final wonder = await lr.create(name: 'Wonder Cement', group: LedgerGroup.supplier);
    await vs.save(
        VoucherInput(type: VoucherType.purchase, date: day, partyId: wonder, payLedgerId: vs.sys('cash'), items: [ItemLine(w.id, 40, rs(250))],
            paid: rs(10000), varhai: rs(500)),
        owner);
    // another walk-in bill rounded down: 2,243 → 2,240
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: day, payLedgerId: vs.sys('cash'), items: [ItemLine(w.id, 1, rs(2243))], roundOff: -rs(3)),
        owner);
    final book = await lr.cashBook([vs.sys('cash')], day);
    final sales = book.rows.where((r) => r.type == VoucherType.sale).toList();
    expect(sales.map((r) => r.particulars), ['', '']); // both "रोख विक्री", not हमाली / राउंड ऑफ
    expect(sales.map((r) => r.inflow), [rs(2270), rs(2240)]);
    final sale = sales.first;
    final varhai = book.rows.where((r) => r.varhai).single;
    expect(varhai.inflow, rs(500));
    expect(varhai.particulars, 'Wonder Cement');
    final paid = book.rows.where((r) => r.type == VoucherType.purchase && !r.varhai).single;
    expect(paid.outflow, rs(10000)); // not netted with the वराई
    expect(sale.inflow, rs(2270));
    expect(book.totalIn - book.totalOut, rs(2270 + 2240 + 500 - 10000));
  });

  test('history: every entry, account, item and status change is recorded before → after', () async {
    Future<List<Map<String, dynamic>>> log(String id) async => [
          for (final r in await db.getAll('SELECT * FROM audit_log WHERE voucher_id = ? ORDER BY at, rowid', [id]))
            {'action': r['action'], 'user': r['user_name'], ...jsonDecode(r['snapshot'] as String) as Map<String, dynamic>}
        ];
    final cust = await lr.create(name: 'Mahesh', group: LedgerGroup.customer, pageNo: '12');
    final w = items['W']!;
    // a staff bill, then the owner corrects qty and adds hamali
    final id = await vs.save(VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, items: [ItemLine(w.id, 10, rs(280))]), staff);
    await vs.save(VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, items: [ItemLine(w.id, 12, rs(280))], hamali: rs(50)), owner,
        existingId: id);
    // saving again with no change adds nothing
    await vs.save(VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, items: [ItemLine(w.id, 12, rs(280))], hamali: rs(50)), owner,
        existingId: id);
    await vs.delete(id, owner);
    var l = await log(id);
    expect(l.map((e) => e['action']), ['create', 'edit', 'delete']);
    expect(l[0]['user'], 'Staff');
    expect(l[0]['after']['amount'], '2,800');
    final diff = AuditLog.diff(l[1]['before'], l[1]['after']);
    expect(diff.map((d) => d.$1), containsAll(['amount', 'items', 'hamali']));
    expect(diff.firstWhere((d) => d.$1 == 'items').$2, 'W सिमेंट 10×280');
    expect(diff.firstWhere((d) => d.$1 == 'items').$3, 'W सिमेंट 12×280');
    expect(l[2]['before']['amount'], '3,410');

    // account: opening balance and interest rate
    await lr.update(cust, name: 'Mahesh', pageNo: '12', openingBalance: rs(500));
    await lr.setInterestRate(cust, 150);
    l = await log(cust);
    expect(l.map((e) => e['action']), ['create', 'edit', 'edit']);
    expect(AuditLog.diff(l[1]['before'], l[1]['after']).single, ('opening_balance', null, '500'));
    expect(AuditLog.diff(l[2]['before'], l[2]['after']).single.$3, '1.5%');

    // item rate
    await sr.save(id: w.id, name: w.name, nameEn: w.nameEn, category: w.category, unit: w.unit, shortCode: w.shortCode, saleRate: rs(290));
    l = await log(w.id);
    expect(AuditLog.diff(l.single['before'], l.single['after']).single, ('sale_rate', '280', '290'));

    // changes that don't touch the amount field are still caught
    final rc = await vs.save(VoucherInput(type: VoucherType.receipt, date: todayIso(), partyId: cust, payLedgerId: vs.sys('cash'), amount: rs(1000)), owner);
    await vs.save(VoucherInput(type: VoucherType.receipt, date: todayIso(), partyId: cust, payLedgerId: vs.sys('cash'), amount: rs(1000), discount: rs(20)), owner,
        existingId: rc);
    l = await log(rc);
    expect(l.map((e) => e['action']), ['create', 'edit']); // discount only → still recorded
    expect(AuditLog.diff(l[1]['before'], l[1]['after']).map((d) => d.$1), contains('postings'));
    expect(l[1]['after']['postings'], contains('सूट दिली +20'));
    final sb = await vs.save(VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, items: [ItemLine(w.id, 1, rs(2243))]), owner);
    await vs.save(VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, items: [ItemLine(w.id, 1, rs(2243))], roundOff: -rs(3)), owner,
        existingId: sb);
    l = await log(sb);
    expect(l.length, 2); // round off only → recorded
    expect(l[0]['after']['postings'], isNotEmpty);

    // promise kept
    final p = await vs.save(VoucherInput(type: VoucherType.promise, date: todayIso(), partyId: cust, amount: rs(500)), owner);
    await vs.setPromiseStatus(p, 'done');
    l = await log(p);
    expect(l.last['action'], 'status');
    expect(AuditLog.diff(l.last['before'], l.last['after']).single, ('status', 'open', 'done'));
  });

  test('older history (before-copy only) rebuilds exactly like today\'s records', () async {
    final cust = await lr.create(name: 'Old Format', group: LedgerGroup.customer);
    final w = items['W']!;
    final id = await vs.save(
        VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, payLedgerId: vs.sys('upi_h'), items: [ItemLine(w.id, 10, rs(280))],
            hamali: rs(30), paid: rs(1000), narration: 'test', haste: 'मुलगा'),
        owner);
    // the copy the old history kept: voucher row + lines + items
    Future<Map<String, dynamic>> oldCopy() async => {
          'voucher': Map<String, Object?>.from(await db.get('SELECT * FROM vouchers WHERE id = ?', [id])),
          'lines': [for (final l in await db.getAll('SELECT ledger_id, debit, credit FROM voucher_lines WHERE voucher_id = ? AND deleted = 0 ORDER BY id', [id])) Map<String, Object?>.from(l)],
          'items': [for (final i in await db.getAll('SELECT item_id, qty, rate, amount FROM inventory_lines WHERE voucher_id = ? AND deleted = 0 ORDER BY id', [id])) Map<String, Object?>.from(i)],
        };
    final ledgers = {for (final l in await db.getAll('SELECT id, name FROM ledgers')) l['id'] as String: l['name'] as String};
    final itemNames = {for (final i in await db.getAll('SELECT id, name FROM items')) i['id'] as String: i['name'] as String};
    Map<String, String> norm(Map<String, dynamic> m) =>
        {for (final e in m.entries) if (e.key != 'vno' && e.key != 'type' && e.value != null && '${e.value}'.isNotEmpty) e.key: '${e.value}'};
    final rebuilt = norm(AuditLog.legacySummary(await oldCopy(), ledgers, itemNames));
    final today = norm(await vs.entrySummary(db, id));
    expect(rebuilt, today); // same entry → no false "changes"
    // a real change (pay mode + qty) shows up
    final before = await oldCopy();
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: cust, payLedgerId: vs.sys('cash'), items: [ItemLine(w.id, 12, rs(280))],
            hamali: rs(30), paid: rs(1000), narration: 'test', haste: 'मुलगा'),
        owner,
        existingId: id);
    final d = AuditLog.diff(norm(AuditLog.legacySummary(before, ledgers, itemNames)), norm(await vs.entrySummary(db, id)));
    expect(d.map((x) => x.$1), containsAll(['pay_mode', 'items', 'amount', 'postings']));
    expect(d.firstWhere((x) => x.$1 == 'pay_mode').$2, 'फोनपे (H)');
  });

  test('staff: may write old entries and fix them the same day, not delete or back-date bills', () async {
    final cust = await lr.create(name: 'Old Khata', group: LedgerGroup.customer, openingBalance: rs(5000));
    const old = '1999-12-01'; // before the tests' books start
    final id = await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: cust, amount: rs(1200), narration: 'M 4×300'), staff);
    expect(await lr.balanceAt(cust), rs(5000)); // still reference only
    await vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: cust, amount: rs(1500), narration: 'M 5×300'), staff, existingId: id);
    expect((await vs.load(id)).$1.amount, rs(1500));
    // an old entry typed in on an earlier day: owner only
    await db.execute("UPDATE vouchers SET created_at = '2020-01-01T00:00:00.000Z' WHERE id = ?", [id]);
    expect(() => vs.save(VoucherInput(type: VoucherType.history, date: old, partyId: cust, amount: rs(9)), staff, existingId: id),
        throwsA(isA<PermissionDenied>()));
    expect(() => vs.delete(id, staff), throwsA(isA<PermissionDenied>()));
    // back-dated real bills stay owner-only
    expect(() => vs.save(VoucherInput(type: VoucherType.sale, date: '2026-01-01', partyId: cust, amount: rs(10)), staff), throwsA(isA<PermissionDenied>()));
    expect(VoucherService.enteredToday(DateTime.now().toUtc().toIso8601String()), isTrue);
  });

  test('old entries show their own running balance, matching the opening – and change nothing', () async {
    final cust = await lr.create(name: 'Running', group: LedgerGroup.customer, openingBalance: rs(12500));
    const d = '1999-10-01';
    await vs.save(VoucherInput(type: VoucherType.history, date: d, partyId: cust, amount: rs(10000)), owner); // goods 10,000
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-10-05', partyId: cust, amount: rs(5000), paid: rs(1000)), owner);
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-10-09', partyId: cust, payLedgerId: 'hist:received', paid: rs(1500)), owner);
    final st = await lr.statement(cust);
    expect(st.references.map((r) => r.balance), [rs(10000), rs(14000), rs(12500)]);
    expect(st.references.last.balance, st.ledger.openingBalance); // adds up to the opening
    expect(await lr.balanceAt(cust), rs(12500)); // real balance untouched
    expect(st.closing, rs(12500));
  });

  test('old ledger can start from a balance carried from an even older book', () async {
    final cust = await lr.create(name: 'Older Book', group: LedgerGroup.customer, openingBalance: rs(31250));
    final sup = await lr.create(name: 'Old Supplier', group: LedgerGroup.supplier, openingBalance: -rs(5000));
    final w = items['W']!;
    final stock0 = await sr.stockAt(w.id, '2026-11-10');
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-04-01', partyId: cust, payLedgerId: 'hist:opening', amount: rs(25000)), owner);
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-05-12', partyId: cust, items: [ItemLine(w.id, 40, rs(280))], paid: 0), owner);
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-06-03', partyId: cust, payLedgerId: 'hist:received', amount: rs(4950)), owner);
    final st = await lr.statement(cust);
    expect(st.references.first.kind, 'opening');
    expect(st.references.map((r) => r.balance), [rs(25000), rs(36200), rs(31250)]);
    expect(st.references.last.balance, st.ledger.openingBalance); // ✓ matches
    // nothing moved
    expect(await lr.balanceAt(cust), rs(31250));
    expect(await sr.stockAt(w.id, '2026-11-10'), stock0);
    // we owed a supplier from an older book
    await vs.save(VoucherInput(type: VoucherType.history, date: '1999-04-01', partyId: sup, payLedgerId: 'hist:opening_cr', amount: rs(5000)), owner);
    expect((await lr.statement(sup)).references.single.balance, -rs(5000));
    expect(await lr.balanceAt(sup), -rs(5000));
  });

  test('रोख मोजणी: short and extra cash go to रोख फरक, books then match the count', () async {
    const day = '2026-11-07';
    final cash = vs.sys('cash');
    final book = await lr.balanceAt(cash, date: day);
    // counted ₹125 less than the books → payment from cash to रोख फरक
    await vs.save(VoucherInput(type: VoucherType.payment, date: day, partyId: vs.sys('cash_diff'), payLedgerId: cash, amount: rs(125)), owner);
    expect(await lr.balanceAt(cash, date: day), book - rs(125));
    expect(await lr.balanceAt(vs.sys('cash_diff')), rs(125)); // a loss
    // next day ₹40 extra → receipt into cash
    await vs.save(VoucherInput(type: VoucherType.receipt, date: '2026-11-08', partyId: vs.sys('cash_diff'), payLedgerId: cash, amount: rs(40)), owner);
    expect(await lr.balanceAt(vs.sys('cash_diff')), rs(85)); // net short for the period
    expect((await lr.byId(vs.sys('cash_diff')))!.group, LedgerGroup.expense);
  });

  test('वराई: driver cash goes to cash + day-end hamali, never the supplier bill', () async {
    final sup = await lr.create(name: 'Laxmi Cement Agency', group: LedgerGroup.supplier);
    final cust = await lr.create(name: 'Vijay', group: LedgerGroup.customer);
    final m = items['M']!;
    const day = '2026-11-07';
    final cashBefore = await lr.balanceAt(vs.sys('cash'));
    // company truck: 100 bags on credit, driver hands over ₹500 varhaai
    final pid = await vs.save(
        VoucherInput(type: VoucherType.purchase, date: day, partyId: sup, items: [ItemLine(m.id, 100, rs(250))], varhai: rs(500)),
        owner);
    expect(await lr.balanceAt(sup), -rs(25000)); // bill untouched
    expect(await lr.balanceAt(vs.sys('cash')), cashBefore + rs(500));
    expect(await lr.balanceAt(vs.sys('varhai')), -rs(500));
    final (pv, _) = await vs.load(pid);
    expect(await vs.varhaiOf(pv), rs(500));

    // a sale with ₹200 hamali, then ₹300 more varhaai entered on its own
    await vs.save(VoucherInput(type: VoucherType.sale, date: day, partyId: cust, items: [ItemLine(m.id, 10, rs(285))], hamali: rs(200)), owner);
    await vs.save(VoucherInput(type: VoucherType.receipt, date: day, partyId: vs.sys('varhai'), payLedgerId: vs.sys('cash'), amount: rs(300)), owner);
    var dc = await lr.dayCharges(day);
    expect(dc.hamaliCharged, rs(200));
    expect(dc.varhai, rs(800));
    expect(dc.hamaliToPay, rs(1000));

    // labourers get the full ₹1,000 → nothing left over
    await vs.save(
        VoucherInput(type: VoucherType.payment, date: day, partyId: vs.sys('hamali'), payLedgerId: vs.sys('cash'), amount: rs(1000)),
        owner);
    dc = await lr.dayCharges(day);
    expect(dc.hamaliProfit, 0);

    // editing the purchase without varhaai removes it
    await vs.save(VoucherInput(type: VoucherType.purchase, date: day, partyId: sup, items: [ItemLine(m.id, 100, rs(250))]), owner,
        existingId: pid);
    expect((await lr.dayCharges(day)).varhai, rs(300));
    expect(await lr.balanceAt(sup), -rs(25000));
  });

  test('bill charges: hamali + own vehicle are income, outside transporter is owed', () async {
    final cust = await lr.create(name: 'Sunil', group: LedgerGroup.customer);
    final ganesh = await lr.create(name: 'Ganesh Transport', group: LedgerGroup.transporter);
    final m = items['M']!;
    final s8 = items['8']!;
    const day = '2026-11-06';
    // 30 bags + 136 kg 8mm, hamali 300, own vehicle 500, on credit
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: day, partyId: cust, items: [
          ItemLine(m.id, 30, rs(285)),
          ItemLine(s8.id, 136, rs(62)),
        ], hamali: rs(300), transport: rs(500)),
        owner);
    expect(await lr.balanceAt(cust), rs(8550 + 8432 + 300 + 500));
    expect(await lr.balanceAt(vs.sys('sales')), -rs(8550 + 8432)); // goods only
    expect(await lr.balanceAt(vs.sys('transport_income')), -rs(500));

    // Outside transporter: customer pays 800, Ganesh's fare is 700 → 100 margin
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: day, partyId: cust, items: [ItemLine(m.id, 10, rs(285))],
            hamali: rs(100), transport: rs(800), transporterId: ganesh, transporterFare: rs(700)),
        owner);
    expect(await lr.balanceAt(ganesh), -rs(700)); // we owe him
    expect(await lr.balanceAt(vs.sys('transport_income')), -rs(600));

    // Day end: pay labourers 300 (less than 400 charged), pay Ganesh 700
    await vs.save(
        VoucherInput(type: VoucherType.payment, date: day, partyId: vs.sys('hamali'), payLedgerId: vs.sys('cash'), amount: rs(300)),
        owner);
    var dc = await lr.dayCharges(day);
    expect(dc.hamaliCharged, rs(400));
    expect(dc.hamaliPaid, rs(300));
    expect(dc.hamaliProfit, rs(100));
    expect(dc.ownTransport, rs(600));
    expect(dc.transporters.single.owed, rs(700));
    expect(dc.transporters.single.earnedToday, rs(700));
    await vs.save(
        VoucherInput(type: VoucherType.payment, date: day, partyId: ganesh, payLedgerId: vs.sys('cash'), amount: rs(700)),
        owner);
    dc = await lr.dayCharges(day);
    expect(dc.transporters.single.owed, 0);

    // khata line shows the charges; edit keeps them
    final st = await lr.statement(cust);
    expect(st.rows.first.hamali, rs(300));
    expect(st.rows.first.transport, rs(500));
    expect(st.rows.last.transporterName, 'Ganesh Transport');
    final (v, _) = await vs.load(st.rows.last.voucherId);
    expect(v.transporterFare, rs(700));
    expect(v.amount, rs(2850 + 100 + 800));
    // our report names the vehicle; the copy sent to the customer does not
    final rep = Reports(db, biz, (k) => k);
    final ours = (await rep.ledgerStatement(cust)).rows.map((r) => r[1]).join(' ');
    final theirs = (await rep.ledgerStatement(cust, forCustomer: true)).rows.map((r) => r[1]).join(' ');
    expect(ours, contains('Ganesh Transport'));
    expect(theirs, isNot(contains('Ganesh')));
    expect(theirs, isNot(contains('own_vehicle')));
    expect(theirs, contains('transport ${Money.fmt(rs(800))}'));
  });

  test('search: words in any order, page no., phone, amount, bill no.', () async {
    final id = await lr.create(name: 'सुरेश जाधव', nameEn: 'Suresh Jadhav', group: LedgerGroup.customer, pageNo: '29', phone: '98500 12345');
    await lr.create(name: 'सुरेश मोरे', nameEn: 'Suresh More', group: LedgerGroup.customer, pageNo: '63');
    expect((await lr.search('jadhav suresh')).single.id, id);
    expect((await lr.search('सुरेश जा')).single.id, id);
    expect((await lr.search('9850012345')).single.id, id);
    expect((await lr.search('29')).first.id, id);
    expect((await lr.search('sure')).length, 2);
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: id, items: [ItemLine(items['M']!.id, 12, rs(285))], narration: 'MH12 AB 1234'),
        owner);
    expect((await lr.searchVouchers('3420')).single.partyName, 'सुरेश जाधव');
    expect((await lr.searchVouchers('३४२०')).length, 1);
    expect((await lr.searchVouchers('AB 1234')).length, 1);
    expect((await lr.searchVouchers('jadhav')).length, 1);
    expect((await lr.searchVouchers('1')).length, 1); // bill no. 1
  });

  test('books check finds incomplete entries; edits never duplicate lines', () async {
    final c = await lr.create(name: 'Check', group: LedgerGroup.customer);
    final id = await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: c, items: [ItemLine(items['M']!.id, 2, rs(285))]), owner);
    expect(await lr.unbalanced(), isEmpty);
    // edit twice – same line ids are reused, nothing doubles
    for (var i = 0; i < 2; i++) {
      await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: c, items: [ItemLine(items['M']!.id, 3, rs(285))]), owner,
          existingId: id);
    }
    final lines = await db.getAll('SELECT id FROM voucher_lines WHERE voucher_id = ?', [id]);
    expect(lines.map((r) => r['id']).toSet(), {'$id:L0', '$id:L1'});
    expect(await lr.balanceAt(c), rs(855));
    // simulate an entry that arrived half-way (a line missing)
    await db.execute('DELETE FROM voucher_lines WHERE id = ?', ['$id:L1']);
    final bad = await lr.unbalanced();
    expect(bad.single.id, id);
  });

  test('accounts: move PhonePe to bank, delete unused, hide used, protect built-ins', () async {
    final d = (await lr.byId(vs.sys('upi_d')))!;
    expect(d.allowedGroups, [LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
    await lr.update(d.id, name: 'HDFC', openingBalance: 0, group: LedgerGroup.bank);
    expect((await lr.byId(d.id))!.group, LedgerGroup.bank);

    final sales = (await lr.byId(vs.sys('sales')))!;
    expect(sales.allowedGroups, [LedgerGroup.sales]);
    expect(() => lr.deleteOrHide(sales), throwsArgumentError);

    final unused = await lr.create(name: 'Old Supplier', group: LedgerGroup.supplier);
    expect(await lr.deleteOrHide((await lr.byId(unused))!), isTrue);
    expect(await lr.byId(unused), isNull);

    final used = await lr.create(name: 'Used', group: LedgerGroup.customer);
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: used, amount: rs(500)), owner);
    expect(await lr.deleteOrHide((await lr.byId(used))!), isFalse);
    expect((await lr.list([LedgerGroup.customer])).any((l) => l.id == used), isFalse);
    expect((await lr.hidden()).single.id, used);
    expect(await lr.balanceAt(used), rs(500)); // books unchanged

    // a hidden built-in ledger is not re-created by app updates
    final p = (await lr.byId(vs.sys('upi_p')))!;
    expect(await lr.deleteOrHide(p), isFalse);
    await db.writeTransaction((tx) => ensureSystemLedgers(tx, biz));
    expect((await lr.list([LedgerGroup.upi])).any((l) => l.id == p.id), isFalse);
  });

  test('round off on sale and purchase keeps the books balanced', () async {
    final c = await lr.create(name: 'Round', group: LedgerGroup.customer);
    final id = await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: c, items: [ItemLine(items['M']!.id, 12, rs(286.42))], roundOff: -300),
        owner); // ₹3,437.04 rounded down by ₹3
    final (v, _) = await vs.load(id);
    expect(v.amount, (12 * 28642) - 300);
    expect(await vs.roundOffOf(v), -300);
    expect(await lr.balanceAt(vs.sys('round_off')), 300); // expense
    final s = await lr.create(name: 'Sup', group: LedgerGroup.supplier);
    final pid = await vs.save(
        VoucherInput(type: VoucherType.purchase, date: '2026-11-09', partyId: s, items: [ItemLine(items['U']!.id, 3, rs(266.6))], roundOff: 20),
        owner);
    final (pv, _) = await vs.load(pid);
    expect(await vs.roundOffOf(pv), 20);
    expect(await lr.balanceAt(s), -(3 * 26660 + 20));
    expect(await lr.unbalanced(), isEmpty);
  });

  test('one person as customer and supplier: one khata, net balance, both lists', () async {
    final raju = await lr.create(name: 'Raju Contractor', group: LedgerGroup.customer);
    final agency = await lr.create(name: 'Agency', group: LedgerGroup.supplier);
    await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: raju, amount: rs(10000)), owner);
    // we buy leftover steel back from Raju on credit
    await vs.save(VoucherInput(type: VoucherType.purchase, date: '2026-11-10', partyId: raju, items: [ItemLine(items['8']!.id, 50, rs(60))]), owner);
    expect(await lr.balanceAt(raju), rs(10000 - 3000)); // he still owes 7,000 net
    final sup = await lr.parties(LedgerGroup.supplier);
    expect(sup.map((l) => l.id).toSet(), {agency, raju});
    expect(sup.firstWhere((l) => l.id == raju).dual, isTrue);
    final cust = await lr.parties(LedgerGroup.customer);
    expect(cust.firstWhere((l) => l.id == raju).dual, isTrue);
    expect(cust.any((l) => l.id == agency), isFalse);
    final d = await lr.dashboard('2026-11-10');
    expect(d['receivable'], rs(7000));
  });

  test('a line entered as qty + total saves the exact total', () async {
    final c = await lr.create(name: 'Total', group: LedgerGroup.customer);
    final id = await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: c, items: [ItemLine.fromTotal(items['M']!.id, 7, rs(2000))]), owner);
    expect(await lr.balanceAt(c), rs(2000));
    final (v, ls) = await vs.load(id);
    expect(v.amount, rs(2000));
    expect(ls.single.amount, rs(2000));
    expect(ls.single.rate, 28571);
    expect(await lr.unbalanced(), isEmpty);
  });

  test('payment promises: noted, due, kept – and they move no money', () async {
    final c = await lr.create(name: 'Promiser', group: LedgerGroup.customer, openingBalance: rs(9000), phone: '9000000002');
    final today = todayIso();
    final later = isoDate(parseIso(today).add(const Duration(days: 5)));
    final id = await vs.save(VoucherInput(type: VoucherType.promise, date: today, partyId: c, amount: rs(5000), narration: 'on phone'), staff);
    await vs.save(VoucherInput(type: VoucherType.promise, date: later, partyId: c), owner); // amount not said
    expect(await lr.balanceAt(c), rs(9000));
    expect(await lr.unbalanced(), isEmpty);
    expect(await lr.dayBook(today), isEmpty);
    final open = await lr.promises();
    expect(open.length, 2);
    expect(open.first.$1.amount, rs(5000));
    expect(open.first.$2.balance, rs(9000));
    expect(await lr.promisesDue(today), 1);
    await vs.setPromiseStatus(id, 'done');
    expect(await lr.promisesDue(today), 0);
    expect((await lr.promises(open: false)).single.$1.status, 'done');
    expect((await lr.promises(partyId: c)).length, 1);
  });

  test('हस्ते is saved, shown on the khata and kept on edit', () async {
    final c = await lr.create(name: 'Through', group: LedgerGroup.customer);
    final id = await vs.save(
        VoucherInput(type: VoucherType.receipt, date: '2026-11-09', partyId: c, payLedgerId: vs.sys('cash'), amount: rs(700), haste: ' Driver Raju '),
        owner);
    final (v, _) = await vs.load(id);
    expect(v.haste, 'Driver Raju');
    expect((await lr.statement(c)).rows.single.haste, 'Driver Raju');
    await vs.save(VoucherInput(type: VoucherType.receipt, date: '2026-11-09', partyId: c, payLedgerId: vs.sys('cash'), amount: rs(800), haste: ''),
        owner, existingId: id);
    final (v2, _) = await vs.load(id);
    expect(v2.haste, isNull);
  });
}
