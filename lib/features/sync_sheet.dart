import 'dart:async';

import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/theme.dart';
import '../state/app_controller.dart';
import 'search_screen.dart';

/// Tapping the ☁ icon: last sync time, entries waiting to upload, entries the
/// server refused, the हिशोब तपासणी (books check) and a "sync now" button.
class SyncSheet extends StatefulWidget {
  const SyncSheet({super.key});

  static Future<void> open(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => const SyncSheet(),
      );

  @override
  State<SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<SyncSheet> {
  int pending = 0;
  List<Map<String, Object?>> errors = [];
  List<Voucher> unbalanced = [];
  List<(VoucherType, int, int)> dupes = [];
  bool busy = false;
  bool checked = false;
  bool deepBusy = false;
  List<(Voucher, String)>? deep;
  int deepCount = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refresh();
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final app = App.read(context);
    final p = await app.pendingUploads();
    final e = await app.syncErrors();
    final u = await app.ledgers.unbalanced();
    final d = await app.ledgers.duplicateNumbers();
    if (mounted) {
      setState(() {
        pending = p;
        errors = e;
        unbalanced = u;
        dupes = d;
        checked = true;
      });
    }
  }

  String _ago(DateTime? t, String Function(String) tr) {
    if (t == null) return tr('never');
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return tr('just_now');
    if (d.inMinutes < 60) return '${d.inMinutes} ${tr('min_ago')}';
    if (d.inHours < 24) return '${d.inHours} ${tr('hours_ago')}';
    final l = t.toLocal();
    return '${l.day}/${l.month} ${l.hour}:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final s = app.syncStatus;
    final online = s?.connected ?? false;
    final working = (s?.uploading ?? false) || (s?.downloading ?? false) || (s?.connecting ?? false);

    final (IconData icon, Color color, String title) = !app.cloud
        ? (Icons.smartphone, AppColors.neutral, t('sync_local'))
        : !online
            ? (Icons.cloud_off_outlined, AppColors.haldi, t('sync_offline'))
            : working || pending > 0
                ? (Icons.cloud_sync_outlined, AppColors.ink, t('sync_working'))
                : (Icons.cloud_done_outlined, AppColors.paid, t('sync_all_done'));

    Widget row(String k, String v, {Color? c}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(k)),
            Text(v, style: TextStyle(fontWeight: FontWeight.w700, color: c)),
          ]),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: ListView(shrinkWrap: true, children: [
        Row(children: [
          CircleAvatar(radius: 22, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color)),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 12),
        if (app.cloud) ...[
          row(t('last_synced'), _ago(s?.lastSyncedAt, t)),
          row(t('pending_uploads'), '$pending', c: pending == 0 ? AppColors.paid : AppColors.haldi),
          if (s?.uploadError != null || s?.downloadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(t('sync_retrying'), style: TextStyle(color: AppColors.haldi, fontSize: 13)),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    await app.syncNow();
                    await Future<void>.delayed(const Duration(seconds: 2));
                    await _refresh();
                    if (mounted) setState(() => busy = false);
                  },
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(t('sync_now')),
          ),
          const SizedBox(height: 6),
          Text(t('sync_auto_note'), style: Theme.of(context).textTheme.bodySmall),
        ] else
          Text(t('sync_local_note'), style: Theme.of(context).textTheme.bodySmall),
        const Divider(height: 28),
        // Books check
        Row(children: [
          Icon(unbalanced.isEmpty ? Icons.verified_outlined : Icons.error_outline,
              color: unbalanced.isEmpty ? AppColors.paid : AppColors.due),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              !checked
                  ? t('books_check')
                  : unbalanced.isEmpty
                      ? t('books_check_ok')
                      : t('books_check_bad').replaceAll('{n}', '${unbalanced.length}'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        for (final v in unbalanced) VoucherTile(v),
        // खोल तपासणी: every entry's postings worked out afresh and compared
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('deep_check'),
            icon: deepBusy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.fact_check_outlined, size: 18),
            label: Text(t('deep_check')),
            onPressed: deepBusy
                ? null
                : () async {
                    setState(() => deepBusy = true);
                    final r = await App.read(context).vouchers.deepCheck();
                    final n = ((await App.read(context).db.get(
                            'SELECT COUNT(*) AS n FROM vouchers WHERE business_id = ? AND deleted = 0', [App.read(context).businessId]))['n'] as num)
                        .toInt();
                    if (mounted) {
                      setState(() {
                        deepBusy = false;
                        deep = r;
                        deepCount = n;
                      });
                    }
                  },
          ),
        ),
        if (deep != null)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Text(
              deep!.isEmpty ? t('deep_check_ok').replaceAll('{n}', '$deepCount') : t('deep_check_bad').replaceAll('{n}', '${deep!.length}'),
              style: TextStyle(fontWeight: FontWeight.w600, color: deep!.isEmpty ? AppColors.paid : AppColors.due),
            ),
          ),
        for (final (v, why) in deep ?? const <(Voucher, String)>[]) ...[
          VoucherTile(v),
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(why, style: TextStyle(fontSize: 12, color: AppColors.due)),
          ),
        ],
        if (dupes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '${t('dup_numbers')}: ${dupes.map((d) => '${t('vt_${d.$1.code}')} #${d.$2} ×${d.$3}').join(', ')}',
              style: TextStyle(color: AppColors.haldi, fontWeight: FontWeight.w600),
            ),
          ),
        if (errors.isNotEmpty) ...[
          const Divider(height: 28),
          Row(children: [
            const Icon(Icons.block, color: AppColors.due),
            const SizedBox(width: 10),
            Expanded(
              child: Text(t('refused_title').replaceAll('{n}', '${errors.length}'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () async {
                await app.clearSyncErrors();
                await _refresh();
              },
              child: Text(t('clear')),
            ),
          ]),
          Text(t('refused_help'), style: Theme.of(context).textTheme.bodySmall),
          for (final e in errors.take(20))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${e['tables']}'),
              subtitle: Text('${DateTime.parse(e['at'] as String).toLocal().toString().substring(0, 16)} · ${e['message']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
      ]),
    );
  }
}
