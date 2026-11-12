
import 'package:sqlite_async/sqlite_async.dart';

import '../core/audit.dart';
import '../core/ids.dart';
import '../core/money.dart';
import '../core/seed.dart';
import 'models.dart';

/// Who is making the entry (for audit + permission checks).
class Actor {
  final String userId;
  final String name;
  final bool isOwner;
  const Actor({required this.userId, required this.name, required this.isOwner});
}

class PermissionDenied implements Exception {
  final String message;
  PermissionDenied(this.message);
  @override
  String toString() => message;
}

/// pay_ledger_id marker for old entries: "hist:sale", "hist:purchase", …
const historyKindPrefix = 'hist:';

/// pay_ledger_id marker for उसना माल that was already out before the books
/// start: counts in the bags owed, but never in shop stock (the opening stock
/// count already left those bags out) and never in money.
const goodsOpeningMarker = 'opening';

class VoucherInput {
  final VoucherType type;
  final String date;
  final String? partyId; // customer / supplier / expense ledger / contra "to"
  final String? payLedgerId; // cash / PhonePe / bank (contra "from")
  final List<ItemLine> items;
  final int amount; // used when there are no item lines
  final int paid; // paid immediately (sale/purchase)
  final int discount; // settlement discount on receipt / payment
  final String? narration;
  final String? refNo;
  final bool gstBillNeeded;
  final List<MoneyLine> journalLines;
  // Sale bill charges
  final int hamali; // labour (unloading) charged to the customer
  final int transport; // transport charged to the customer
  final String? transporterId; // null = our own vehicle
  final int? transporterFare; // owed to the outside transporter (default = transport)

  VoucherInput({
    required this.type,
    required this.date,
    this.partyId,
    this.payLedgerId,
    this.items = const [],
    this.amount = 0,
    this.paid = 0,
    this.discount = 0,
    this.narration,
    this.refNo,
    this.gstBillNeeded = false,
    this.journalLines = const [],
    this.hamali = 0,
    this.transport = 0,
    this.transporterId,
    this.transporterFare,
    this.gstRate = 0,
    this.roundOff = 0,
    this.haste,
    this.varhai = 0,
  });

  /// वराई on a purchase: cash the company's driver gave for the labourers.
  /// Goes into cash and the वराई ledger; never part of the supplier's bill.
  final int varhai;

  /// GST on a genuine GST bill: rate is percent × 100 (1800 = 18 %), charged on the goods value.
  final int gstRate;

  /// हस्ते: who brought the money / took the goods for the party (optional).
  final String? haste;

  /// Round off on a sale / purchase bill: signed paise added to the total
  /// (−700 makes ₹3,437 → ₹3,430; +300 makes it ₹3,440).
  final int roundOff;

  bool get roundOffApplies =>
      roundOff != 0 && (type == VoucherType.sale || type == VoucherType.purchase || type == VoucherType.history);

  /// Old (pre-books) entry kind, stored in pay_ledger_id as "hist:<kind>":
  /// sale = goods given, purchase = goods bought, received / paid = money only.
  String get historyKind {
    final k = payLedgerId ?? '';
    return k.startsWith(historyKindPrefix) ? k.substring(historyKindPrefix.length) : 'sale';
  }

  /// Charges (hamali, transport) belong on sales – and on old bills, for the record.
  bool get _chargesOn => type == VoucherType.sale || type == VoucherType.history;

  /// Value of goods (or the plain amount when there are no item lines).
  int get goods => items.isEmpty ? amount : items.fold(0, (s, l) => s + l.amount);

  bool get hasCharges => type == VoucherType.sale && (hamali != 0 || transport != 0);

  /// Bill total = goods + hamali + transport (charges only on sales).
  bool get gstApplies => gstRate > 0 && (type == VoucherType.sale || type == VoucherType.purchase);

  /// GST amount, rounded to whole rupees as on most bills.
  int get gst => gstApplies ? ((goods * gstRate / 10000) / 100).round() * 100 : 0;

  int get total => goods + (_chargesOn ? hamali + transport : 0) + gst + (roundOffApplies ? roundOff : 0);

  int get fare => transporterId == null ? 0 : (transporterFare ?? transport);
}

/// Turns simple entries ("sale 15 bags at 275 to Suresh Jadhav, paid by PhonePe")
/// into balanced double-entry vouchers – the Tally engine under a Khatabook face.
/// status of a विभागून transfer: `split:<main entry id>`.
const splitPrefix = 'split:';

/// status of a bill / payment made from a दरमहा reminder: `monthly:<template id>|<YYYY-MM>`.
const monthlyPrefix = 'monthly:';

class VoucherService {
  final SqliteConnection db;
  final String businessId;
  VoucherService(this.db, this.businessId);

  String sys(String key) => systemLedgerId(businessId, key);

  /// Builds the debit/credit lines for an input. Pure – unit-testable.
  /// [services]: item ids that are services (सेवा) – their value goes to
  /// service income / cost instead of sales / purchase.
  List<MoneyLine> buildLines(VoucherInput v, {Set<String> services = const {}}) {
    final serviceValue = v.items.where((l) => services.contains(l.itemId)).fold<int>(0, (s, l) => s + l.amount);
    final total = v.total;
    final lines = <MoneyLine>[];
    void dr(String id, int amt) {
      if (amt != 0) lines.add(MoneyLine(id, debit: amt));
    }

    void cr(String id, int amt) {
      if (amt != 0) lines.add(MoneyLine(id, credit: amt));
    }

    final pay = v.payLedgerId ?? sys('cash');
    switch (v.type) {
      case VoucherType.sale:
        final party = v.partyId ?? pay; // walk-in cash sale
        dr(party, total);
        cr(sys('sales'), v.goods - serviceValue);
        cr(sys('service_income'), serviceValue);
        cr(sys('gst'), v.gst); // output GST payable
        // Hamali charged on the bill is our income; paying the labourers at
        // day end is an expense (हमाली), so charging more shows as profit.
        cr(sys('hamali_income'), v.hamali);
        // bill rounded up → small income; rounded down → small expense
        if (v.roundOffApplies && v.roundOff > 0) cr(sys('round_off'), v.roundOff);
        if (v.roundOffApplies && v.roundOff < 0) dr(sys('round_off'), -v.roundOff);
        if (v.transport != 0 || v.fare != 0) {
          if (v.transporterId == null) {
            cr(sys('transport_income'), v.transport); // own vehicle → indirect income
          } else {
            cr(v.transporterId!, v.fare); // we owe the outside transporter
            final margin = v.transport - v.fare;
            if (margin > 0) cr(sys('transport_income'), margin);
            if (margin < 0) dr(sys('freight'), -margin);
          }
        }
        if (v.paid > 0 && party != pay) {
          dr(pay, v.paid);
          cr(party, v.paid);
        }
      case VoucherType.salesReturn:
        final party = v.partyId ?? pay;
        dr(sys('sales_return'), total);
        cr(party, total);
        if (v.paid > 0 && party != pay) {
          dr(party, v.paid);
          cr(pay, v.paid);
        }
      case VoucherType.purchase:
        final party = v.partyId ?? pay;
        dr(sys('purchase'), v.goods - serviceValue);
        dr(sys('service_cost'), serviceValue); // e.g. a contractor's work bought in
        dr(sys('gst'), v.gst); // input GST (credit)
        // we pay a rounded amount: up → small expense, down → small income
        if (v.roundOffApplies && v.roundOff > 0) dr(sys('round_off'), v.roundOff);
        if (v.roundOffApplies && v.roundOff < 0) cr(sys('round_off'), -v.roundOff);
        cr(party, total);
        if (v.paid > 0 && party != pay) {
          dr(party, v.paid);
          cr(pay, v.paid);
        }
        if (v.varhai > 0) {
          dr(sys('cash'), v.varhai); // handed over by the driver
          cr(sys('varhai'), v.varhai);
        }
      case VoucherType.purchaseReturn:
        final party = v.partyId ?? pay;
        dr(party, total);
        cr(sys('purchase_return'), total);
        if (v.paid > 0 && party != pay) {
          dr(pay, v.paid);
          cr(party, v.paid);
        }
      case VoucherType.receipt:
        _require(v.partyId, 'party');
        dr(pay, total);
        cr(v.partyId!, total);
        if (v.discount > 0) {
          dr(sys('discount_given'), v.discount);
          cr(v.partyId!, v.discount);
        }
      case VoucherType.payment:
        _require(v.partyId, 'party');
        dr(v.partyId!, total);
        cr(pay, total);
        if (v.discount > 0) {
          dr(v.partyId!, v.discount);
          cr(sys('discount_recd'), v.discount);
        }
      case VoucherType.contra:
        _require(v.partyId, 'to account');
        dr(v.partyId!, total);
        cr(pay, total);
      case VoucherType.history:
        // Old khata entry: REFERENCE ONLY. The opening balance already is the
        // net of all old entries, so an old entry posts nothing – no ledger,
        // no stock, no cash, no hamali. It is kept to show a customer which
        // bill / payment made up their balance.
        _require(v.partyId, 'party');
      case VoucherType.journal:
        lines.addAll(v.journalLines.where((l) => l.debit != 0 || l.credit != 0));
      case VoucherType.promise:
        // promised payment date: a reminder, posts nothing
        _require(v.partyId, 'party');
      case VoucherType.salary:
        // पगार: the full month's salary is the expense; what is handed over
        // leaves cash, the rest is recovered from the advance (उचल)
        _require(v.partyId, 'party');
        dr(sys('salary'), total);
        cr(v.partyId!, total);
        if (v.paid > 0) {
          dr(v.partyId!, v.paid);
          cr(pay, v.paid);
        }
      case VoucherType.recurring:
      case VoucherType.recurringPay:
        // monthly template: each month's bill / payment is a separate entry
        _require(v.partyId, 'party');
      case VoucherType.booking:
        // बुकिंग: a promise of goods at a rate – the advance is a separate
        // receipt / payment, so the booking itself posts nothing
        _require(v.partyId, 'party');
      case VoucherType.interest:
        // व्याज on an overdue balance: the party owes it, it is our income
        _require(v.partyId, 'party');
        dr(v.partyId!, total);
        cr(sys('interest_income'), total);
      case VoucherType.goodsOut:
      case VoucherType.goodsIn:
        // bags lent / returned: counted in bags on the party's khata, no money
        _require(v.partyId, 'party');
      case VoucherType.stockAdjust:
      case VoucherType.opening:
        break;
    }
    final d = lines.fold<int>(0, (s, l) => s + l.debit);
    final c = lines.fold<int>(0, (s, l) => s + l.credit);
    if (d != c) {
      throw ArgumentError('Voucher not balanced: debit $d != credit $c');
    }
    return lines;
  }

  void _require(String? v, String what) {
    if (v == null || v.isEmpty) throw ArgumentError(what == 'party' ? 'err_party' : 'err_to_account');
  }

  /// Creates or (if [existingId] is given) edits a voucher. Returns its id.
  Future<String> save(VoucherInput v, Actor actor, {String? existingId}) async {
    // services on the bill (no stock, own income account)
    final itemIds = v.items.map((l) => l.itemId).toSet().toList();
    final services = itemIds.isEmpty
        ? <String>{}
        : {
            for (final r in await db.getAll(
                'SELECT id FROM items WHERE category = ? AND id IN (${List.filled(itemIds.length, '?').join(',')})',
                [serviceCategory, ...itemIds]))
              r['id'] as String
          };
    final lines = buildLines(v, services: services);
    final goodsLoan = v.type.isGoodsLoan;
    final total = goodsLoan ? 0 : v.total; // उसना माल has no money value
    if (goodsLoan && !v.items.any((i) => i.qty != 0)) throw ArgumentError('err_items');
    final goodsOpening = goodsLoan && v.payLedgerId == goodsOpeningMarker;
    if (goodsOpening) {
      if (!actor.isOwner) throw PermissionDenied('err_owner_opening_goods');
      if (v.date != Books.start) throw ArgumentError('err_opening_goods_date');
    }
    final today = todayIso();
    // staff work on today's entries – and may also write old khata entries
    // (जुनी नोंद), which are reference only and change no figure
    if (!actor.isOwner && v.date.compareTo(today) < 0 && v.type != VoucherType.history) {
      throw PermissionDenied('err_staff_today');
    }
    if (v.type == VoucherType.history) {
      if (v.total <= 0 && v.paid <= 0) throw ArgumentError('err_amount');
    } else if (v.type == VoucherType.promise) {
      // amount is optional ("will pay something on Monday")
    } else if (v.items.isEmpty && lines.isEmpty && v.type != VoucherType.stockAdjust && v.type != VoucherType.recurringPay) {
      throw ArgumentError('err_amount');
    }
    if (v.type == VoucherType.history) {
      if (!Books.isHistory(v.date)) {
        throw ArgumentError('err_old_date');
      }
    } else if (v.type == VoucherType.booking && Books.isHistory(v.date)) {
      // a booking from before the books start is only a note (it posts nothing anyway)
      if (!actor.isOwner) throw PermissionDenied('err_owner_old');
    } else if (Books.isHistory(v.date)) {
      throw ArgumentError('err_before_books');
    }
    if (v.gstApplies && !actor.isOwner) throw PermissionDenied('err_owner_gst');
    if (v.type == VoucherType.interest && !actor.isOwner) throw PermissionDenied('err_owner_interest');
    if (v.type == VoucherType.salary) {
      if (!actor.isOwner) throw PermissionDenied('err_owner_salary');
      if (v.paid > v.total || v.paid < 0) throw ArgumentError('err_salary_cut');
    }

    return db.writeTransaction((tx) async {
      final now = nowIso();
      String id;
      int version = 1;
      Map<String, Object?>? before;
      if (existingId != null) {
        final old = await tx.get('SELECT * FROM vouchers WHERE id = ?', [existingId]);
        if (old['vtype'] == 'history' && !actor.isOwner) {
          // staff may correct an old entry on the day they wrote it
          if (!enteredToday(old['created_at'] as String?) || v.type != VoucherType.history) {
            throw PermissionDenied('err_owner_edit_old');
          }
        } else {
          _checkEditable(actor, old['vdate'] as String, deleting: false);
        }
        before = await entrySummary(tx, existingId); // बदल इतिहास: what it was
        await tx.execute('DELETE FROM voucher_lines WHERE voucher_id = ?', [existingId]);
        await tx.execute('DELETE FROM inventory_lines WHERE voucher_id = ?', [existingId]);
        version = ((old['version'] as int?) ?? 1) + 1;
        final keepStatus = old['status']; // a closed booking stays closed when edited
        id = existingId;
        await tx.execute(
          'UPDATE vouchers SET vtype=?, vdate=?, party_id=?, pay_ledger_id=?, amount=?, paid=?, '
          'narration=?, ref_no=?, gst_bill_needed=?, hamali=?, transport=?, transporter_id=?, transporter_fare=?, gst_rate=?, gst=?, haste=?, status=?, '
          'updated_at=?, version=? WHERE id=?',
          [
            v.type.code, v.date, v.partyId, v.payLedgerId, total, _paidFor(v, total), v.narration,
            v.refNo, v.gstBillNeeded ? 1 : 0, ..._charges(v), now, version, id
          ],
        );
        if ((v.type == VoucherType.booking || '$keepStatus'.startsWith(splitPrefix) || '$keepStatus'.startsWith(monthlyPrefix)) &&
            keepStatus != null) {
          await tx.execute('UPDATE vouchers SET status = ? WHERE id = ?', [keepStatus, id]);
        }
      } else {
        id = newId();
        final vno = await _nextNo(tx, v.type, v.date);
        await tx.execute(
          'INSERT INTO vouchers (id, business_id, vtype, vno, vdate, party_id, pay_ledger_id, amount, '
          'paid, narration, ref_no, gst_bill_needed, hamali, transport, transporter_id, transporter_fare, gst_rate, gst, haste, status, '
          'created_by, created_at, updated_at, deleted, version) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1)',
          [
            id, businessId, v.type.code, vno, v.date, v.partyId, v.payLedgerId, total,
            _paidFor(v, total), v.narration, v.refNo, v.gstBillNeeded ? 1 : 0, ..._charges(v), actor.name, now, now
          ],
        );
      }
      // Line ids are derived from the voucher id, so an edit made on two
      // devices at once replaces the same rows instead of adding duplicates.
      for (var n = 0; n < lines.length; n++) {
        final l = lines[n];
        await tx.execute(
          'INSERT INTO voucher_lines (id, business_id, voucher_id, ledger_id, debit, credit, vdate, deleted) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
          ['$id:L$n', businessId, id, l.ledgerId, l.debit, l.credit, v.date],
        );
      }
      final dir = goodsOpening ? 0 : v.type.stockDirection;
      var n = 0;
      for (final it in v.items) {
        // stock adjustment: sign of qty decides in/out
        final service = services.contains(it.itemId);
        final d = service ? 0 : v.type == VoucherType.stockAdjust ? (it.qty >= 0 ? 1 : -1) : dir;
        // old bills keep their item lines for the record, with no stock effect
        // old bills, opening उसना माल and bookings keep their item lines with no stock effect
        if (d == 0 && v.type != VoucherType.history && v.type != VoucherType.booking && v.type != VoucherType.recurring && !goodsOpening && !service) continue;
        if (it.qty == 0) continue;
        await tx.execute(
          'INSERT INTO inventory_lines (id, business_id, voucher_id, item_id, qty, rate, amount, direction, vdate, deleted) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
          ['$id:I${n++}', businessId, id, it.itemId, it.qty.abs(), goodsLoan ? 0 : it.rate, goodsLoan ? 0 : it.amount.abs(), d, v.date],
        );
      }
      // बदल इतिहास: every new entry and every edit, field by field
      final after = await entrySummary(tx, id);
      await AuditLog.write(tx,
          businessId: businessId,
          recordId: id,
          action: before == null ? 'create' : 'edit',
          kind: 'voucher',
          title: _entryTitle(after),
          before: before,
          after: after,
          by: actor);
      return id;
    });
  }

  List<Object?> _charges(VoucherInput v) => [
        ...(v.type == VoucherType.sale
            ? [v.hamali, v.transport, v.transporterId, v.transporterId == null ? null : v.fare]
            : v.type == VoucherType.history
                ? [v.hamali, v.transport, null, null]
                : [0, 0, null, null]),
        v.gstApplies ? v.gstRate : 0,
        v.gst,
        (v.haste?.trim().isEmpty ?? true) ? null : v.haste!.trim(),
        v.type == VoucherType.promise || v.type == VoucherType.booking ? 'open' : null,
      ];

  int _paidFor(VoucherInput v, int total) => switch (v.type) {
        VoucherType.receipt || VoucherType.payment || VoucherType.contra => total,
        VoucherType.interest => 0,
        VoucherType.salary || VoucherType.booking => v.paid,
        VoucherType.sale || VoucherType.purchase || VoucherType.salesReturn || VoucherType.purchaseReturn =>
          v.partyId == null ? total : v.paid,
        VoucherType.history => v.paid,
        _ => 0,
      };

  /// Soft delete – the voucher stays in the audit trail.
  Future<void> delete(String id, Actor actor) async {
    await db.writeTransaction((tx) async {
      final old = await tx.get('SELECT * FROM vouchers WHERE id = ?', [id]);
      _checkEditable(actor, old['vdate'] as String, deleting: true);
      await _markDeleted(tx, id, actor);
      // its विभागून part goes with it
      for (final r in await tx.getAll("SELECT id FROM vouchers WHERE status = ? AND deleted = 0", ['$splitPrefix$id'])) {
        await _markDeleted(tx, r['id'] as String, actor);
      }
    });
  }

  Future<void> _markDeleted(SqliteWriteContext tx, String id, Actor actor) async {
    final before = await entrySummary(tx, id);
    await AuditLog.write(tx,
        businessId: businessId, recordId: id, action: 'delete', kind: 'voucher', title: _entryTitle(before), before: before, by: actor);
    await tx.execute('UPDATE vouchers SET deleted = 1, updated_at = ? WHERE id = ?', [nowIso(), id]);
    await tx.execute('UPDATE voucher_lines SET deleted = 1 WHERE voucher_id = ?', [id]);
    await tx.execute('UPDATE inventory_lines SET deleted = 1 WHERE voucher_id = ?', [id]);
    // a monthly bill / payment made from a दरमहा reminder: that month is due again
    final st = (await tx.getOptional('SELECT status FROM vouchers WHERE id = ?', [id]))?['status'] as String?;
    if (st != null && st.startsWith(monthlyPrefix)) {
      final parts = st.substring(monthlyPrefix.length).split('|'); // template id | YYYY-MM
      if (parts.length == 2) {
        final tpl = await tx.getOptional('SELECT status, vdate FROM vouchers WHERE id = ? AND deleted = 0', [parts[0]]);
        if (tpl != null && tpl['status'] == 'active:${parts[1]}') {
          final y = int.parse(parts[1].substring(0, 4)), m = int.parse(parts[1].substring(5, 7));
          final prev = m == 1 ? '${y - 1}-12' : '$y-${(m - 1).toString().padLeft(2, '0')}';
          final first = (tpl['vdate'] as String).substring(0, 7);
          await tx.execute('UPDATE vouchers SET status = ?, updated_at = ? WHERE id = ?',
              [prev.compareTo(first) < 0 ? 'active' : 'active:$prev', nowIso(), parts[0]]);
        }
      }
    }
    // its bank statement line is unmatched again (not left pointing at a deleted entry)
    await tx.execute("UPDATE bank_lines SET status = 'open', voucher_id = NULL WHERE voucher_id = ?", [id]);
  }

  /// Entry types whose money can be split over two modes (रोख + फोनपे).
  static const splitTypes = {
    VoucherType.sale, VoucherType.receipt, VoucherType.purchaseReturn, // money in
    VoucherType.purchase, VoucherType.payment, VoucherType.salesReturn, // money out
  };
  static bool _moneyIn(VoucherType t) => t == VoucherType.sale || t == VoucherType.receipt || t == VoucherType.purchaseReturn;

  /// विभागून: [amount] of entry [mainId]'s money came / went by [ledgerId]
  /// instead of the entry's own mode. Kept as a linked transfer between the
  /// two accounts (status `split:<mainId>`), so the party's khata shows one
  /// line and cash and PhonePe are each exact. null / 0 removes the split.
  Future<void> saveSplit(String mainId, Actor actor, {String? ledgerId, int amount = 0}) async {
    final m = await db.get('SELECT vtype, vdate, vno, pay_ledger_id, party_id FROM vouchers WHERE id = ?', [mainId]);
    final type = VoucherType.fromCode(m['vtype'] as String);
    final pay = m['pay_ledger_id'] as String?;
    final existing = (await db.getOptional("SELECT id FROM vouchers WHERE status = ? AND deleted = 0", ['$splitPrefix$mainId']))?['id'] as String?;
    if (ledgerId == null || amount <= 0 || pay == null || ledgerId == pay || !splitTypes.contains(type)) {
      if (existing != null) {
        await db.writeTransaction((tx) => _markDeleted(tx, existing, actor));
      }
      return;
    }
    final party = m['party_id'] == null ? null : (await db.getOptional('SELECT name FROM ledgers WHERE id = ?', [m['party_id']]))?['name'];
    final into = _moneyIn(type);
    final id = await save(
      VoucherInput(
        type: VoucherType.contra,
        date: m['vdate'] as String,
        partyId: into ? ledgerId : pay,
        payLedgerId: into ? pay : ledgerId,
        amount: amount,
        narration: 'विभागून · ${type.code == 'sale' || type.code == 'purchase' ? 'बिल ' : ''}#${m['vno']}${party == null ? '' : ' · $party'}',
      ),
      actor,
      existingId: existing,
    );
    await db.execute('UPDATE vouchers SET status = ? WHERE id = ?', ['$splitPrefix$mainId', id]);
  }

  /// The split of an entry: (second mode, its amount), or null.
  Future<(String, int)?> splitOf(String mainId) async {
    final r = await db.getOptional(
        'SELECT s.party_id, s.pay_ledger_id, s.amount, v.pay_ledger_id AS main_pay FROM vouchers s JOIN vouchers v ON v.id = ? '
        'WHERE s.status = ? AND s.deleted = 0',
        [mainId, '$splitPrefix$mainId']);
    if (r == null) return null;
    final other = r['party_id'] == r['main_pay'] ? r['pay_ledger_id'] : r['party_id'];
    return (other as String, (r['amount'] as int?) ?? 0);
  }

  static bool canEdit(Actor actor, String vdate) =>
      actor.isOwner || vdate.compareTo(todayIso()) >= 0;

  /// Was this entry typed in today (India time)? created_at is stored in UTC.
  static bool enteredToday(String? createdAt) {
    final c = createdAt == null ? null : DateTime.tryParse(createdAt);
    if (c == null) return false;
    final ist = c.toUtc().add(const Duration(hours: 5, minutes: 30));
    final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    return ist.year == now.year && ist.month == now.month && ist.day == now.day;
  }

  void _checkEditable(Actor actor, String vdate, {required bool deleting}) {
    if (actor.isOwner) return;
    if (deleting) throw PermissionDenied('err_owner_delete');
    if (vdate.compareTo(todayIso()) < 0) throw PermissionDenied('err_owner_edit_old');
  }

  Future<int> _nextNo(SqliteWriteContext tx, VoucherType t, String date) async {
    final r = await tx.get(
      'SELECT COALESCE(MAX(vno), 0) AS n FROM vouchers WHERE business_id = ? AND vtype = ? AND vdate >= ?',
      [businessId, t.code, fyStart(date)],
    );
    return (r['n'] as int) + 1;
  }

  /// Readable summary of an entry for the change history (field → text).
  Future<Map<String, Object?>> entrySummary(SqliteReadContext tx, String id) async {
    final v = await tx.getOptional(
      'SELECT v.*, p.name AS party_name, pl.name AS pay_name, tr.name AS transporter_name FROM vouchers v '
      'LEFT JOIN ledgers p ON p.id = v.party_id LEFT JOIN ledgers pl ON pl.id = v.pay_ledger_id '
      'LEFT JOIN ledgers tr ON tr.id = v.transporter_id WHERE v.id = ?',
      [id],
    );
    if (v == null) return {};
    final items = await tx.getAll(
      'SELECT i.name, il.qty, il.rate, il.amount FROM inventory_lines il JOIN items i ON i.id = il.item_id '
      'WHERE il.voucher_id = ? AND il.deleted = 0 ORDER BY il.id',
      [id],
    );
    String money(Object? p) => (p as int? ?? 0) == 0 ? '' : Money.fmt(p as int);
    String q(num x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';
    // every account the entry touches, so no money change (discount, round
    // off, वराई, transporter fare, GST …) can slip past the history
    final postings = await tx.getAll(
      'SELECT l.name, vl.debit, vl.credit FROM voucher_lines vl JOIN ledgers l ON l.id = vl.ledger_id '
      'WHERE vl.voucher_id = ? AND vl.deleted = 0 ORDER BY vl.id',
      [id],
    );
    return {
      'type': v['vtype'],
      'vno': v['vno'],
      'date': v['vdate'],
      'party': v['party_name'],
      'amount': money(v['amount']),
      'paid': money(v['paid']),
      'pay_mode': v['pay_name'],
      'items': [
        for (final i in items) '${i['name']} ${q(i['qty'] as num)}${(i['rate'] as int) > 0 ? '×${Money.fmt(i['rate'] as int)}' : ''}'
      ].join(', '),
      'hamali': money(v['hamali']),
      'transport': money(v['transport']),
      'transporter': v['transporter_name'],
      'gst': money(v['gst']),
      'ref': v['ref_no'],
      'narration': v['narration'],
      'haste': v['haste'],
      // internal links (विभागून part, monthly bill) are not a status to show
      'status': '${v['status'] ?? ''}'.startsWith(splitPrefix) || '${v['status'] ?? ''}'.startsWith(monthlyPrefix) ? null : v['status'],
      'transporter_fare': money(v['transporter_fare']),
      'gst_rate': (v['gst_rate'] as int? ?? 0) == 0 ? '' : '${(v['gst_rate'] as int) / 100}%',
      'gst_bill': (v['gst_bill_needed'] as int? ?? 0) == 1 ? '✓' : '',
      'postings': [
        for (final p in postings)
          '${p['name']} ${(p['debit'] as int) > 0 ? '+${Money.fmt(p['debit'] as int)}' : '−${Money.fmt(p['credit'] as int)}'}'
      ].join(', '),
    };
  }

  static String _entryTitle(Map<String, Object?> s) => '${s['type'] ?? ''}|${s['vno'] ?? ''}|${s['party'] ?? ''}';


  /// Loads a voucher with its item lines (for editing / bill view).
  /// Payment promise kept / broken / reopened. Anyone may record the outcome.
  Future<void> setPromiseStatus(String id, String status) => setStatusLogged(id, status, onlyType: 'promise');

  /// Changes an entry's status (promise kept, booking closed, month charged …)
  /// and writes it to the change history.
  Future<void> setStatusLogged(String id, String status, {String? onlyType}) async {
    final before = await entrySummary(db, id);
    await db.execute(
        'UPDATE vouchers SET status = ?, updated_at = ? WHERE id = ?${onlyType == null ? '' : ' AND vtype = ?'}',
        [status, nowIso(), id, if (onlyType != null) onlyType]);
    final after = await entrySummary(db, id);
    await AuditLog.write(db,
        businessId: businessId, recordId: id, action: 'status', kind: 'voucher', title: _entryTitle(after), before: before, after: after);
  }

  /// Old entries used to move the khata; now they are reference only.
  /// Detaches any lines such entries still have (run by the owner).
  Future<int> detachHistoryLines() async {
    final r = await db.get(
      "SELECT COUNT(*) AS n FROM voucher_lines WHERE deleted = 0 AND voucher_id IN "
      "(SELECT id FROM vouchers WHERE business_id = ? AND vtype = 'history')",
      [businessId],
    );
    final n = r['n'] as int;
    if (n > 0) {
      await db.execute(
        "UPDATE voucher_lines SET deleted = 1 WHERE deleted = 0 AND voucher_id IN "
        "(SELECT id FROM vouchers WHERE business_id = ? AND vtype = 'history')",
        [businessId],
      );
    }
    return n;
  }

  /// वराई received with a purchase (read back from its वराई line).
  Future<int> varhaiOf(Voucher v) async {
    if (v.type != VoucherType.purchase) return 0;
    final r = await db.get(
        'SELECT COALESCE(SUM(credit - debit), 0) AS n FROM voucher_lines WHERE voucher_id = ? AND ledger_id = ? AND deleted = 0',
        [v.id, sys('varhai')]);
    return (r['n'] as num).toInt();
  }

  /// Round off stored on a bill (read back from its round-off line).
  /// The सूट (settlement discount) on a saved जमा / payment.
  Future<int> discountOf(Voucher v) async {
    if (v.type != VoucherType.receipt && v.type != VoucherType.payment) return 0;
    final r = await db.get(
        'SELECT COALESCE(SUM(debit), 0) AS g, COALESCE((SELECT SUM(credit) FROM voucher_lines WHERE voucher_id = ? AND ledger_id = ? AND deleted = 0), 0) AS rcv '
        'FROM voucher_lines WHERE voucher_id = ? AND ledger_id = ? AND deleted = 0',
        [v.id, sys('discount_recd'), v.id, sys('discount_given')]);
    return v.type == VoucherType.receipt ? (r['g'] as num).toInt() : (r['rcv'] as num).toInt();
  }

  /// How much a saved entry moved [ledgerId]'s balance (debit − credit).
  Future<int> effectOn(String voucherId, String ledgerId) async => ((await db.get(
          'SELECT COALESCE(SUM(debit - credit), 0) AS n FROM voucher_lines WHERE voucher_id = ? AND ledger_id = ? AND deleted = 0',
          [voucherId, ledgerId]))['n'] as num)
      .toInt();

  Future<int> roundOffOf(Voucher v) async {
    if (v.type == VoucherType.history) {
      // old entries have no round-off line: work it out from the stored parts
      final g = await db.get('SELECT COALESCE(SUM(amount), 0) AS g, COUNT(*) AS n FROM inventory_lines WHERE voucher_id = ? AND deleted = 0', [v.id]);
      if ((g['n'] as int) == 0) return 0;
      return v.amount - (g['g'] as num).toInt() - v.hamali - v.transport;
    }
    if (v.type != VoucherType.sale && v.type != VoucherType.purchase) return 0;
    final r = await db.get(
        'SELECT COALESCE(SUM(credit - debit), 0) AS n FROM voucher_lines WHERE voucher_id = ? AND ledger_id = ? AND deleted = 0',
        [v.id, sys('round_off')]);
    final n = (r['n'] as num).toInt();
    return v.type == VoucherType.sale ? n : -n;
  }

  /// Entry types that post money (the rest are notes or stock-only).
  static const postingTypes = {
    VoucherType.sale, VoucherType.purchase, VoucherType.salesReturn, VoucherType.purchaseReturn,
    VoucherType.receipt, VoucherType.payment, VoucherType.contra, VoucherType.salary, VoucherType.interest,
  };

  /// A saved entry turned back into the input that made it – exactly what
  /// the edit screen must show. Saving this again must change nothing.
  Future<VoucherInput> inputOf(String id) async {
    final (v, items) = await load(id);
    final ro = await roundOffOf(v);
    final onBill = v.type == VoucherType.sale ? v.hamali + v.transport : 0;
    return VoucherInput(
      type: v.type,
      date: v.date,
      partyId: v.partyId,
      payLedgerId: v.payLedgerId,
      items: items,
      amount: items.isEmpty ? v.amount - onBill - v.gst - ro : 0,
      paid: v.paid,
      discount: await discountOf(v),
      narration: v.narration,
      refNo: v.refNo,
      gstBillNeeded: v.gstBillNeeded,
      hamali: v.hamali,
      transport: v.transport,
      transporterId: v.transporterId,
      transporterFare: v.transporterFare,
      gstRate: v.gstRate,
      roundOff: ro,
      haste: v.haste,
      varhai: await varhaiOf(v),
    );
  }

  /// खोल तपासणी: for every money entry, works out afresh what it should have
  /// posted from its saved details and compares that with the lines in the
  /// books, account by account. Returns (entry, what differs); empty = all good.
  Future<List<(Voucher, String)>> deepCheck() async {
    final rows = await db.getAll(
        'SELECT v.*, p.name AS party_name FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id '
        'WHERE v.business_id = ? AND v.deleted = 0 ORDER BY v.vdate, v.created_at',
        [businessId]);
    final services = {
      for (final r in await db.getAll('SELECT id FROM items WHERE business_id = ? AND category = ?', [businessId, serviceCategory]))
        r['id'] as String
    };
    final names = {
      for (final r in await db.getAll('SELECT id, name FROM ledgers WHERE business_id = ?', [businessId])) r['id'] as String: r['name'] as String
    };
    // goods and services are one bucket: an item may have been moved between them later
    String bucket(String id) => id == sys('service_income') ? sys('sales') : id == sys('service_cost') ? sys('purchase') : id;
    final bad = <(Voucher, String)>[];
    for (final r in rows) {
      final v = Voucher.fromRow(r);
      final actual = <String, int>{};
      var net = 0;
      for (final l in await db.getAll('SELECT ledger_id, debit, credit FROM voucher_lines WHERE voucher_id = ? AND deleted = 0', [v.id])) {
        final d = ((l['debit'] as int?) ?? 0) - ((l['credit'] as int?) ?? 0);
        actual[bucket(l['ledger_id'] as String)] = (actual[bucket(l['ledger_id'] as String)] ?? 0) + d;
        net += d;
      }
      actual.removeWhere((_, x) => x == 0);
      if (!postingTypes.contains(v.type)) {
        // notes and stock-only entries must never touch money
        if (v.type != VoucherType.journal && actual.isNotEmpty) bad.add((v, 'note entry has money lines'));
        continue;
      }
      if (net != 0) {
        bad.add((v, 'debit ≠ credit by ${Money.fmt(net.abs())}'));
        continue;
      }
      final VoucherInput input;
      final expected = <String, int>{};
      try {
        input = await inputOf(v.id);
        for (final l in buildLines(input, services: services)) {
          expected[bucket(l.ledgerId)] = (expected[bucket(l.ledgerId)] ?? 0) + l.debit - l.credit;
        }
      } catch (e) {
        bad.add((v, 'cannot be rebuilt: $e'));
        continue;
      }
      expected.removeWhere((_, x) => x == 0);
      final diffs = [
        for (final k in {...expected.keys, ...actual.keys})
          if ((expected[k] ?? 0) != (actual[k] ?? 0))
            '${names[k] ?? k}: ${Money.fmt(actual[k] ?? 0)} ≠ ${Money.fmt(expected[k] ?? 0)}',
      ];
      if (input.total != v.amount && v.type != VoucherType.salary) diffs.add('total ${Money.fmt(v.amount)} ≠ ${Money.fmt(input.total)}');
      if (diffs.isNotEmpty) bad.add((v, diffs.join('; ')));
    }
    // a विभागून part must belong to a live entry and be smaller than its money
    for (final r in await db.getAll(
        "SELECT s.*, m.deleted AS m_deleted, m.paid AS m_paid, m.vdate AS m_date FROM vouchers s "
        "LEFT JOIN vouchers m ON m.id = substr(s.status, ${splitPrefix.length + 1}) "
        "WHERE s.business_id = ? AND s.deleted = 0 AND s.status LIKE '$splitPrefix%'",
        [businessId])) {
      final why = r['m_deleted'] == null || r['m_deleted'] == 1
          ? 'split part without its entry'
          : ((r['amount'] as int?) ?? 0) >= ((r['m_paid'] as int?) ?? 0)
              ? 'split part is not smaller than the money paid'
              : r['m_date'] != r['vdate']
                  ? 'split part on a different date'
                  : null;
      if (why != null) bad.add((Voucher.fromRow(r), why));
    }
    return bad;
  }

  Future<(Voucher, List<ItemLine>)> load(String id) async {
    final v = Voucher.fromRow(await db.get('SELECT * FROM vouchers WHERE id = ?', [id]));
    final items = await db.getAll(
        // lines in the order they were typed (ids end in I0, I1 … I10)
        'SELECT item_id, qty, rate, amount, direction FROM inventory_lines WHERE voucher_id = ? AND deleted = 0 ORDER BY LENGTH(id), id',
        [id]);
    return (
      v,
      [
        for (final r in items)
          ItemLine(
            r['item_id'] as String,
            (r['qty'] as num).toDouble() *
                (v.type == VoucherType.stockAdjust ? (r['direction'] as int) : 1),
            r['rate'] as int,
            amount: v.type == VoucherType.stockAdjust ? null : r['amount'] as int?,
          )
      ]
    );
  }
}
