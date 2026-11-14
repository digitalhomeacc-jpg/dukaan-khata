// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'package:expense_tracker/data/app_data.dart';
import 'package:expense_tracker/models.dart';
import 'package:expense_tracker/ui/entry_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('a payment shows its own changes, who made them, and undo for each', (tester) async {
    final data = AppData.preview(
      categories: const [
        Category(id: 'f', name: 'Food & Dining', icon: 'restaurant', color: 0xFFFF5722),
        Category(id: 's', name: 'Stuff', icon: 'shopping_bag', color: 0xFF3F51B5),
      ],
      transactions: const [],
    );
    final rows = [
      {
        'id': 3,
        'batch': 3,
        'at': '2026-11-14T10:00:00Z',
        'tbl': 'transactions',
        'op': 'update',
        'by_user': true,
        'row_key': {'id': 't'},
        'before': {'category_id': 'f'},
        'after': {'category_id': 's'},
        'context': {'merchant': 'Corner shop', 'amount': 80},
        'undone': false,
      },
      {
        'id': 2,
        'batch': 2,
        'at': '2026-11-13T10:00:00Z',
        'tbl': 'txn_shares',
        'op': 'insert',
        'by_user': true,
        'row_key': {'id': 'x'},
        'after': {'person': 'Ravi', 'amount': 40},
        'context': {'merchant': 'Corner shop', 'amount': 80, 'person': 'Ravi'},
        'undone': false,
      },
      {
        'id': 1,
        'batch': 1,
        'at': '2026-11-12T10:00:00Z',
        'tbl': 'transactions',
        'op': 'insert',
        'by_user': false,
        'row_key': {'id': 't'},
        'after': {'amount': 80},
        'context': {'merchant': 'Corner shop', 'amount': 80, 'source': 'email'},
        'undone': false,
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EntryHistorySection(data: data, txnId: 't', loader: () async => rows),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Category: Food & Dining → Stuff'), findsOneWidget);
    expect(find.textContaining('Ravi’s part of Corner shop'), findsOneWidget);
    expect(find.textContaining('Bank email'), findsOneWidget);
    // Undo on the two changes, not on the payment arriving.
    expect(find.text('Undo'), findsNWidgets(2));
  });
}
