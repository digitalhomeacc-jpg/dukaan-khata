// Offline preview of the app with made-up data – no Supabase needed.
//   flutter run -d chrome -t tool/preview_main.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/screens/home_shell.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final now = DateTime.now();
  DateTime ago(int days, int h, int m) => DateTime(now.year, now.month, now.day - days, h, m);
  const cats = [
    Category(id: 'food', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722),
    Category(id: 'groc', name: 'Groceries', icon: 'shopping_cart', color: 0xFF4CAF50),
    Category(id: 'shop', name: 'Shopping', icon: 'shopping_bag', color: 0xFFE91E63),
    Category(id: 'trans', name: 'Transport', icon: 'directions_car', color: 0xFF2196F3),
    Category(id: 'bills', name: 'Bills & Utilities', icon: 'receipt', color: 0xFFFF9800),
    Category(id: 'fun', name: 'Entertainment', icon: 'movie', color: 0xFF9C27B0),
    Category(id: 'sal', name: 'Salary', icon: 'payments', color: 0xFF009688),
  ];
  var n = 0;
  Txn t(double a, DateTime at, String m, String? c, {bool debit = true, String bank = 'HDFC', bool excluded = false}) =>
      Txn(id: '${n++}', amount: a, isDebit: debit, txnAt: at, merchant: m, categoryId: c, bank: bank,
          accountLast4: bank == 'HDFC' ? '4321' : '5678', source: 'email', method: 'upi', excluded: excluded);
  final txns = [
    t(250, ago(0, 13, 5), 'SWIGGY LIMITED', 'food'),
    t(180, ago(0, 9, 40), 'UBER INDIA', 'trans', bank: 'ICICI'),
    t(1249, ago(1, 21, 10), 'AMAZON PAY INDIA', 'shop', bank: 'ICICI'),
    t(80, ago(1, 17, 0), 'CHAI POINT', null),
    t(2340, ago(2, 11, 30), 'DMART', 'groc'),
    t(499, ago(3, 8, 0), 'NETFLIX', 'fun', bank: 'SBI'),
    t(1875, ago(4, 20, 10), 'BOOKMYSHOW', 'fun', bank: 'Axis'),
    t(1450, ago(5, 10, 0), 'BESCOM ELECTRICITY', 'bills'),
    t(15430, ago(5, 12, 0), 'HDFC Credit Card bill', null, debit: false, excluded: true),
    t(85000, ago(6, 9, 0), 'ACME TECHNOLOGIES PVT LTD', 'sal', debit: false, bank: 'ICICI'),
    for (var i = 1; i <= 5; i++) ...[
      t(9000.0 + i * 1700, DateTime(now.year, now.month - i, 12), 'DMART', 'groc'),
      t(4000.0 + i * 900, DateTime(now.year, now.month - i, 18), 'SWIGGY LIMITED', 'food'),
    ],
  ];
  final data = AppData.preview(
    transactions: txns..sort((a, b) => b.txnAt.compareTo(a.txnAt)),
    categories: cats,
    profile: {'display_name': 'Asha', 'ingest_token': 'ab' * 24, 'last_sync_at': now.toUtc().toIso8601String()},
  );
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00897B)),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    ),
    home: HomeShell(data: data),
  ));
}
