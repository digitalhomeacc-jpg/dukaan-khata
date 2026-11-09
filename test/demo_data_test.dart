import 'package:dukaan_khata/accounting/ledger_repo.dart';
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
    await db.close();
  });
}
