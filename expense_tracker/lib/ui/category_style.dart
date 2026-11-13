import 'package:material_ui/material_ui.dart';

import '../models.dart';

/// Icons a category can use. Stored by name in the database.
const categoryIcons = <String, IconData>{
  'restaurant': Icons.restaurant,
  'shopping_cart': Icons.shopping_cart,
  'shopping_bag': Icons.shopping_bag,
  'directions_car': Icons.directions_car,
  'receipt': Icons.receipt_long,
  'movie': Icons.movie,
  'local_hospital': Icons.local_hospital,
  'flight': Icons.flight,
  'home': Icons.home,
  'payments': Icons.payments,
  'swap_horiz': Icons.swap_horiz,
  'school': Icons.school,
  'fitness': Icons.fitness_center,
  'pets': Icons.pets,
  'phone': Icons.phone_android,
  'fuel': Icons.local_gas_station,
  'gift': Icons.card_giftcard,
  'savings': Icons.savings,
  'coffee': Icons.local_cafe,
  'handshake': Icons.handshake,
  'group': Icons.group,
  'label': Icons.label,
};

const categoryColors = <int>[
  0xFFFF5722,
  0xFF4CAF50,
  0xFFE91E63,
  0xFF2196F3,
  0xFFFF9800,
  0xFF9C27B0,
  0xFFF44336,
  0xFF00BCD4,
  0xFF795548,
  0xFF009688,
  0xFF607D8B,
  0xFF3F51B5,
];

IconData iconFor(Category? c) => categoryIcons[c?.icon] ?? Icons.help_outline;
Color colorFor(Category? c) => c == null ? const Color(0xFF9E9E9E) : Color(c.color);

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar(this.category, {super.key, this.size = 40});

  final Category? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = colorFor(category);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
      child: Icon(iconFor(category), color: color, size: size * 0.55),
    );
  }
}

IconData accountIcon(Account? a) => switch (a?.kind) {
  AccountKind.cash => Icons.payments_outlined,
  AccountKind.card => Icons.credit_card,
  AccountKind.wallet => Icons.account_balance_wallet_outlined,
  AccountKind.bank => Icons.account_balance,
  null => Icons.help_outline,
};

String accountKindLabel(AccountKind k) => switch (k) {
  AccountKind.cash => 'Cash',
  AccountKind.bank => 'Bank account',
  AccountKind.card => 'Credit card',
  AccountKind.wallet => 'Wallet',
};

/// Categories in display order: each group followed by the categories in it.
List<({Category cat, bool inGroup})> groupedCategories(Iterable<Category> all) {
  final list = all.toList();
  final ids = {for (final c in list) c.id};
  final tops = list.where((c) => c.parentId == null || !ids.contains(c.parentId)).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [
    for (final t in tops) ...[
      (cat: t, inGroup: false),
      for (final c
          in (list.where((c) => c.parentId == t.id).toList()
            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))))
        (cat: c, inGroup: true),
    ],
  ];
}
