import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../accounting/bank_repo.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../shared/pdf_text.dart';
import '../shared/statement_parser.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// Upload a bank statement and tick off each line against a customer,
/// supplier, transporter or expense. Owner only.
class BankScreen extends StatefulWidget {
  const BankScreen({super.key});
  @override
  State<BankScreen> createState() => _BankScreenState();
}

class _BankScreenState extends State<BankScreen> {
  String? bankId;
  String status = 'open';
  bool busy = false;

  BankRepo _repo(AppController app) => BankRepo(app.db, app.businessId!, app.vouchers);

  Future<void> _upload(AppController app) async {
    final t = app.t;
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'csv', 'xlsx', 'xls', 'txt']);
    if (files.isEmpty || bankId == null) return;
    setState(() => busy = true);
    try {
      final f = files.single;
      final bytes = await f.readAsBytes();
      final isPdf = f.name.toLowerCase().endsWith('.pdf') ||
          (bytes.length > 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46); // %PDF
      final lines = isPdf ? await _readPdf(app, bytes) : StatementParser.parse(bytes, f.name);
      if (lines == null) {
        if (mounted) setState(() => busy = false);
        return; // password dialog cancelled
      }
      final r = await _repo(app).import(bankId!, lines);
      if (mounted) {
        toast(context, t('bank_imported').replaceAll('{a}', '${r.added}').replaceAll('{d}', '${r.duplicates}').replaceAll('{m}', '${r.autoMatched}'));
      }
    } on StatementFormatException catch (e) {
      if (mounted) toast(context, t('bank_err_${e.message}'), error: true);
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => busy = false);
  }

  /// PDF statements: asks for the password when the bank has locked the file
  /// (often date of birth, PAN or account number – the bank's email says which).
  Future<List<StatementLine>?> _readPdf(AppController app, Uint8List bytes) async {
    String? password;
    String? hint;
    while (true) {
      try {
        return StatementParser.parsePdfJson(await extractPdfText(bytes, password: password));
      } on StatementFormatException catch (e) {
        if (e.message != 'needs_password' && e.message != 'wrong_password') rethrow;
        if (!mounted) return null;
        hint = e.message == 'wrong_password' ? app.t('pdf_wrong_password') : null;
        password = await _askPassword(app, hint);
        if (password == null) return null;
      }
    }
  }

  Future<String?> _askPassword(AppController app, String? error) {
    final t = app.t;
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('pdf_password_title')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('pdf_password_help'), style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(labelText: t('password'), errorText: error),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(t('ok'))),
        ],
      ),
    );
  }

  Future<void> _assign(AppController app, BankLine l, Ledger party) async {
    try {
      await _repo(app).assign(l, party, app.actor);
      if (mounted) toast(context, '${app.t('saved')} · ${party.name}');
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('bank_reco')),
        actions: [
          IconButton(
            tooltip: t('auto_match'),
            icon: const Icon(Icons.auto_fix_high),
            onPressed: bankId == null
                ? null
                : () async {
                    final n = await _repo(app).autoMatch(bankId!);
                    if (context.mounted) toast(context, '${t('auto_match')}: $n');
                  },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'bank_upload',
        icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file),
        label: Text(t('upload_statement')),
        onPressed: busy || bankId == null ? null : () => _upload(app),
      ),
      body: LiveBuilder<(List<Ledger>, Map<String, int>, List<BankLine>, (String, int)?, int)>(
        tables: const ['bank_lines', 'vouchers', 'voucher_lines', 'ledgers'],
        reloadKey: '$bankId|$status',
        load: () async {
          final banks = (await app.ledgers.list([LedgerGroup.bank, LedgerGroup.upi]))
            ..sort((a, b) => (a.group == LedgerGroup.bank ? 0 : 1).compareTo(b.group == LedgerGroup.bank ? 0 : 1));
          if (bankId == null) {
            bankId = banks.where((b) => b.group == LedgerGroup.bank).firstOrNull?.id ?? banks.firstOrNull?.id;
            // enable the upload / auto-match buttons, which were built before the account was known
            if (bankId != null && mounted) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
          }
          if (bankId == null) return (banks, <String, int>{}, <BankLine>[], null, 0);
          final repo = _repo(app);
          final stmt = await repo.statementBalance(bankId!);
          final book = stmt == null ? 0 : await app.ledgers.balanceAt(bankId!, date: stmt.$1);
          return (banks, await repo.counts(bankId!), await repo.list(bankId!, status), stmt, book);
        },
        builder: (context, data) {
          final (banks, counts, lines, stmt, book) = data;
          return Column(children: [
            SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), children: [
                for (final b in banks)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(b.display(app.english)),
                      selected: bankId == b.id,
                      onSelected: (_) => setState(() => bankId = b.id),
                    ),
                  ),
              ]),
            ),
            if (stmt != null)
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(child: _kv(context, '${t('stmt_balance')} ${shortDate(stmt.$1)}', stmt.$2)),
                    Expanded(child: _kv(context, t('book_balance'), book)),
                    Expanded(
                      child: _kv(context, t('difference'), stmt.$2 - book,
                          color: stmt.$2 == book ? Colors.green.shade700 : Colors.red.shade700),
                    ),
                  ]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'open', label: Text('${t('bank_open')} (${counts['open'] ?? 0})')),
                  ButtonSegment(value: 'matched', label: Text('${t('bank_matched')} (${counts['matched'] ?? 0})')),
                  ButtonSegment(value: 'ignored', label: Text('${t('bank_ignored')} (${counts['ignored'] ?? 0})')),
                ],
                selected: {status},
                onSelectionChanged: (s) => setState(() => status = s.first),
              ),
            ),
            Expanded(
              child: lines.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(counts.isEmpty ? t('bank_empty') : t('no_entries'), textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 90),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => _LineCard(
                        line: lines[i],
                        repo: _repo(app),
                        onAssign: (p) => _assign(app, lines[i], p),
                      ),
                    ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _kv(BuildContext context, String k, int v, {Color? color}) => Column(children: [
        Text(k, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
        Text(Money.fmt(v), style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      ]);
}

class _LineCard extends StatelessWidget {
  final BankLine line;
  final BankRepo repo;
  final ValueChanged<Ledger> onAssign;
  const _LineCard({required this.line, required this.repo, required this.onAssign});

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final l = line;
    final color = l.isIn ? Colors.green.shade700 : Colors.red.shade700;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(shortDate(l.date), style: Theme.of(context).textTheme.bodySmall),
                Text(l.description, maxLines: 3, overflow: TextOverflow.ellipsis),
                if (l.ref.isNotEmpty) Text(l.ref, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            const SizedBox(width: 8),
            Text('${l.isIn ? '+' : '−'}${Money.fmt(l.amount)}', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
          const SizedBox(height: 6),
          if (l.status == 'open')
            FutureBuilder<List<Ledger>>(
              future: repo.suggest(l.description),
              builder: (context, snap) => Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final p in snap.data ?? const <Ledger>[])
                  ActionChip(avatar: const Icon(Icons.check, size: 16), label: Text(p.name), onPressed: () => onAssign(p)),
                ActionChip(
                  avatar: const Icon(Icons.search, size: 16),
                  label: Text(t('select')),
                  onPressed: () async {
                    final p = await pickLedger(context, groups: [
                      LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter, LedgerGroup.expense,
                      LedgerGroup.directExpense, LedgerGroup.income, LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank,
                      LedgerGroup.capital, LedgerGroup.loan, LedgerGroup.gst, LedgerGroup.otherAsset, LedgerGroup.otherLiability,
                    ], createAs: l.isIn ? LedgerGroup.customer : LedgerGroup.supplier);
                    if (p != null && p.id != l.bankLedgerId) onAssign(p);
                  },
                ),
                TextButton(onPressed: () => repo.setStatus(l, 'ignored'), child: Text(t('bank_ignore'))),
              ]),
            )
          else
            Row(children: [
              Icon(l.status == 'matched' ? Icons.link : Icons.visibility_off, size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(l.status == 'matched' ? (l.partyName ?? t('bank_matched')) : t('bank_ignored'))),
              if (l.voucherId != null)
                TextButton(onPressed: () => VoucherScreen.edit(context, l.voucherId!), child: Text(t('edit'))),
              TextButton(onPressed: () => repo.setStatus(l, 'open'), child: Text(t('bank_undo'))),
            ]),
        ]),
      ),
    );
  }
}
