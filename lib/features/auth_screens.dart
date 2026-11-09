import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/money.dart';
import '../shared/widgets.dart';
import 'books_screens.dart';
import '../state/app_controller.dart';

Widget _langToggle(AppController app) => TextButton(
      onPressed: () => app.setEnglish(!app.english),
      child: Text(app.english ? 'मराठी' : 'English'),
    );

/// First launch without cloud: shop name + owner name + PIN.
class SetupLocalScreen extends StatefulWidget {
  const SetupLocalScreen({super.key});
  @override
  State<SetupLocalScreen> createState() => _SetupLocalScreenState();
}

class _SetupLocalScreenState extends State<SetupLocalScreen> {
  final shop = TextEditingController();
  final name = TextEditingController();
  final pin = TextEditingController();
  final staffPin = TextEditingController();
  bool busy = false;
  String booksStart = todayIso();
  int fyMonth = 4;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(t('app_name')), actions: [_langToggle(app)]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
            const Icon(Icons.menu_book, size: 64, color: Colors.deepOrange),
            const SizedBox(height: 16),
            TextField(controller: shop, decoration: d(t('business_name'))),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: d(t('your_name'))),
            const SizedBox(height: 12),
            TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: d('${t('role_owner')} ${t('set_pin')}')),
            TextField(controller: staffPin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: d('${t('role_staff')} ${t('set_pin')}')),
            const SizedBox(height: 8),
            BooksFields(
              booksStart: booksStart,
              fyMonth: fyMonth,
              onStart: (s) => setState(() => booksStart = s),
              onMonth: (m) => setState(() => fyMonth = m),
            ),
            const SizedBox(height: 4),
            Text(t('books_start_help'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: busy
                  ? null
                  : () async {
                      if (shop.text.trim().isEmpty || name.text.trim().isEmpty || pin.text.length < 4) {
                        toast(context, t('err_required'), error: true);
                        return;
                      }
                      setState(() => busy = true);
                      await app.setupLocal(
                          shopName: shop.text.trim(),
                          ownerName: name.text.trim(),
                          ownerPin: pin.text,
                          staffPin: staffPin.text,
                          booksStart: booksStart,
                          fyStartMonth: fyMonth);
                    },
              child: Text(t('create_shop')),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.restore),
              label: Text(t('restore_backup')),
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty || pin.text.length < 4) {
                        toast(context, t('restore_need_pin'), error: true);
                        return;
                      }
                      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
                      if (files.isEmpty) return;
                      setState(() => busy = true);
                      try {
                        await app.restoreLocal(await files.single.readAsBytes(),
                            ownerName: name.text.trim(), ownerPin: pin.text, staffPin: staffPin.text);
                      } catch (e) {
                        if (context.mounted) toast(context, errText(context, e), error: true);
                        setState(() => busy = false);
                      }
                    },
            ),
          ]),
        ),
      ),
    );
  }
}

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});
  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String pin = '';
  bool wrong = false;

  void _tap(String d) {
    final app = App.read(context);
    setState(() {
      wrong = false;
      pin = d == 'del' ? (pin.isEmpty ? '' : pin.substring(0, pin.length - 1)) : pin + d;
    });
    if (pin.length >= 4 && app.unlock(pin)) return;
    if (pin.length >= 6) setState(() {
      wrong = true;
      pin = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(title: Text(app.businessName), actions: [_langToggle(app)]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t('enter_pin'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 4; i++)
                Container(
                  margin: const EdgeInsets.all(8),
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < pin.length ? Theme.of(context).colorScheme.primary : Colors.grey.shade300,
                  ),
                ),
            ]),
            if (wrong) Text(t('wrong_pin'), style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            for (final row in [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['', '0', 'del'],
            ])
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final k in row)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 76,
                      height: 76,
                      child: k.isEmpty
                          ? null
                          : FilledButton.tonal(
                              style: FilledButton.styleFrom(shape: const CircleBorder()),
                              onPressed: () => _tap(k),
                              child: k == 'del'
                                  ? const Icon(Icons.backspace_outlined, size: 26)
                                  : Text(k, style: const TextStyle(fontSize: 26)),
                            ),
                    ),
                  ),
              ]),
          ]),
        ),
      ),
    );
  }
}

/// Cloud mode: email + password sign in / sign up.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final pw = TextEditingController();
  bool busy = false;

  Future<void> _go(bool signUp) async {
    final app = App.read(context);
    setState(() => busy = true);
    try {
      signUp ? await app.signUp(email.text, pw.text) : await app.signIn(email.text, pw.text);
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(t('app_name')), actions: [_langToggle(app)]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
            const Icon(Icons.menu_book, size: 64, color: Colors.deepOrange),
            const SizedBox(height: 16),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: d(t('email'))),
            const SizedBox(height: 12),
            TextField(controller: pw, obscureText: true, decoration: d(t('password'))),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: busy ? null : () => _go(false),
              child: Text(t('sign_in')),
            ),
            TextButton(onPressed: busy ? null : () => _go(true), child: Text(t('sign_up'))),
          ]),
        ),
      ),
    );
  }
}

class CreateShopScreen extends StatefulWidget {
  const CreateShopScreen({super.key});
  @override
  State<CreateShopScreen> createState() => _CreateShopScreenState();
}

class _CreateShopScreenState extends State<CreateShopScreen> {
  final shop = TextEditingController();
  final name = TextEditingController();
  bool busy = false;
  String booksStart = todayIso();
  int fyMonth = 4;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(t('create_shop')), actions: [_langToggle(app)]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
            TextField(controller: shop, decoration: d(t('business_name'))),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: d(t('your_name'))),
            const SizedBox(height: 12),
            BooksFields(
              booksStart: booksStart,
              fyMonth: fyMonth,
              onStart: (s) => setState(() => booksStart = s),
              onMonth: (m) => setState(() => fyMonth = m),
            ),
            const SizedBox(height: 4),
            Text(t('books_start_help'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        if (shop.text.trim().isEmpty || name.text.trim().isEmpty) {
                          toast(context, t('err_required'), error: true);
                          setState(() => busy = false);
                          return;
                        }
                        await app.createShop(shop.text.trim(), name.text.trim(), booksStart: booksStart, fyStartMonth: fyMonth);
                      } catch (e) {
                        if (context.mounted) toast(context, errText(context, e), error: true);
                        setState(() => busy = false);
                      }
                    },
              child: Text(t('create_shop')),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('staff_join_help'), style: Theme.of(context).textTheme.bodySmall),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(t('check_again')),
                      onPressed: busy
                          ? null
                          : () async {
                              setState(() => busy = true);
                              try {
                                await app.recheckMembership();
                              } catch (e) {
                                if (context.mounted) toast(context, errText(context, e), error: true);
                              }
                              if (mounted) setState(() => busy = false);
                            },
                    ),
                  ),
                ]),
              ),
            ),
            TextButton(onPressed: app.signOut, child: Text(t('sign_out'))),
          ]),
        ),
      ),
    );
  }
}
