import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';
import 'category_style.dart';

/// Which payments to look at: all, one account (Cash, HDFC, Amazon Pay…) or one way of paying (UPI, card…).
class PaidWith {
  const PaidWith.all() : accountId = null, method = null;
  const PaidWith.account(String this.accountId) : method = null;
  const PaidWith.method(String this.method) : accountId = null;

  final String? accountId;
  final String? method;

  bool get isAll => accountId == null && method == null;

  bool keep(Txn t) => (accountId == null || t.accountId == accountId) && (method == null || t.method == method);

  String label(AppData data) => accountId != null
      ? (data.account(accountId)?.name ?? 'Account')
      : method != null
      ? (methodNames[method] ?? method!)
      : 'All accounts';

  @override
  bool operator ==(Object other) => other is PaidWith && other.accountId == accountId && other.method == method;

  @override
  int get hashCode => Object.hash(accountId, method);
}

const methodNames = {
  'upi': 'UPI',
  'card': 'Card',
  'netbanking': 'Bank transfer',
  'atm': 'ATM',
  'cash': 'Cash',
  'other': 'Other',
};

/// A chip that opens the choice of account or way of paying.
class PaidWithChip extends StatelessWidget {
  const PaidWithChip({super.key, required this.data, required this.value, required this.onChanged});

  final AppData data;
  final PaidWith value;
  final ValueChanged<PaidWith> onChanged;

  Future<void> _pick(BuildContext context) async {
    final methods = {for (final t in data.transactions) t.method};
    final picked = await showModalBottomSheet<PaidWith>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.all_inclusive),
                title: const Text('All accounts'),
                trailing: value.isAll ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(c, const PaidWith.all()),
              ),
              const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text('Paid from')),
              for (final a in data.accounts.where((a) => !a.archived))
                ListTile(
                  leading: Icon(accountIcon(a)),
                  title: Text(a.name),
                  trailing: value.accountId == a.id ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, PaidWith.account(a.id)),
                ),
              const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text('Way of paying')),
              for (final m in methodNames.keys.where(methods.contains))
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: Text(methodNames[m]!),
                  trailing: value.method == m ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(c, PaidWith.method(m)),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => InputChip(
    avatar: Icon(value.isAll ? Icons.account_balance_wallet_outlined : Icons.filter_alt, size: 18),
    label: Text(value.isAll ? 'All accounts' : value.label(data)),
    selected: !value.isAll,
    onPressed: () => _pick(context),
    onDeleted: value.isAll ? null : () => onChanged(const PaidWith.all()),
  );
}
