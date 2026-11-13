import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite_async/sqlite_async.dart';

import '../core/audit.dart';
import '../core/ids.dart';
import '../core/money.dart';
import 'models.dart';
import 'voucher_service.dart' show historyKindPrefix;

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
  final int varhai; // वराई: hamali money the company's driver handed over
  final int transportCharged; // गाडी भाडे taken from customers on today's bills
  final int freightPaid; // other भाडे paid today as an expense (not to a transporter's khata)
  /// आज किती हमाल – shared by every phone (null = not set yet).
  int? hamals;
  DayCharges(this.date, this.hamaliCharged, this.hamaliPaid, this.ownTransport, this.transporters,
      {this.varhai = 0, this.transportCharged = 0, this.freightPaid = 0});
  /// Outside drivers' share of today's fares / what they were paid today / still owed (all days).
  int get driversEarned => transporters.fold(0, (s, d) => s + d.earnedToday);
  int get driversPaid => transporters.fold(0, (s, d) => s + d.paidToday);
  int get driversOwed => transporters.fold(0, (s, d) => s + (d.owed > 0 ? d.owed : 0));
  /// Delivery fares paid out today (to drivers). Other भाडे – e.g. freight on
  /// goods coming in – is shown on its own, not mixed with the bills' fares.
  int get transportPaid => driversPaid;
  bool get hasTransport => transportCharged != 0 || ownTransport != 0 || transporters.isNotEmpty || freightPaid != 0;
  /// What the labourers get today: hamali taken on bills + वराई.
  int get hamaliToPay => hamaliCharged + varhai;
  int get hamaliProfit => hamaliToPay - hamaliPaid;
  bool get isEmpty => hamaliCharged == 0 && hamaliPaid == 0 && varhai == 0 && !hasTransport;
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
  /// Cash the company's driver handed over with a purchase (वराई).
  final bool varhai;
  /// Bill number (विक्री #18).
  final int? vno;
  CashRow(this.voucherId, this.type, this.particulars, this.inflow, this.outflow, this.code,
      this.gstBillNeeded, this.narration, {this.varhai = false, this.vno});

  /// A counter sale: no customer name (रोख विक्री).
  bool get walkInSale => type == VoucherType.sale && particulars.isEmpty && !varhai;
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
  /// Days since each party's balance was last paid towards: the last day a
  /// customer paid us (or we paid a supplier); if never, since their first
  /// entry (or the books start for an opening balance). Parties with a
  /// balance only. Key = ledger id.
  /// Old entries per party (one pass over all of them).
  Future<Map<String, OldSummary>> oldSummaries() async {
    final out = <String, OldSummary>{};
    for (final r in await db.getAll(
        "SELECT party_id, vdate, amount, paid, pay_ledger_id FROM vouchers WHERE business_id = ? AND vtype = 'history' "
        'AND deleted = 0 AND party_id IS NOT NULL ORDER BY vdate',
        [businessId])) {
      final (_, d, c) = oldEntryEffect(r['pay_ledger_id'] as String?, (r['amount'] as int?) ?? 0, (r['paid'] as int?) ?? 0);
      final o = out.putIfAbsent(r['party_id'] as String, OldSummary.new);
      o.total += d - c;
      o.count++;
      final date = r['vdate'] as String;
      if (o.first.isEmpty) o.first = date;
      o.last = date;
    }
    return out;
  }

  /// हिशोब पुन्हा तपासायचा: parties marked for a manual re-check (shared by
  /// every phone through the change history; the latest mark wins).
  Future<Map<String, String>> recheckMarks() async {
    final out = <String, String>{};
    for (final r in await db.getAll(
        "SELECT voucher_id, snapshot FROM audit_log WHERE business_id = ? AND voucher_id LIKE 'recheck:%' ORDER BY at", [businessId])) {
      final id = (r['voucher_id'] as String).substring(8);
      try {
        final after = (jsonDecode(r['snapshot'] as String) as Map)['after'] as Map?;
        if (after?['recheck'] == '✓') {
          out[id] = '${after?['note'] ?? ''}';
        } else {
          out.remove(id);
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> setRecheck(String ledgerId, String name, bool on, {String note = ''}) => AuditLog.write(db,
      businessId: businessId,
      recordId: 'recheck:$ledgerId',
      action: 'edit',
      kind: 'recheck',
      title: name,
      after: {'recheck': on ? '✓' : '', 'note': on ? note.trim() : ''});

  Future<Map<String, int>> daysUnpaid() async {
    final rows = await db.getAll(
      'SELECT l.id, l.opening_balance, $_balanceExpr AS balance, '
      '(SELECT MAX(vdate) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0 AND credit > 0) AS last_cr, '
      '(SELECT MAX(vdate) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0 AND debit > 0) AS last_dr, '
      '(SELECT MIN(vdate) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0) AS first, '
      // old entries (before the books start) change no figure – only their
      // dates are read, so "days since they last paid" reaches back into them
      "(SELECT MAX(vdate) FROM vouchers WHERE party_id = l.id AND vtype = 'history' AND deleted = 0 "
      " AND (pay_ledger_id = '${historyKindPrefix}received' OR (pay_ledger_id = '${historyKindPrefix}sale' AND paid > 0))) AS old_cr, "
      "(SELECT MAX(vdate) FROM vouchers WHERE party_id = l.id AND vtype = 'history' AND deleted = 0 "
      " AND (pay_ledger_id = '${historyKindPrefix}paid' OR (pay_ledger_id = '${historyKindPrefix}purchase' AND paid > 0))) AS old_dr, "
      "(SELECT MIN(vdate) FROM vouchers WHERE party_id = l.id AND vtype = 'history' AND deleted = 0) AS old_first "
      "FROM ledgers l WHERE l.business_id = ? AND l.grp IN ('customer', 'supplier')",
      [businessId],
    );
    final today = parseIso(todayIso());
    final olds = await oldSummaries();
    final out = <String, int>{};
    for (final r in rows) {
      final bal = (r['balance'] as num).toInt();
      if (bal == 0) continue;
      // they owe us → their last payment (a credit); we owe them → our last payment (a debit)
      final last = (bal > 0 ? (r['last_cr'] ?? r['old_cr']) : (r['last_dr'] ?? r['old_dr'])) as String?;
      final opening = (r['opening_balance'] as int?) ?? 0;
      final old = olds[r['id']];
      // never paid: once the old entries are complete (they add up to the
      // opening balance) count from the last of them; otherwise from the first
      final since = last ??
          (opening != 0
              ? (old == null ? Books.start : (old.total == opening ? old.last : old.first))
              : r['first'] as String?);
      if (since == null) continue;
      final d = today.difference(parseIso(since)).inDays;
      if (d > 0) out[r['id'] as String] = d;
    }
    return out;
  }

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
    await _log(id, 'create', null, await _snap(id));
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
    final before = await _snap(id);
    await db.execute(
      'UPDATE ledgers SET name=?, name_en=?, phone=?, address=?, page_no=?, short_code=?, gstin=?, opening_balance=?, '
      'credit_limit=?${group != null ? ', grp=?' : ''} WHERE id=?',
      [name.trim(), _n(nameEn), _n(phone), _n(address), _n(pageNo), _n(shortCode), _n(gstin)?.toUpperCase(),
        openingBalance, creditLimit,
        if (group != null) group.code, id],
    );
    await _log(id, 'edit', before, await _snap(id));
  }

  // ---- बदल इतिहास for accounts
  /// The details the history records for an account (for the health check).
  Future<Map<String, Object?>> snapOf(String id) => _snap(id);

  Future<Map<String, Object?>> _snap(String id) async {
    final r = await db.getOptional('SELECT * FROM ledgers WHERE id = ?', [id]);
    return r == null ? {} : _snapRow(r);
  }

  static Map<String, Object?> _snapRow(Map<String, Object?> r) {
    String m(Object? p) => (p as int? ?? 0) == 0 ? '' : Money.fmt(p as int);
    return {
      'name': r['name'],
      'name_en': r['name_en'],
      'group': r['grp'],
      'page_no': r['page_no'],
      'phone': r['phone'],
      'address': r['address'],
      'gstin': r['gstin'],
      'opening_balance': m(r['opening_balance']),
      'credit_limit': m(r['credit_limit']),
      'interest_rate': (r['interest_rate'] as int? ?? 0) == 0 ? '' : '${(r['interest_rate'] as int) / 100}%',
      'salary': m(r['salary']),
      'salary_cut': m(r['salary_cut']),
      'hidden': (r['archived'] as int? ?? 0) == 1 ? '✓' : '',
    };
  }

  Future<void> _log(String id, String action, Map<String, Object?>? before, Map<String, Object?>? after) => AuditLog.write(db,
      businessId: businessId,
      recordId: id,
      action: action,
      kind: 'ledger',
      title: '${(after ?? before)?['name'] ?? ''}',
      before: before,
      after: after);

  /// Staff: monthly salary and advance recovered per month (paise).
  Future<void> setStaffPay(String id, {required int salary, required int cut}) async {
    final before = await _snap(id);
    await db.execute('UPDATE ledgers SET salary = ?, salary_cut = ? WHERE id = ?', [salary, cut, id]);
    await _log(id, 'edit', before, await _snap(id));
  }

  /// Interest rate for a party (% per month × 100; 0 = no interest).
  Future<void> setInterestRate(String id, int rate) async {
    final before = await _snap(id);
    await db.execute('UPDATE ledgers SET interest_rate = ? WHERE id = ?', [rate, id]);
    await _log(id, 'edit', before, await _snap(id));
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
      final before = await _snap(l.id);
      await db.execute('DELETE FROM ledgers WHERE id = ?', [l.id]);
      await _log(l.id, 'delete', before, null);
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

  Future<void> setArchived(String id, bool archived) async {
    final before = await _snap(id);
    await db.execute('UPDATE ledgers SET archived = ? WHERE id = ?', [archived ? 1 : 0, id]);
    await _log(id, archived ? 'hide' : 'unhide', before, await _snap(id));
  }

  /// Built-in accounts (रोख, फोनपे, बँक…) whose details no longer match their
  /// last recorded change. That can only happen through a change that skipped
  /// the history: the Nov 2026 bug where a phone re-created these accounts
  /// blank (opening 0). Each fix lists field → (now, was) from the history.
  Future<List<AccountFix>> resetDamage() async {
    final out = <AccountFix>[];
    final rows = await db.getAll('SELECT * FROM ledgers WHERE business_id = ? AND system = 1 ORDER BY name', [businessId]);
    for (final r in rows) {
      final id = r['id'] as String;
      final a = await db.getOptional('SELECT snapshot, at FROM audit_log WHERE voucher_id = ? ORDER BY at DESC LIMIT 1', [id]);
      if (a == null) continue;
      Map<String, dynamic>? after;
      try {
        final snap = jsonDecode(a['snapshot'] as String? ?? '{}') as Map<String, dynamic>;
        if (snap['kind'] != 'ledger') continue;
        after = (snap['after'] as Map?)?.cast<String, dynamic>();
      } catch (_) {
        continue;
      }
      if (after == null) continue;
      final cur = await _snap(id);
      final fix = AccountFix(id, '${r['name'] ?? ''}', '${a['at'] ?? ''}', '${r['created_at'] ?? ''}');
      for (final k in const ['name', 'name_en', 'page_no', 'opening_balance', 'credit_limit', 'hidden']) {
        if (k == 'name' && !after.containsKey('name')) continue;
        final was = '${after[k] ?? ''}', now = '${cur[k] ?? ''}';
        if (was != now) fix.changes[k] = (now, was);
      }
      if (fix.changes.isNotEmpty) out.add(fix);
    }
    return out;
  }

  /// The same check against a backup file (Drive or the app's own): built-in
  /// accounts whose details differ from the file. Returns the file's date too.
  Future<(String, List<AccountFix>)> compareWithBackup(Uint8List bytes) async {
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (data['format'] != 'dukaan-khata-backup') throw const FormatException('Not a Dukaan Khata backup file');
    if (data['business_id'] != businessId) throw const FormatException('This backup is of another shop');
    final rows = ((data['tables'] as Map)['ledgers'] as List? ?? const []).cast<Map>();
    final out = <AccountFix>[];
    for (final raw in rows) {
      final r = raw.cast<String, Object?>();
      if ('${r['system']}' != '1' && r['system'] != true) continue;
      final id = r['id'] as String;
      final cur = await _snap(id);
      if (cur.isEmpty) continue;
      String v(Object? x) => '${x ?? ''}';
      final was = _snapRow({...r, 'opening_balance': _int(r['opening_balance']), 'credit_limit': _int(r['credit_limit']),
        'interest_rate': _int(r['interest_rate']), 'salary': _int(r['salary']), 'salary_cut': _int(r['salary_cut']),
        'archived': _int(r['archived'])});
      final fix = AccountFix(id, v(cur['name']), '${data['exported_at'] ?? ''}', '');
      for (final k in const ['name', 'name_en', 'page_no', 'opening_balance', 'credit_limit', 'hidden']) {
        if (v(was[k]) != v(cur[k])) fix.changes[k] = (v(cur[k]), v(was[k]));
      }
      if (fix.changes.isNotEmpty) out.add(fix);
    }
    return ('${data['exported_at'] ?? ''}', out);
  }

  static int _int(Object? x) => x is int ? x : x is num ? x.round() : int.tryParse('${x ?? ''}') ?? 0;

  /// Puts the recorded values back (each restore is itself recorded).
  Future<void> repair(List<AccountFix> fixes) async {
    for (final f in fixes) {
      final before = await _snap(f.id);
      String? was(String k) => f.changes[k]?.$2;
      final sets = <String>[], args = <Object?>[];
      void put(String col, Object? v) {
        sets.add('$col = ?');
        args.add(v);
      }

      if (was('name') case final v? when v.isNotEmpty) put('name', v);
      if (was('name_en') case final v?) put('name_en', v.isEmpty ? null : v);
      if (was('page_no') case final v?) put('page_no', v.isEmpty ? null : v);
      if (was('opening_balance') case final v?) put('opening_balance', Money.parse(v) ?? 0);
      if (was('credit_limit') case final v?) put('credit_limit', Money.parse(v) ?? 0);
      if (was('hidden') case final v?) put('archived', v.isEmpty ? 0 : 1);
      for (final k in const ['phone', 'address', 'gstin']) {
        if (was(k) case final v?) put(k, v.isEmpty ? null : v);
      }
      if (was('group') case final v? when v.isNotEmpty) put('grp', v);
      if (was('salary') case final v?) put('salary', Money.parse(v) ?? 0);
      if (was('salary_cut') case final v?) put('salary_cut', Money.parse(v) ?? 0);
      if (was('interest_rate') case final v?) {
        put('interest_rate', ((double.tryParse(v.replaceAll('%', '').trim()) ?? 0) * 100).round());
      }
      if (sets.isEmpty) continue;
      await db.execute('UPDATE ledgers SET ${sets.join(', ')} WHERE id = ?', [...args, f.id]);
      await _log(f.id, 'edit', before, await _snap(f.id));
    }
  }

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
      'v.hamali, v.transport, v.haste, tr.name AS transporter_name, v.paid, pl.name AS pay_name, '
      // विभागून: part of the money by a second mode (a linked transfer)
      "(SELECT s.amount || '|' || l2.name FROM vouchers s JOIN ledgers l2 ON l2.id = "
      ' CASE WHEN s.party_id = v.pay_ledger_id THEN s.pay_ledger_id ELSE s.party_id END '
      " WHERE s.status = 'split:' || v.id AND s.deleted = 0) AS split, "
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
      final split = (r['split'] as String?)?.split('|');
      final parts = [
        if (items != null) items,
        if (split != null)
          '${r['pay_name']} ₹${Money.fmt(((r['paid'] as int?) ?? 0) - int.parse(split[0]))} + ${split[1]} ₹${Money.fmt(int.parse(split[0]))}',
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
    // running balance of the old entries alone – shown to see how the
    // opening balance came about; it is never added to any figure
    var oldRun = 0;
    for (final r in refRows) {
      final amount = (r['amount'] as int?) ?? 0;
      final paid = (r['paid'] as int?) ?? 0;
      final (kind, d, c) = oldEntryEffect(r['pay_ledger_id'] as String?, amount, paid);
      oldRun += d - c;
      final items = _cleanItems(r['items'] as String?);
      final parts = [
        if (items != null) items,
        if ((r['narration'] as String?)?.isNotEmpty ?? false) r['narration'] as String,
      ];
      refs.add(StatementRow(r['id'] as String, r['vdate'] as String, VoucherType.history, (r['vno'] as int?) ?? 0,
          parts.join(' · '), d, c, oldRun, null,
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
      "WHERE v.business_id = ? AND v.deleted = 0 AND v.vtype NOT IN ('stock_adjust', 'opening', 'history', 'promise', 'goods_out', 'goods_in', 'booking', 'recurring', 'recurring_pay') AND ("
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
  /// How many hamals worked on [date]: the latest saved count, shared by
  /// every phone through the change history (which also shows who set it).
  Future<int?> hamalsOn(String date) async {
    final r = await db.getOptional(
        "SELECT snapshot FROM audit_log WHERE business_id = ? AND voucher_id = ? ORDER BY at DESC LIMIT 1", [businessId, 'hamals:$date']);
    if (r == null) return null;
    try {
      final after = (jsonDecode(r['snapshot'] as String) as Map)['after'] as Map?;
      return int.tryParse('${after?['hamal_count'] ?? 0}') ?? 0;
    } catch (_) {
      return null;
    }
  }

  Future<void> setHamals(String date, int n, int? before) => AuditLog.write(db,
      businessId: businessId,
      recordId: 'hamals:$date',
      action: before == null ? 'create' : 'edit',
      kind: 'hamals',
      title: date,
      before: before == null ? null : {'hamal_count': '$before'},
      after: {'hamal_count': '$n'});

  Future<DayCharges> dayCharges(String date) async {
    Future<int> sum(String ledgerId, String expr) async => ((await db.get(
          'SELECT COALESCE(SUM($expr),0) AS s FROM voucher_lines WHERE ledger_id = ? AND vdate = ? AND deleted = 0',
          [ledgerId, date],
        ))['s'] as num)
            .toInt();
    final hamaliCharged = await sum('$businessId:hamali_income', 'credit - debit');
    final hamaliPaid = await sum('$businessId:hamali', 'debit - credit');
    final ownTransport = await sum('$businessId:transport_income', 'credit - debit');
    final varhai = await sum('$businessId:varhai', 'credit - debit');
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
    final transportCharged = ((await db.get(
      "SELECT COALESCE(SUM(transport),0) AS s FROM vouchers WHERE business_id = ? AND vtype = 'sale' AND vdate = ? AND deleted = 0",
      [businessId, date],
    ))['s'] as num)
        .toInt();
    // भाडे paid out today (a payment entry), not the bills' own fare-margin postings
    final freightPaid = ((await db.get(
      'SELECT COALESCE(SUM(vl.debit - vl.credit),0) AS s FROM voucher_lines vl JOIN vouchers v ON v.id = vl.voucher_id '
      "WHERE vl.ledger_id = ? AND vl.vdate = ? AND vl.deleted = 0 AND v.vtype = 'payment'",
      ['$businessId:freight', date],
    ))['s'] as num)
        .toInt();
    final dc = DayCharges(date, hamaliCharged, hamaliPaid, ownTransport, dues,
        varhai: varhai, transportCharged: transportCharged, freightPaid: freightPaid);
    dc.hamals = await hamalsOn(date);
    return dc;
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
      'SELECT v.id, v.vtype, v.vno, v.narration, v.gst_bill_needed, ml.short_code AS code, SUM(vl.debit) AS d, SUM(vl.credit) AS c, '
      '(SELECT GROUP_CONCAT(x.name, \' / \') FROM (SELECT DISTINCT l2.name FROM voucher_lines vl2 JOIN ledgers l2 ON l2.id = vl2.ledger_id '
      ' WHERE vl2.voucher_id = v.id AND vl2.deleted = 0 AND vl2.ledger_id NOT IN ($ph) '
      " AND l2.grp NOT IN ('sales','purchase','sales_return','purchase_return')) x) AS other, "
      'pty.name AS party_name '
      // a विभागून transfer counts as part of its entry: one bill, रोख 1,800 + फोनपे 1,200
      'FROM voucher_lines vl JOIN vouchers s ON s.id = vl.voucher_id '
      "JOIN vouchers v ON v.id = CASE WHEN s.status LIKE 'split:%' THEN substr(s.status, 7) ELSE s.id END "
      'JOIN ledgers ml ON ml.id = vl.ledger_id '
      'LEFT JOIN ledgers pty ON pty.id = v.party_id '
      'WHERE vl.ledger_id IN ($ph) AND vl.deleted = 0 AND vl.vdate = ? '
      'GROUP BY v.id, vl.ledger_id ORDER BY v.created_at',
      [...moneyLedgerIds, ...moneyLedgerIds, date],
    );
    final out = <CashRow>[];
    for (final r in rows) {
      final d = (r['d'] as num).toInt();
      final c = (r['c'] as num).toInt();
      final type = VoucherType.fromCode(r['vtype'] as String);
      // a bill is titled by its party; without one it is a cash sale / purchase –
      // never by the hamali / transport / service income on it
      final bill = const {VoucherType.sale, VoucherType.salesReturn, VoucherType.purchase, VoucherType.purchaseReturn}.contains(type);
      final particulars = (r['party_name'] as String?) ??
          (bill ? null : r['other'] as String?) ??
          (bill ? null : r['narration'] as String?) ??
          '';
      final code = r['code'] as String?;
      final gst = (r['gst_bill_needed'] as int?) == 1;
      final narration = r['narration'] as String?;
      if (type == VoucherType.purchase && d > 0) {
        // money coming in on a purchase is वराई: its own row, not netted with the payment
        out.add(CashRow(r['id'] as String, type, particulars, d, 0, code, gst, narration, varhai: true));
        if (c > 0) out.add(CashRow(r['id'] as String, type, particulars, 0, c, code, gst, narration));
        continue;
      }
      final net = d - c;
      if (net == 0) continue;
      out.add(CashRow(r['id'] as String, type, particulars, net > 0 ? net : 0, net < 0 ? -net : 0, code, gst, narration,
          vno: (r['vno'] as num?)?.toInt()));
    }
    return CashBook(date, (o['b'] as num).toInt(), out);
  }

  /// All vouchers of a day (Day Book).
  Future<List<Voucher>> dayBook(String from, [String? to]) async {
    final rows = await db.getAll(
      'SELECT v.*, p.name AS party_name, pl.short_code AS pay_code FROM vouchers v '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      "WHERE v.business_id = ? AND v.deleted = 0 AND v.vtype NOT IN ('history', 'promise', 'recurring', 'recurring_pay') AND v.vdate >= ? AND v.vdate <= ? "
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

/// One built-in account to put back: field → (now, was).
class AccountFix {
  AccountFix(this.id, this.name, this.lastChange, this.createdAt);
  final String id, name, lastChange, createdAt;
  final changes = <String, (String, String)>{};
}

/// One bill (or old balance) still not fully paid.
class PendingBill {
  PendingBill(this.date, this.row, this.amount, this.left, this.old);
  final String date;
  final StatementRow? row; // null = the opening balance
  final int amount; // the bill
  final int left; // still unpaid
  final bool old; // from the old (reference) entries
}

/// बिलनिहाय बाकी: which bills make up the balance today. Payments clear the
/// oldest bills first. Old entries are used for their dates when they add up
/// to the opening balance; otherwise the opening balance is one lump on the
/// day the books start. Changes nothing – it only reads the khata.
List<PendingBill> pendingBills(Statement st, String booksStart) {
  final items = <(String, StatementRow?, int dr, int cr, bool old)>[];
  if (st.references.isNotEmpty && st.references.last.balance == st.opening) {
    for (final r in st.references) {
      items.add((r.date, r, r.debit, r.credit, true));
    }
  } else if (st.opening != 0) {
    items.add((booksStart, null, st.opening > 0 ? st.opening : 0, st.opening < 0 ? -st.opening : 0, false));
  }
  for (final r in st.rows) {
    items.add((r.date, r, r.debit, r.credit, false));
  }
  final closing = st.closing;
  if (closing == 0) return const [];
  final theyOwe = closing > 0;
  // what was paid towards the bills, in total
  var pool = items.fold<int>(0, (s, x) => s + (theyOwe ? x.$4 : x.$3));
  final out = <PendingBill>[];
  for (final x in items) {
    final bill = theyOwe ? x.$3 : x.$4;
    if (bill <= 0) continue;
    final used = pool >= bill ? bill : pool;
    pool -= used;
    if (bill - used > 0) out.add(PendingBill(x.$1, x.$2, bill, bill - used, x.$5));
  }
  return out;
}

/// An old (pre-books) entry's kind and its नावे / जमा on the old khata – the
/// one formula used by the khata, the days count and the "not matching" list.
(String, int, int) oldEntryEffect(String? payLedgerId, int amount, int paid) {
  var kind = (payLedgerId ?? '').replaceFirst('hist:', '');
  // entries saved before the kind was stored: money only = received, else goods given
  if (!const {'sale', 'purchase', 'received', 'paid', 'opening', 'opening_cr'}.contains(kind)) {
    kind = amount == 0 && paid > 0 ? 'received' : 'sale';
  }
  final (int d, int c) = switch (kind) {
    'purchase' => (paid, amount),
    // जुनी बाकी: the balance from an even older book – where the old ledger starts
    'opening' => (amount, 0),
    'opening_cr' => (0, amount),
    'received' => (0, amount == 0 ? paid : amount),
    'paid' => (amount, 0),
    _ => (amount, paid),
  };
  return (kind, d, c);
}

/// A party's old entries in short: their total (as on the old khata), how
/// many, and the first and last dates.
class OldSummary {
  int total = 0, count = 0;
  String first = '', last = '';
}
