import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../shared/shortcode_parser.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'audit_screen.dart';

const monthNames = [
  ('जानेवारी', 'January'), ('फेब्रुवारी', 'February'), ('मार्च', 'March'), ('एप्रिल', 'April'),
  ('मे', 'May'), ('जून', 'June'), ('जुलै', 'July'), ('ऑगस्ट', 'August'),
  ('सप्टेंबर', 'September'), ('ऑक्टोबर', 'October'), ('नोव्हेंबर', 'November'), ('डिसेंबर', 'December'),
];

/// Books start date + financial-year month pickers (used on setup and in settings).
class BooksFields extends StatelessWidget {
  final String booksStart;
  final int fyMonth;
  final ValueChanged<String> onStart;
  final ValueChanged<int> onMonth;
  const BooksFields({super.key, required this.booksStart, required this.fyMonth, required this.onStart, required this.onMonth});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.event),
        label: Text('${t('books_start')}: ${shortDate(booksStart)}'),
        onPressed: () async {
          final p = await showDatePicker(
            context: context,
            initialDate: parseIso(booksStart),
            firstDate: DateTime(2015),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (p != null) onStart(isoDate(p));
        },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: fyMonth,
        decoration: InputDecoration(labelText: t('fy_start'), border: const OutlineInputBorder()),
        items: [
          for (var m = 1; m <= 12; m++)
            DropdownMenuItem(value: m, child: Text(app.english ? monthNames[m - 1].$2 : monthNames[m - 1].$1)),
        ],
        onChanged: (m) => onMonth(m!),
      ),
    ]);
  }
}

/// Owner: shop name, address, phone, GSTIN, books start, FY month.
class ShopDetailsScreen extends StatefulWidget {
  const ShopDetailsScreen({super.key});
  @override
  State<ShopDetailsScreen> createState() => _ShopDetailsScreenState();
}

class _ShopDetailsScreenState extends State<ShopDetailsScreen> {
  late final app = App.read(context);
  late final name = TextEditingController(text: app.businessName);
  late final nameEn = TextEditingController(text: app.shopNameEn);
  late final address = TextEditingController(text: app.shopAddress);
  late final phone = TextEditingController(text: app.shopPhone);
  late final gstin = TextEditingController(text: app.shopGstin);
  late String start = Books.start;
  late int month = Books.fyStartMonth;

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(t('shop_details'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, decoration: d(t('business_name'))),
        const SizedBox(height: 12),
        TextField(
          key: const Key('shop_name_en'),
          controller: nameEn,
          textCapitalization: TextCapitalization.words,
          decoration: d(t('business_name_en')).copyWith(helperText: t('business_name_en_help')),
        ),
        const SizedBox(height: 12),
        TextField(controller: address, maxLines: 2, decoration: d(t('address'))),
        const SizedBox(height: 12),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: d(t('phone'))),
        const SizedBox(height: 12),
        TextField(controller: gstin, textCapitalization: TextCapitalization.characters, decoration: d('GSTIN')),
        SectionTitle(t('books')),
        BooksFields(
          booksStart: start,
          fyMonth: month,
          onStart: (s) => setState(() => start = s),
          onMonth: (m) => setState(() => month = m),
        ),
        const SizedBox(height: 8),
        Text(t('books_start_help'), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () async {
            if (name.text.trim().isEmpty) return toast(context, t('err_required'), error: true);
            if (start != Books.start) {
              final clash = await app.db.getOptional(
                "SELECT COUNT(*) AS n FROM vouchers WHERE business_id = ? AND deleted = 0 AND "
                "((vtype = 'history' AND vdate >= ?) OR (vtype NOT IN ('history', 'booking', 'promise') AND vdate < ?))",
                [app.businessId, start, start],
              );
              final n = (clash?['n'] as int?) ?? 0;
              if (n > 0) {
                if (context.mounted) toast(context, t('books_start_clash').replaceAll('{n}', '$n'), error: true);
                return;
              }
            }
            await app.saveShopDetails(
              name: name.text.trim(),
              nameEn: nameEn.text,
              address: address.text.trim(),
              phone: phone.text.trim(),
              gstin: gstin.text.trim(),
              booksStart: start,
              fyStartMonth: month,
            );
            if (context.mounted) {
              toast(context, t('saved'));
              Navigator.pop(context);
            }
          },
          child: Text(t('save')),
        ),
      ]),
    );
  }
}
