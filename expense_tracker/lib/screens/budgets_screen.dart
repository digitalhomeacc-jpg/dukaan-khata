import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../models.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';

/// Set monthly budgets: overall and per category.
class BudgetsScreen extends StatelessWidget {
  const BudgetsScreen({super.key, required this.data});

  final AppData data;

  Future<void> _edit(BuildContext context, Category? c) async {
    final existing = data.budgets.where((b) => b.categoryId == c?.id).firstOrNull;
    final ctl = TextEditingController(
        text: existing == null ? '' : existing.amount.toStringAsFixed(existing.amount == existing.amount.roundToDouble() ? 0 : 2));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? 'Monthly budget (all spending)' : 'Monthly budget: ${c.name}'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: const InputDecoration(prefixText: '₹ ', labelText: 'Amount a month'),
        ),
        actions: [
          if (existing != null) TextButton(onPressed: () => Navigator.pop(ctx, 'remove'), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (result == 'remove' && existing != null) await data.deleteBudget(existing.id);
    final v = double.tryParse(ctl.text.replaceAll(',', ''));
    if (result == 'save' && v != null && v > 0) await data.saveBudget(c?.id, v);
  }

  @override
  Widget build(BuildContext context) {
    final month = summarize(data.transactions, monthStart(DateTime.now()),
        loanCategoryIds: data.notSpendingCategoryIds, shares: data.shareTotalsNow);
    final progress = {for (final p in budgetProgress(data.budgets, month)) p.budget.categoryId: p};
    Widget row(Category? c) {
      final p = progress[c?.id];
      return ListTile(
        leading: c == null ? const CircleAvatar(child: Icon(Icons.account_balance_wallet_outlined)) : CategoryAvatar(c),
        title: Text(c?.name ?? 'All spending'),
        subtitle: p == null ? const Text('No budget') : BudgetBar(progress: p),
        trailing: Text(p == null ? 'Set' : money(p.budget.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
        onTap: () => _edit(context, c),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Budgets')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('A monthly limit for all spending or a category. Only your share of split payments counts.'),
          ),
          row(null),
          const Divider(),
          for (final c in data.categories.where((c) => !c.isLoan)) row(c),
        ],
      ),
    );
  }
}

/// "₹1,800 of ₹2,000 · ₹200 left" with a coloured bar.
class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.progress});

  final BudgetProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = progress.over ? scheme.error : (progress.close ? Colors.orange.shade700 : scheme.primary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress.share.clamp(0, 1).toDouble(),
            minHeight: 6,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          progress.over
              ? '${money(progress.spent)} spent · ${money(-progress.left)} over'
              : '${money(progress.spent)} spent · ${money(progress.left)} left',
          style: TextStyle(color: progress.over ? scheme.error : null, fontSize: 12),
        ),
      ],
    );
  }
}
