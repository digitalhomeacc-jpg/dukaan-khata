import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'accounting/models.dart';
import 'core/theme.dart';
import 'features/auth_screens.dart';
import 'features/home_screen.dart';
import 'features/parties_screen.dart';
import 'core/demo.dart';
import 'features/rojmal_screen.dart';
import 'features/screen_tour.dart';
import 'features/settings_screen.dart';
import 'features/stock_screen.dart';
import 'features/voucher_screen.dart';
import 'shared/export.dart';
import 'state/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController()..init();
  runApp(App(controller: controller, child: const DukaanKhataApp()));
}

class DukaanKhataApp extends StatelessWidget {
  const DukaanKhataApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    return MaterialApp(
      navigatorKey: Exporter.navigatorKey,
      title: app.t('app_name'),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: Locale(app.english ? 'en' : 'mr', 'IN'),
      supportedLocales: const [Locale('mr', 'IN'), Locale('en', 'IN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // layout check (demo tour) at a larger text size, like a phone set to big fonts
      builder: (ctx, child) => ScreenTour.textScale == null
          ? child!
          : MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(ScreenTour.textScale!)), child: child!),
      home: switch (app.stage) {
        Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
        Stage.error => Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(app.error ?? 'Error')))),
        Stage.setupLocal => const SetupLocalScreen(),
        Stage.login => const LoginScreen(),
        Stage.createShop => const CreateShopScreen(),
        Stage.locked => const PinScreen(),
        Stage.ready => const Shell(),
      },
    );
  }
}

/// Bottom navigation on phones, side rail on the Windows laptop / tablets.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

  @override
  void initState() {
    super.initState();
    // demo build, opened with ?tour=1: walk through every screen (layout check)
    if (demoMode && Uri.base.queryParameters['tour'] != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ScreenTour.run(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final pages = const [
      HomeScreen(),
      PartiesScreen(group: LedgerGroup.customer),
      RojmalScreen(),
      StockScreen(),
      SettingsScreen(),
    ];
    final dests = [
      (Icons.home_outlined, Icons.home, t('home')),
      (Icons.people_outline, Icons.people, t('customers')),
      (Icons.menu_book_outlined, Icons.menu_book, t('rojmal')),
      (Icons.inventory_2_outlined, Icons.inventory_2, t('stock')),
      (Icons.more_horiz, Icons.more_horiz, t('more')),
    ];
    // खाता मोड: only home, customers and more (रोजमेळ and stock are hidden)
    final shown = app.simpleMode ? const [0, 1, 4] : const [0, 1, 2, 3, 4];
    final at = shown.contains(index) ? shown.indexOf(index) : 0;
    void go(int i) => setState(() => index = shown[i]);
    final wide = MediaQuery.of(context).size.width >= 800;
    final body = IndexedStack(index: at, children: [for (final i in shown) pages[i]]);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: at,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FloatingActionButton(
                heroTag: 'rail_sale',
                tooltip: t('sale'),
                onPressed: () => VoucherScreen.open(context, VoucherType.sale),
                child: const Icon(Icons.add),
              ),
            ),
            destinations: [
              for (final (i, s, l) in [for (final k in shown) dests[k]]) NavigationRailDestination(icon: Icon(i), selectedIcon: Icon(s), label: Text(l)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: at,
        onDestinationSelected: go,
        destinations: [
          for (final (i, s, l) in [for (final k in shown) dests[k]]) NavigationDestination(icon: Icon(i), selectedIcon: Icon(s), label: l),
        ],
      ),
    );
  }
}
