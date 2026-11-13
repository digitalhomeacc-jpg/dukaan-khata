import 'package:flutter/material.dart';

import '../accounting/health.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// हिशोब तपासणी: everything the whole-books check found, each with its fix.
class HealthScreen extends StatelessWidget {
  const HealthScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HealthScreen()));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final issues = app.health;
    final scheme = Theme.of(context).colorScheme;
    String field(String k) {
      final s = t('fix_f_$k');
      return s == 'fix_f_$k' ? k : s;
    }

    String entryTitle(String title) {
      final p = title.split(' #');
      return p.length == 2 ? '${t('vt_${p[0]}')} #${p[1]}' : title;
    }

    String v(String s) => s.isEmpty ? '0' : s;

    Future<void> act(Future<void> Function() f) async {
      try {
        await f();
        if (context.mounted) toast(context, t('fix_done'));
      } catch (e) {
        if (context.mounted) toast(context, errText(context, e), error: true);
      }
      await app.runHealth(force: true);
    }

    Future<bool> sure(String msg) async =>
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(msg),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('ok'))),
            ],
          ),
        ) ==
        true;

    Widget card(HealthIssue i) {
      final hc = HealthCheck(app.db, app.businessId!, app.vouchers, app.ledgers, app.stock);
      final title = switch (i.kind) {
        'entry' || 'postings' => entryTitle(i.title),
        'books' => t('health_books'),
        _ => i.title,
      };
      final why = t('health_why_${i.kind}');
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.report_gmailerrorred, color: scheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(why, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              if (i.changes.isNotEmpty)
                for (final c in i.changes.entries)
                  Text('${field(c.key)}: ${t('health_recorded')} ${v(c.value.$2)}  →  ${t('fix_now')} ${v(c.value.$1)}')
              else
                Text(i.detail),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  if (i.voucherId != null && i.kind != 'books')
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(t('health_open')),
                      onPressed: () => VoucherScreen.edit(context, i.voucherId!),
                    ),
                  if (i.fix != null)
                    FilledButton.tonal(onPressed: () => act(() => app.ledgers.repair([i.fix!])), child: Text(t('fix_restore'))),
                  if (i.itemFix != null)
                    FilledButton.tonal(
                      onPressed: () => act(
                        () => app.stock.putBack(i.itemFix!.id, {for (final c in i.itemFix!.changes.entries) c.key: c.value.$2}),
                      ),
                      child: Text(t('fix_restore')),
                    ),
                  if (i.lineIds.isNotEmpty)
                    FilledButton.tonal(
                      onPressed: () async {
                        if (await sure(t('health_drop_q'))) await act(() => hc.dropOrphanLines(i));
                      },
                      child: Text(t('health_drop')),
                    ),
                  if (i.kind == 'postings' && i.voucherId != null)
                    FilledButton.tonal(
                      onPressed: () async {
                        if (await sure(t('health_rebuild_q'))) await act(() => hc.rebuild(i.voucherId!, app.actor));
                      },
                      child: Text(t('health_rebuild')),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('health'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(t('health_intro'), style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  app.healthBusy
                      ? t('health_running')
                      : app.healthAt == null
                      ? t('health_never')
                      : '${t('health_checked')} ${TimeOfDay.fromDateTime(app.healthAt!).format(context)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton.icon(
                key: const Key('health_run'),
                icon: app.healthBusy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.fact_check_outlined, size: 18),
                label: Text(t('health_run')),
                onPressed: app.healthBusy ? null : () => app.runHealth(force: true),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (issues != null && issues.isEmpty && !app.healthBusy)
            Material(
              color: AppColors.paid.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              child: ListTile(
                key: const Key('health_ok'),
                leading: const Icon(Icons.verified, color: AppColors.paid),
                title: Text(t('health_ok'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(t('health_ok_sub')),
              ),
            ),
          for (final i in issues ?? const <HealthIssue>[]) card(i),
        ],
      ),
    );
  }
}
