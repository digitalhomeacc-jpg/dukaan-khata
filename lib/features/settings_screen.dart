import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../accounting/models.dart';
import '../core/config.dart';
import '../core/money.dart';
import '../shared/party_import.dart';
import '../shared/statement_parser.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'audit_screen.dart';
import 'bank_screen.dart';
import 'books_screens.dart';
import 'parties_screen.dart';
import 'report_view.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final owner = app.actor.isOwner;
    return Scaffold(
      appBar: AppBar(title: Text(t('more'))),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.local_shipping),
          title: Text(t('suppliers')),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PartiesScreen(group: LedgerGroup.supplier))),
        ),
        ListTile(
          leading: const Icon(Icons.bar_chart),
          title: Text(t('reports')),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen())),
        ),
        const Divider(),
        SectionTitle(t('settings')),
        ListTile(
          leading: const Icon(Icons.translate),
          title: Text(t('language')),
          trailing: SegmentedButton<bool>(
            segments: [ButtonSegment(value: false, label: Text(t('marathi'))), ButtonSegment(value: true, label: Text(t('english')))],
            selected: {app.english},
            onSelectionChanged: (s) => app.setEnglish(s.first),
          ),
        ),
        if (owner)
          ListTile(
            leading: const Icon(Icons.store),
            title: Text(t('shop_details')),
            subtitle: Text('${app.businessName} · ${t('books_start')} ${shortDate(Books.start)}'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShopDetailsScreen())),
          ),
        if (owner)
          ListTile(
            leading: const Icon(Icons.account_balance),
            title: Text(t('bank_reco')),
            subtitle: Text(t('bank_reco_sub')),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BankScreen())),
          ),
        ListTile(
          leading: const Icon(Icons.account_balance_wallet),
          title: Text(t('accounts')),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountsScreen())),
        ),
        if (owner) ...[
          ListTile(
            leading: const Icon(Icons.people),
            title: Text(t('users')),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UsersScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: Text(t('import_opening')),
            subtitle: Text(t('import_opening_sub')),
            onTap: () => _import(context),
          ),
          ListTile(
            leading: const Icon(Icons.description),
            title: Text(t('export_template')),
            onTap: () => _template(context),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: Text(t('full_backup')),
            subtitle: Text(t('full_backup_sub')),
            onTap: () async {
              final bytes = await app.exportBackup();
              final name = 'dukaan_khata_backup_${todayIso()}.json';
              await SharePlus.instance.share(ShareParams(
                files: [XFile.fromData(bytes, mimeType: 'application/json', name: name)],
                fileNameOverrides: [name],
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(t('audit')),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AuditScreen())),
          ),
        ],
        if (app.cloud)
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(t('sign_out')),
            onTap: () async {
              if (!await confirm(context, '${t('sign_out')}?')) return;
              try {
                await app.signOut();
              } catch (e) {
                if (context.mounted) toast(context, errText(context, e), error: true);
              }
            },
          ),
        const SizedBox(height: 24),
        Center(child: Text('Dukaan Khata · ${t('version')} ${AppConfig.build}', style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 24),
      ]),
    );
  }

  Future<void> _template(BuildContext context) async {
    final book = xl.Excel.createExcel();
    final s = book[book.getDefaultSheet()!];
    s.appendRow(['name', 'page_no', 'phone', 'balance', 'name_en', 'type'].map(xl.TextCellValue.new).toList());
    s.appendRow([
      xl.TextCellValue('सुरेश जाधव'),
      xl.TextCellValue('29'),
      xl.TextCellValue('9800000000'),
      xl.DoubleCellValue(31250),
      xl.TextCellValue('Suresh Jadhav'),
      xl.TextCellValue('customer'),
    ]);
    final bytes = book.encode()!;
    await SharePlus.instance.share(ShareParams(files: [
      XFile.fromData(
        Uint8List.fromList(bytes),
        mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        name: 'opening_balances.xlsx',
      )
    ], fileNameOverrides: const ['opening_balances.xlsx']));
  }

  /// Import customers / suppliers with opening balances from Excel or CSV
  /// (see PartyImport for the columns and how balances are read).
  Future<void> _import(BuildContext context) async {
    final app = App.read(context);
    final t = app.t;
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'csv']);
    if (files.isEmpty) return;
    final f = files.single;
    final PartySheet sheet;
    try {
      sheet = PartyImport.parse(StatementParser.rowsFromBytes(await f.readAsBytes(), f.name));
    } catch (e) {
      if (context.mounted) toast(context, '${t('import_failed')}: $e', error: true);
      return;
    }
    if (sheet.rows.isEmpty) {
      if (context.mounted) toast(context, t('import_nothing'), error: true);
      return;
    }
    // show what will happen before writing anything
    final owe = sheet.rows.where((r) => r.balance > 0).length;
    final adv = sheet.rows.where((r) => r.balance < 0).length;
    if (!context.mounted) return;
    final ok = await confirm(
      context,
      t('import_preview')
          .replaceAll('{n}', '${sheet.rows.length}')
          .replaceAll('{owe}', '$owe')
          .replaceAll('{adv}', '$adv')
          .replaceAll('{skip}', sheet.skipped.isEmpty ? '' : '\n${t('import_skipped')}: ${sheet.skipped.join(', ')}'),
    );
    if (!ok) return;
    var added = 0, updated = 0;
    final all = await app.ledgers.list(const [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter]);
    for (final r in sheet.rows) {
      // same person already there? match on page no. + name, or the exact name
      final existing = all.where((l) =>
          l.group == r.group &&
          (l.name == r.name || (r.nameEn != null && l.nameEn == r.nameEn)) &&
          (r.pageNo == null || l.pageNo == null || l.pageNo == r.pageNo)).firstOrNull;
      if (existing != null) {
        await app.ledgers.update(existing.id,
            // a Marathi name added to the sheet later replaces the English one
            name: r.nameEn != null && r.name != r.nameEn ? r.name : existing.name,
            nameEn: r.nameEn ?? existing.nameEn,
            phone: r.phone ?? existing.phone,
            address: existing.address,
            pageNo: r.pageNo ?? existing.pageNo,
            shortCode: existing.shortCode,
            gstin: existing.gstin,
            openingBalance: r.balance,
            creditLimit: existing.creditLimit);
        updated++;
      } else {
        await app.ledgers.create(
            name: r.name, nameEn: r.nameEn, group: r.group, phone: r.phone, pageNo: r.pageNo, openingBalance: r.balance);
        added++;
      }
    }
    if (context.mounted) {
      toast(context, t('import_done').replaceAll('{a}', '$added').replaceAll('{u}', '$updated'));
    }
  }
}

/// Money accounts, expenses, GST, capital… (everything that isn't a customer/supplier).
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final groups = LedgerGroup.values.where((g) => !g.isParty).toList();
    return Scaffold(
      appBar: AppBar(title: Text(t('accounts'))),
      floatingActionButton: app.actor.isOwner
          ? FloatingActionButton(
              heroTag: 'acct_add',
              onPressed: () => PartyForm.open(context, LedgerGroup.expense),
              child: const Icon(Icons.add),
            )
          : null,
      body: LiveBuilder<(List<Ledger>, List<Ledger>)>(
        load: () async => (await app.ledgers.list(groups), await app.ledgers.hidden()),
        builder: (context, data) {
          final (list, hidden) = data;
          final children = <Widget>[];
          for (final g in groups) {
            final ls = list.where((l) => l.group == g).toList();
            if (ls.isEmpty) continue;
            children.add(SectionTitle(t('grp_${g.code}')));
            for (final l in ls) {
              children.add(ListTile(
                leading: l.shortCode == null ? const Icon(Icons.folder_outlined) : CircleAvatar(child: Text(l.shortCode!)),
                title: Text(l.display(app.english)),
                subtitle: l.nameEn != null && !app.english ? Text(l.nameEn!) : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(Money.fmt(l.balance), style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (app.actor.isOwner)
                    IconButton(
                      tooltip: t('edit'),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => PartyForm.open(context, l.group, existing: l),
                    ),
                ]),
                onTap: () => KhataScreen.open(context, l.id),
              ));
            }
          }
          if (hidden.isNotEmpty && app.actor.isOwner) {
            children.add(const Divider(height: 32));
            children.add(SectionTitle('${t('hidden_ledgers')} (${hidden.length})'));
            for (final l in hidden) {
              children.add(ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(l.display(app.english)),
                subtitle: Text('${t('grp_${l.group.code}')} · ${Money.fmt(l.balance)}'),
                trailing: TextButton(
                  onPressed: () => app.ledgers.setArchived(l.id, false),
                  child: Text(t('restore')),
                ),
              ));
            }
          }
          return ListView(padding: const EdgeInsets.only(bottom: 90), children: children);
        },
      ),
    );
  }
}

/// Local mode: owner PIN + staff PIN. Cloud mode: invite staff by email + device PIN.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final ownerPin = TextEditingController();
  final staffPin = TextEditingController();
  final staffName = TextEditingController();
  final devicePin = TextEditingController();
  final email = TextEditingController();
  List<Map<String, dynamic>> members = [];

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final app = App.read(context);
    if (!app.cloud) return;
    try {
      final m = await app.listMembers();
      if (mounted) setState(() => members = m);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(t('users'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!app.cloud) ...[
          Text('${t('role_owner')} – ${t('pin')}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(controller: ownerPin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: d(t('set_pin'))),
          const SizedBox(height: 16),
          Text('${t('role_staff')} – ${t('pin')}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(controller: staffName, decoration: d(t('name'))),
          const SizedBox(height: 8),
          TextField(controller: staffPin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: d(t('set_pin'))),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await app.setPins(
                ownerPin: ownerPin.text.length >= 4 ? ownerPin.text : null,
                staffPin: staffPin.text.length >= 4 ? staffPin.text : null,
                staffName: staffName.text.isEmpty ? null : staffName.text,
              );
              if (context.mounted) toast(context, t('saved'));
            },
            child: Text(t('save')),
          ),
        ] else ...[
          Text(t('invite_staff'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(controller: staffName, decoration: d(t('name'))),
          const SizedBox(height: 8),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: d(t('email'))),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              try {
                await app.inviteStaff(email.text, staffName.text);
                email.clear();
                staffName.clear();
                await _loadMembers();
              } catch (e) {
                if (context.mounted) toast(context, errText(context, e), error: true);
              }
            },
            child: Text(t('add')),
          ),
          const SizedBox(height: 16),
          for (final m in members)
            ListTile(
              leading: Icon(m['role'] == 'owner' ? Icons.star : Icons.person),
              title: Text('${m['name'] ?? ''} (${m['role'] == 'owner' ? t('role_owner') : t('role_staff')})'),
              subtitle: Text('${m['email'] ?? ''}${m['user_id'] == null ? ' · pending' : ''}'),
              trailing: m['role'] == 'owner'
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await app.removeMember(m['id'] as String);
                        await _loadMembers();
                      },
                    ),
            ),
          const Divider(height: 32),
          Text('${t('pin')} (this device)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(controller: devicePin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: d(t('set_pin'))),
          FilledButton(
            onPressed: () async {
              await app.setPins(devicePin: devicePin.text);
              if (context.mounted) toast(context, t('saved'));
            },
            child: Text(t('save')),
          ),
        ],
      ]),
    );
  }
}
