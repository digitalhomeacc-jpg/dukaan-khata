import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';

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
class VoucherService {
  final SqliteConnection db;
  final String businessId;
  VoucherService(this.db, this.businessId);

  String sys(String key) => systemLedgerId(businessId, key);

  /// Builds the debit/credit lines for an input. Pure – unit-testable.
  List<MoneyLine> buildLines(VoucherInput v) {
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
        cr(sys('sales'), v.goods);
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
        dr(sys('purchase'), v.goods);
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
    final lines = buildLines(v);
    final goodsLoan = v.type.isGoodsLoan;
    final total = goodsLoan ? 0 : v.total; // उसना माल has no money value
    if (goodsLoan && !v.items.any((i) => i.qty != 0)) throw ArgumentError('err_items');
    final goodsOpening = goodsLoan && v.payLedgerId == goodsOpeningMarker;
    if (goodsOpening) {
      if (!actor.isOwner) throw PermissionDenied('err_owner_opening_goods');
      if (v.date != Books.start) throw ArgumentError('err_opening_goods_date');
    }
    final today = todayIso();
    if (!actor.isOwner && v.date.compareTo(today) < 0) {
      throw PermissionDenied('err_staff_today');
    }
    if (v.type == VoucherType.history) {
      if (v.total <= 0 && v.paid <= 0) throw ArgumentError('err_amount');
    } else if (v.type == VoucherType.promise) {
      // amount is optional ("will pay something on Monday")
    } else if (v.items.isEmpty && lines.isEmpty && v.type != VoucherType.stockAdjust) {
      throw ArgumentError('err_amount');
    }
    if (v.type == VoucherType.history) {
      if (!actor.isOwner) throw PermissionDenied('err_owner_old');
      if (!Books.isHistory(v.date)) {
        throw ArgumentError('err_old_date');
      }
    } else if (Books.isHistory(v.date)) {
      throw ArgumentError('err_before_books');
    }
    if (v.gstApplies && !actor.isOwner) throw PermissionDenied('err_owner_gst');

    return db.writeTransaction((tx) async {
      final now = nowIso();
      String id;
      int version = 1;
      if (existingId != null) {
        final old = await tx.get('SELECT * FROM vouchers WHERE id = ?', [existingId]);
        _checkEditable(actor, old['vdate'] as String, deleting: false);
        await _audit(tx, existingId, 'edit', actor, old);
        await tx.execute('DELETE FROM voucher_lines WHERE voucher_id = ?', [existingId]);
        await tx.execute('DELETE FROM inventory_lines WHERE voucher_id = ?', [existingId]);
        version = ((old['version'] as int?) ?? 1) + 1;
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
        await _audit(tx, id, 'create', actor, null);
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
        final d = v.type == VoucherType.stockAdjust ? (it.qty >= 0 ? 1 : -1) : dir;
        // old bills keep their item lines for the record, with no stock effect
        if (d == 0 && v.type != VoucherType.history && !goodsOpening) continue;
        if (it.qty == 0) continue;
        await tx.execute(
          'INSERT INTO inventory_lines (id, business_id, voucher_id, item_id, qty, rate, amount, direction, vdate, deleted) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
          ['$id:I${n++}', businessId, id, it.itemId, it.qty.abs(), goodsLoan ? 0 : it.rate, goodsLoan ? 0 : it.amount.abs(), d, v.date],
        );
      }
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
        v.type == VoucherType.promise ? 'open' : null,
      ];

  int _paidFor(VoucherInput v, int total) => switch (v.type) {
        VoucherType.receipt || VoucherType.payment || VoucherType.contra => total,
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
      await _audit(tx, id, 'delete', actor, old);
      await tx.execute('UPDATE vouchers SET deleted = 1, updated_at = ? WHERE id = ?', [nowIso(), id]);
      await tx.execute('UPDATE voucher_lines SET deleted = 1 WHERE voucher_id = ?', [id]);
      await tx.execute('UPDATE inventory_lines SET deleted = 1 WHERE voucher_id = ?', [id]);
    });
  }

  static bool canEdit(Actor actor, String vdate) =>
      actor.isOwner || vdate.compareTo(todayIso()) >= 0;

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

  Future<void> _audit(SqliteWriteContext tx, String voucherId, String action, Actor actor,
      Map<String, Object?>? snapshot) async {
    String? snap;
    if (snapshot != null) {
      final lines = await tx.getAll(
          'SELECT ledger_id, debit, credit FROM voucher_lines WHERE voucher_id = ?', [voucherId]);
      final items = await tx.getAll(
          'SELECT item_id, qty, rate, amount FROM inventory_lines WHERE voucher_id = ?', [voucherId]);
      snap = jsonEncode({
        'voucher': Map<String, Object?>.from(snapshot),
        'lines': [for (final l in lines) Map<String, Object?>.from(l)],
        'items': [for (final i in items) Map<String, Object?>.from(i)],
      });
    }
    await tx.execute(
      'INSERT INTO audit_log (id, business_id, voucher_id, action, user_id, user_name, at, snapshot) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [newId(), businessId, voucherId, action, actor.userId, actor.name, nowIso(), snap],
    );
  }

  /// Loads a voucher with its item lines (for editing / bill view).
  /// Payment promise kept / broken / reopened. Anyone may record the outcome.
  Future<void> setPromiseStatus(String id, String status) => db.execute(
      "UPDATE vouchers SET status = ?, updated_at = ? WHERE id = ? AND vtype = 'promise'", [status, nowIso(), id]);

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

  Future<(Voucher, List<ItemLine>)> load(String id) async {
    final v = Voucher.fromRow(await db.get('SELECT * FROM vouchers WHERE id = ?', [id]));
    final items = await db.getAll(
        'SELECT item_id, qty, rate, amount, direction FROM inventory_lines WHERE voucher_id = ? AND deleted = 0', [id]);
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
