import 'package:sqlite_async/sqlite_async.dart';

import '../core/ids.dart';
import '../core/money.dart';
import 'models.dart';
import 'voucher_service.dart';

/// दरमहा आकार: a monthly charge to a party (rent, water …) – a template that
/// posts nothing itself. From the 1st of each month it is due until the owner
/// puts that month's bill on the party's khata.
///
/// Stored as a voucher of type `recurring` (items = what to charge, rate 0 =
/// ask every month); `status` is `active`, `active:YYYY-MM` (last month
/// charged) or `stopped`.
class RecurringLine {
  final Item item;
  final double qty;
  final int rate; // 0 = enter each month
  RecurringLine(this.item, this.qty, this.rate);
}

class Recurring {
  final String id;
  final String partyId;
  final String partyName;
  final String? pageNo;
  final String startMonth; // YYYY-MM
  final String? lastCharged; // YYYY-MM
  final bool stopped;
  final String? note;
  final List<RecurringLine> lines;
  /// दरमहा देणे: money we pay every month (loan interest, light bill …)
  /// into [partyId] from [payFromId]; [amount] 0 = ask each month.
  final bool payment;
  final int amount;
  final String? payFromId;
  Recurring(this.id, this.partyId, this.partyName, this.pageNo, this.startMonth, this.lastCharged, this.stopped, this.note,
      this.lines, {this.payment = false, this.amount = 0, this.payFromId});

  int get fixedTotal => payment ? amount : lines.fold(0, (s, l) => s + (l.qty * l.rate).round());

  /// Months still to charge, oldest first, up to [today]'s month.
  List<String> dueMonths(String today) {
    if (stopped) return [];
    final now = monthOf(today);
    var m = lastCharged == null ? startMonth : nextMonth(lastCharged!);
    final out = <String>[];
    while (m.compareTo(now) <= 0 && out.length < 24) {
      out.add(m);
      m = nextMonth(m);
    }
    return out;
  }
}

String monthOf(String isoDate) => isoDate.substring(0, 7);
String nextMonth(String ym) {
  final y = int.parse(ym.substring(0, 4)), m = int.parse(ym.substring(5, 7));
  return m == 12 ? '${y + 1}-01' : '$y-${(m + 1).toString().padLeft(2, '0')}';
}

class RecurringService {
  final SqliteConnection db;
  final String businessId;
  RecurringService(this.db, this.businessId);

  Future<List<Recurring>> list({String? partyId}) async {
    final items = {
      for (final r in await db.getAll('SELECT * FROM items WHERE business_id = ?', [businessId])) r['id'] as String: Item.fromRow(r)
    };
    final rows = await db.getAll(
      'SELECT v.id, v.vtype, v.vdate, v.party_id, v.pay_ledger_id, v.amount, v.status, v.narration, p.name AS party_name, p.page_no '
      'FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id '
      "WHERE v.business_id = ? AND v.vtype IN ('recurring', 'recurring_pay') AND v.deleted = 0 ${partyId != null ? 'AND v.party_id = ? ' : ''}"
      'ORDER BY p.name, v.created_at',
      [businessId, if (partyId != null) partyId],
    );
    final out = <Recurring>[];
    for (final r in rows) {
      final lines = [
        for (final l in await db.getAll(
            'SELECT item_id, qty, rate FROM inventory_lines WHERE voucher_id = ? AND deleted = 0 ORDER BY id', [r['id']]))
          if (items[l['item_id']] case final it?) RecurringLine(it, (l['qty'] as num).toDouble(), l['rate'] as int),
      ];
      final status = (r['status'] as String?) ?? 'active';
      out.add(Recurring(
        r['id'] as String,
        r['party_id'] as String,
        (r['party_name'] as String?) ?? '?',
        r['page_no'] as String?,
        monthOf(r['vdate'] as String),
        status.startsWith('active:') ? status.substring(7) : null,
        status == 'stopped',
        r['narration'] as String?,
        lines,
        payment: r['vtype'] == 'recurring_pay',
        amount: (r['amount'] as int?) ?? 0,
        payFromId: r['pay_ledger_id'] as String?,
      ));
    }
    return out;
  }

  /// (charge, month) pairs still to put on the khata.
  Future<List<(Recurring, String)>> due(String today) async => [
        for (final r in await list())
          for (final m in r.dueMonths(today)) (r, m),
      ];

  /// Creates / edits the template. [startMonth] is the first month to charge.
  Future<String> save(VoucherService vs, Actor actor,
      {String? existingId, required String partyId, required String startMonth, required List<ItemLine> lines, String? note}) async {
    if (!actor.isOwner) throw PermissionDenied('err_owner_recurring');
    var date = '$startMonth-01';
    if (Books.isHistory(date)) date = Books.start;
    String? keep;
    if (existingId != null) {
      keep = (await db.get('SELECT status FROM vouchers WHERE id = ?', [existingId]))['status'] as String?;
    }
    final id = await vs.save(
      VoucherInput(type: VoucherType.recurring, date: date, partyId: partyId, items: lines, narration: note),
      actor,
      existingId: existingId,
    );
    await db.execute('UPDATE vouchers SET status = ? WHERE id = ?', [keep ?? 'active', id]);
    return id;
  }

  Future<void> setStopped(String id, bool stopped, {String? lastCharged}) =>
      VoucherService(db, businessId).setStatusLogged(id, stopped ? 'stopped' : (lastCharged == null ? 'active' : 'active:$lastCharged'));

  /// Puts one month's charge on the khata (a sale bill on credit, dated the
  /// 1st of that month) and marks the month done.
  Future<String> charge(VoucherService vs, Actor actor, Recurring r, String month, List<ItemLine> lines,
      {required String narration}) async {
    if (!actor.isOwner) throw PermissionDenied('err_owner_recurring');
    var date = '$month-01';
    if (Books.isHistory(date)) date = Books.start;
    final id = await vs.save(
      VoucherInput(type: VoucherType.sale, date: date, partyId: r.partyId, items: lines, narration: narration),
      actor,
    );
    await db.execute("UPDATE vouchers SET status = ?, updated_at = ? WHERE id = ?", ['active:$month', nowIso(), r.id]);
    // remember which month this bill settles: deleting it makes the month due again
    await db.execute('UPDATE vouchers SET status = ? WHERE id = ?', ['$monthlyPrefix${r.id}|$month', id]);
    return id;
  }

  /// दरमहा देणे template: pay [amount] (0 = ask) to [ledgerId] from [payFromId] every month.
  Future<String> savePayment(VoucherService vs, Actor actor,
      {String? existingId, required String ledgerId, required String payFromId, required String startMonth, int amount = 0, String? note}) async {
    if (!actor.isOwner) throw PermissionDenied('err_owner_recurring');
    var date = '$startMonth-01';
    if (Books.isHistory(date)) date = Books.start;
    String? keep;
    if (existingId != null) {
      keep = (await db.get('SELECT status FROM vouchers WHERE id = ?', [existingId]))['status'] as String?;
    }
    final id = await vs.save(
      VoucherInput(type: VoucherType.recurringPay, date: date, partyId: ledgerId, payLedgerId: payFromId, amount: amount, narration: note),
      actor,
      existingId: existingId,
    );
    await db.execute('UPDATE vouchers SET status = ? WHERE id = ?', [keep ?? 'active', id]);
    return id;
  }

  /// Pays one month (a payment dated today, or the 1st of a past month) and marks it done.
  Future<String> pay(VoucherService vs, Actor actor, Recurring r, String month,
      {required int amount, required String payFromId, required String narration, String? date}) async {
    if (!actor.isOwner) throw PermissionDenied('err_owner_recurring');
    var d = date ?? '$month-01';
    if (Books.isHistory(d)) d = Books.start;
    final id = await vs.save(
      VoucherInput(type: VoucherType.payment, date: d, partyId: r.partyId, payLedgerId: payFromId, amount: amount, narration: narration),
      actor,
    );
    await db.execute('UPDATE vouchers SET status = ?, updated_at = ? WHERE id = ?', ['active:$month', nowIso(), r.id]);
    await db.execute('UPDATE vouchers SET status = ? WHERE id = ?', ['$monthlyPrefix${r.id}|$month', id]);
    return id;
  }

  /// Skip a month without charging (e.g. shop closed).
  Future<void> skip(Recurring r, String month) => VoucherService(db, businessId).setStatusLogged(r.id, 'active:$month');
}
