import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/accounting/reports.dart';
import 'package:dukaan_khata/accounting/stock_pnl.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

int rs(num r) => Money.fromRupees(r);

void main() {
  const biz = 'b1';
  const owner = Actor(userId: 'u1', name: 'Owner', isOwner: true);

  test('item-wise profit worked out by hand, to the paise; proven against the accounts; next year opens at last year\'s closing', () async {
    final keep = Books.start;
    Books.start = '2026-11-08';
    try {
      final db = await openTestDb(biz);
      final vs = VoucherService(db, biz), lr = LedgerRepo(db, biz), sr = StockRepo(db, biz);
      final w = await sr.save(name: 'Wonder Test', category: 'cement', unit: 'bag', saleRate: rs(350), openingQty: 100, openingRate: rs(300));
      final sup = await lr.create(name: 'Wonder', group: LedgerGroup.supplier);
      final cust = await lr.create(name: 'Cust', group: LedgerGroup.customer);
      // before the books: 200 bags for ₹60,000 on the old statement (reference only)
      await vs.save(VoucherInput(type: VoucherType.history, date: '2026-06-01', partyId: sup, payLedgerId: '${historyKindPrefix}purchase',
          items: [ItemLine(w, 200, rs(300))]), owner);
      // in the books: 100 bags @ 290 = 29,000
      await vs.save(VoucherInput(type: VoucherType.purchase, date: '2026-11-10', partyId: sup, items: [ItemLine(w, 100, rs(290))]), owner);
      // the company's discount for the year so far: ₹4,450 on ₹89,000 of goods = 5 %
      await vs.save(VoucherInput(type: VoucherType.payment, date: '2026-12-01', partyId: sup, payLedgerId: vs.sys('cash'),
          amount: rs(10000), discount: rs(4450)), owner);
      // a Wonder coin – kept out of the cost (valued later)
      await vs.save(VoucherInput(type: VoucherType.payment, date: '2026-12-02', partyId: sup, payLedgerId: vs.sys('cash'),
          amount: rs(1), discount: rs(500), narration: 'Wonder coin'), owner);
      // 150 bags sold @ 350 = 52,500; 2 bags damaged
      await vs.save(VoucherInput(type: VoucherType.sale, date: '2026-11-15', partyId: cust, items: [ItemLine(w, 150, rs(350))]), owner);
      await vs.save(VoucherInput(type: VoucherType.stockAdjust, date: '2026-11-20', items: [ItemLine(w, -2, 0)]), owner);

      final r = await StockPnlEngine(db, biz).compute('2027-03-31');
      final i = r.items.single;
      expect(r.from, '2026-11-08');
      expect(i.openQty, 100);
      expect(i.openVal, rs(30000));
      expect(i.purVal, rs(29000));
      expect(i.discR, rs(1450), reason: '5 % of this year\'s ₹29,000 in the books');
      expect(i.avg, rs(287.75), reason: '(30,000 + 27,550) ÷ 200 bags');
      expect(i.closeQty, 48);
      expect(i.closeVal, rs(13812));
      expect(i.cost, rs(43738));
      expect(i.sales, rs(52500));
      expect(i.profit, rs(8762));
      expect(r.discRecd, rs(4950));
      expect(r.discSchemes, rs(500));
      expect(r.discOther, rs(3000), reason: 'the share for the 200 bags bought before the books');
      expect(r.salesGap, 0);
      expect(r.purchaseGap, 0);
      expect(r.netProfit, rs(8762 + 3000 + 500));
      expect(r.accountsProfit, r.netProfit, reason: 'two independent ways, same rupee');

      // the next year opens exactly where this one closed
      final n = await StockPnlEngine(db, biz).compute('2027-04-10');
      expect(n.from, '2027-04-01');
      expect(n.items.single.openVal, rs(13812));
      expect(n.items.single.cost, 0);
      expect(n.accountsProfit, n.netProfit);
      await db.close();
    } finally {
      Books.start = keep;
    }
  });

  test('an item with opening stock but no opening rate is flagged, never silently free', () async {
    final keep = Books.start;
    Books.start = '2026-11-08';
    try {
      final db = await openTestDb(biz);
      final sr = StockRepo(db, biz);
      await sr.save(name: 'No Rate', category: 'other', unit: 'pc', purchaseRate: rs(10), openingQty: 5);
      final r = await StockPnlEngine(db, biz).compute('2026-12-01');
      final i = r.items.firstWhere((x) => x.item.name == 'No Rate');
      expect(i.flags, contains('opening_rate_missing'));
      expect(i.openVal, rs(50), reason: 'valued at the purchase rate meanwhile');
      await db.close();
    } finally {
      Books.start = keep;
    }
  });

  test('no opening rate: opening stock valued from the newest old purchases at their year\'s real cost; '
      'discount rate identical to the Real cost report; a typed rate always wins', () async {
    final keep = Books.start;
    Books.start = '2026-11-08';
    try {
      final db = await openTestDb(biz);
      final vs = VoucherService(db, biz), lr = LedgerRepo(db, biz), sr = StockRepo(db, biz);
      final w = await sr.save(name: 'Wonder Old', category: 'cement', unit: 'bag', openingQty: 100);
      final typed = await sr.save(name: 'Typed Rate', category: 'cement', unit: 'bag', openingQty: 10, openingRate: rs(250));
      final sup = await lr.create(name: 'Wonder', group: LedgerGroup.supplier);
      Future<void> old(String d, String item, double q, int rate) => vs.save(
          VoucherInput(type: VoucherType.history, date: d, partyId: sup, payLedgerId: '${historyKindPrefix}purchase', items: [ItemLine(item, q, rs(rate))]),
          owner);
      await old('2026-06-01', w, 200, 300); // 60,000
      await old('2026-10-01', w, 50, 310); // 15,500 – the newest
      await old('2026-10-02', typed, 10, 999); // ignored: its rate is typed in
      await vs.save(VoucherInput(type: VoucherType.purchase, date: '2026-11-10', partyId: sup, items: [ItemLine(w, 100, rs(290))]), owner);
      // the year's discount: 5 % of all the year's goods (60,000 + 15,500 + 9,990 + 29,000 = 1,14,490)
      await vs.save(VoucherInput(type: VoucherType.payment, date: '2026-12-01', partyId: sup, payLedgerId: vs.sys('cash'),
          amount: rs(1), discount: rs(5724.50)), owner);
      final r = await StockPnlEngine(db, biz).compute('2027-03-31');
      final i = r.items.firstWhere((x) => x.item.id == w);
      // 50 newest bags @ 310 less 5 % = 14,725 ; 50 more @ 300 less 5 % = 14,250
      expect(i.openVal, rs(28975));
      expect(i.openFromOld, isTrue);
      expect(i.flags, isEmpty);
      expect(i.discR, rs(1450), reason: '5 % of the ₹29,000 bought in the books');
      expect(r.items.firstWhere((x) => x.item.id == typed).openVal, rs(2500), reason: 'the typed rate wins');
      // the Real cost report uses the very same yearly rate
      final rep = await Reports(db, biz, (k) => k).supplierCost(sup, '2026-04-01', '2027-03-31');
      expect(rep.subtitle, contains('5.0%'));
      expect(r.accountsProfit, r.netProfit);
      await db.close();
    } finally {
      Books.start = keep;
    }
  });
}
