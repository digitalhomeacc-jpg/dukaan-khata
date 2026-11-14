import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import '../inventory/stock_repo.dart';
import 'ledger_repo.dart';
import 'models.dart';
import 'stock_pnl.dart';

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

  /// [forCustomer]: the copy sent to the party – no names of whose vehicle went.
  Future<ReportTable> ledgerStatement(String ledgerId, {String? from, String? to, bool forCustomer = false}) async {
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
              if (r.transport != 0)
                '+ ${tr('transport')} ${Money.fmt(r.transport)}${forCustomer ? '' : ' (${r.transporterName ?? tr('own_vehicle')})'}',
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
      // balance right after the name, so it shows on a phone without scrolling
      rows.add([
        l.pageNo ?? '',
        l.name,
        Money.fmt(b),
        lastDate == null ? '—' : shortDate(lastDate),
        days >= 999 ? '—' : '$days',
        l.phone ?? '',
      ]);
      refs.add(l.id);
    }
    // sort by amount desc
    final idx = List.generate(rows.length, (i) => i)
      ..sort((a, b) => Money.parse(rows[b][2])!.compareTo(Money.parse(rows[a][2])!));
    return ReportTable(
      title: group == LedgerGroup.customer ? tr('r_receivable') : tr('r_payable'),
      subtitle: '0-30: ${Money.fmt(buckets[0])} · 31-60: ${Money.fmt(buckets[1])} · '
          '61-90: ${Money.fmt(buckets[2])} · 90+: ${Money.fmt(buckets[3])}',
      columns: [
        ReportColumn(tr('page_no'), flex: 1),
        ReportColumn(tr('name'), flex: 4),
        ReportColumn.num(tr('balance'), flex: 3),
        ReportColumn(tr('last_payment'), flex: 2),
        ReportColumn.num(tr('days'), flex: 1),
        ReportColumn(tr('phone'), flex: 3),
      ],
      rows: [for (final i in idx) rows[i]],
      rowRefs: [for (final i in idx) refs[i]],
      highlight: {for (var j = 0; j < idx.length; j++) if (hl.contains(idx[j])) j},
      totals: ['', tr('total'), Money.fmt(total), '', '', ''],
    );
  }

  /// उधारी: what went on credit on [date] – bills not paid in full (given to
  /// customers / taken from suppliers) and goods lent or brought back.
  Future<UdhariDay> udhariDay(String date) async {
    final rows = await db.getAll(
      'SELECT v.id, v.vtype, v.amount, v.paid, v.pay_ledger_id, p.name AS party_name, p.page_no, '
      "(SELECT GROUP_CONCAT(COALESCE(i.name, '?') || ' ' || il.qty || ' ' || COALESCE(i.unit, ''), ', ') "
      ' FROM inventory_lines il JOIN items i ON i.id = il.item_id WHERE il.voucher_id = v.id AND il.deleted = 0) AS items '
      'FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id '
      "WHERE v.business_id = ? AND v.vdate = ? AND v.deleted = 0 AND v.party_id IS NOT NULL "
      "AND v.vtype IN ('sale', 'purchase', 'goods_out', 'goods_in') ORDER BY v.created_at",
      [businessId, date],
    );
    final out = <UdhariRow>[];
    for (final r in rows) {
      final type = VoucherType.fromCode(r['vtype'] as String);
      if (type.isGoodsLoan && r['pay_ledger_id'] == 'opening') continue; // carried from before the books
      final unpaid = ((r['amount'] as int?) ?? 0) - ((r['paid'] as int?) ?? 0);
      if (!type.isGoodsLoan && unpaid <= 0) continue;
      // "सळई 8mm 12.0 kg" → "सळई 8mm 12 kg"
      final items = (r['items'] as String?)?.replaceAllMapped(RegExp(r'(\d+)\.0(?=\D|$)'), (m) => m[1]!).replaceAllMapped(
              RegExp(r' (bag|kg|nos|ft|ton|brass|ltr|sqft|job|day)(?=,|$)'), (m) => ' ${tr('unit_${m[1]}')}') ??
          '';
      out.add(UdhariRow(r['id'] as String, type, (r['party_name'] as String?) ?? '', r['page_no'] as String?, items,
          type.isGoodsLoan ? 0 : unpaid));
    }
    return UdhariDay(date, out);
  }

  Future<ReportTable> udhariTable(String date) async {
    final d = await udhariDay(date);
    String money(UdhariRow r, VoucherType t) => r.type == t ? Money.fmt(r.amount) : '';
    return ReportTable(
      title: tr('udhari_tab'),
      subtitle: shortDate(date),
      columns: [
        ReportColumn(tr('party'), flex: 4),
        ReportColumn(tr('details'), flex: 5),
        ReportColumn.num(tr('udhari_given'), flex: 2),
        ReportColumn.num(tr('udhari_taken'), flex: 2),
      ],
      rows: [
        for (final r in d.rows)
          [
            '${r.party}${r.pageNo != null ? ' (${r.pageNo})' : ''}',
            [
              if (r.type.isGoodsLoan) vtypeLabel(r.type, tr),
              if (r.items.isNotEmpty) r.items,
            ].join(' · '),
            money(r, VoucherType.sale),
            money(r, VoucherType.purchase),
          ]
      ],
      rowRefs: [for (final r in d.rows) r.voucherId],
      totals: ['', tr('total'), Money.fmt(d.given), Money.fmt(d.taken)],
    );
  }

  /// खरी किंमत: what each of a supplier's items really cost per bag after
  /// the company's discounts, month by month – so the rate paid a year ago
  /// is there to price today's sales. Counts old entries brought in from the
  /// company's statement (invoices with items, discounts) as well as the
  /// purchases and credit notes since the books start. A month's discounts
  /// are shared over that month's items by value; security / other charges
  /// and payments are not costs.
  /// Rewards paid out as gift cards (Wonder Coin) and insurance (GMC policy)
  /// are not a discount on the goods: left out of the real cost.
  static const _notScheme = "AND COALESCE(v.narration, '') NOT LIKE '%coin%' AND COALESCE(v.narration, '') NOT LIKE '%GMC%' "
      "AND COALESCE(v.narration, '') NOT LIKE '%gift%'";

  Future<ReportTable> supplierCost(String supplierId, String from, String to) async {
    final sup = (await ledgers.byId(supplierId))!;
    // whole financial years, so a year's discounts are spread over all of its goods
    from = fyStart(from);
    final goods = await db.getAll(
      "SELECT substr(il.vdate, 1, 7) AS m, il.item_id, i.name AS item, i.unit, "
      "SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.qty ELSE il.qty END) AS q, "
      "SUM(CASE WHEN v.vtype = 'purchase_return' THEN -il.amount ELSE il.amount END) AS a "
      'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id JOIN items i ON i.id = il.item_id '
      'WHERE v.party_id = ? AND v.deleted = 0 AND il.deleted = 0 AND il.vdate BETWEEN ? AND ? '
      "AND (v.vtype IN ('purchase', 'purchase_return') OR (v.vtype = 'history' AND v.pay_ledger_id = 'hist:purchase')) "
      'GROUP BY m, il.item_id ORDER BY m, i.name',
      [supplierId, from, to],
    );
    // discounts: credit notes since the books start + old ones from the statement
    final disc = <String, int>{};
    for (final r in await db.getAll(
        'SELECT substr(vl.vdate, 1, 7) AS m, SUM(vl.credit - vl.debit) AS d FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
        'WHERE v.party_id = ? AND v.deleted = 0 AND vl.deleted = 0 AND vl.ledger_id = ? AND vl.vdate BETWEEN ? AND ? $_notScheme GROUP BY m',
        [supplierId, '$businessId:discount_recd', from, to])) {
      disc[r['m'] as String] = (disc[r['m'] as String] ?? 0) + (r['d'] as num).toInt();
    }
    for (final r in await db.getAll(
        "SELECT substr(vdate, 1, 7) AS m, SUM(amount) AS d FROM vouchers WHERE party_id = ? AND vtype = 'history' AND deleted = 0 "
        "AND vdate BETWEEN ? AND ? AND (status LIKE 'stmt:discount%' OR (COALESCE(status, '') NOT LIKE 'stmt:%' "
        "AND pay_ledger_id = 'hist:paid' AND (narration LIKE '%discount%' OR narration LIKE '%सूट%' OR narration LIKE '%scheme%'))) "
        '${_notScheme.replaceAll('v.narration', 'narration')} GROUP BY m',
        [supplierId, from, to])) {
      disc[r['m'] as String] = (disc[r['m'] as String] ?? 0) + (r['d'] as num).toInt();
    }
    // financial year (April–March): every discount of the year – trade,
    // special, quarterly, coins, cash, yearly – spread over the year's goods
    String fyOf(String m) => fyStart('$m-01').substring(0, 7);
    final monthValue = <String, int>{}, fyValue = <String, int>{}, fyDisc = <String, int>{};
    for (final g in goods) {
      final m = g['m'] as String, a = (g['a'] as num).toInt();
      monthValue[m] = (monthValue[m] ?? 0) + a;
      fyValue[fyOf(m)] = (fyValue[fyOf(m)] ?? 0) + a;
    }
    for (final e in disc.entries) {
      fyDisc[fyOf(e.key)] = (fyDisc[fyOf(e.key)] ?? 0) + e.value;
    }
    String rate(num amount, double qty) => qty <= 0 ? '' : Money.fmt(((amount / qty) / 100).round() * 100);
    String mon(String m) => '${m.substring(5)}/${m.substring(2, 4)}';
    String fyLabel(String f) {
      final y = int.parse(f.substring(0, 4));
      return '${y % 100}-${(y + 1) % 100}';
    }

    final rows = <List<String>>[];
    final per = <String, (String, double, int, double)>{}; // item → name, qty, value, value after year's discounts
    var ta = 0, tq = 0.0, tn = 0.0;
    var usedMonth = 0.0, usedYear = 0.0; // discount taken off in each column – must be the same money
    for (final g in goods) {
      final m = g['m'] as String, f = fyOf(m);
      final q = (g['q'] as num).toDouble(), a = (g['a'] as num).toInt();
      final mv = monthValue[m] ?? 0;
      final dMonth = mv <= 0 ? 0.0 : (disc[m] ?? 0) * a / mv; // this month's discounts, by value
      final fyShare = (fyValue[f] ?? 0) <= 0 ? 0.0 : (fyDisc[f] ?? 0) / fyValue[f]!; // year's discount per rupee
      final net = a * (1 - fyShare);
      usedMonth += dMonth;
      usedYear += a - net;
      final name = '${g['item']}';
      rows.add([mon(m), name, fmtQty(q), rate(a, q), rate(a - dMonth, q), rate(net, q)]);
      final p = per[g['item_id'] as String] ?? (name, 0.0, 0, 0.0);
      per[g['item_id'] as String] = (name, p.$2 + q, p.$3 + a, p.$4 + net);
      ta += a;
      tq += q;
      tn += net;
    }
    // per item over the whole period
    for (final p in per.values) {
      rows.add([tr('total'), p.$1, fmtQty(p.$2), rate(p.$3, p.$2), '', rate(p.$4, p.$2)]);
    }
    final fys = {...fyValue.keys, ...fyDisc.keys}.toList()..sort();
    return ReportTable(
      title: '${tr('r_real_cost')} – ${sup.name}',
      subtitle: [
        _range(from, to),
        // the proof that nothing is counted twice: both columns use the same discounts
        tr('real_cost_same').replaceAll('{m}', Money.fmt(usedMonth.round())).replaceAll('{y}', Money.fmt(usedYear.round()))
            .replaceAll('{d}', Money.fmt(disc.values.fold(0, (s, x) => s + x))),
        for (final f in fys)
          '${tr('fy')} ${fyLabel(f)}: ${tr('purchase')} ₹${Money.fmt(fyValue[f] ?? 0)} · ${tr('discount')} ₹${Money.fmt(fyDisc[f] ?? 0)}'
              '${(fyValue[f] ?? 0) > 0 ? ' (${((fyDisc[f] ?? 0) * 1000 / fyValue[f]!).round() / 10}%)' : ''}',
        tr('real_cost_note'),
      ].join(' · '),
      columns: [
        ReportColumn(tr('month'), flex: 2),
        ReportColumn(tr('item'), flex: 4),
        ReportColumn.num(tr('qty'), flex: 2),
        ReportColumn.num(tr('bill_rate'), flex: 2),
        ReportColumn.num(tr('net_rate_month'), flex: 2),
        ReportColumn.num(tr('net_rate_fy'), flex: 2),
      ],
      rows: rows,
      totals: ['', '', fmtQty(tq), rate(ta, tq), '', rate(tn, tq)],
    );
  }

  /// जुन्या नोंदी: the old (pre-books) entries of a party with their own
  /// running balance, and whether that ends at the opening balance.
  Future<ReportTable?> oldEntriesTable(String ledgerId) async {
    final st = await ledgers.statement(ledgerId);
    if (st.references.isEmpty) return null;
    String bal(int b) => b == 0 ? '0' : '${Money.fmt(b, abs: true)} ${b > 0 ? tr('dr_short') : tr('cr_short')}';
    final last = st.references.last.balance, opening = st.ledger.openingBalance;
    return ReportTable(
      title: '${st.ledger.name} – ${tr('old_entries_ref')}',
      subtitle: '${tr('old_total')}: ${bal(last)} · ${tr('opening_balance')}: ${bal(opening)}'
          '${last == opening ? ' · ✓ ${tr('old_matches')}' : ' · ${tr('old_diff')} ${bal(opening - last)}'}',
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('details'), flex: 5),
        ReportColumn.num(tr('debit_given')),
        ReportColumn.num(tr('credit_got')),
        ReportColumn.num(tr('balance')),
      ],
      rows: [
        for (final r in st.references)
          [
            shortDate(r.date),
            [tr('old_${r.kind ?? 'sale'}'), if (r.details.isNotEmpty) r.details].join(' · '),
            r.debit == 0 ? '' : Money.fmt(r.debit),
            r.credit == 0 ? '' : Money.fmt(r.credit),
            bal(r.balance),
          ]
      ],
      rowRefs: [for (final r in st.references) r.voucherId],
      totals: [
        '',
        tr('total'),
        Money.fmt(st.references.fold(0, (s, r) => s + r.debit)),
        Money.fmt(st.references.fold(0, (s, r) => s + r.credit)),
        bal(last),
      ],
    );
  }

  Future<ReportTable> moneyBook(List<String> ledgerIds, String title, String from, String to) async {
    final rows = <List<String>>[];
    final refs = <String?>[];
    final highlight = <int>{};
    int? opening;
    var tin = 0, tout = 0, closing = 0;
    for (var d = parseIso(from); !d.isAfter(parseIso(to)); d = d.add(const Duration(days: 1))) {
      final book = await ledgers.cashBook(ledgerIds, isoDate(d));
      opening ??= book.opening;
      // counter sales (रोख विक्री): one total line, as written in the cash book,
      // with each bill listed under it – per cash / PhonePe / bank
      final counter = <String, List<CashRow>>{};
      for (final r in book.rows.where((r) => r.walkInSale)) {
        counter.putIfAbsent(r.code ?? '', () => []).add(r);
      }
      for (final r in book.rows) {
        final g = r.walkInSale ? counter[r.code ?? '']! : const <CashRow>[];
        if (g.length >= 2) {
          if (!identical(r, g.first)) continue;
          final sum = g.fold<int>(0, (s, x) => s + x.inflow - x.outflow);
          highlight.add(rows.length);
          rows.add([
            shortDate(book.date),
            '${tr('cash_sale')} (${g.length} ${tr('bills')})',
            r.code ?? '',
            sum > 0 ? Money.fmt(sum) : '',
            sum < 0 ? Money.fmt(-sum) : '',
          ]);
          refs.add(null);
          for (final x in g) {
            rows.add([
              '',
              '    - ${tr('bill')} ${x.vno != null ? '#${x.vno}' : ''}: ${Money.fmt(x.inflow - x.outflow)}'
                  '${x.narration != null ? ' · ${x.narration}' : ''}',
              '',
              '',
              '',
            ]);
            refs.add(x.voucherId);
          }
          continue;
        }
        rows.add([
          shortDate(book.date),
          '${r.varhai ? '${tr('varhai')}${r.particulars.isNotEmpty ? ' · ${r.particulars}' : ''}' : r.particulars.isNotEmpty ? r.particulars : tr(r.type == VoucherType.sale ? 'cash_sale' : r.type == VoucherType.purchase ? 'cash_purchase' : 'vt_${r.type.code}')}${r.narration != null && r.narration != r.particulars ? ' · ${r.narration}' : ''}',
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
      highlight: highlight,
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

  /// हमाली व गाडी भाडे: bill by bill – hamali taken / paid, fares taken / paid,
  /// and whose vehicle went (own or which driver, at what fare).
  Future<ReportTable> chargesRegister(String from, String to) async {
    final b = businessId;
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.vtype, v.vno, v.transport, v.transporter_fare, p.name AS party_name, p.page_no, p.grp AS party_grp, '
      'tr.name AS transporter_name, '
      "SUM(CASE WHEN vl.ledger_id IN (?, ?) THEN vl.credit - vl.debit ELSE 0 END) AS hamali_in, "
      "SUM(CASE WHEN vl.ledger_id = ? THEN vl.debit - vl.credit ELSE 0 END) AS hamali_out, "
      "SUM(CASE WHEN v.vtype = 'payment' AND l.grp = 'transporter' THEN vl.debit - vl.credit ELSE 0 END) AS fare_out "
      'FROM vouchers v JOIN voucher_lines vl ON vl.voucher_id = v.id AND vl.deleted = 0 JOIN ledgers l ON l.id = vl.ledger_id '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers tr ON tr.id = v.transporter_id '
      'WHERE v.business_id = ? AND v.deleted = 0 AND v.vdate BETWEEN ? AND ? '
      'GROUP BY v.id ORDER BY v.vdate, v.created_at',
      ['$b:hamali_income', '$b:varhai', '$b:hamali', b, from, to],
    );
    final out = <List<String>>[];
    final refs = <String?>[];
    var hin = 0, hout = 0, fin = 0, fout = 0;
    for (final r in rows) {
      final type = VoucherType.fromCode(r['vtype'] as String);
      final hi = (r['hamali_in'] as num).toInt(), ho = (r['hamali_out'] as num).toInt();
      final fi = type == VoucherType.sale ? ((r['transport'] as int?) ?? 0) : 0;
      final fo = (r['fare_out'] as num).toInt();
      if (hi == 0 && ho == 0 && fi == 0 && fo == 0) continue;
      final party = r['party_name'] as String?;
      final who = r['party_grp'] == 'transporter' || party == null ? '' : '$party${r['page_no'] != null ? ' (${r['page_no']})' : ''}';
      final vehicle = fi == 0
          ? (fo != 0 ? (party ?? '') : '')
          : r['transporter_name'] == null
              ? tr('own_vehicle')
              : '${r['transporter_name']} ${Money.fmt((r['transporter_fare'] as int?) ?? fi)}';
      out.add([
        shortDate(r['vdate'] as String),
        [
          '${vtypeLabel(type, tr)}${type == VoucherType.sale ? ' #${r['vno']}' : ''}',
          if (who.isNotEmpty) who,
        ].join(' · '),
        hi == 0 ? '' : Money.fmt(hi),
        ho == 0 ? '' : Money.fmt(ho),
        fi == 0 ? '' : Money.fmt(fi),
        fo == 0 ? '' : Money.fmt(fo),
        vehicle,
      ]);
      refs.add(r['id'] as String);
      hin += hi;
      hout += ho;
      fin += fi;
      fout += fo;
    }
    return ReportTable(
      title: tr('r_charges'),
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('details'), flex: 5),
        ReportColumn.num(tr('c_hamali_in'), flex: 2),
        ReportColumn.num(tr('c_hamali_out'), flex: 2),
        ReportColumn.num(tr('c_fare_in'), flex: 2),
        ReportColumn.num(tr('c_fare_out'), flex: 2),
        ReportColumn(tr('c_vehicle'), flex: 3),
      ],
      rows: out,
      rowRefs: refs,
      totals: ['', tr('total'), Money.fmt(hin), Money.fmt(hout), Money.fmt(fin), Money.fmt(fout), ''],
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
  String _pnlRange(StockPnl r) => '${shortDate(r.from)} – ${shortDate(r.to)}';
  String _pct(int profit, int sales) => sales == 0 ? '' : '${(profit * 100 / sales).toStringAsFixed(1)}%';
  String _flags(ItemPnl i) => i.flags.isEmpty ? '' : '  ⚠ ${i.flags.map((f) => tr('pnl_flag_$f')).join(', ')}';

  /// माल-निहाय नफा: each item's sales, the real cost of what was sold, profit.
  Future<ReportTable> itemProfit(String from, String to) async {
    final r = await StockPnlEngine(db, businessId).compute(to);
    // only items that sold or cost something (stock just lying there: see stock costing)
    final list = [...r.items.where((i) => i.sales != 0 || i.cost != 0 || i.flags.isNotEmpty)]
      ..sort((a, b) => b.profit.compareTo(a.profit));
    String pr(int p, int s) => '${Money.fmt(p)}${s == 0 ? '' : '\n${_pct(p, s)}'}';
    return ReportTable(
      title: tr('r_item_profit'),
      subtitle: '${_pnlRange(r)} · ${tr('pnl_note')}',
      columns: [
        ReportColumn(tr('item'), flex: 3),
        ReportColumn.num(tr('pnl_sold')),
        ReportColumn.num(tr('sales')),
        ReportColumn.num(tr('pnl_cost')),
        ReportColumn.num(tr('profit')),
      ],
      rows: [
        for (final i in list)
          [
            '${i.item.name}${_flags(i)}',
            '${fmtQty(i.saleQty)} ${tr('unit_${i.item.unit}')}',
            Money.fmt(i.sales),
            Money.fmt(i.cost),
            pr(i.profit, i.sales),
          ]
      ],
      highlight: {for (var k = 0; k < list.length; k++) if (list[k].flags.isNotEmpty) k},
      totals: [tr('total'), '', Money.fmt(r.itemSales), Money.fmt(r.itemCost), pr(r.goodsProfit, r.itemSales)],
    );
  }

  /// प्रकार-निहाय नफा: the same, added up per category.
  Future<ReportTable> categoryProfit(String to) async {
    final r = await StockPnlEngine(db, businessId).compute(to);
    final cat = <String, (int, int, int)>{};
    for (final i in r.items) {
      final c = cat[i.item.category] ?? (0, 0, 0);
      cat[i.item.category] = (c.$1 + i.sales, c.$2 + i.cost, c.$3 + i.profit);
    }
    final keys = cat.keys.toList()..sort((a, b) => cat[b]!.$3.compareTo(cat[a]!.$3));
    return ReportTable(
      title: tr('r_cat_profit'),
      subtitle: '${_pnlRange(r)} · ${tr('pnl_note')}',
      columns: [
        ReportColumn(tr('category'), flex: 3),
        ReportColumn.num(tr('sales')),
        ReportColumn.num(tr('pnl_cost')),
        ReportColumn.num(tr('profit')),
        ReportColumn.num('%'),
      ],
      rows: [
        for (final k in keys)
          if (cat[k]!.$1 != 0 || cat[k]!.$2 != 0)
            [tr('cat_$k'), Money.fmt(cat[k]!.$1), Money.fmt(cat[k]!.$2), Money.fmt(cat[k]!.$3), _pct(cat[k]!.$3, cat[k]!.$1)]
      ],
      totals: [tr('total'), Money.fmt(r.itemSales), Money.fmt(r.itemCost), Money.fmt(r.goodsProfit), _pct(r.goodsProfit, r.itemSales)],
    );
  }

  /// मालाची किंमत: how each item's cost was worked out (opening, purchases,
  /// company discount, closing stock and the net cost per unit).
  Future<ReportTable> stockCosting(String to) async {
    final r = await StockPnlEngine(db, businessId).compute(to);
    String qv(double q, int v) => '${fmtQty(q)} / ${Money.fmt(v)}';
    return ReportTable(
      title: tr('r_stock_costing'),
      subtitle: '${_pnlRange(r)} · ${tr('pnl_costing_note')}',
      columns: [
        ReportColumn(tr('item'), flex: 4),
        ReportColumn.num(tr('opening_stock'), flex: 3),
        ReportColumn.num(tr('purchases'), flex: 3),
        ReportColumn.num(tr('pnl_disc')),
        ReportColumn.num(tr('closing_stock'), flex: 3),
        ReportColumn.num(tr('pnl_unit_cost')),
      ],
      rows: [
        for (final i in r.items)
          [
            '${i.item.name}${_flags(i)}',
            qv(i.openQty, i.openVal),
            qv(i.purQty, i.purVal),
            Money.fmt(i.discR),
            qv(i.closeQty, i.closeVal),
            Money.fmt(i.avg.round()),
          ]
      ],
      highlight: {for (var k = 0; k < r.items.length; k++) if (r.items[k].flags.isNotEmpty) k},
      totals: [tr('total'), Money.fmt(r.openTotal), Money.fmt(r.itemPurchases), Money.fmt(r.discToGoods), Money.fmt(r.closeTotal), ''],
    );
  }

  /// नफ्याची जुळवणी: goods profit → net profit, line by line, and the same net
  /// profit worked out a second way straight from the accounts.
  Future<ReportTable> profitProof(String to) async {
    final r = await StockPnlEngine(db, businessId).compute(to);
    final cogs = r.openTotal + r.itemPurchases - r.discToGoods - r.closeTotal;
    final rows = <List<String>>[
      [tr('opening_stock'), Money.fmt(r.openTotal)],
      ['+ ${tr('purchases')}', Money.fmt(r.itemPurchases)],
      ['− ${tr('pnl_disc_goods')}', Money.fmt(r.discToGoods)],
      ['− ${tr('closing_stock')}', Money.fmt(r.closeTotal)],
      [tr('cogs'), Money.fmt(cogs)],
      [tr('net_sales'), Money.fmt(r.itemSales)],
      [tr('pnl_goods_profit'), Money.fmt(r.goodsProfit)],
      if (r.salesGap != 0) ['+ ${tr('pnl_sales_gap')}', Money.fmt(r.salesGap)],
      if (r.purchaseGap != 0) ['− ${tr('pnl_purchase_gap')}', Money.fmt(r.purchaseGap)],
      if (r.discOther != 0) ['+ ${tr('pnl_disc_other')}', Money.fmt(r.discOther)],
      if (r.discSchemes != 0) ['+ ${tr('pnl_disc_schemes')}', Money.fmt(r.discSchemes)],
      for (final e in r.otherIncome) ['+ ${e.$1}', Money.fmt(e.$2)],
      for (final e in r.expenses) ['− ${e.$1}', Money.fmt(e.$2)],
    ];
    final netAt = rows.length;
    rows.add([r.netProfit >= 0 ? tr('net_profit') : tr('net_loss'), Money.fmt(r.netProfit.abs())]);
    rows.add([
      tr('pnl_check_accounts'),
      '${Money.fmt(r.accountsProfit.abs())} ${r.proven ? '✓' : '✗'}',
    ]);
    rows.add([tr('pnl_check_sales'), r.salesGap == 0 ? '✓' : '✗ ${Money.fmt(r.salesGap)}']);
    rows.add([tr('pnl_check_purchases'), r.purchaseGap == 0 ? '✓' : '✗ ${Money.fmt(r.purchaseGap)}']);
    final flagged = r.items.where((i) => i.flags.isNotEmpty).length;
    if (flagged > 0) rows.add([tr('pnl_check_flags').replaceAll('{n}', '$flagged'), '⚠']);
    return ReportTable(
      title: tr('r_pnl_proof'),
      subtitle: _pnlRange(r),
      columns: [ReportColumn(tr('particulars'), flex: 5), ReportColumn.num(tr('amount'))],
      rows: rows,
      highlight: {6, netAt},
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

  /// Stock value at cost – the same valuation as the item-wise profit, so
  /// every report shows the same rupee.
  Future<int> _stockValue({String? before, String? upto}) async {
    final e = StockPnlEngine(db, businessId);
    if (upto != null) return (await e.compute(upto)).closeTotal;
    if (before!.compareTo(Books.start) <= 0) return (await e.compute(Books.start)).openTotal;
    return (await e.compute(isoDate(parseIso(before).subtract(const Duration(days: 1))))).closeTotal;
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

  /// A service has no stock card: list every bill it was on.
  Future<ReportTable> _serviceEntries(Item item, String from, String to) async {
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.vtype, p.name AS party_name, p.page_no, il.qty, il.rate, il.amount '
      'FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id LEFT JOIN ledgers p ON p.id = v.party_id '
      "WHERE il.item_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.vtype IN ('sale', 'sales_return', 'purchase', 'purchase_return') "
      'AND il.vdate BETWEEN ? AND ? ORDER BY il.vdate, v.created_at',
      [item.id, from, to],
    );
    var sold = 0, bought = 0;
    final out = <List<String>>[];
    for (final r in rows) {
      final vt = r['vtype'] as String;
      final ret = vt.endsWith('_return');
      final buy = vt.startsWith('purchase');
      final amt = ((r['amount'] as int?) ?? ((r['qty'] as num) * (r['rate'] as int)).round()) * (ret ? -1 : 1);
      buy ? bought += amt : sold += amt;
      out.add([
        shortDate(r['vdate'] as String),
        '${vtypeLabel(VoucherType.fromCode(vt), tr)} ${r['party_name'] ?? ''}${r['page_no'] != null ? ' (${r['page_no']})' : ''}',
        fmtQty((r['qty'] as num).toDouble() * (ret ? -1 : 1)),
        Money.fmt(r['rate'] as int),
        buy ? '' : Money.fmt(amt),
        buy ? Money.fmt(amt) : '',
      ]);
    }
    return ReportTable(
      title: item.name,
      subtitle: _range(from, to),
      columns: [
        ReportColumn(tr('date'), flex: 2),
        ReportColumn(tr('particulars'), flex: 4),
        ReportColumn.num(tr('qty')),
        ReportColumn.num(tr('rate')),
        ReportColumn.num(tr('sales')),
        ReportColumn.num(tr('purchase')),
      ],
      rows: out,
      totals: ['', tr('total'), '', '', Money.fmt(sold), bought == 0 ? '' : Money.fmt(bought)],
      rowRefs: [for (final r in rows) r['id'] as String],
    );
  }

  Future<ReportTable> itemMovement(String itemId, String from, String to) async {
    final item = (await stock.byId(itemId))!;
    if (item.isService) return _serviceEntries(item, from, to);
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

class UdhariRow {
  final String voucherId;
  final VoucherType type; // sale / purchase (money) or goods_out / goods_in (goods only)
  final String party;
  final String? pageNo;
  final String items;
  final int amount; // the unpaid part of the bill
  UdhariRow(this.voucherId, this.type, this.party, this.pageNo, this.items, this.amount);
}

class UdhariDay {
  final String date;
  final List<UdhariRow> rows;
  UdhariDay(this.date, this.rows);
  int get given => rows.where((r) => r.type == VoucherType.sale).fold(0, (s, r) => s + r.amount);
  int get taken => rows.where((r) => r.type == VoucherType.purchase).fold(0, (s, r) => s + r.amount);
  List<UdhariRow> get goods => rows.where((r) => r.type.isGoodsLoan).toList();
}

/// Sort / filter for any report (on screen and in its PDF / Excel).
///
/// [query]: rows with any cell containing it (case-insensitive, Marathi digits
/// allowed). [sortCol]: sort by that column – numbers, dates (d/m/yy) and page
/// numbers by value, the rest alphabetically; empty cells last. While filtered,
/// number totals are re-added for the rows shown.
ReportTable shapeReport(ReportTable t, {String query = '', int? sortCol, bool ascending = true}) {
  final q = normalizeDigits(query.trim()).toLowerCase();
  var idx = [for (var i = 0; i < t.rows.length; i++) i];
  if (q.isNotEmpty) {
    idx = idx.where((i) => t.rows[i].any((c) => normalizeDigits(c).toLowerCase().contains(q))).toList();
  }
  if (sortCol != null && sortCol >= 0 && sortCol < t.columns.length) {
    String cell(int r) => sortCol < t.rows[r].length ? t.rows[r][sortCol].trim() : '';
    final values = idx.map(cell).where((c) => c.isNotEmpty && c != '—' && c != '–').toList();
    final kind = values.isNotEmpty && values.every((c) => _dateKey(c) != null)
        ? 'date'
        : values.isNotEmpty && values.every(_isAmount)
            ? 'num'
            : 'text';
    Comparable? key(int r) {
      final c = cell(r);
      if (c.isEmpty || c == '—' || c == '–') return null;
      return switch (kind) { 'date' => _dateKey(c), 'num' => _numKey(c), _ => NaturalKey(c) };
    }

    idx.sort((a, b) {
      final ka = key(a), kb = key(b);
      if (ka == null && kb == null) return a.compareTo(b);
      if (ka == null) return 1; // empty cells last either way
      if (kb == null) return -1;
      final c = ka.compareTo(kb);
      return c == 0 ? a.compareTo(b) : (ascending ? c : -c);
    });
  }
  final filtered = q.isNotEmpty;
  List<String>? totals = t.totals;
  if (filtered && totals != null) {
    totals = [
      for (var i = 0; i < totals.length; i++)
        if (RegExp(r'^-?[\d,]+(\.\d+)?$').hasMatch(totals[i].trim()))
          Money.fmt((idx.fold<double>(0, (s, r) => s + (i < t.rows[r].length ? (_numKey(t.rows[r][i]) ?? 0) : 0)) * 100).round())
        else if (i == 0 || totals[i].trim().isEmpty || _numKey(totals[i]) == null)
          totals[i]
        else
          '',
    ];
  }
  final old = {for (var n = 0; n < idx.length; n++) idx[n]: n};
  return ReportTable(
    title: t.title,
    subtitle: filtered ? '${t.subtitle}${t.subtitle.isEmpty ? '' : ' · '}${idx.length} / ${t.rows.length}' : t.subtitle,
    columns: t.columns,
    rows: [for (final i in idx) t.rows[i]],
    totals: totals,
    rowRefs: [for (final i in idx) t.rowRefs[i]],
    highlight: {for (final h in t.highlight) if (old[h] != null) old[h]!},
  );
}

/// Text that sorts the way people count: "1/2" < "3" < "11" < "100" < "12A"
/// after "12" – digit runs compare as numbers, the rest alphabetically.
class NaturalKey implements Comparable<NaturalKey> {
  final List<Object> parts; // int or String, alternating
  NaturalKey(String s)
      : parts = [
          for (final m in RegExp(r'\d+|\D+').allMatches(normalizeDigits(s.toLowerCase().trim())))
            int.tryParse(m[0]!) ?? m[0]!,
        ];

  @override
  int compareTo(NaturalKey o) {
    for (var i = 0; i < parts.length && i < o.parts.length; i++) {
      final a = parts[i], b = o.parts[i];
      final c = a is int && b is int
          ? a.compareTo(b)
          : a is int
              ? -1 // a number sorts before text ("12" before "A")
              : b is int
                  ? 1
                  : (a as String).compareTo(b as String);
      if (c != 0) return c;
    }
    return parts.length.compareTo(o.parts.length);
  }
}

/// A cell that is only an amount / number ("1,04,594", "₹532 येणे", "-12.5",
/// "20,532 Dr") – not a page number like "1/2" or "12A".
bool _isAmount(String c) => RegExp(r'^[₹\-\s]*[\d,]+(\.\d+)?\s*(Dr|Cr|येणे|देणे|जमा|आगाऊ|%)?$').hasMatch(normalizeDigits(c.trim()));

/// "1,04,594", "₹532 येणे", "-12.5", "20,532 Dr" → number; null if no number.
double? _numKey(String s) {
  final m = RegExp(r'-?[\d,]*\d(\.\d+)?').firstMatch(normalizeDigits(s));
  if (m == null) return null;
  final v = double.tryParse(m[0]!.replaceAll(',', ''));
  if (v == null) return null;
  // advance / payable shown with a word instead of a minus
  final neg = RegExp(r'(\bCr\b|जमा|देणे|आगाऊ)').hasMatch(s) && !s.contains('-');
  return neg ? -v : v;
}

/// "9/11/26", "31/08/2026" → sortable "2026-11-09".
String? _dateKey(String s) {
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})$').firstMatch(normalizeDigits(s.trim()));
  if (m == null) return null;
  final y = m[3]!.length == 2 ? '20${m[3]}' : m[3]!;
  return '$y-${m[2]!.padLeft(2, '0')}-${m[1]!.padLeft(2, '0')}';
}
