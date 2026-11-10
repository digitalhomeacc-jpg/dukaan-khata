import 'package:sqlite_async/sqlite_async.dart';

import '../core/money.dart';
import 'models.dart';
import 'voucher_service.dart';

/// pay_ledger_id marker telling a customer booking from a supplier booking.
const bookingSaleMarker = 'book:sale';
const bookingPurchaseMarker = 'book:purchase';

class BookingLine {
  final Item item;
  final double qty;
  final int rate; // paise per unit – the locked rate
  double delivered = 0;
  BookingLine(this.item, this.qty, this.rate);
  double get remaining => (qty - delivered) > 0.0001 ? qty - delivered : 0;
  int get value => (qty * rate).round();
}

/// बुकिंग: goods booked at a fixed rate. The advance is an ordinary receipt /
/// payment on the khata; deliveries are the party's sale / purchase bills of
/// the same item from the booking date on, counted oldest booking first.
class Booking {
  final String id;
  final String date;
  final String partyId;
  final String partyName;
  final String? partyNameEn;
  final String? pageNo;
  final bool customer; // true: they booked from us; false: we booked from a supplier
  final int advance; // paid with the booking (for display; the money is on the khata)
  final String? note;
  final bool closed;
  final List<BookingLine> lines;
  Booking(this.id, this.date, this.partyId, this.partyName, this.partyNameEn, this.pageNo, this.customer, this.advance,
      this.note, this.closed, this.lines);

  int get value => lines.fold(0, (s, l) => s + l.value);
  bool get done => lines.every((l) => l.remaining == 0);
  bool get open => !closed && !done;
  /// Dated before the books start: a note only (advance already in the opening balance).
  bool get old => Books.isHistory(date);
}

class BookingService {
  final SqliteConnection db;
  final String businessId;
  BookingService(this.db, this.businessId);

  /// All bookings with what has been delivered against each line.
  Future<List<Booking>> list({bool? customer, String? partyId}) async {
    final items = {
      for (final r in await db.getAll('SELECT * FROM items WHERE business_id = ?', [businessId])) r['id'] as String: Item.fromRow(r)
    };
    final rows = await db.getAll(
      'SELECT v.id, v.vdate, v.created_at, v.party_id, v.pay_ledger_id, v.paid, v.narration, v.status, '
      'p.name AS party_name, p.name_en AS party_name_en, p.page_no '
      'FROM vouchers v LEFT JOIN ledgers p ON p.id = v.party_id '
      "WHERE v.business_id = ? AND v.vtype = 'booking' AND v.deleted = 0 "
      '${partyId != null ? 'AND v.party_id = ? ' : ''}'
      'ORDER BY v.vdate, v.created_at',
      [businessId, if (partyId != null) partyId],
    );
    if (rows.isEmpty) return [];
    final ids = rows.map((r) => r['id'] as String).toList();
    final lineRows = await db.getAll(
      'SELECT voucher_id, item_id, qty, rate FROM inventory_lines WHERE deleted = 0 AND voucher_id IN '
      '(${List.filled(ids.length, '?').join(',')}) ORDER BY id',
      ids,
    );
    final byVoucher = <String, List<BookingLine>>{};
    for (final l in lineRows) {
      final it = items[l['item_id']];
      if (it == null) continue;
      (byVoucher[l['voucher_id'] as String] ??= []).add(BookingLine(it, (l['qty'] as num).toDouble(), l['rate'] as int));
    }
    final all = [
      for (final r in rows)
        Booking(
          r['id'] as String,
          r['vdate'] as String,
          r['party_id'] as String,
          (r['party_name'] as String?) ?? '?',
          r['party_name_en'] as String?,
          r['page_no'] as String?,
          r['pay_ledger_id'] != bookingPurchaseMarker,
          (r['paid'] as int?) ?? 0,
          r['narration'] as String?,
          r['status'] == 'closed',
          byVoucher[r['id']] ?? [],
        ),
    ];
    await _countDeliveries(all.where((b) => !b.closed).toList());
    return all.where((b) => customer == null || b.customer == customer).toList();
  }

  /// Open bookings with something still to deliver – for the bill screen.
  Future<List<Booking>> openFor(String partyId, {required bool customer}) async =>
      (await list(customer: customer, partyId: partyId)).where((b) => b.open).toList();

  /// Deliveries (sale bills for customers, purchase bills for suppliers) of
  /// a booked item, from the booking date on, fill the oldest booking first.
  Future<void> _countDeliveries(List<Booking> open) async {
    final groups = <String, List<(Booking, BookingLine)>>{};
    for (final b in open) {
      for (final l in b.lines) {
        (groups['${b.partyId}|${b.customer}|${l.item.id}'] ??= []).add((b, l));
      }
    }
    for (final g in groups.values) {
      final (first, line) = g.first;
      final rows = await db.getAll(
        'SELECT il.vdate, il.qty FROM inventory_lines il JOIN vouchers v ON v.id = il.voucher_id '
        'WHERE v.party_id = ? AND il.item_id = ? AND il.deleted = 0 AND v.deleted = 0 AND v.vtype = ? AND il.vdate >= ? '
        'ORDER BY il.vdate, v.created_at',
        [first.partyId, line.item.id, first.customer ? 'sale' : 'purchase', first.date],
      );
      for (final r in rows) {
        var q = (r['qty'] as num).toDouble();
        final d = r['vdate'] as String;
        for (final (b, l) in g) {
          if (q <= 0) break;
          if (b.date.compareTo(d) > 0 || l.remaining == 0) continue;
          final take = q < l.remaining ? q : l.remaining;
          l.delivered += take;
          q -= take;
        }
      }
    }
  }

  /// Booking + its advance (a receipt from a customer / payment to a supplier).
  Future<String> save(
    VoucherService vs,
    Actor actor, {
    String? existingId,
    required String date,
    required String partyId,
    required bool customer,
    required List<ItemLine> items,
    int advance = 0,
    String? advanceLedgerId,
    String? note,
  }) async {
    final id = await vs.save(
      VoucherInput(
        type: VoucherType.booking,
        date: date,
        partyId: partyId,
        payLedgerId: customer ? bookingSaleMarker : bookingPurchaseMarker,
        items: items,
        paid: advance,
        narration: note,
      ),
      actor,
      existingId: existingId,
    );
    // before the books start the advance is already in the opening balance:
    // the booking is only a note, no receipt / payment is made
    if (advance > 0 && existingId == null && !Books.isHistory(date)) {
      await vs.save(
        VoucherInput(
          type: customer ? VoucherType.receipt : VoucherType.payment,
          date: date,
          partyId: partyId,
          payLedgerId: advanceLedgerId,
          amount: advance,
          narration: '${customer ? 'बुकिंग आगाऊ' : 'बुकिंग आगाऊ दिले'}${note == null ? '' : ' · $note'}',
        ),
        actor,
      );
    }
    return id;
  }

  Future<void> setClosed(String id, bool closed) =>
      VoucherService(db, businessId).setStatusLogged(id, closed ? 'closed' : 'open', onlyType: 'booking');
}
