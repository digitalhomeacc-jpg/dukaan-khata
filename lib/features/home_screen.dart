import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'promise_screen.dart';
import 'recurring_screen.dart';
import 'search_screen.dart';
import 'sync_sheet.dart';
import 'voucher_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final today = todayIso();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(app.businessName, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${app.actor.name} · ${app.actor.isOwner ? t('role_owner') : t('role_staff')} · ${shortDate(today)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
        actions: [
          IconButton(tooltip: t('search'), icon: const Icon(Icons.search), onPressed: () => SearchScreen.open(context)),
          _SyncBadge(),
          TextButton(onPressed: () => app.setEnglish(!app.english), child: Text(app.english ? 'मराठी' : 'EN')),
          IconButton(tooltip: t('lock'), icon: const Icon(Icons.lock_outline), onPressed: app.lock),
        ],
      ),
      body: LiveBuilder<(Map<String, int>, List<Item>, List<Voucher>, int, int)>(
        load: () async => (
          await app.ledgers.dashboard(today),
          (await app.stock.list()).where((i) => i.lowStock > 0 && i.stock <= i.lowStock).toList(),
          (await app.ledgers.dayBook(today)).reversed.take(12).toList(),
          await app.ledgers.promisesDue(today),
          app.actor.isOwner ? (await app.recurring.due(today)).length : 0, // दरमहा आकार to charge
        ),
        builder: (context, data) {
          final (d, low, recent, due, monthly) = data;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            _SearchField(onTap: () => SearchScreen.open(context), hint: t('search_all_hint')),
            if (due > 0) ...[
              const SizedBox(height: 10),
              Material(
                color: AppColors.haldi.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  leading: const Icon(Icons.event_available, color: AppColors.haldi),
                  title: Text(t('promises_due').replaceAll('{n}', '$due'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => PromisesScreen.open(context),
                ),
              ),
            ],
            if (monthly > 0) ...[
              const SizedBox(height: 10),
              Material(
                color: AppColors.ink.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  key: const Key('home_monthly_due'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  leading: const Icon(Icons.event_repeat, color: AppColors.ink),
                  title: Text(t('recurring_due').replaceAll('{n}', '$monthly'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => DueChargesScreen.open(context),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _ActionGrid(),
            const SizedBox(height: 18),
            _Panel(title: t('today'), children: [
              _Figure(t('today_sales'), d['sales']!, AppColors.sale),
              _Figure(t('today_collection'), d['collections']!, AppColors.paid),
            ]),
            // shop-wide totals (balances, total udhaari) are for owners only
            if (app.actor.isOwner) _Panel(title: t('balances'), children: [
              _Figure(t('cash_in_hand'), d['cash']!, scheme.onSurface),
              _Figure(t('upi_balance'), d['upi']!, scheme.onSurface),
              _Figure(t('bank_balance'), d['bank']!, scheme.onSurface),
            ]),
            if (app.actor.isOwner) _Panel(title: t('dues'), children: [
              _Figure(t('receivable'), d['receivable']!, AppColors.due),
              _Figure(t('payable'), d['payable']!, AppColors.haldi),
            ]),
            if (low.isNotEmpty) ...[
              const SizedBox(height: 8),
              _Header(t('low_stock_items')),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final i in low)
                  Chip(
                    avatar: Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.due),
                    label: Text('${i.display(app.english)} · ${fmtQty(i.stock)} ${t('unit_${i.unit}')}'),
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            _Header(t('today_entries')),
            Card(
              child: recent.isEmpty
                  ? Padding(padding: const EdgeInsets.all(20), child: Center(child: Text(t('no_entries'))))
                  : Column(children: [
                      for (var i = 0; i < recent.length; i++) ...[
                        if (i > 0) const Divider(indent: 72),
                        VoucherTile(recent[i]),
                      ],
                    ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final VoidCallback onTap;
  final String hint;
  const _SearchField({required this.onTap, required this.hint});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: scheme.outlineVariant)),
      child: InkWell(
        key: const Key('home_search'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(children: [
            Icon(Icons.search, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(hint, style: TextStyle(color: scheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );
  }
}

/// ☁ status icon – tap for the sync panel.
class _SyncBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final s = app.syncStatus;
    final ok = s?.connected ?? false;
    final busy = (s?.uploading ?? false) || (s?.downloading ?? false);
    final (IconData icon, Color? color, String tip) = !app.cloud
        ? (Icons.smartphone, null, app.t('sync_local'))
        : !ok
            ? (Icons.cloud_off_outlined, AppColors.haldi, app.t('sync_offline'))
            : busy
                ? (Icons.cloud_sync_outlined, AppColors.ink, app.t('sync_working'))
                : (Icons.cloud_done_outlined, AppColors.paid, app.t('sync_ok'));
    return IconButton(
      key: const Key('sync_badge'),
      tooltip: tip,
      icon: Icon(icon, color: color),
      onPressed: () => SyncSheet.open(context),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    Widget big(String label, String sub, IconData icon, Color c, VoidCallback onTap) => Expanded(
          child: Material(
            color: c.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c)),
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        );
    Widget small(String label, IconData icon, VoidCallback onTap) => Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );
    return Column(children: [
      Row(children: [
        big(t('sale'), t('sale_sub'), Icons.point_of_sale, AppColors.sale, () => VoucherScreen.open(context, VoucherType.sale)),
        const SizedBox(width: 10),
        big(t('receipt'), t('receipt_sub'), Icons.south_west, AppColors.receipt, () => VoucherScreen.open(context, VoucherType.receipt)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        big(t('expense'), t('expense_sub'), Icons.receipt_long, AppColors.expense,
            () => VoucherScreen.open(context, VoucherType.payment, expense: true)),
        const SizedBox(width: 10),
        big(t('purchase'), t('purchase_sub'), Icons.local_shipping_outlined, AppColors.purchase,
            () => VoucherScreen.open(context, VoucherType.purchase)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        small(t('payment'), Icons.north_east, () => VoucherScreen.open(context, VoucherType.payment)),
        const SizedBox(width: 8),
        small(t('contra'), Icons.swap_horiz, () => VoucherScreen.open(context, VoucherType.contra)),
        const SizedBox(width: 8),
        small(t('suppliers'), Icons.storefront_outlined,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PartiesScreen(group: LedgerGroup.supplier)))),
      ]),
    ]);
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.4,
                  fontWeight: FontWeight.w600,
                )),
      );
}

/// A labelled card of figures laid out side by side.
class _Panel extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Panel({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Header(title),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Row(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Container(width: 1, height: 36, color: Theme.of(context).dividerTheme.color),
                Expanded(child: children[i]),
              ],
            ]),
          ),
        ),
      ]);
}

class _Figure extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _Figure(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('₹${Money.fmt(value)}',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ]);
}
