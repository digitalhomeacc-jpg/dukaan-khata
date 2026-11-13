import 'dart:convert';

import 'package:sqlite_async/sqlite_async.dart';

import '../core/audit.dart';
import '../core/money.dart';
import '../inventory/stock_repo.dart';
import 'ledger_repo.dart';
import 'voucher_service.dart';

/// हिशोब तपासणी – the whole-books safety net.
///
/// Every number in the books must be explained by an entry, and every change
/// must be in the history. This looks for anything that is not:
///  * the books as a whole do not balance (total debit ≠ total credit)
///  * money / stock lines left over from a deleted entry, or pointing at an
///    account / item that no longer exists
///  * an entry whose money lines no longer match its own details (e.g. two
///    phones edited the same bill at once)
///  * an entry, account or item whose figures differ from its last recorded
///    change (something changed it without leaving a history line – like the
///    blank रोख / फोनपे accounts in Nov 2026)
/// It only reads; each finding comes with a fix the owner chooses to apply.
class HealthIssue {
  HealthIssue(
    this.kind,
    this.title,
    this.detail, {
    this.voucherId,
    this.fix,
    this.itemFix,
    this.lineIds = const [],
    this.changes = const {},
  });

  /// books | orphan | postings | entry | account | item
  final String kind;
  final String title;
  final String detail;
  final String? voucherId;
  final AccountFix? fix; // account: put back from history
  final ItemFix? itemFix; // item: put back from history
  final List<String> lineIds; // orphan lines to switch off
  /// field → (now, recorded)
  final Map<String, (String, String)> changes;
}

/// One item to put back: field → (now, was).
class ItemFix {
  ItemFix(this.id, this.name);
  final String id, name;
  final changes = <String, (String, String)>{};
}

/// Same value? Numbers are compared as numbers ("5" = "5.0", "1,200" = "1200").
bool sameValue(String a, String b) {
  if (a == b) return true;
  final x = double.tryParse(normalizeDigits(a).replaceAll(',', '').replaceAll('₹', '').trim());
  final y = double.tryParse(normalizeDigits(b).replaceAll(',', '').replaceAll('₹', '').trim());
  if (x != null && y != null) return (x - y).abs() < 0.0001;
  // empty and zero mean the same in the history (zeros are not written)
  if ((a.isEmpty && y == 0) || (b.isEmpty && x == 0)) return true;
  return false;
}

class HealthCheck {
  HealthCheck(this.db, this.businessId, this.vouchers, this.ledgers, this.stock);
  final SqliteConnection db;
  final String businessId;
  final VoucherService vouchers;
  final LedgerRepo ledgers;
  final StockRepo stock;

  Future<List<HealthIssue>> run() async {
    final out = <HealthIssue>[];
    final b = businessId;

    // 1. the books balance
    final tb = await db.get(
      'SELECT COALESCE(SUM(debit),0) - COALESCE(SUM(credit),0) AS d FROM voucher_lines WHERE business_id = ? AND deleted = 0',
      [b],
    );
    final diff = (tb['d'] as num).toInt();
    if (diff != 0) out.add(HealthIssue('books', 'debit ≠ credit', Money.fmt(diff.abs())));

    // 2. lines with no live entry, account or item behind them
    final orphan = await db.getAll(
      'SELECT vl.id, vl.voucher_id, vl.debit, vl.credit, v.vno, v.vtype, v.deleted AS vdel, l.name AS lname, l.id AS lid FROM voucher_lines vl '
      'LEFT JOIN vouchers v ON v.id = vl.voucher_id LEFT JOIN ledgers l ON l.id = vl.ledger_id '
      'WHERE vl.business_id = ? AND vl.deleted = 0 AND (v.id IS NULL OR v.deleted = 1 OR l.id IS NULL)',
      [b],
    );
    final byVoucher = <String, List<Map<String, Object?>>>{};
    for (final r in orphan) {
      (byVoucher[r['voucher_id'] as String] ??= []).add(r);
    }
    for (final e in byVoucher.entries) {
      final r = e.value.first;
      final money = e.value.fold<int>(0, (s, x) => s + ((x['debit'] as int?) ?? 0));
      if (r['lid'] == null) {
        out.add(
          HealthIssue(
            'orphan',
            'account missing',
            '${r['vtype'] ?? ''} #${r['vno'] ?? '?'} · ${Money.fmt(money)}',
            voucherId: r['vno'] == null ? null : e.key,
          ),
        );
      } else {
        out.add(
          HealthIssue(
            'orphan',
            r['vno'] == null ? 'entry missing' : 'entry deleted, money still counted',
            '${r['vtype'] ?? ''} #${r['vno'] ?? '?'} · ${Money.fmt(money)}',
            voucherId: r['vno'] == null ? null : e.key,
            lineIds: [for (final x in e.value) x['id'] as String],
          ),
        );
      }
    }
    final stockOrphan = await db.getAll(
      'SELECT il.id, il.voucher_id, il.qty, v.vno, v.vtype, i.id AS iid FROM inventory_lines il '
      'LEFT JOIN vouchers v ON v.id = il.voucher_id LEFT JOIN items i ON i.id = il.item_id '
      'WHERE il.business_id = ? AND il.deleted = 0 AND il.direction <> 0 AND (v.id IS NULL OR v.deleted = 1 OR i.id IS NULL)',
      [b],
    );
    final stockBy = <String, List<Map<String, Object?>>>{};
    for (final r in stockOrphan) {
      (stockBy[r['voucher_id'] as String] ??= []).add(r);
    }
    for (final e in stockBy.entries) {
      final r = e.value.first;
      out.add(
        HealthIssue(
          'orphan',
          r['iid'] == null ? 'item missing' : 'entry deleted, stock still counted',
          '${r['vtype'] ?? ''} #${r['vno'] ?? '?'}',
          voucherId: r['vno'] == null ? null : e.key,
          lineIds: r['iid'] == null ? const [] : [for (final x in e.value) 'I:${x['id']}'],
        ),
      );
    }

    // 3. each entry's money lines worked out again from its details
    for (final (v, why) in await vouchers.deepCheck()) {
      out.add(HealthIssue('postings', '${v.type.code} #${v.vno}', why, voucherId: v.id));
    }

    // 4. everything vs its last recorded change
    // latest record per entry / account / item (repairs and notes are other kinds)
    final last = <String, (String action, Map<String, dynamic>? after)>{};
    for (final r in await db.getAll('SELECT voucher_id, action, snapshot FROM audit_log WHERE business_id = ? ORDER BY at', [
      b,
    ])) {
      final id = r['voucher_id'] as String?;
      if (id == null) continue;
      try {
        final s = jsonDecode(r['snapshot'] as String? ?? '{}') as Map<String, dynamic>;
        if (!const {'voucher', 'ledger', 'item'}.contains(s['kind'])) continue; // very old rows / other kinds
        last[id] = (r['action'] as String, (s['after'] as Map?)?.cast<String, dynamic>());
      } catch (_) {}
    }

    // entries (old/reference entries carry no money and are added in batches)
    for (final r in await db.getAll("SELECT id, vtype, vno, deleted FROM vouchers WHERE business_id = ? AND vtype <> 'history'", [
      b,
    ])) {
      final id = r['id'] as String;
      final h = last[id];
      if (h == null) continue; // made before the history existed
      final deleted = (r['deleted'] as int? ?? 0) == 1;
      final label = '${r['vtype']} #${r['vno']}';
      if (h.$1 == 'delete') {
        if (!deleted) out.add(HealthIssue('entry', label, 'deleted in the history, but back in the books', voucherId: id));
        continue;
      }
      if (deleted) {
        out.add(HealthIssue('entry', label, 'deleted without a history line', voucherId: id));
        continue;
      }
      final after = h.$2;
      if (after == null) continue;
      final now = await vouchers.entrySummary(db, id);
      final changed = <String, (String, String)>{
        for (final k in const ['type', 'date', 'amount', 'paid', 'hamali', 'transport', 'gst'])
          if (!sameValue('${now[k] ?? ''}', '${after[k] ?? ''}')) k: ('${now[k] ?? ''}', '${after[k] ?? ''}'),
      };
      if (changed.isNotEmpty) {
        out.add(
          HealthIssue(
            'entry',
            label,
            changed.entries.map((c) => '${c.key}: ${c.value.$2} → ${c.value.$1}').join(' · '),
            voucherId: id,
            changes: changed,
          ),
        );
      }
    }

    // accounts
    for (final r in await db.getAll('SELECT id, name FROM ledgers WHERE business_id = ?', [b])) {
      final id = r['id'] as String;
      final h = last[id];
      if (h == null || h.$1 == 'delete' || h.$2 == null) continue;
      final cur = await ledgers.snapOf(id);
      final fix = AccountFix(id, '${r['name'] ?? ''}', '', '');
      for (final k in {...cur.keys, ...h.$2!.keys}) {
        if (k == 'name' && !h.$2!.containsKey('name')) continue;
        final was = '${h.$2![k] ?? ''}', now = '${cur[k] ?? ''}';
        if (!sameValue(was, now)) fix.changes[k] = (now, was);
      }
      if (fix.changes.isNotEmpty) {
        out.add(
          HealthIssue(
            'account',
            fix.name,
            fix.changes.entries
                .map((c) => '${c.key}: ${c.value.$2.isEmpty ? 0 : c.value.$2} → ${c.value.$1.isEmpty ? 0 : c.value.$1}')
                .join(' · '),
            fix: fix,
            changes: fix.changes,
          ),
        );
      }
    }

    // items
    for (final r in await db.getAll('SELECT id, name FROM items WHERE business_id = ?', [b])) {
      final id = r['id'] as String;
      final h = last[id];
      if (h == null || h.$1 == 'delete' || h.$2 == null) continue;
      final cur = await stock.snapOf(id);
      final fix = ItemFix(id, '${r['name'] ?? ''}');
      for (final k in {...cur.keys, ...h.$2!.keys}) {
        final was = '${h.$2![k] ?? ''}', now = '${cur[k] ?? ''}';
        if (!sameValue(was, now)) fix.changes[k] = (now, was);
      }
      if (fix.changes.isNotEmpty) {
        out.add(
          HealthIssue(
            'item',
            fix.name,
            fix.changes.entries
                .map((c) => '${c.key}: ${c.value.$2.isEmpty ? 0 : c.value.$2} → ${c.value.$1.isEmpty ? 0 : c.value.$1}')
                .join(' · '),
            itemFix: fix,
            changes: fix.changes,
          ),
        );
      }
    }
    return out;
  }

  /// Switches off lines left over from a deleted entry (recorded in the history).
  Future<void> dropOrphanLines(HealthIssue i) async {
    if (i.lineIds.isEmpty) return;
    final money = i.lineIds.where((x) => !x.startsWith('I:')).toList();
    final stockIds = [for (final x in i.lineIds.where((x) => x.startsWith('I:'))) x.substring(2)];
    await db.writeTransaction((tx) async {
      for (final id in money) {
        await tx.execute('UPDATE voucher_lines SET deleted = 1 WHERE id = ?', [id]);
      }
      for (final id in stockIds) {
        await tx.execute('UPDATE inventory_lines SET deleted = 1 WHERE id = ?', [id]);
      }
      await AuditLog.write(
        tx,
        businessId: businessId,
        recordId: i.voucherId ?? businessId,
        action: 'edit',
        kind: 'repair',
        title: i.title,
        before: {'detail': i.detail},
        after: {'detail': 'lines removed: ${i.lineIds.length}'},
      );
    });
  }

  /// Works an entry's money and stock lines out again from its details.
  Future<void> rebuild(String voucherId, Actor actor) async =>
      vouchers.save(await vouchers.inputOf(voucherId), actor, existingId: voucherId);
}
