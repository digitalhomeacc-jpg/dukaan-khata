import 'dart:convert';
import 'dart:typed_data';

import 'package:dukaan_khata/accounting/bank_repo.dart';
import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/backup.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:dukaan_khata/shared/statement_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'test_db.dart';

const biz = 'biz2';
const owner = Actor(userId: 'u1', name: 'Owner', isOwner: true);
const staff = Actor(userId: 'u2', name: 'Staff', isOwner: false);
int rs(num r) => Money.fromRupees(r);

void main() {
  late SqliteDatabase db;
  late VoucherService vs;
  late LedgerRepo lr;
  late StockRepo sr;
  late Map<String, Item> items;

  setUp(() async {
    Books.start = '2026-11-08';
    Books.fyStartMonth = 4;
    db = await openTestDb(biz);
    vs = VoucherService(db, biz);
    lr = LedgerRepo(db, biz);
    sr = StockRepo(db, biz);
    items = {for (final i in await sr.list()) i.shortCode!: i};
  });
  tearDown(() => db.close());

  group('books start + old entries', () {
    test('old entries are reference only: no balance, opening balance, cash or stock changes', () async {
      final m = await lr.create(name: 'Old Party', group: LedgerGroup.customer, pageNo: '9', openingBalance: rs(31250));
      await vs.save(VoucherInput(type: VoucherType.history, date: '2026-09-14', partyId: m, amount: rs(1365), narration: 'M 5×273'), owner);
      await vs.save(
          VoucherInput(type: VoucherType.history, date: '2026-10-06', partyId: m, payLedgerId: '${historyKindPrefix}received', amount: rs(30000)),
          owner);
      expect(await lr.balanceAt(m), rs(31250)); // the opening balance already is the net
      expect((await lr.byId(m))!.openingBalance, rs(31250));
      expect(await lr.balanceAt(vs.sys('cash')), 0);
      expect(await lr.balanceAt(vs.sys('sales')), 0);
      expect(await lr.balanceAt(vs.sys('history_adj')), 0);
      expect(await sr.stockAt(items['M']!.id, '2026-12-31'), 0);
      final st = await lr.statement(m);
      expect(st.rows, isEmpty); // nothing in the running khata…
      expect(st.references.length, 2); // …but both show as reference
      expect(st.references.first.details, 'M 5×273');
      expect(st.references.first.debit, rs(1365));
      expect(st.references.last.credit, rs(30000));
      expect(st.closing, rs(31250));
      expect(await lr.unbalanced(), isEmpty);
      expect(await lr.dayBook('2026-09-01', '2026-10-31'), isEmpty);
    });

    test('old entries saved before this change are detached', () async {
      final m = await lr.create(name: 'Legacy', group: LedgerGroup.customer, openingBalance: rs(1000));
      final id = await vs.save(VoucherInput(type: VoucherType.history, date: '2026-09-14', partyId: m, amount: rs(500)), owner);
      // simulate the old behaviour: lines that moved the balance
      await db.execute(
          'INSERT INTO voucher_lines (id, business_id, voucher_id, ledger_id, debit, credit, vdate, deleted) VALUES (?, ?, ?, ?, ?, 0, ?, 0)',
          ['$id:L0', biz, id, m, rs(500), '2026-09-14']);
      expect(await lr.balanceAt(m), rs(1500));
      expect(await vs.detachHistoryLines(), 1);
      expect(await lr.balanceAt(m), rs(1000));
    });

    test('an old bill keeps items, hamali, transport and round off – for reference only', () async {
      final c = await lr.create(name: 'Old Customer', group: LedgerGroup.customer, openingBalance: rs(50000));
      final s2 = await lr.create(name: 'Old Supplier', group: LedgerGroup.supplier, openingBalance: -rs(20000));
      final m = items['M']!;
      await vs.save(
          VoucherInput(
              type: VoucherType.history,
              date: '2026-09-20',
              partyId: c,
              payLedgerId: '${historyKindPrefix}sale',
              items: [ItemLine(m.id, 12, rs(285)), ItemLine.fromTotal(items['8']!.id, 50, rs(3100))],
              hamali: rs(120),
              transport: rs(400),
              roundOff: -50,
              paid: rs(2000),
              haste: 'Son'),
          owner);
      await vs.save(
          VoucherInput(type: VoucherType.history, date: '2026-09-22', partyId: s2, payLedgerId: '${historyKindPrefix}purchase',
              items: [ItemLine(m.id, 100, rs(260))]),
          owner);
      // nothing moves
      expect(await lr.balanceAt(c), rs(50000));
      expect(await lr.balanceAt(s2), -rs(20000));
      for (final k in ['cash', 'sales', 'purchase', 'hamali_income', 'transport_income', 'round_off', 'history_adj']) {
        expect(await lr.balanceAt(vs.sys(k)), 0, reason: k);
      }
      expect(await sr.stockAt(m.id, '2026-12-31'), 0);
      expect((await sr.movements(m.id)).length, 0);
      // …but the bill is there to show the customer
      final st = await lr.statement(c);
      final ref = st.references.single;
      expect(ref.details, contains('M 12×285'));
      expect(ref.hamali, rs(120));
      expect(ref.transport, rs(400));
      expect(ref.haste, 'Son');
      expect(ref.debit, 12 * 28500 + rs(3100) + rs(120) + rs(400) - 50);
      expect(ref.credit, rs(2000));
      final (v, ls) = await vs.load(ref.voucherId);
      expect(ls.length, 2);
      expect(await vs.roundOffOf(v), -50);
      expect((await lr.statement(s2)).references.single.credit, rs(26000));
    });

    test('dates are kept on the right side of the books start', () async {
      final c = await lr.create(name: 'X', group: LedgerGroup.customer);
      expect(() => vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-07', partyId: c, amount: rs(10)), owner),
          throwsArgumentError);
      expect(() => vs.save(VoucherInput(type: VoucherType.history, date: '2026-11-08', partyId: c, amount: rs(10)), owner),
          throwsArgumentError);
      // staff may write old entries now, but still only before the books start
      expect(() => vs.save(VoucherInput(type: VoucherType.history, date: '2026-11-08', partyId: c, amount: rs(10)), staff),
          throwsA(anything));
      expect(await vs.save(VoucherInput(type: VoucherType.history, date: '2026-10-01', partyId: c, amount: rs(10)), staff), isNotEmpty);
    });

    test('financial year start month is configurable', () {
      expect(fyStart('2026-11-08'), '2026-04-01');
      Books.fyStartMonth = 1;
      expect(fyStart('2026-11-08'), '2026-01-01');
      Books.fyStartMonth = 11;
      expect(fyStart('2026-10-31'), '2025-11-01');
      Books.fyStartMonth = 4;
    });
  });

  group('GST bills', () {
    test('sale and purchase with GST post to the GST ledger', () async {
      final c = await lr.create(name: 'Builder', group: LedgerGroup.customer, gstin: '27abcde1234f1z5');
      final s = await lr.create(name: 'Cement Agency', group: LedgerGroup.supplier);
      final u = items['U']!;
      await vs.save(
          VoucherInput(type: VoucherType.purchase, date: '2026-11-10', partyId: s, items: [ItemLine(u.id, 100, rs(250))], gstRate: 2800),
          owner);
      expect(await lr.balanceAt(vs.sys('gst')), rs(7000)); // input credit
      expect(await lr.balanceAt(s), -rs(32000));
      final id = await vs.save(
          VoucherInput(type: VoucherType.sale, date: '2026-11-10', partyId: c, items: [ItemLine(u.id, 10, rs(300))], gstRate: 2800, hamali: rs(100)),
          owner);
      expect(await lr.balanceAt(c), rs(3000 + 840 + 100));
      expect(await lr.balanceAt(vs.sys('gst')), rs(7000 - 840));
      expect(await lr.balanceAt(vs.sys('sales')), -rs(3000));
      final (v, _) = await vs.load(id);
      expect(v.gst, rs(840));
      expect(v.gstRate, 2800);
      expect((await lr.byId(c))!.gstin, '27ABCDE1234F1Z5');
      // staff cannot make GST bills
      expect(
          () => vs.save(VoucherInput(type: VoucherType.sale, date: todayIso().compareTo(Books.start) < 0 ? Books.start : todayIso(),
              partyId: c, amount: rs(100), gstRate: 1800), staff),
          throwsA(isA<PermissionDenied>()));
    });
  });

  group('bank statements', () {
    const csv = '''Bank of India - Account Statement
Account No,123456789
Txn Date,Value Date,Description,Ref No./Cheque No.,Debit,Credit,Balance
08/11/2026,08/11/2026,NEFT-SURESH JADHAV-SBIN0001234,N12345,,"25,000.00","2,75,000.00"
09-Nov-2026,09-Nov-2026,UPI/RAMESH K/9876543210/payment,UPI998,,1500.00,276500.00
10/11/26,10/11/26,RTGS LAXMI CEMENT AGENCY,RT55,"50,000.00",,226500.00
10/11/2026,10/11/2026,CASH DEPOSIT SELF,,,5000.00,231500.00
,,Closing Balance,,,,231500.00
''';

    test('parser reads split debit/credit CSV with Indian formats', () {
      final lines = StatementParser.parse(Uint8List.fromList(utf8.encode(csv)), 'stmt.csv');
      expect(lines.length, 4);
      expect(lines[0].date, '2026-11-08');
      expect(lines[0].credit, rs(25000));
      expect(lines[0].balance, rs(275000));
      expect(lines[1].date, '2026-11-09');
      expect(lines[2].debit, rs(50000));
      expect(lines[2].date, '2026-11-10');
    });

    test('parser reads Amount + Dr/Cr layout and HTML .xls', () {
      final rows = [
        ['Date', 'Narration', 'Amount', 'Dr/Cr', 'Balance'],
        ['01/12/2026', 'IMPS SAGAR TEMPO', '700', 'DR', '1000 Cr'],
        ['02/12/2026', 'NEFT SUNIL', '2,000', 'CR', '3000 Cr'],
      ];
      final l = StatementParser.parseRows(rows);
      expect(l[0].debit, rs(700));
      expect(l[1].credit, rs(2000));
      const html = '<html><table><tr><td>Tran Date</td><td>Particulars</td><td>Withdrawals</td><td>Deposits</td>'
          '<td>Balance</td></tr><tr><td>05-11-2026</td><td>BY CLG GANESH</td><td></td><td>1,200.00</td><td>9,200.00</td></tr></table></html>';
      final h = StatementParser.parse(Uint8List.fromList(utf8.encode(html)), 'OpTransactionHistory.xls');
      expect(h.single.credit, rs(1200));
      expect(h.single.description, 'BY CLG GANESH');
    });

    test('import de-duplicates, auto-matches, suggests names and creates entries', () async {
      final bank = vs.sys('bank');
      final suresh = await lr.create(name: 'सुरेश जाधव', nameEn: 'Suresh Jadhav', group: LedgerGroup.customer);
      final ramesh = await lr.create(name: 'रमेश', nameEn: 'Ramesh Kale', group: LedgerGroup.customer, phone: '98765 43210');
      final agency = await lr.create(name: 'लक्ष्मी एजन्सी', nameEn: 'Laxmi Cement Agency', group: LedgerGroup.supplier);
      // already in the books: payment to the agency by RTGS
      await vs.save(
          VoucherInput(type: VoucherType.payment, date: '2026-11-10', partyId: agency, payLedgerId: bank, amount: rs(50000)), owner);
      final repo = BankRepo(db, biz, vs);
      final lines = StatementParser.parse(Uint8List.fromList(utf8.encode(csv)), 'stmt.csv');
      final r = await repo.import(bank, lines);
      expect(r.added, 4);
      expect(r.autoMatched, 1);
      final again = await repo.import(bank, lines);
      expect(again.added, 0);
      expect(again.duplicates, 4);

      final open = await repo.list(bank, 'open');
      expect(open.length, 3);
      final neft = open.firstWhere((l) => l.description.contains('SURESH'));
      expect((await repo.suggest(neft.description)).first.id, suresh);
      final upi = open.firstWhere((l) => l.description.contains('RAMESH'));
      expect((await repo.suggest(upi.description)).first.id, ramesh); // phone number + name
      await lr.create(name: 'राम शेटे', nameEn: 'Ram Shete', group: LedgerGroup.customer);
      expect((await repo.suggest(upi.description)).map((l) => l.id), [ramesh]); // "RAM" must not match "RAMESH"
      await repo.assign(neft, (await lr.byId(suresh))!, owner);
      expect(await lr.balanceAt(suresh), -rs(25000)); // received
      // cash deposit → contra from cash
      final dep = open.firstWhere((l) => l.description.contains('CASH'));
      await repo.assign(dep, (await lr.byId(vs.sys('cash')))!, owner);
      expect(await lr.balanceAt(vs.sys('cash')), -rs(5000));
      final counts = await repo.counts(bank);
      expect(counts['matched'], 3);
      expect(counts['open'], 1);
    });
  });

  test('full backup restores every entry on a fresh device', () async {
    final c = await lr.create(name: 'Sunil', group: LedgerGroup.customer, openingBalance: rs(500));
    await vs.save(
        VoucherInput(type: VoucherType.sale, date: '2026-11-09', partyId: c, items: [ItemLine(items['M']!.id, 3, rs(285))], hamali: rs(30)),
        owner);
    await vs.save(VoucherInput(type: VoucherType.history, date: '2026-10-01', partyId: c, amount: rs(100)), owner);
    final bytes = await Backup.export(db, biz);

    final fresh = await openTestDb('other-shop');
    final (id, name) = await fresh.writeTransaction((tx) => Backup.restore(tx, bytes));
    expect(id, biz);
    expect(name, 'Test Shop');
    final lr2 = LedgerRepo(fresh, biz);
    expect(await lr2.balanceAt(c), rs(500 + 855 + 30)); // the old entry is reference only
    expect(await StockRepo(fresh, biz).stockAt(items['M']!.id, '2026-12-31'), -3);
    await fresh.close();
  });

  group('PDF statements', () {
    // An HDFC-style page: right-aligned amounts, a narration that wraps onto a
    // second line, a footer, and the header repeated on page 2.
    List<Object?> t(int page, double x, double y, String s, {double w = 0}) => [page, x, y, w == 0 ? s.length * 4.5 : w, s];
    final items = <List<Object?>>[
      t(1, 40, 780, 'Statement of account'),
      t(1, 40, 740, 'Date'), t(1, 90, 740, 'Narration'), t(1, 260, 740, 'Chq./Ref.No.'),
      t(1, 360, 740, 'Withdrawal Amt.'), t(1, 440, 740, 'Deposit Amt.'), t(1, 520, 740, 'Closing Balance'),
      // row 1 – deposit, narration wraps
      t(1, 40, 720, '08/11/26'), t(1, 90, 720, 'NEFT CR-SBIN0001234-SURESH'), t(1, 260, 720, 'N31226'),
      t(1, 470, 720, '25,000.00', w: 40), t(1, 545, 720, '2,75,000.00', w: 50),
      t(1, 90, 710, 'JADHAV-PAYMENT'),
      // row 2 – withdrawal
      t(1, 40, 695, '10/11/26'), t(1, 90, 695, 'RTGS DR-LAXMI CEMENT'), t(1, 260, 695, 'RT5501'),
      t(1, 395, 695, '50,000.00', w: 40), t(1, 545, 695, '2,25,000.00', w: 50),
      t(1, 40, 60, 'This is a computer generated statement'),
      // page 2
      t(2, 40, 780, 'Date'), t(2, 90, 780, 'Narration'), t(2, 260, 780, 'Chq./Ref.No.'),
      t(2, 360, 780, 'Withdrawal Amt.'), t(2, 440, 780, 'Deposit Amt.'), t(2, 520, 780, 'Closing Balance'),
      t(2, 40, 760, '11/11/26'), t(2, 90, 760, 'UPI-RAMESH KALE-9876543210'), t(2, 260, 760, 'UPI77'),
      t(2, 478, 760, '1,500.00', w: 32), t(2, 545, 760, '2,26,500.00', w: 50),
    ];

    test('rebuilds rows, joins wrapped narration, skips footer and repeated header', () {
      final lines = StatementParser.parsePdfJson(jsonEncode(items));
      expect(lines.length, 3);
      expect(lines[0].date, '2026-11-08');
      expect(lines[0].description, 'NEFT CR-SBIN0001234-SURESH JADHAV-PAYMENT');
      expect(lines[0].ref, 'N31226');
      expect(lines[0].credit, rs(25000));
      expect(lines[0].debit, 0);
      expect(lines[0].balance, rs(275000));
      expect(lines[1].debit, rs(50000));
      expect(lines[1].credit, 0);
      expect(lines[2].date, '2026-11-11');
      expect(lines[2].credit, rs(1500));
    });

    test('a scanned PDF (no text) gives a clear message', () {
      expect(() => StatementParser.parsePdfJson('[]'),
          throwsA(isA<StatementFormatException>().having((e) => e.message, 'message', 'pdf_scanned')));
    });
  });

  test('item subcategory + bulk change: logged per item, stock untouched', () async {
    final a = items['M']!, b = items.values.firstWhere((x) => x.id != a.id);
    final before = await sr.stockAt(a.id, '2026-12-31');
    await sr.bulkUpdate([a.id, b.id], category: 'plumbing', subcategory: ' टाकी ', unit: 'nos');
    final after = {for (final i in await sr.list()) i.id: i};
    expect(after[a.id]!.category, 'plumbing');
    expect(after[b.id]!.subcategory, 'टाकी');
    expect(after[a.id]!.unit, 'nos');
    expect(await sr.stockAt(a.id, '2026-12-31'), before);
    expect(await sr.subcategories(category: 'plumbing'), ['टाकी']);
    // an item edit without a subcategory keeps it; '' removes it
    await sr.save(id: a.id, name: after[a.id]!.name, category: 'plumbing', unit: 'nos');
    expect((await sr.list()).firstWhere((x) => x.id == a.id).subcategory, 'टाकी');
    await sr.bulkUpdate([a.id], subcategory: '');
    expect((await sr.list()).firstWhere((x) => x.id == a.id).subcategory, isNull);
    final log = await db.getAll("SELECT action FROM audit_log WHERE voucher_id IN (?, ?)", [a.id, b.id]);
    expect(log.length, greaterThanOrEqualTo(3));
    await sr.bulkUpdate([b.id], archived: true);
    expect((await sr.list()).any((x) => x.id == b.id), isFalse);
  });
}
