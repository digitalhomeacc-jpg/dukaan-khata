import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/reports.dart';
import 'package:dukaan_khata/accounting/stock_pnl.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/demo.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_db.dart';

void main() {
  test('demo data loads completely', () async {
    Books.start = isoDate(DateTime.now().subtract(const Duration(days: 70)));
    final db = await openTestDb('demo');
    final vs = VoucherService(db, 'demo');
    await loadDemoData(vs, LedgerRepo(db, 'demo'), StockRepo(db, 'demo'));
    final n = await db.get("SELECT COUNT(*) AS n FROM vouchers WHERE vtype = 'purchase'");
    expect(n['n'], 1);
    final today = await db.get('SELECT COUNT(*) AS n FROM vouchers WHERE vdate = ?', [todayIso()]);
    expect(today['n'] as int, greaterThan(5));

    // a whole real-looking shop: item profits add up to the accounts exactly
    final r = await StockPnlEngine(db, 'demo').compute(todayIso());
    expect(r.salesGap, 0, reason: 'every rupee in the sales account is on an item line');
    expect(r.purchaseGap, 0, reason: 'every rupee in the purchase account is on an item line');
    expect(r.accountsProfit, r.netProfit);
    // and the shop P&L shows the very same net profit
    final pnl = await Reports(db, 'demo', (k) => k).profitAndLoss(r.from, r.to);
    expect(Money.parse(pnl.totals!.last), r.netProfit.abs());
    await db.close();
  });
}
