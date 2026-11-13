import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_data.dart';
import 'insights_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';
import 'txn_editor.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.data});

  /// Normally created here from Supabase; passed in for the offline preview.
  final AppData? data;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final AppData data = widget.data ?? AppData(Supabase.instance.client);
  var _tab = 0;

  @override
  void dispose() {
    if (widget.data == null) data.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) => Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            TransactionsScreen(data: data),
            InsightsScreen(data: data),
            SettingsScreen(data: data),
          ],
        ),
        floatingActionButton: _tab == 2
            ? null
            : FloatingActionButton.extended(
                onPressed: () => openTxnEditor(context, data),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transactions'),
            const NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Insights'),
            NavigationDestination(
              icon: Badge(isLabelVisible: data.unread.isNotEmpty, child: const Icon(Icons.settings_outlined)),
              selectedIcon: const Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
