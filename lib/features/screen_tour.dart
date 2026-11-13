import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../state/app_controller.dart';
import 'audit_screen.dart';
import 'bank_screen.dart';
import 'booking_screen.dart';
import 'books_screens.dart';
import 'cash_count_screen.dart';
import 'check_lists_screen.dart';
import 'day_close_screen.dart';
import 'health_screen.dart';
import 'home_screen.dart';
import 'interest_screen.dart';
import 'parties_screen.dart';
import 'pending_screen.dart';
import 'promise_screen.dart';
import 'recurring_screen.dart';
import 'report_view.dart';
import 'review_screen.dart';
import 'rojmal_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'staff_screen.dart';
import 'stock_screen.dart';
import 'supplier_match_screen.dart';
import 'sync_sheet.dart';
import 'voucher_screen.dart';

/// Demo build only (open the demo with ?tour=1): opens every screen, form,
/// report and sheet one after another and collects every layout problem
/// Flutter reports (something cut off, overflowing or failing to draw).
/// Run at several screen sizes / text sizes / languages to find them all.
class ScreenTour {
  /// Text size multiplier for the run (large-text phones), null = normal.
  static double? textScale;

  /// Cards that normally start closed open themselves during the tour.
  static bool expandAll = false;

  static Future<void> run(BuildContext context) async {
    final app = App.read(context);
    final q = Uri.base.queryParameters;
    textScale = double.tryParse(q['scale'] ?? '');
    if (q['lang'] != null) app.setEnglish(q['lang'] == 'en');
    expandAll = true;
    final problems = <String>[];
    var current = 'start';
    final old = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.exceptionAsString().split('\n').first;
      final where = d.context?.toDescription() ?? '';
      // which widget: the overflowing box knows the chain of widgets that made it
      var hint = '';
      try {
        for (final n in d.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
          final v = n.value;
          if (v is RenderObject && v.debugCreator is DebugCreator) {
            hint = (v.debugCreator as DebugCreator).element.debugGetCreatorChain(14);
            final c = v.constraints;
            hint = '$hint  {${c is BoxConstraints ? 'max ${c.maxWidth.round()}×${c.maxHeight.isFinite ? c.maxHeight.round() : '∞'}' : ''}}';
            break;
          }
        }
      } catch (_) {}
      problems.add('[$current] $s $where $hint');
    };
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final db = app.db, b = app.businessId;
    Future<String?> one(String sql) async => (await db.getOptional(sql, [b]))?['id'] as String?;
    final cust = await one("SELECT l.id FROM ledgers l WHERE business_id = ? AND grp = 'customer' ORDER BY "
        '(SELECT COUNT(*) FROM vouchers v WHERE v.party_id = l.id) DESC LIMIT 1');
    final supp = await one("SELECT id FROM ledgers WHERE business_id = ? AND grp = 'supplier' LIMIT 1");
    final staff = await one("SELECT id FROM ledgers WHERE business_id = ? AND grp = 'staff' LIMIT 1");
    final bank = await one("SELECT id FROM ledgers WHERE business_id = ? AND grp = 'bank' LIMIT 1");
    final trans = await one("SELECT id FROM ledgers WHERE business_id = ? AND grp = 'transporter' LIMIT 1");
    final sale = await one("SELECT id FROM vouchers WHERE business_id = ? AND vtype = 'sale' AND deleted = 0 ORDER BY amount DESC LIMIT 1");
    final purchase = await one("SELECT id FROM vouchers WHERE business_id = ? AND vtype = 'purchase' AND deleted = 0 LIMIT 1");
    final suppLedger = supp == null ? null : await app.ledgers.byId(supp);
    final staffLedger = staff == null ? null : await app.ledgers.byId(staff);
    final item = (await app.stock.list()).firstOrNull;
    final today = todayIso();
    final from = '${today.substring(0, 8)}01';
    final r = app.reports;

    final screens = <(String, Widget Function())>[
      ('home', () => const HomeScreen()),
      ('customers', () => const PartiesScreen(group: LedgerGroup.customer)),
      ('suppliers', () => const PartiesScreen(group: LedgerGroup.supplier)),
      ('rojmal', () => const RojmalScreen()),
      ('stock', () => const StockScreen()),
      ('settings', () => const SettingsScreen()),
      ('day close', () => DayCloseScreen(date: today)),
      ('cash count', () => CashCountScreen(date: today)),
      ('review', () => const ReviewScreen()),
      ('health', () => const HealthScreen()),
      ('recheck list', () => const RecheckScreen()),
      ('old mismatch', () => const OldMismatchScreen()),
      ('reports', () => const ReportsScreen()),
      ('promises', () => const PromisesScreen()),
      ('audit', () => const AuditScreen()),
      ('search', () => const SearchScreen()),
      ('bank', () => const BankScreen()),
      ('bookings', () => const BookingsScreen()),
      ('booking new', () => BookingScreen(partyId: cust)),
      ('shop details', () => const ShopDetailsScreen()),
      ('accounts', () => const AccountsScreen()),
      ('users', () => const UsersScreen()),
      ('staff', () => const StaffScreen()),
      ('staff form', () => const StaffForm()),
      ('interest list', () => const InterestListScreen()),
      ('recurring list', () => const RecurringListScreen()),
      ('recurring form', () => RecurringForm(partyId: cust)),
      ('recurring pay form', () => const RecurringPayForm()),
      ('due charges', () => const DueChargesScreen()),
      ('daily register', () => const Scaffold(body: DailyRegisterView())),
      ('item form new', () => const ItemForm()),
      if (item != null) ('item form edit', () => ItemForm(existing: item)),
      for (final g in [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.bank, LedgerGroup.expense, LedgerGroup.transporter])
        ('party form ${g.code}', () => PartyForm(group: g)),
      if (cust != null) ...[
        ('khata customer', () => KhataScreen(ledgerId: cust)),
        ('pending customer', () => PendingScreen(ledgerId: cust)),
        ('interest', () => InterestScreen(partyId: cust)),
      ],
      if (supp != null) ('khata supplier', () => KhataScreen(ledgerId: supp)),
      if (suppLedger != null) ('supplier match', () => SupplierMatchScreen(supplier: suppLedger)),
      if (staff != null) ('khata staff', () => KhataScreen(ledgerId: staff)),
      if (staffLedger != null) ('salary', () => SalaryScreen(staffId: staffLedger.id)),
      if (bank != null) ('khata bank', () => KhataScreen(ledgerId: bank)),
      if (trans != null) ('khata transporter', () => KhataScreen(ledgerId: trans)),
      for (final vt in [
        VoucherType.sale, VoucherType.receipt, VoucherType.purchase, VoucherType.payment, VoucherType.salesReturn,
        VoucherType.purchaseReturn, VoucherType.contra, VoucherType.journal, VoucherType.stockAdjust, VoucherType.goodsOut,
        VoucherType.goodsIn,
      ])
        ('new ${vt.code}', () => VoucherScreen(type: vt, partyId: vt == VoucherType.purchase || vt == VoucherType.payment ? supp : cust)),
      ('new expense', () => const VoucherScreen(type: VoucherType.payment, expenseMode: true)),
      ('new old entry', () => VoucherScreen(type: VoucherType.history, partyId: cust, historyKind: 'sale')),
      if (sale != null) ('edit sale', () => VoucherScreen(type: VoucherType.sale, editId: sale)),
      if (purchase != null) ('edit purchase', () => VoucherScreen(type: VoucherType.purchase, editId: purchase)),
      // every report table
      for (final (name, load) in <(String, Future<ReportTable> Function())>[
        ('daybook', () => r.dayBook(from, today)),
        ('charges', () => r.chargesRegister(from, today)),
        ('udhari', () => r.udhariTable(today)),
        ('outstanding c', () => r.outstanding(LedgerGroup.customer)),
        ('outstanding s', () => r.outstanding(LedgerGroup.supplier)),
        ('stock summary', () => r.stockSummary()),
        ('goods owed', () => r.goodsOwed()),
        ('sales register', () => r.register(VoucherType.sale, from, today)),
        ('purchase register', () => r.register(VoucherType.purchase, from, today)),
        ('item profit', () => r.itemProfit(from, today)),
        ('expenses', () => r.expenseSummary(from, today)),
        ('p&l', () => r.profitAndLoss(from, today)),
        ('trial balance', () => r.trialBalance(today)),
        ('balance sheet', () => r.balanceSheet(today)),
        ('gst summary', () => r.gstSummary(from, today)),
        ('gst bills', () => r.gstBillsNeeded(from, today)),
        ('daily register', () => r.dailyRegister(today)),
        if (cust != null) ('statement', () => r.ledgerStatement(cust)),
        if (supp != null) ('real cost', () => r.supplierCost(supp, from, today)),
      ])
        ('report $name', () => ReportView(load: load)),
    ];

    var n = 0;
    for (final (name, build) in screens) {
      if (!context.mounted) break;
      current = name;
      n++;
      final route = MaterialPageRoute<void>(builder: (_) => build());
      Navigator.push(context, route).ignore();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      if (route.isActive && context.mounted) Navigator.of(context).removeRoute(route);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // sheets
    if (context.mounted) {
      current = 'sync sheet';
      n++;
      showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const SyncSheet()).ignore();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      if (context.mounted) Navigator.of(context).pop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    FlutterError.onError = old;
    expandAll = false;
    final seen = <String>{};
    final unique = [for (final p in problems) if (seen.add(p)) p];
    debugPrint('TOUR ${unique.isEmpty ? 'OK' : 'FAIL'}: $n screens, ${unique.length} problems');
    for (final p in unique) {
      debugPrint('TOUR PROBLEM: $p');
    }
    debugPrint('TOUR END');
  }
}
