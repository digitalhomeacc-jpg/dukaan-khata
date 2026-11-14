import 'dart:math';

import 'package:dukaan_khata/accounting/health.dart';
import 'package:dukaan_khata/accounting/ledger_repo.dart';
import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/accounting/stock_pnl.dart';
import 'package:dukaan_khata/accounting/voucher_service.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/inventory/stock_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'test_db.dart';

/// Balances must be perfect. This test makes thousands of random entries,
/// edits, re-saves, split payments and deletes, and after every step checks
/// the books against an independent calculation (a plain "who owes what"
/// tally kept beside the app, written without the app's posting code).
const biz = 'fuzz';
const owner = Actor(userId: 'u1', name: 'Owner', isOwner: true);

/// What one entry does, worked out the simple way.
class Effect {
  final ledgers = <String, int>{}; // + = balance goes up (debit side)
  final stock = <String, double>{};
  void l(String? id, int amt) {
    if (id != null && amt != 0) ledgers[id] = (ledgers[id] ?? 0) + amt;
  }
}

void main() {
  late SqliteDatabase db;
  late VoucherService vs;
  late LedgerRepo lr;
  late StockRepo sr;

  setUp(() async {
    Books.start = '2026-04-01';
    Books.fyStartMonth = 4;
    db = await openTestDb(biz);
    vs = VoucherService(db, biz);
    lr = LedgerRepo(db, biz);
    sr = StockRepo(db, biz);
  });
  tearDown(() => db.close());

  Future<Map<String, Object?>> snapshot() async => {
        for (final r in await db.getAll(
            'SELECT l.id, l.opening_balance + COALESCE((SELECT SUM(debit - credit) FROM voucher_lines WHERE ledger_id = l.id AND deleted = 0), 0) AS b '
            'FROM ledgers l WHERE l.business_id = ?',
            [biz]))
          'L:${r['id']}': r['b'],
        for (final i in await sr.list()) 'S:${i.id}': i.stock,
        for (final r in await db.getAll(
            'SELECT id, vtype, vdate, party_id, pay_ledger_id, amount, paid, hamali, transport, transporter_id, transporter_fare, gst_rate, gst, '
            'narration, ref_no, haste, status, deleted FROM vouchers WHERE business_id = ?',
            [biz]))
          'V:${r['id']}': r.values.join('|'),
        for (final r in await db.getAll(
            'SELECT voucher_id, ledger_id, SUM(debit) AS d, SUM(credit) AS c FROM voucher_lines WHERE deleted = 0 GROUP BY voucher_id, ledger_id'))
          'P:${r['voucher_id']}:${r['ledger_id']}': '${r['d']}/${r['c']}',
        for (final r in await db.getAll('SELECT id, item_id, qty, rate, amount, direction FROM inventory_lines WHERE deleted = 0'))
          'I:${r['id']}': r.values.join('|'),
      };

  for (final seed in [1, 7, 42, 2026]) {
    test('random entries, edits, splits and deletes keep every balance exact (seed $seed)', () async {
      final rnd = Random(seed);
      T pick<T>(List<T> l) => l[rnd.nextInt(l.length)];
      bool chance(int pct) => rnd.nextInt(100) < pct;
      int rupees(int max) => (1 + rnd.nextInt(max)) * 100;

      final cash = vs.sys('cash'), pe = vs.sys('upi_h'), bank = vs.sys('bank');
      final money = [cash, pe, bank];
      final customers = [for (var i = 0; i < 4; i++) await lr.create(name: 'Cust $i', group: LedgerGroup.customer, openingBalance: i * 100000)];
      final suppliers = [for (var i = 0; i < 3; i++) await lr.create(name: 'Sup $i', group: LedgerGroup.supplier, openingBalance: -i * 50000)];
      final drivers = [for (var i = 0; i < 2; i++) await lr.create(name: 'Driver $i', group: LedgerGroup.transporter)];
      final staff = await lr.create(name: 'Helper', group: LedgerGroup.staff);
      final service = await sr.save(name: 'Work', category: serviceCategory, unit: 'job', saleRate: 50000);
      final goods = (await sr.list()).where((i) => !i.isService).take(5).toList();
      final services = {service};

      // the independent tally
      final opening = {for (final r in await db.getAll('SELECT id, opening_balance FROM ledgers WHERE business_id = ?', [biz])) r['id'] as String: (r['opening_balance'] as int?) ?? 0};
      final stock0 = {for (final i in await sr.list()) i.id: i.stock};
      final effects = <String, Effect>{}; // entry id → its effect
      final splits = <String, (String, int)>{}; // entry id → (other mode, amount)
      final inputs = <String, VoucherInput>{};

      List<ItemLine> randomLines() => [
            for (var n = 0; n <= rnd.nextInt(3); n++)
              () {
                final svc = chance(15);
                final id = svc ? service : pick(goods).id;
                final qty = chance(30) ? (1 + rnd.nextInt(4000)) / 1000 * 10 : (1 + rnd.nextInt(60)).toDouble(); // 12.345 kg or 15 bags
                final rate = pick([27500, 28500, 6250, 6175, 9050, 100, 33333]);
                return chance(20) ? ItemLine.fromTotal(id, qty, rupees(9000)) : ItemLine(id, qty, rate);
              }()
          ];

      VoucherInput randomInput(VoucherType type) {
        final today = todayIso();
        switch (type) {
          case VoucherType.sale:
          case VoucherType.purchase:
          case VoucherType.salesReturn:
          case VoucherType.purchaseReturn:
            final selling = type == VoucherType.sale || type == VoucherType.salesReturn;
            final party = chance(25) ? null : pick(selling ? customers : suppliers);
            final lines = randomLines();
            final bill = type == VoucherType.sale || type == VoucherType.purchase;
            final hamali = type == VoucherType.sale && chance(40) ? rupees(5) * 10 : 0;
            final transport = type == VoucherType.sale && chance(40) ? rupees(15) * 10 : 0;
            final driver = transport > 0 && chance(50) ? pick(drivers) : null;
            final gstRate = bill && chance(20) ? pick([500, 1200, 1800, 2800]) : 0;
            final roundOff = bill && chance(30) ? (rnd.nextInt(19) - 9) * 100 : 0;
            final draft = VoucherInput(type: type, date: today, partyId: party, items: lines, hamali: hamali, transport: transport, gstRate: gstRate, roundOff: roundOff);
            final total = draft.total;
            // on credit / part paid / paid in full (a cash bill without a name is always paid)
            final mode = party == null ? 2 : rnd.nextInt(3);
            final pay = mode == 0 ? null : pick(money);
            final paid = mode == 0 ? 0 : mode == 1 ? (total ~/ 300) * 100 : total;
            return VoucherInput(
              type: type,
              date: today,
              partyId: party,
              payLedgerId: pay,
              items: lines,
              paid: paid < 0 ? 0 : paid,
              hamali: hamali,
              transport: transport,
              transporterId: driver,
              transporterFare: driver == null ? null : (chance(50) ? transport : (transport * 0.8).round() ~/ 100 * 100),
              gstRate: gstRate,
              roundOff: roundOff,
              varhai: type == VoucherType.purchase && chance(30) ? rupees(8) * 10 : 0,
              varhaiLedgerId: chance(50) ? pick(money) : null,
              haste: chance(20) ? 'Ramu' : null,
              narration: chance(30) ? 'note ${rnd.nextInt(99)}' : null,
            );
          case VoucherType.receipt:
            return VoucherInput(type: type, date: today, partyId: pick([...customers, ...suppliers]), payLedgerId: pick(money), amount: rupees(40000), discount: chance(30) ? rupees(50) : 0);
          case VoucherType.payment:
            return VoucherInput(
                type: type, date: today, partyId: pick([...suppliers, ...customers, ...drivers, vs.sys('hamali'), vs.sys('freight')]), payLedgerId: pick(money), amount: rupees(40000),
                discount: chance(20) ? rupees(50) : 0);
          case VoucherType.contra:
            final from = pick(money);
            return VoucherInput(type: type, date: today, partyId: pick(money.where((m) => m != from).toList()), payLedgerId: from, amount: rupees(20000));
          case VoucherType.salary:
            final sal = (5000 + rnd.nextInt(10000)) * 100; // ₹5,000 – 15,000
            return VoucherInput(type: type, date: today, partyId: staff, payLedgerId: pick(money), amount: sal, paid: sal - (chance(40) ? rupees(20) * 100 : 0));
          default:
            return VoucherInput(type: VoucherType.interest, date: today, partyId: pick(customers), amount: rupees(900));
        }
      }

      /// The plain-arithmetic effect of an entry (no app posting code).
      Effect effectOf(VoucherInput v, (String, int)? split) {
        final e = Effect();
        final goodsValue = v.items.isEmpty ? v.amount : v.items.fold<int>(0, (s, l) => s + l.amount);
        final gst = v.gstRate > 0 ? ((goodsValue * v.gstRate / 10000) / 100).round() * 100 : 0;
        final pay = v.payLedgerId ?? cash;
        final dir = v.type.stockDirection;
        for (final l in v.items) {
          if (!services.contains(l.itemId)) e.stock[l.itemId] = (e.stock[l.itemId] ?? 0) + dir * l.qty;
        }
        switch (v.type) {
          case VoucherType.sale:
            final total = goodsValue + v.hamali + v.transport + gst + v.roundOff;
            if (v.partyId == null) {
              e.l(pay, total);
            } else {
              e.l(v.partyId, total - v.paid);
              e.l(pay, v.paid);
            }
            if (v.transporterId != null && v.transport != 0) e.l(v.transporterId, -(v.transporterFare ?? v.transport));
          case VoucherType.purchase:
            final total = goodsValue + gst + v.roundOff;
            if (v.partyId == null) {
              e.l(pay, -total);
            } else {
              e.l(v.partyId, -(total - v.paid));
              e.l(pay, -v.paid);
            }
            e.l(v.varhaiLedgerId ?? cash, v.varhai);
          case VoucherType.salesReturn:
            if (v.partyId == null) {
              e.l(pay, -goodsValue);
            } else {
              e.l(v.partyId, -(goodsValue - v.paid));
              e.l(pay, -v.paid);
            }
          case VoucherType.purchaseReturn:
            if (v.partyId == null) {
              e.l(pay, goodsValue);
            } else {
              e.l(v.partyId, goodsValue - v.paid);
              e.l(pay, v.paid);
            }
          case VoucherType.receipt:
            e.l(pay, v.amount);
            e.l(v.partyId, -(v.amount + v.discount));
          case VoucherType.payment:
            e.l(pay, -v.amount);
            e.l(v.partyId, v.amount + v.discount);
          case VoucherType.contra:
            e.l(v.partyId, v.amount);
            e.l(pay, -v.amount);
          case VoucherType.salary:
            e.l(v.partyId, -(v.amount - v.paid));
            e.l(pay, -v.paid);
          case VoucherType.interest:
            e.l(v.partyId, v.amount);
          default:
            break;
        }
        if (split != null) {
          final moneyIn = v.type == VoucherType.sale || v.type == VoucherType.receipt || v.type == VoucherType.purchaseReturn;
          e.l(pay, moneyIn ? -split.$2 : split.$2);
          e.l(split.$1, moneyIn ? split.$2 : -split.$2);
        }
        return e;
      }

      int moneyOf(VoucherInput v) => switch (v.type) {
            VoucherType.receipt || VoucherType.payment => v.amount,
            _ => v.partyId == null ? v.total : v.paid,
          };

      /// What the entry screen does after saving: keep, change or drop the split.
      Future<void> applySplit(String id, VoucherInput v, (String, int)? want) async {
        final ok = want != null && VoucherService.splitTypes.contains(v.type) && v.payLedgerId != null && want.$1 != v.payLedgerId && want.$2 > 0 && want.$2 < moneyOf(v);
        await vs.saveSplit(id, owner, ledgerId: ok ? want.$1 : null, amount: ok ? want.$2 : 0);
        ok ? splits[id] = want : splits.remove(id);
      }

      Future<void> check(String what) async {
        // 1. the books balance as a whole
        final net = (await db.get('SELECT COALESCE(SUM(debit - credit), 0) AS n FROM voucher_lines WHERE deleted = 0'))['n'] as int;
        expect(net, 0, reason: 'debit ≠ credit after $what');
        // 2. every party, cash / bank account and item matches the independent tally
        final want = Map<String, int>.from(opening);
        final wantStock = Map<String, double>.from(stock0);
        for (final e in effects.entries) {
          final eff = effectOf(inputs[e.key]!, splits[e.key]);
          eff.ledgers.forEach((k, x) => want[k] = (want[k] ?? 0) + x);
          eff.stock.forEach((k, x) => wantStock[k] = (wantStock[k] ?? 0) + x);
        }
        for (final id in [...customers, ...suppliers, ...drivers, staff, ...money]) {
          expect(await lr.balanceAt(id), want[id] ?? 0, reason: 'balance of $id after $what');
        }
        for (final i in await sr.list()) {
          expect(i.stock, closeTo(wantStock[i.id] ?? 0, 1e-6), reason: 'stock of ${i.name} after $what');
        }
      }

      const types = [
        VoucherType.sale, VoucherType.sale, VoucherType.sale, VoucherType.purchase, VoucherType.receipt, VoucherType.receipt,
        VoucherType.payment, VoucherType.salesReturn, VoucherType.purchaseReturn, VoucherType.contra, VoucherType.salary, VoucherType.interest,
      ];
      for (var step = 0; step < 400; step++) {
        final live = effects.keys.toList();
        final op = live.isEmpty ? 0 : rnd.nextInt(100);
        if (op < 45) {
          // new entry (sometimes paid by two modes)
          final v = randomInput(pick(types));
          final id = await vs.save(v, owner);
          inputs[id] = v;
          effects[id] = Effect();
          final m = moneyOf(v);
          await applySplit(id, v, chance(25) && m > 200 ? (pick(money), (m ~/ 300) * 100) : null);
          await check('new ${v.type.code}');
        } else if (op < 65) {
          // edit: same kind, new details – the split is carried like the screen does
          final id = pick(live);
          final v = randomInput(inputs[id]!.type);
          await vs.save(v, owner, existingId: id);
          inputs[id] = v;
          await applySplit(id, v, splits[id]);
          await check('edit ${v.type.code}');
        } else if (op < 85) {
          // open and save unchanged: nothing at all may move
          final id = pick(live);
          final before = await snapshot();
          final again = await vs.inputOf(id);
          await vs.save(again, owner, existingId: id);
          await applySplit(id, again, splits[id]);
          final after = await snapshot();
          for (final k in {...before.keys, ...after.keys}) {
            expect(after[k], before[k], reason: 're-saving ${inputs[id]!.type.code} unchanged moved $k');
          }
          await check('re-save');
        } else if (op < 92) {
          // change / remove the split
          final id = pick(live);
          final m = moneyOf(inputs[id]!);
          await applySplit(id, inputs[id]!, chance(50) && m > 200 ? (pick(money), (m ~/ 400) * 100) : null);
          await check('split');
        } else {
          final id = pick(live);
          await vs.delete(id, owner);
          effects.remove(id);
          inputs.remove(id);
          splits.remove(id);
          await check('delete');
        }
        if (step % 50 == 49) {
          final bad = await vs.deepCheck();
          expect(bad.map((b) => '${b.$1.type.code}: ${b.$2}').toList(), isEmpty, reason: 'deep check at step $step');
          expect(await lr.unbalanced(), isEmpty);
        }
      }
      expect((await vs.deepCheck()).map((b) => '${b.$1.type.code}: ${b.$2}').toList(), isEmpty);
      // the full health check must stay silent on books made the normal way
      final health = await HealthCheck(db, biz, vs, lr, sr).run();
      expect(health.map((i) => '${i.kind} ${i.title}: ${i.detail}').toList(), isEmpty);
      // item-wise profit adds up to the accounts to the paise
      final pnl = await StockPnlEngine(db, biz).compute(todayIso());
      expect(pnl.salesGap, 0);
      expect(pnl.purchaseGap, 0);
      expect(pnl.accountsProfit, pnl.netProfit);
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('deep check catches an entry whose postings no longer match its details', () async {
    final c = await lr.create(name: 'C', group: LedgerGroup.customer);
    final w = (await sr.list()).first;
    final id = await vs.save(
        VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: c, payLedgerId: vs.sys('cash'), paid: 100000, items: [ItemLine(w.id, 10, 28000)]), owner);
    expect(await vs.deepCheck(), isEmpty);
    // damage: the bill says ₹1,000 was paid but the books moved ₹800
    await db.execute('UPDATE voucher_lines SET debit = 80000 WHERE voucher_id = ? AND ledger_id = ?', [id, vs.sys('cash')]);
    await db.execute('UPDATE voucher_lines SET credit = 80000 WHERE voucher_id = ? AND ledger_id = ? AND credit = 100000', [id, c]);
    final bad = await vs.deepCheck();
    expect(bad.length, 1);
    expect(bad.single.$2, contains('≠'));
    expect(Money.fmt(0), '0');
  });

  test('health check finds each kind of silent damage', () async {
    final hc = HealthCheck(db, biz, vs, lr, sr);
    final c = await lr.create(name: 'C', group: LedgerGroup.customer, openingBalance: 50000);
    final w = (await sr.list()).first;
    Future<String> sale(int paid) => vs.save(
        VoucherInput(type: VoucherType.sale, date: todayIso(), partyId: c, payLedgerId: vs.sys('cash'), paid: paid, items: [ItemLine(w.id, 10, 28000)]),
        owner);
    final a = await sale(100000), b = await sale(0), d = await sale(5000);
    await lr.update(vs.sys('cash'), name: 'रोख', openingBalance: 2077800);
    await sr.save(id: w.id, name: w.name, category: w.category, unit: w.unit, saleRate: w.saleRate, purchaseRate: w.purchaseRate,
        openingQty: 40, openingRate: 25000, lowStock: 0);
    await vs.delete(d, owner);
    expect((await hc.run()).map((i) => '${i.kind} ${i.title}: ${i.detail}').toList(), isEmpty);

    // 1. an account blanked without a history line (the Nov 2026 bug)
    await db.execute('UPDATE ledgers SET opening_balance = 0 WHERE id = ?', [vs.sys('cash')]);
    // 2. an item's opening stock changed silently
    await db.execute('UPDATE items SET opening_qty = 4 WHERE id = ?', [w.id]);
    // 3. a bill's amount changed silently (its lines no longer match either)
    await db.execute('UPDATE vouchers SET amount = 1 WHERE id = ?', [a]);
    // 4. a deleted bill's money lines came back
    await db.execute('UPDATE voucher_lines SET deleted = 0 WHERE voucher_id = ?', [d]);
    // 5. a bill vanished without a history line
    await db.execute('UPDATE vouchers SET deleted = 1 WHERE id = ?', [b]);
    final found = await hc.run();
    String kinds() => found.map((i) => '${i.kind}:${i.title}').join(' | ');
    expect(found.where((i) => i.kind == 'account' && i.fix!.changes.containsKey('opening_balance')).length, 1, reason: kinds());
    expect(found.where((i) => i.kind == 'item' && i.itemFix!.changes.containsKey('opening_qty')).length, 1, reason: kinds());
    expect(found.where((i) => i.kind == 'entry' && i.voucherId == a && i.detail.contains('amount')).length, 1, reason: kinds());
    expect(found.where((i) => i.kind == 'orphan' && i.voucherId == d).length, 1, reason: kinds());
    expect(found.where((i) => i.kind == 'entry' && i.voucherId == b && i.detail.contains('deleted')).length, 1, reason: kinds());

    // the fixes put everything back and the check goes quiet again
    for (final i in found) {
      if (i.fix != null) await lr.repair([i.fix!]);
      if (i.itemFix != null) await sr.putBack(i.itemFix!.id, {for (final e in i.itemFix!.changes.entries) e.key: e.value.$2});
      if (i.lineIds.isNotEmpty) await hc.dropOrphanLines(i);
    }
    expect((await db.get('SELECT opening_balance o FROM ledgers WHERE id = ?', [vs.sys('cash')]))['o'], 2077800);
    expect((await db.get('SELECT opening_qty q FROM items WHERE id = ?', [w.id]))['q'], 40);
    await db.execute('UPDATE vouchers SET amount = 280000 WHERE id = ?', [a]); // owner corrects the bill
    await db.execute('UPDATE vouchers SET deleted = 0 WHERE id = ?', [b]); // and brings back the vanished bill
    await db.execute('UPDATE voucher_lines SET deleted = 0 WHERE voucher_id = ?', [b]);
    expect((await hc.run()).map((i) => '${i.kind} ${i.title}: ${i.detail}').toList(), isEmpty);
  });
}
