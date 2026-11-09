import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import '../inventory/stock_repo.dart';
import 'ledger_repo.dart';
import 'models.dart';

enum ColAlign { left, right }

class ReportColumn {
  final String title;
  final ColAlign align;
  final int flex;
  const ReportColumn(this.title, {this.align = ColAlign.left, this.flex = 2});
  const ReportColumn.num(this.title, {this.flex = 2}) : align = ColAlign.right;
}

/// Generic table that every report produces – rendered on screen and exported
/// to PDF / Excel by the same code.
class ReportTable {
  final String title;
  final String subtitle;
  final List<ReportColumn> columns;
  final List<List<String>> rows;
  final List<String>? totals;
  /// Optional raw voucher id per row (tap to open).
  final List<String?> rowRefs;
  /// Rows to highlight (e.g. overdue, low stock).
  final Set<int> highlight;
  ReportTable({
    required this.title,
    this.subtitle = '',
    required this.columns,
    required this.rows,
    this.totals,
    List<String?>? rowRefs,
    this.highlight = const {},
  }) : rowRefs = rowRefs ?? List.filled(rows.length, null);
}

typedef T = String Function(String key);

String vtypeLabel(VoucherType t, T tr) => tr('vt_${t.code}');

class Reports {
  final SqliteConnection db;
  final String businessId;
  final LedgerRepo ledgers;
  final StockRepo stock;
  final T tr;
  Reports(this.db, this.businessId, this.tr)
      : ledgers = LedgerRepo(db, businessId),
        stock = StockRepo(db, businessId);

  String _range(String from, String to) => from == to ? shortDate(from) : '${shortDate(from)} – ${shortDate(to)}';

  Future<ReportTable> dayBook(String from, String to) async {
    final vs = await ledgers.dayBook(from, to);
    return ReportTable(
      title: tr('r_daybook'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('type'), flex: 2),
        ReportColumn(tr('party'), flex: 4),
        ReportColumn('', flex: 1),
        ReportColumn.num(tr('amount')),
        ReportColumn.num(tr('paid')),
      ],
      rows: [
        for (final v in vs)
          [
            shortDate(v.date),
            '${vtypeLabel(v.type, tr)} ${v.vno}',
            v.partyName ?? v.narration ?? '',
            v.payCode ?? '',
            Money.fmt(v.amount),
            Money.fmt(v.paid),
          ]
      ],
      rowRefs: [for (final v in vs) v.id],
      highlight: {for (var i = 0; i < vs.length; i++) if (vs[i].gstBillNeeded) i},
    );
  }

  Future<ReportTable> ledgerStatement(String ledgerId, {String? from, String? to}) async {
    final st = await ledgers.statement(ledgerId, from: from, to: to);
    return ReportTable(
      title: st.ledger.name,
      subtitle: [
        if (st.ledger.pageNo != null) '${tr('page_no')} ${st.ledger.pageNo}',
        if (from != null || to != null) _range(from ?? '2000-01-01', to ?? todayIso()),
      ].join(' · '),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('details'), flex: 5),
        ReportColumn.num(tr('debit_given')),
        ReportColumn.num(tr('credit_got')),
        ReportColumn.num(tr('balance')),
      ],
      rows: [
        ['', tr('opening_balance'), '', '', _bal(st.opening)],
        for (final r in st.rows)
          [
            shortDate(r.date),
            [
              '${vtypeLabel(r.type, tr)}${r.payCode != null && r.credit > 0 ? ' (${r.payCode})' : ''} ${r.details}',
              if (r.hamali != 0) '+ ${tr('hamali')} ${Money.fmt(r.hamali)}',
              if (r.transport != 0) '+ ${tr('transport')} ${Money.fmt(r.transport)} (${r.transporterName ?? tr('own_vehicle')})',
              if (r.haste != null) '· ${tr('haste')}: ${r.haste}',
            ].join(' '),
            r.debit == 0 ? '' : Money.fmt(r.debit),
            r.credit == 0 ? '' : Money.fmt(r.credit),
            _bal(r.balance),
          ]
      ],
      rowRefs: [null, for (final r in st.rows) r.voucherId],
      totals: ['', tr('total'), Money.fmt(st.totalDebit), Money.fmt(st.totalCredit), _bal(st.closing)],
    );
  }

  /// "12,000 Dr" style balance using simple words.
  String _bal(int b) => b == 0 ? '0' : '${Money.fmt(b, abs: true)} ${b > 0 ? tr('dr_short') : tr('cr_short')}';

  /// दैनिक स्टॉक रजिस्टर for printing: one row per bill, one column per item.
  Future<ReportTable> dailyRegister(String date, {bool allItems = false}) async {
    final reg = await stock.dailyRegister(date);
    final items = reg.items.where((i) => allItems || reg.moved(i.id)).toList();
    String q(double v) => v == 0 ? '' : fmtQty(v);
    String pay(RegisterRow r) => switch (r.type) {
          VoucherType.salesReturn || VoucherType.purchaseReturn || VoucherType.stockAdjust || VoucherType.goodsOut ||
          VoucherType.goodsIn =>
            vtypeLabel(r.type, tr),
          _ when r.amount == 0 => vtypeLabel(r.type, tr),
          _ when r.paid >= r.amount => r.payName ?? tr('paid'),
          _ when r.paid == 0 => tr('reg_credit'),
          _ => tr('reg_part_paid').replaceAll('{paid}', Money.fmt(r.paid)),
        };
    String party(RegisterRow r) =>
        '${r.partyName ?? (r.type == VoucherType.sale ? tr('cash_sale') : vtypeLabel(r.type, tr))}${r.pageNo != null ? ' (${r.pageNo})' : ''}';
    final saleTotal = reg.rows.where((r) => r.type == VoucherType.sale).fold(0, (s, r) => s + r.amount);
    final rows = <List<String>>[
      ['', tr('opening'), for (final i in items) q(reg.opening[i.id] ?? 0), '', ''],
      for (final r in reg.rows)
        [
          '${r.serial}',
          party(r),
          for (final i in items)
            r.qty[i.id] == null
                ? ''
                : '${r.qty[i.id]! > 0 ? '+' : ''}${fmtQty(r.qty[i.id]!.abs())}'
                    '${(r.rate[i.id] ?? 0) > 0 ? '\n@${Money.fmt(r.rate[i.id]!)}' : ''}',
          r.type.isGoodsLoan ? '' : Money.fmt(r.amount),
          pay(r),
        ],
      ['', '− ${tr('out')}', for (final i in items) q(reg.totalOut(i.id)), Money.fmt(saleTotal), ''],
      ['', '+ ${tr('in')}', for (final i in items) q(reg.totalIn(i.id)), '', ''],
    ];
    return ReportTable(
      title: tr('daily_register'),
      subtitle: shortDate(date),
      columns: [
        const ReportColumn('#', flex: 1),
        ReportColumn(tr('party'), flex: 4),
        for (final i in items) ReportColumn.num('${i.name}\n${tr('unit_${i.unit}')}'),
        ReportColumn.num(tr('amount'), flex: 3),
        ReportColumn(tr('pay_mode'), flex: 3),
      ],
      rows: rows,
      rowRefs: [null, for (final r in reg.rows) r.voucherId, null, null],
      highlight: {0, rows.length - 2, rows.length - 1},
      totals: ['', tr('closing'), for (final i in items) fmtQty(reg.closing(i.id)), '', ''],
    );
  }

  /// उसना माल: bags lent to / borrowed from each party.
  Future<ReportTable> goodsOwed() async {
    final list = await stock.goodsOwed();
    return ReportTable(
      title: tr('r_goods_owed'),
      subtitle: tr('goods_owed_sub'),
      columns: [
        ReportColumn(tr('page_no'), flex: 1),
        ReportColumn(tr('name'), flex: 4),
        ReportColumn(tr('item'), flex: 3),
        ReportColumn.num(tr('goods_they_owe')),
        ReportColumn.num(tr('goods_we_owe')),
      ],
      rows: [
        for (final g in list)
          [
            g.pageNo ?? '',
            g.partyName,
            g.item.name,
            g.qty > 0 ? '${fmtQty(g.qty)} ${tr('unit_${g.item.unit}')}' : '',
            g.qty < 0 ? '${fmtQty(-g.qty)} ${tr('unit_${g.item.unit}')}' : '',
          ],
      ],
      rowRefs: [for (final g in list) g.partyId],
    );
  }

  Future<ReportTable> outstanding(LedgerGroup group) async {
    // a person can be both customer and supplier – the net balance decides
    // whether they appear under receivable or payable
    final list = await ledgers.list([LedgerGroup.customer, LedgerGroup.supplier]);
    final today = parseIso(todayIso());
    final rows = <List<String>>[];
    final refs = <String?>[];
    final hl = <int>{};
    var total = 0;
    final buckets = [0, 0, 0, 0];
    for (final l in list) {
      final b = group == LedgerGroup.customer ? l.balance : -l.balance;
      if (b <= 0) continue;
      // ageing: oldest unpaid bill date by FIFO – approximate with last receipt/payment date
      final last = await db.getOptional(
        'SELECT MAX(vl.vdate) AS d FROM voucher_lines vl WHERE vl.ledger_id = ? AND vl.deleted = 0 AND '
        '${group == LedgerGroup.customer ? 'vl.credit' : 'vl.debit'} > 0',
        [l.id],
      );
      final lastDate = last?['d'] as String?;
      final days = lastDate == null ? 999 : today.difference(parseIso(lastDate)).inDays;
      final bucket = days <= 30 ? 0 : days <= 60 ? 1 : days <= 90 ? 2 : 3;
      buckets[bucket] += b;
      total += b;
      if (days > 60) hl.add(rows.length);
      rows.add([
        l.pageNo ?? '',
        l.name,
        l.phone ?? '',
        lastDate == null ? '—' : shortDate(lastDate),
        days >= 999 ? '—' : '$days',
        Money.fmt(b),
      ]);
      refs.add(l.id);
    }
    // sort by amount desc
    final idx = List.generate(rows.length, (i) => i)
      ..sort((a, b) => Money.parse(rows[b][5])!.compareTo(Money.parse(rows[a][5])!));
    return ReportTable(
      title: group == LedgerGroup.customer ? tr('r_receivable') : tr('r_payable'),
      subtitle: '0-30: ${Money.fmt(buckets[0])} · 31-60: ${Money.fmt(buckets[1])} · '
          '61-90: ${Money.fmt(buckets[2])} · 90+: ${Money.fmt(buckets[3])}',
      columns: [
        ReportColumn(tr('page_no'), flex: 1),
        ReportColumn(tr('name'), flex: 4),
        ReportColumn(tr('phone'), flex: 3),
        ReportColumn(tr('last_payment'), flex: 2),
        ReportColumn.num(tr('days'), flex: 1),
        ReportColumn.num(tr('balance')),
      ],
      rows: [for (final i in idx) rows[i]],
      rowRefs: [for (final i in idx) refs[i]],
      highlight: {for (var j = 0; j < idx.length; j++) if (hl.contains(idx[j])) j},
      totals: ['', tr('total'), '', '', '', Money.fmt(total)],
    );
  }

  Future<ReportTable> moneyBook(List<String> ledgerIds, String title, String from, String to) async {
    final rows = <List<String>>[];
    final refs = <String?>[];
    int? opening;
    var tin = 0, tout = 0, closing = 0;
    for (var d = parseIso(from); !d.isAfter(parseIso(to)); d = d.add(const Duration(days: 1))) {
      final book = await ledgers.cashBook(ledgerIds, isoDate(d));
      opening ??= book.opening;
      for (final r in book.rows) {
        rows.add([
          shortDate(book.date),
          '${r.particulars.isNotEmpty ? r.particulars : tr(r.type == VoucherType.sale ? 'cash_sale' : 'vt_${r.type.code}')}${r.narration != null && r.narration != r.particulars ? ' · ${r.narration}' : ''}',
          r.code ?? '',
          r.inflow == 0 ? '' : Money.fmt(r.inflow),
          r.outflow == 0 ? '' : Money.fmt(r.outflow),
        ]);
        refs.add(r.voucherId);
      }
      tin += book.totalIn;
      tout += book.totalOut;
      closing = book.closing;
    }
    return ReportTable(
      title: title,
      subtitle: '${_range(from, to)} · ${tr('opening')}: ${Money.fmt(opening ?? 0)} · ${tr('closing')}: ${Money.fmt(closing)}',
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('particulars'), flex: 5),
        ReportColumn('', flex: 1),
        ReportColumn.num(tr('inflow')),
        ReportColumn.num(tr('outflow')),
      ],
      rows: rows,
      rowRefs: refs,
      totals: ['', tr('total'), '', Money.fmt(tin), Money.fmt(tout)],
    );
  }

  Future<ReportTable> stockSummary() async {
    final items = (await stock.list()).where((i) => !i.isService).toList();
    final avg = await stock.averageCosts();
    var value = 0.0;
    final hl = <int>{};
    final rows = <List<String>>[];
    for (final i in items) {
      final v = i.stock * (avg[i.id] ?? 0);
      value += v;
      if (i.lowStock > 0 && i.stock <= i.lowStock) hl.add(rows.length);
      rows.add([
        i.shortCode ?? '',
        i.name,
        '${fmtQty(i.stock)} ${tr('unit_${i.unit}')}',
        Money.fmt((avg[i.id] ?? 0).round()),
        Money.fmt(v.round()),
      ]);
    }
    return ReportTable(
      title: tr('r_stock'),
      subtitle: todayIso().split('-').reversed.join('/'),
      columns: [
        ReportColumn(tr('code'), flex: 1),
        ReportColumn(tr('item'), flex: 4),
        ReportColumn.num(tr('stock')),
        ReportColumn.num(tr('avg_cost')),
        ReportColumn.num(tr('value')),
      ],
      rows: rows,
      rowRefs: [for (final i in items) i.id],
      highlight: hl,
      totals: ['', tr('total'), '', '', Money.fmt(value.round())],
    );
  }

  Future<ReportTable> register(VoucherType type, String from, String to) async {
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.vno, v.amount, v.paid, p.name AS party, pl.short_code AS code, '
      '(SELECT GROUP_CONCAT(COALESCE(i.short_code, i.name) || \' \' || il.qty || \'×\' || (il.rate/100.0), \', \') '
      ' FROM inventory_lines il JOIN items i ON i.id = il.item_id WHERE il.voucher_id = v.id AND il.deleted = 0) AS items '
      'FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      'WHERE v.business_id = ? AND v.vtype = ? AND v.deleted = 0 AND v.vdate BETWEEN ? AND ? ORDER BY v.vdate, v.vno',
      [businessId, type.code, from, to],
    );
    var tot = 0, paid = 0;
    return ReportTable(
      title: type == VoucherType.sale ? tr('r_sales') : tr('r_purchases'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn('#', flex: 1),
        ReportColumn(tr('party'), flex: 3),
        ReportColumn(tr('items'), flex: 4),
        ReportColumn.num(tr('amount')),
        ReportColumn.num(tr('due')),
      ],
      rows: [
        for (final r in rows)
          () {
            final a = r['amount'] as int;
            final p = r['paid'] as int;
            tot += a;
            paid += p;
            return [
              shortDate(r['vdate'] as String),
              '${r['vno']}',
              (r['party'] as String?) ?? tr('cash_sale'),
              ((r['items'] as String?) ?? '').replaceAllMapped(RegExp(r'(\d+)\.0\b'), (m) => m[1]!),
              Money.fmt(a),
              a - p == 0 ? '' : Money.fmt(a - p),
            ];
          }()
      ],
      rowRefs: [for (final r in rows) r['id'] as String],
      totals: ['', '', tr('total'), '', Money.fmt(tot), Money.fmt(tot - paid)],
    );
  }

  /// Item-wise sales with profit using weighted-average cost.
  Future<ReportTable> itemProfit(String from, String to) async {
    final avg = await stock.averageCosts(date: to);
    final rows = await db.getAll(
      'SELECT i.id, i.name, i.unit, SUM(il.qty) AS q, SUM(il.amount) AS a FROM inventory_lines il '
      'JOIN items i ON i.id = il.item_id JOIN vouchers v ON v.id = il.voucher_id '
      "WHERE il.business_id = ? AND il.deleted = 0 AND v.vtype = 'sale' AND il.vdate BETWEEN ? AND ? "
      'GROUP BY i.id ORDER BY a DESC',
      [businessId, from, to],
    );
    var ts = 0, tp = 0;
    return ReportTable(
      title: tr('r_item_profit'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('item'), flex: 4),
        ReportColumn.num(tr('qty')),
        ReportColumn.num(tr('sales')),
        ReportColumn.num(tr('cost')),
        ReportColumn.num(tr('profit')),
      ],
      rows: [
        for (final r in rows)
          () {
            final q = (r['q'] as num).toDouble();
            final a = (r['a'] as num).toInt();
            final c = (q * (avg[r['id']] ?? 0)).round();
            ts += a;
            tp += a - c;
            return [r['name'] as String, '${fmtQty(q)} ${tr('unit_${r['unit']}')}', Money.fmt(a), Money.fmt(c), Money.fmt(a - c)];
          }()
      ],
      totals: [tr('total'), '', Money.fmt(ts), Money.fmt(ts - tp), Money.fmt(tp)],
    );
  }

  /// Net movement per ledger in a period.
  Future<Map<String, (Ledger, int)>> _movement(String from, String to, List<LedgerGroup> groups) async {
    final rows = await db.getAll(
      'SELECT l.*, COALESCE(SUM(vl.debit - vl.credit),0) AS mv FROM ledgers l '
      'LEFT JOIN voucher_lines vl ON vl.ledger_id = l.id AND vl.deleted = 0 AND vl.vdate BETWEEN ? AND ? '
      'WHERE l.business_id = ? AND l.grp IN (${groups.map((g) => "'${g.code}'").join(',')}) GROUP BY l.id',
      [from, to, businessId],
    );
    return {for (final r in rows) r['id'] as String: (Ledger.fromRow(r), (r['mv'] as num).toInt())};
  }

  Future<ReportTable> expenseSummary(String from, String to) async {
    final mv = await _movement(from, to, [LedgerGroup.expense, LedgerGroup.directExpense]);
    final list = mv.values.where((e) => e.$2 != 0).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final total = list.fold<int>(0, (s, e) => s + e.$2);
    return ReportTable(
      title: tr('r_expenses'),
      subtitle: _range(from, to),
      columns: [ReportColumn(tr('ledger'), flex: 5), ReportColumn.num(tr('amount'))],
      rows: [for (final e in list) [e.$1.name, Money.fmt(e.$2)]],
      rowRefs: [for (final e in list) e.$1.id],
      totals: [tr('total'), Money.fmt(total)],
    );
  }

  /// Profit & Loss (trading + P&L combined, simple vertical format).
  Future<ReportTable> profitAndLoss(String from, String to) async {
    final mv = await _movement(from, to, LedgerGroup.values);
    int sumG(LedgerGroup g) => mv.values.where((e) => e.$1.group == g).fold(0, (s, e) => s + e.$2);
    final sales = -sumG(LedgerGroup.sales) - sumG(LedgerGroup.salesReturn);
    final purchases = sumG(LedgerGroup.purchase) + sumG(LedgerGroup.purchaseReturn);
    final direct = sumG(LedgerGroup.directExpense);
    final openingStock = await _stockValue(before: from);
    final closingStock = await _stockValue(upto: to);
    final cogs = openingStock + purchases + direct - closingStock;
    final gross = sales - cogs;
    final expenses = mv.values.where((e) => e.$1.group == LedgerGroup.expense && e.$2 != 0).toList();
    final otherIncome = -sumG(LedgerGroup.income);
    final totalExp = expenses.fold<int>(0, (s, e) => s + e.$2);
    final net = gross + otherIncome - totalExp;
    return ReportTable(
      title: tr('r_pnl'),
      subtitle: _range(from, to),
      columns: [ReportColumn(tr('particulars'), flex: 5), ReportColumn.num(tr('amount'))],
      rows: [
        [tr('net_sales'), Money.fmt(sales)],
        ['  ${tr('opening_stock')}', Money.fmt(openingStock)],
        ['  + ${tr('purchases')}', Money.fmt(purchases)],
        ['  + ${tr('direct_exp')}', Money.fmt(direct)],
        ['  − ${tr('closing_stock')}', Money.fmt(closingStock)],
        [tr('cogs'), Money.fmt(cogs)],
        [tr('gross_profit'), Money.fmt(gross)],
        [tr('other_income'), Money.fmt(otherIncome)],
        for (final e in expenses) ['  − ${e.$1.name}', Money.fmt(e.$2)],
        [tr('total_expenses'), Money.fmt(totalExp)],
      ],
      highlight: {6},
      totals: [net >= 0 ? tr('net_profit') : tr('net_loss'), Money.fmt(net.abs())],
    );
  }

  Future<int> _stockValue({String? before, String? upto}) async {
    final items = await stock.list();
    final avg = await stock.averageCosts(date: upto ?? before);
    var v = 0.0;
    for (final i in items) {
      final q = before != null ? await stock.stockAt(i.id, before, before: true) : await stock.stockAt(i.id, upto!);
      // bags lent out (उसना) are still ours; bags borrowed are not
      final lent = before != null ? await stock.lentAt(i.id, before, before: true) : await stock.lentAt(i.id, upto!);
      v += lent * (avg[i.id] ?? 0);
      v += q * (avg[i.id] ?? 0);
    }
    return v.round();
  }

  Future<ReportTable> trialBalance(String to) async {
    final rows = await db.getAll(
      'SELECT l.*, l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id '
      'AND deleted = 0 AND vdate <= ?),0) AS balance FROM ledgers l WHERE l.business_id = ? ORDER BY l.grp, l.name',
      [to, businessId],
    );
    var td = 0, tc = 0;
    final out = <List<String>>[];
    for (final r in rows) {
      final l = Ledger.fromRow(r);
      if (l.balance == 0) continue;
      if (l.balance > 0) td += l.balance; else tc -= l.balance;
      out.add([tr('grp_${l.group.code}'), l.name, l.balance > 0 ? Money.fmt(l.balance) : '', l.balance < 0 ? Money.fmt(-l.balance) : '']);
    }
    // Opening balances of parties may not balance (single-entry history) → show difference.
    final diff = td - tc;
    if (diff != 0) {
      out.add(['', tr('opening_diff'), diff < 0 ? Money.fmt(-diff) : '', diff > 0 ? Money.fmt(diff) : '']);
      if (diff > 0) tc += diff; else td -= diff;
    }
    return ReportTable(
      title: tr('r_trial'),
      subtitle: shortDate(to),
      columns: [
        ReportColumn(tr('group'), flex: 2),
        ReportColumn(tr('ledger'), flex: 4),
        ReportColumn.num(tr('dr_short')),
        ReportColumn.num(tr('cr_short')),
      ],
      rows: out,
      totals: ['', tr('total'), Money.fmt(td), Money.fmt(tc)],
    );
  }

  Future<ReportTable> balanceSheet(String to) async {
    final rows = await db.getAll(
      'SELECT l.*, l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id '
      'AND deleted = 0 AND vdate <= ?),0) AS balance FROM ledgers l WHERE l.business_id = ?',
      [to, businessId],
    );
    final ls = rows.map(Ledger.fromRow).toList();
    int sum(bool Function(Ledger) f) => ls.where(f).fold(0, (s, l) => s + l.balance);
    final stockVal = await _stockValue(upto: to);
    final fy = fyStart(to);
    final pnl = await profitAndLoss(fy, to);
    final profitStr = pnl.totals![1];
    final profit = (Money.parse(profitStr) ?? 0) * (pnl.totals![0] == tr('net_profit') ? 1 : -1);
    final debtors = ls.where((l) => l.group == LedgerGroup.customer && l.balance > 0).fold(0, (s, l) => s + l.balance);
    final custAdv = -ls.where((l) => l.group == LedgerGroup.customer && l.balance < 0).fold(0, (s, l) => s + l.balance);
    final creditors = -ls.where((l) => l.group == LedgerGroup.supplier && l.balance < 0).fold(0, (s, l) => s + l.balance);
    final supAdv = ls.where((l) => l.group == LedgerGroup.supplier && l.balance > 0).fold(0, (s, l) => s + l.balance);
    final cash = sum((l) => l.group == LedgerGroup.cash);
    final upi = sum((l) => l.group == LedgerGroup.upi);
    final bank = sum((l) => l.group == LedgerGroup.bank);
    final other = sum((l) => l.group == LedgerGroup.otherAsset);
    final capital = -sum((l) => l.group == LedgerGroup.capital);
    final loans = -sum((l) => l.group == LedgerGroup.loan);
    final gst = -sum((l) => l.group == LedgerGroup.gst);
    final otherLiab = -sum((l) => l.group == LedgerGroup.otherLiability);
    // staff: advances still with them are an asset, unpaid salary a liability
    final staffAdv = ls.where((l) => l.group == LedgerGroup.staff && l.balance > 0).fold(0, (s, l) => s + l.balance);
    final staffDue = -ls.where((l) => l.group == LedgerGroup.staff && l.balance < 0).fold(0, (s, l) => s + l.balance);
    final assets = debtors + supAdv + cash + upi + bank + other + stockVal + staffAdv;
    final liabilities = capital + loans + gst + otherLiab + creditors + custAdv + profit + staffDue;
    final diff = assets - liabilities;
    return ReportTable(
      title: tr('r_bs'),
      subtitle: shortDate(to),
      columns: [ReportColumn(tr('particulars'), flex: 5), ReportColumn.num(tr('amount'))],
      rows: [
        [tr('liabilities'), ''],
        ['  ${tr('grp_capital')}', Money.fmt(capital)],
        ['  ${tr('net_profit')} (${tr('this_fy')})', Money.fmt(profit)],
        ['  ${tr('grp_loan')}', Money.fmt(loans)],
        ['  ${tr('suppliers_payable')}', Money.fmt(creditors)],
        ['  ${tr('customer_advance')}', Money.fmt(custAdv)],
        ['  GST', Money.fmt(gst)],
        ['  ${tr('grp_other_liability')}', Money.fmt(otherLiab)],
        if (staffDue != 0) ['  ${tr('salary_due')}', Money.fmt(staffDue)],
        if (diff != 0) ['  ${tr('opening_diff')}', Money.fmt(diff)],
        [tr('assets'), ''],
        ['  ${tr('customers_receivable')}', Money.fmt(debtors)],
        ['  ${tr('supplier_advance')}', Money.fmt(supAdv)],
        ['  ${tr('closing_stock')}', Money.fmt(stockVal)],
        ['  ${tr('grp_cash')}', Money.fmt(cash)],
        ['  ${tr('grp_upi')}', Money.fmt(upi)],
        ['  ${tr('grp_bank')}', Money.fmt(bank)],
        ['  ${tr('grp_other_asset')}', Money.fmt(other)],
        if (staffAdv != 0) ['  ${tr('advance_due')}', Money.fmt(staffAdv)],
      ],
      highlight: {0, 8 + (staffDue != 0 ? 1 : 0) + (diff != 0 ? 1 : 0)},
      totals: [tr('total'), Money.fmt(assets)],
    );
  }

  /// Month-wise GST on genuine GST bills: input (purchases) vs output (sales).
  Future<ReportTable> gstSummary(String from, String to) async {
    final rows = await db.getAll(
      "SELECT substr(vdate, 1, 7) AS m, vtype, SUM(amount - gst - hamali - transport) AS taxable, SUM(gst) AS g "
      "FROM vouchers WHERE business_id = ? AND deleted = 0 AND gst <> 0 AND vtype IN ('sale','purchase') "
      'AND vdate BETWEEN ? AND ? GROUP BY m, vtype ORDER BY m',
      [businessId, from, to],
    );
    final months = <String, List<int>>{}; // m → [pTaxable, input, sTaxable, output]
    for (final r in rows) {
      final v = months.putIfAbsent(r['m'] as String, () => [0, 0, 0, 0]);
      final sale = r['vtype'] == 'sale';
      v[sale ? 2 : 0] += (r['taxable'] as num).toInt();
      v[sale ? 3 : 1] += (r['g'] as num).toInt();
    }
    final tot = [0, 0, 0, 0];
    final out = <List<String>>[];
    for (final e in months.entries) {
      for (var i = 0; i < 4; i++) {
        tot[i] += e.value[i];
      }
      final ym = e.key.split('-');
      out.add(['${ym[1]}/${ym[0]}', ...e.value.map(Money.fmt), Money.fmt(e.value[3] - e.value[1])]);
    }
    return ReportTable(
      title: tr('r_gst_summary'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('month'), flex: 2),
        ReportColumn.num(tr('gst_purchase')),
        ReportColumn.num(tr('gst_input')),
        ReportColumn.num(tr('gst_sale')),
        ReportColumn.num(tr('gst_output')),
        ReportColumn.num(tr('gst_net')),
      ],
      rows: out,
      totals: [tr('total'), ...tot.map(Money.fmt), Money.fmt(tot[3] - tot[1])],
    );
  }

  Future<ReportTable> gstLedger(String from, String to) async =>
      ledgerStatement('$businessId:gst', from: from, to: to);

  Future<ReportTable> gstBillsNeeded(String from, String to) async {
    final rows = await db.getAll(
      'SELECT v.*, p.name AS party_name, pl.short_code AS pay_code FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id '
      'LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id WHERE v.business_id = ? AND v.deleted = 0 AND v.gst_bill_needed = 1 '
      'AND v.vdate BETWEEN ? AND ? ORDER BY v.vdate',
      [businessId, from, to],
    );
    final vs = rows.map(Voucher.fromRow).toList();
    return ReportTable(
      title: tr('r_gst_bills'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('type'), flex: 2),
        ReportColumn(tr('party'), flex: 4),
        ReportColumn(tr('ref'), flex: 2),
        ReportColumn.num(tr('amount')),
      ],
      rows: [
        for (final v in vs)
          [shortDate(v.date), vtypeLabel(v.type, tr), v.partyName ?? v.narration ?? '', v.refNo ?? '', Money.fmt(v.amount)]
      ],
      rowRefs: [for (final v in vs) v.id],
      totals: ['', '', tr('total'), '', Money.fmt(vs.fold(0, (s, v) => s + v.amount))],
    );
  }

  Future<ReportTable> itemMovement(String itemId, String from, String to) async {
    final item = (await stock.byId(itemId))!;
    final mv = await stock.movements(itemId, from: from, to: to);
    final opening = await stock.stockAt(itemId, from, before: true);
    return ReportTable(
      title: item.name,
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('particulars'), flex: 4),
        ReportColumn.num(tr('in')),
        ReportColumn.num(tr('out')),
        ReportColumn.num(tr('rate')),
        ReportColumn.num(tr('balance')),
      ],
      rows: [
        ['', tr('opening'), '', '', '', fmtQty(opening)],
        for (final m in mv)
          [
            shortDate(m.date),
            '${vtypeLabel(m.type, tr)} ${m.partyName ?? ''}${m.pageNo != null ? ' (${m.pageNo})' : ''}',
            m.qtyIn == 0 ? '' : fmtQty(m.qtyIn),
            m.qtyOut == 0 ? '' : fmtQty(m.qtyOut),
            Money.fmt(m.rate),
            fmtQty(m.balance),
          ]
      ],
      rowRefs: [null, for (final m in mv) m.voucherId],
    );
  }
}
