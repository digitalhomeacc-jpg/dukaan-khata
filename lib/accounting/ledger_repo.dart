import 'package:sqlite_async/sqlite_async.dart';

import '../core/ids.dart';
import '../core/money.dart';
import 'models.dart';

/// One row of a ledger statement (the digital khata page).
class StatementRow {
  final String voucherId;
  final String date;
  final VoucherType type;
  final int vno;
  final String details; // "M 12×285" or narration
  final int debit; // नावे – goods given / money paid out to them
  final int credit; // जमा – money received / goods returned
  final int balance; // running
  final String? payCode;
  final int hamali; // charged on this bill
  final int transport;
  final String? transporterName; // null + transport > 0 = own vehicle
  final String? kind; // old entries: sale | purchase | received | paid
  final String? haste; // हस्ते
  StatementRow(this.voucherId, this.date, this.type, this.vno, this.details, this.debit, this.credit,
      this.balance, this.payCode, {this.hamali = 0, this.transport = 0, this.transporterName, this.kind, this.haste});
}

/// One outside transporter's position for the day-end settlement.
class TransporterDue {
  final Ledger transporter;
  final int earnedToday; // fares credited to him today
  final int paidToday;
  final int owed; // total we owe him now (all days)
  TransporterDue(this.transporter, this.earnedToday, this.paidToday, this.owed);
}

/// Day-end hisab of bill charges: hamali charged vs paid, transport.
class DayCharges {
  final String date;
  final int hamaliCharged; // taken from customers on bills
  final int hamaliPaid; // paid to labourers
  final int ownTransport; // own vehicle income + margin on outside trips
  final List<TransporterDue> transporters;
  DayCharges(this.date, this.hamaliCharged, this.hamaliPaid, this.ownTransport, this.transporters);
  int get hamaliProfit => hamaliCharged - hamaliPaid;
  bool get isEmpty => hamaliCharged == 0 && hamaliPaid == 0 && ownTransport == 0 && transporters.isEmpty;
}

class Statement {
  final Ledger ledger;
  final String? from;
  final String? to;
  final int opening;
  final List<StatementRow> rows;
  /// Old entries from the paper khata – shown for reference, never counted.
  final List<StatementRow> references;
  Statement(this.ledger, this.from, this.to, this.opening, this.rows, {this.references = const []});
  int get closing => rows.isEmpty ? opening : rows.last.balance;
  int get totalDebit => rows.fold(0, (s, r) => s + r.debit);
  int get totalCredit => rows.fold(0, (s, r) => s + r.credit);
}

/// A row in the Rojmal (cash/PhonePe/bank book).
class CashRow {
  final String voucherId;
  final VoucherType type;
  final String particulars;
  final int inflow;
  final int outflow;
  final String? code;
  final bool gstBillNeeded;
  final String? narration;
  CashRow(this.voucherId, this.type, this.particulars, this.inflow, this.outflow, this.code,
      this.gstBillNeeded, this.narration);
}

class CashBook {
  final String date;
  final int opening;
  final List<CashRow> rows;
  CashBook(this.date, this.opening, this.rows);
  int get totalIn => rows.fold(0, (s, r) => s + r.inflow);
  int get totalOut => rows.fold(0, (s, r) => s + r.outflow);
  int get closing => opening + totalIn - totalOut;
}

class LedgerRepo {
  final SqliteConnection db;
  final String businessId;
  LedgerRepo(this.db, this.businessId);

  static const _balanceExpr =
      '(l.opening_balance + COALESCE((SELECT SUM(vl.debit - vl.credit) FROM voucher_lines vl '
      'WHERE vl.ledger_id = l.id AND vl.deleted = 0), 0))';

  String _listSql(List<LedgerGroup> groups, {bool includeArchived = false}) =>
      'SELECT l.*, $_balanceExpr AS balance FROM ledgers l WHERE l.business_id = ? '
      'AND l.grp IN (${groups.map((g) => "'${g.code}'").join(',')}) '
      '${includeArchived ? '' : 'AND COALESCE(l.archived,0) = 0'} '
      'ORDER BY l.system DESC, CASE l.grp WHEN \'cash\' THEN 0 WHEN \'upi\' THEN 1 WHEN \'bank\' THEN 2 ELSE 3 END, '
      'l.short_code, l.name COLLATE NOCASE';

  /// Customers (or suppliers) list. Also includes people from the other side
  /// who have traded this way – a supplier who bought from us appears among
  /// customers, marked `dual` – so one person keeps one khata.
  Future<List<Ledger>> parties(LedgerGroup g) async {
    final other = g == LedgerGroup.customer ? 'supplier' : 'customer';
    final mine = g == LedgerGroup.customer ? "'sale','sales_return'" : "'purchase','purchase_return'";
    final theirs = g == LedgerGroup.customer ? "'purchase','purchase_return'" : "'sale','sales_return'";
    final rows = await db.getAll(
      'SELECT l.*, $_balanceExpr AS balance, CASE WHEN l.grp = ? THEN 1 '
      'WHEN EXISTS (SELECT 1 FROM vouchers v WHERE v.party_id = l.id AND v.deleted = 0 AND v.vtype IN ($theirs)) THEN 1 ELSE 0 END AS dual '
      'FROM ledgers l WHERE l.business_id = ? AND COALESCE(l.archived,0) = 0 AND (l.grp = ? OR (l.grp = ? AND EXISTS '
      '(SELECT 1 FROM vouchers v WHERE v.party_id = l.id AND v.deleted = 0 AND v.vtype IN ($mine)))) '
      'ORDER BY l.name COLLATE NOCASE',
      [other, businessId, g.code, other],
    );
    return rows.map(Ledger.fromRow).toList();
  }

  Future<List<Ledger>> list(List<LedgerGroup> groups) async =>
      (await db.getAll(_listSql(groups), [businessId])).map(Ledger.fromRow).toList();

  /// Live-updating list (used by screens).
  Stream<List<Ledger>> watch(List<LedgerGroup> groups) => db
      .watch(_listSql(groups), parameters: [businessId], triggerOnTables: const ['ledgers', 'voucher_lines'])
      .map((rs) => rs.map(Ledger.fromRow).toList());

  Future<Ledger?> byId(String id) async {
    final r = await db.getOptional('SELECT l.*, $_balanceExpr AS balance FROM ledgers l WHERE l.id = ?', [id]);
    return r == null ? null : Ledger.fromRow(r);
  }

  Future<Ledger?> byShortCode(String code) async {
    final r = await db.getOptional(
        'SELECT l.*, $_balanceExpr AS balance FROM ledgers l WHERE l.business_id = ? '
        'AND UPPER(l.short_code) = UPPER(?) AND l.grp IN (\'cash\',\'upi\',\'bank\') AND COALESCE(l.archived,0)=0',
        [businessId, code]);
    return r == null ? null : Ledger.fromRow(r);
  }

  /// Search by Marathi name, English name, phone, or old khata page number.
  /// Every word must match somewhere (any order): "jadhav 29", "सुरेश जा".
  Future<List<Ledger>> search(String q, {List<LedgerGroup>? groups, int limit = 30}) async {
    final term = normalizeDigits(q.trim()).replaceAll(RegExp(r'[.,]'), ' ');
    final words = term.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return groups == null ? [] : list(groups);
    final grpFilter = groups == null ? '' : 'AND l.grp IN (${groups.map((g) => "'${g.code}'").join(',')})';
    final conds = <String>[];
    final args = <Object?>[businessId];
    for (final w in words) {
      conds.add("(l.name LIKE ? OR l.name_en LIKE ? OR REPLACE(COALESCE(l.phone,''),' ','') LIKE ? OR l.page_no = ?)");
      args.addAll(['%$w%', '%$w%', '%$w%', w]);
    }
    final rows = await db.getAll(
      'SELECT l.*, $_balanceExpr AS balance FROM ledgers l WHERE l.business_id = ? $grpFilter '
      'AND COALESCE(l.archived,0) = 0 AND ${conds.join(' AND ')} '
      'ORDER BY CASE WHEN l.page_no = ? THEN 0 WHEN l.name LIKE ? OR l.name_en LIKE ? THEN 1 ELSE 2 END, '
      "CASE l.grp WHEN 'customer' THEN 0 WHEN 'supplier' THEN 1 ELSE 2 END, l.name LIMIT $limit",
      [...args, term, '$term%', '$term%'],
    );
    return rows.map(Ledger.fromRow).toList();
  }

  /// Entries matching a number (bill no. / amount), a note, ref no. or a party name.
  Future<List<Voucher>> searchVouchers(String q, {int limit = 40}) async {
    final term = normalizeDigits(q.trim()).replaceAll(',', '');
    if (term.isEmpty) return [];
    final amount = double.tryParse(term);
    final rows = await db.getAll(
      'SELECT v.*, p.name AS party_name, pl.short_code AS pay_code FROM vouchers v '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      'WHERE v.business_id = ? AND v.deleted = 0 AND ('
      '${amount != null ? 'v.amount = ? OR v.paid = ? OR v.vno = ? OR ' : ''}'
      'v.narration LIKE ? OR v.ref_no LIKE ? OR p.name LIKE ? OR p.name_en LIKE ?) '
      'ORDER BY v.vdate DESC, v.created_at DESC LIMIT $limit',
      [
        businessId,
        if (amount != null) ...[(amount * 100).round(), (amount * 100).round(), amount.toInt()],
        '%$term%', '%$term%', '%$term%', '%$term%',
      ],
    );
    return rows.map(Voucher.fromRow).toList();
  }

  Future<String> create({
    required String name,
    String? nameEn,
    required LedgerGroup group,
    String? phone,
    String? address,
    String? pageNo,
    String? shortCode,
    String? gstin,
    int openingBalance = 0,
    int creditLimit = 0,
  }) async {
    final id = newId();
    await db.execute(
      'INSERT INTO ledgers (id, business_id, name, name_en, grp, phone, address, page_no, short_code, gstin, '
      'opening_balance, credit_limit, system, archived, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?)',
      [id, businessId, name.trim(), _n(nameEn), group.code, _n(phone), _n(address), _n(pageNo), _n(shortCode),
        _n(gstin)?.toUpperCase(), openingBalance, creditLimit, nowIso()],
    );
    return id;
  }

  Future<void> update(String id,
      {required String name,
      String? nameEn,
      String? phone,
      String? address,
      String? pageNo,
      String? shortCode,
      String? gstin,
      required int openingBalance,
      int creditLimit = 0,
      LedgerGroup? group}) async {
    await db.execute(
      'UPDATE ledgers SET name=?, name_en=?, phone=?, address=?, page_no=?, short_code=?, gstin=?, opening_balance=?, '
      'credit_limit=?${group != null ? ', grp=?' : ''} WHERE id=?',
      [name.trim(), _n(nameEn), _n(phone), _n(address), _n(pageNo), _n(shortCode), _n(gstin)?.toUpperCase(),
        openingBalance, creditLimit,
        if (group != null) group.code, id],
    );
  }

  /// How many entries use this account (including deleted ones kept for history).
  Future<int> usageCount(String id) async {
    final r = await db.get(
      'SELECT (SELECT COUNT(*) FROM voucher_lines WHERE ledger_id = ?) + '
      '(SELECT COUNT(*) FROM vouchers WHERE party_id = ? OR pay_ledger_id = ? OR transporter_id = ?) + '
      '(SELECT COUNT(*) FROM bank_lines WHERE bank_ledger_id = ?) AS n',
      [id, id, id, id, id],
    );
    return (r['n'] as int?) ?? 0;
  }

  /// Deletes an unused account. An account that has entries (or is built in)
  /// is hidden instead, so old bills and reports stay correct.
  /// Returns true if it was deleted, false if it was hidden.
  Future<bool> deleteOrHide(Ledger l) async {
    if (l.isCore) throw ArgumentError('err_core_ledger');
    if (!l.system && await usageCount(l.id) == 0) {
      await db.execute('DELETE FROM ledgers WHERE id = ?', [l.id]);
      return true;
    }
    await setArchived(l.id, true);
    return false;
  }

  Future<List<Ledger>> hidden() async => (await db.getAll(
        'SELECT l.*, $_balanceExpr AS balance FROM ledgers l WHERE l.business_id = ? AND COALESCE(l.archived,0) = 1 ORDER BY l.name',
        [businessId],
      ))
          .map(Ledger.fromRow)
          .toList();

  Future<void> setArchived(String id, bool archived) =>
      db.execute('UPDATE ledgers SET archived = ? WHERE id = ?', [archived ? 1 : 0, id]);

  String? _n(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  /// Balance as at end of [date] (inclusive). null = all time.
  Future<int> balanceAt(String ledgerId, {String? date, bool before = false}) async {
    final op = before ? '<' : '<=';
    final r = await db.get(
      'SELECT l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id '
      'AND deleted = 0 ${date == null ? '' : 'AND vdate $op ?'}), 0) AS b FROM ledgers l WHERE l.id = ?',
      [if (date != null) date, ledgerId],
    );
    return (r['b'] as num).toInt();
  }

  /// The digital khata page: one row per voucher, with running balance.
  Future<Statement> statement(String ledgerId, {String? from, String? to}) async {
    final ledger = (await byId(ledgerId))!;
    final opening = from == null ? ledger.openingBalance : await balanceAt(ledgerId, date: from, before: true);
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.vtype, v.vno, v.narration, v.ref_no, pl.short_code AS pay_code, '
      'v.hamali, v.transport, v.haste, tr.name AS transporter_name, '
      'SUM(vl.debit) AS d, SUM(vl.credit) AS c, '
      '(SELECT GROUP_CONCAT(COALESCE(i.short_code, i.name) || \' \' || il.qty || \'×\' || (il.rate / 100.0), \', \') '
      ' FROM inventory_lines il JOIN items i ON i.id = il.item_id WHERE il.voucher_id = v.id AND il.deleted = 0) AS items '
      'FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
      'LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      'LEFT JOIN ledgers tr ON tr.id = v.transporter_id '
      'WHERE vl.ledger_id = ? AND vl.deleted = 0 '
      '${from != null ? 'AND vl.vdate >= ? ' : ''}${to != null ? 'AND vl.vdate <= ? ' : ''}'
      'GROUP BY v.id ORDER BY v.vdate, v.created_at',
      [ledgerId, if (from != null) from, if (to != null) to],
    );
    var bal = opening;
    final out = <StatementRow>[];
    for (final r in rows) {
      final d = (r['d'] as num).toInt();
      final c = (r['c'] as num).toInt();
      bal += d - c;
      final items = _cleanItems(r['items'] as String?);
      final parts = [
        if (items != null) items,
        if ((r['narration'] as String?)?.isNotEmpty ?? false) r['narration'] as String,
      ];
      out.add(StatementRow(r['id'] as String, r['vdate'] as String, VoucherType.fromCode(r['vtype'] as String),
          (r['vno'] as int?) ?? 0, parts.join(' · '), d, c, bal, r['pay_code'] as String?,
          hamali: (r['hamali'] as int?) ?? 0,
          transport: (r['transport'] as int?) ?? 0,
          transporterName: r['transporter_name'] as String?,
          haste: r['haste'] as String?));
    }
    // old (pre-books) entries: reference only, never part of the balance
    final refRows = await db.getAll(
      'SELECT v.*, '
      '(SELECT GROUP_CONCAT(COALESCE(i.short_code, i.name) || \' \' || il.qty || \'×\' || (il.rate / 100.0), \', \') '
      ' FROM inventory_lines il JOIN items i ON i.id = il.item_id WHERE il.voucher_id = v.id AND il.deleted = 0) AS items '
      "FROM vouchers v WHERE v.party_id = ? AND v.vtype = 'history' AND v.deleted = 0 ORDER BY v.vdate, v.created_at",
      [ledgerId],
    );
    final refs = <StatementRow>[];
    for (final r in refRows) {
      final kind = ((r['pay_ledger_id'] as String?) ?? '').replaceFirst('hist:', '');
      final amount = (r['amount'] as int?) ?? 0;
      final paid = (r['paid'] as int?) ?? 0;
      final (int d, int c) = switch (kind) {
        'purchase' => (paid, amount),
        'received' => (0, amount == 0 ? paid : amount),
        'paid' => (amount, 0),
        _ => (amount, paid),
      };
      final items = _cleanItems(r['items'] as String?);
      final parts = [
        if (items != null) items,
        if ((r['narration'] as String?)?.isNotEmpty ?? false) r['narration'] as String,
      ];
      refs.add(StatementRow(r['id'] as String, r['vdate'] as String, VoucherType.history, (r['vno'] as int?) ?? 0,
          parts.join(' · '), d, c, 0, null,
          hamali: (r['hamali'] as int?) ?? 0, transport: (r['transport'] as int?) ?? 0, kind: kind,
          haste: r['haste'] as String?));
    }
    return Statement(ledger, from, to, opening, out, references: refs);
  }

  /// हिशोब तपासणी: entries whose debit and credit don't match, or that have
  /// lost their lines. Should always be empty; anything here means an entry
  /// arrived incomplete and needs to be opened and saved again.
  Future<List<Voucher>> unbalanced() async {
    final rows = await db.getAll(
      'SELECT v.*, p.name AS party_name, pl.short_code AS pay_code FROM vouchers v '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      "WHERE v.business_id = ? AND v.deleted = 0 AND v.vtype NOT IN ('stock_adjust', 'opening', 'history', 'promise') AND ("
      ' COALESCE((SELECT SUM(debit) - SUM(credit) FROM voucher_lines WHERE voucher_id = v.id AND deleted = 0), 0) <> 0'
      ' OR (v.amount <> 0 AND NOT EXISTS (SELECT 1 FROM voucher_lines WHERE voucher_id = v.id AND deleted = 0)))'
      ' ORDER BY v.vdate DESC',
      [businessId],
    );
    return rows.map(Voucher.fromRow).toList();
  }

  /// Bill numbers used twice in this financial year (possible when two
  /// devices make bills while both are offline). Returns "type #no" labels.
  Future<List<(VoucherType, int, int)>> duplicateNumbers() async {
    final rows = await db.getAll(
      "SELECT vtype, vno, COUNT(*) AS n FROM vouchers WHERE business_id = ? AND deleted = 0 AND vdate >= ? "
      "AND vtype IN ('sale','purchase','receipt','payment') GROUP BY vtype, vno HAVING COUNT(*) > 1 ORDER BY vtype, vno",
      [businessId, fyStart(todayIso())],
    );
    return [for (final r in rows) (VoucherType.fromCode(r['vtype'] as String), r['vno'] as int, r['n'] as int)];
  }

  /// Payment promises (वसुली वायदे) with the party and its current balance.
  /// [open] = still waiting; otherwise kept / missed ones, newest first.
  Future<List<(Voucher, Ledger)>> promises({bool open = true, String? partyId}) async {
    final rows = await db.getAll(
      'SELECT v.*, l.id AS l_id, l.name AS l_name, l.name_en AS l_name_en, l.grp AS l_grp, l.phone AS l_phone, '
      'l.page_no AS l_page_no, l.opening_balance AS l_ob, '
      '(l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0), 0)) AS l_balance '
      "FROM vouchers v JOIN ledgers l ON l.id = v.party_id WHERE v.business_id = ? AND v.vtype = 'promise' AND v.deleted = 0 "
      "AND ${open ? "COALESCE(v.status, 'open') = 'open'" : "COALESCE(v.status, 'open') <> 'open'"} "
      '${partyId != null ? 'AND v.party_id = ? ' : ''}'
      'ORDER BY ${open ? 'v.vdate ASC' : 'v.updated_at DESC'}',
      [businessId, if (partyId != null) partyId],
    );
    return [
      for (final r in rows)
        (
          Voucher.fromRow(r),
          Ledger(
            id: r['l_id'] as String,
            name: (r['l_name'] as String?) ?? '',
            nameEn: r['l_name_en'] as String?,
            group: LedgerGroup.fromCode(r['l_grp'] as String?),
            phone: r['l_phone'] as String?,
            pageNo: r['l_page_no'] as String?,
            openingBalance: (r['l_ob'] as int?) ?? 0,
            balance: (r['l_balance'] as num?)?.toInt() ?? 0,
          ),
        )
    ];
  }

  /// Promises due today or earlier and still open (for the home screen).
  Future<int> promisesDue(String today) async => ((await db.get(
        "SELECT COUNT(*) AS n FROM vouchers WHERE business_id = ? AND vtype = 'promise' AND deleted = 0 "
        "AND COALESCE(status, 'open') = 'open' AND vdate <= ?",
        [businessId, today],
      ))['n'] as int);

  /// Day-end settlement of hamali and transport for [date].
  Future<DayCharges> dayCharges(String date) async {
    Future<int> sum(String ledgerId, String expr) async => ((await db.get(
          'SELECT COALESCE(SUM($expr),0) AS s FROM voucher_lines WHERE ledger_id = ? AND vdate = ? AND deleted = 0',
          [ledgerId, date],
        ))['s'] as num)
            .toInt();
    final hamaliCharged = await sum('$businessId:hamali_income', 'credit - debit');
    final hamaliPaid = await sum('$businessId:hamali', 'debit - credit');
    final ownTransport = await sum('$businessId:transport_income', 'credit - debit');
    final rows = await db.getAll(
      'SELECT l.*, $_balanceExpr AS balance, '
      'COALESCE((SELECT SUM(credit) FROM voucher_lines WHERE ledger_id = l.id AND vdate = ? AND deleted = 0),0) AS earned, '
      'COALESCE((SELECT SUM(debit) FROM voucher_lines WHERE ledger_id = l.id AND vdate = ? AND deleted = 0),0) AS paid '
      "FROM ledgers l WHERE l.business_id = ? AND l.grp = 'transporter' AND COALESCE(l.archived,0) = 0 ORDER BY l.name",
      [date, date, businessId],
    );
    final dues = [
      for (final r in rows)
        if ((r['earned'] as num) != 0 || (r['paid'] as num) != 0 || (r['balance'] as num) != 0)
          TransporterDue(Ledger.fromRow(r), (r['earned'] as num).toInt(), (r['paid'] as num).toInt(),
              -(r['balance'] as num).toInt()),
    ];
    return DayCharges(date, hamaliCharged, hamaliPaid, ownTransport, dues);
  }

  /// "M 12.0×285.0" → "M 12×285"
  String? _cleanItems(String? s) => s?.replaceAllMapped(RegExp(r'(\d+)\.0\b'), (m) => m[1]!);

  /// Rojmal for one money account (or several) on one date.
  Future<CashBook> cashBook(List<String> moneyLedgerIds, String date) async {
    if (moneyLedgerIds.isEmpty) return CashBook(date, 0, []);
    final ph = List.filled(moneyLedgerIds.length, '?').join(',');
    final o = await db.get(
      'SELECT COALESCE(SUM(l.opening_balance),0) + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines '
      'WHERE ledger_id IN ($ph) AND deleted = 0 AND vdate < ?),0) AS b FROM ledgers l WHERE l.id IN ($ph)',
      [...moneyLedgerIds, date, ...moneyLedgerIds],
    );
    final rows = await db.getAll(
      'SELECT v.id, v.vtype, v.narration, v.gst_bill_needed, ml.short_code AS code, SUM(vl.debit) AS d, SUM(vl.credit) AS c, '
      '(SELECT GROUP_CONCAT(x.name, \' / \') FROM (SELECT DISTINCT l2.name FROM voucher_lines vl2 JOIN ledgers l2 ON l2.id = vl2.ledger_id '
      ' WHERE vl2.voucher_id = v.id AND vl2.deleted = 0 AND vl2.ledger_id NOT IN ($ph) '
      " AND l2.grp NOT IN ('sales','purchase','sales_return','purchase_return')) x) AS other, "
      'pty.name AS party_name '
      'FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id JOIN ledgers ml ON ml.id = vl.ledger_id '
      'LEFT JOIN ledgers pty ON pty.id = v.party_id '
      'WHERE vl.ledger_id IN ($ph) AND vl.deleted = 0 AND vl.vdate = ? '
      'GROUP BY v.id, vl.ledger_id ORDER BY v.created_at',
      [...moneyLedgerIds, ...moneyLedgerIds, date],
    );
    final out = <CashRow>[];
    for (final r in rows) {
      final d = (r['d'] as num).toInt();
      final c = (r['c'] as num).toInt();
      final net = d - c;
      if (net == 0) continue;
      final type = VoucherType.fromCode(r['vtype'] as String);
      final particulars = (r['party_name'] as String?) ??
          (r['other'] as String?) ??
          (r['narration'] as String?) ??
          '';
      out.add(CashRow(r['id'] as String, type, particulars, net > 0 ? net : 0, net < 0 ? -net : 0,
          r['code'] as String?, (r['gst_bill_needed'] as int?) == 1, r['narration'] as String?));
    }
    return CashBook(date, (o['b'] as num).toInt(), out);
  }

  /// All vouchers of a day (Day Book).
  Future<List<Voucher>> dayBook(String from, [String? to]) async {
    final rows = await db.getAll(
      'SELECT v.*, p.name AS party_name, pl.short_code AS pay_code FROM vouchers v '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      "WHERE v.business_id = ? AND v.deleted = 0 AND v.vtype NOT IN ('history', 'promise') AND v.vdate >= ? AND v.vdate <= ? "
      'ORDER BY v.vdate, v.created_at',
      [businessId, from, to ?? from],
    );
    return rows.map(Voucher.fromRow).toList();
  }

  Stream<void> changes() => db.onChange(const ['vouchers', 'voucher_lines', 'ledgers', 'inventory_lines', 'items']);

  /// Totals for the home screen.
  Future<Map<String, int>> dashboard(String date) async {
    Future<int> sumGroup(String grp) async => ((await db.get(
          'SELECT COALESCE(SUM($_balanceExpr),0) AS b FROM ledgers l WHERE l.business_id = ? AND l.grp = ?',
          [businessId, grp],
        ))['b'] as num)
            .toInt();
    Future<int> sumType(String type, String col) async => ((await db.get(
          'SELECT COALESCE(SUM($col),0) AS s FROM vouchers WHERE business_id = ? AND vtype = ? AND vdate = ? AND deleted = 0',
          [businessId, type, date],
        ))['s'] as num)
            .toInt();
    final receivable = ((await db.get(
      'SELECT COALESCE(SUM(b),0) AS s FROM (SELECT $_balanceExpr AS b FROM ledgers l WHERE l.business_id = ? '
      "AND l.grp IN ('customer','supplier')) WHERE b > 0",
      [businessId],
    ))['s'] as num)
        .toInt();
    final payable = ((await db.get(
      'SELECT COALESCE(SUM(b),0) AS s FROM (SELECT $_balanceExpr AS b FROM ledgers l WHERE l.business_id = ? '
      "AND l.grp IN ('customer','supplier')) WHERE b < 0",
      [businessId],
    ))['s'] as num)
        .toInt();
    final collections = ((await db.get(
      "SELECT COALESCE(SUM(vl.debit),0) AS s FROM voucher_lines vl JOIN ledgers l ON l.id = vl.ledger_id "
      "JOIN vouchers v ON v.id = vl.voucher_id WHERE v.business_id = ? AND vl.vdate = ? AND vl.deleted = 0 "
      "AND l.grp IN ('cash','upi','bank') AND v.vtype IN ('sale','receipt')",
      [businessId, date],
    ))['s'] as num)
        .toInt();
    return {
      'sales': await sumType('sale', 'amount'),
      'collections': collections,
      'expenses': await sumType('payment', 'amount'),
      'cash': await sumGroup('cash'),
      'upi': await sumGroup('upi'),
      'bank': await sumGroup('bank'),
      'receivable': receivable,
      'payable': -payable,
    };
  }
}
