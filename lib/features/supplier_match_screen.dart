import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/pdf_text.dart';
import '../shared/statement_parser.dart';
import '../shared/supplier_statement.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'voucher_screen.dart';

/// कंपनी स्टेटमेंट जुळवा: the supplier's own account statement (PDF) set
/// against our khata – what is on theirs but not ours, and the other way.
class SupplierMatchScreen extends StatefulWidget {
  final Ledger supplier;
  const SupplierMatchScreen({super.key, required this.supplier});
  static Future<void> open(BuildContext context, Ledger supplier) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => SupplierMatchScreen(supplier: supplier)));
  @override
  State<SupplierMatchScreen> createState() => _SupplierMatchScreenState();
}

class _SupplierMatchScreenState extends State<SupplierMatchScreen> {
  List<SupplierLine>? lines; // the whole statement
  SupplierMatch? match; // from the books start on
  int ourBalance = 0, ourOpening = 0;
  bool busy = false;
  String? error;

  Future<void> _pick() async {
    final app = App.read(context);
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (files.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final Uint8List bytes = await files.single.readAsBytes();
      final parsed = SupplierStatement.parsePdfJson(await extractPdfText(bytes));
      if (parsed.isEmpty) throw StatementFormatException('pdf_unreadable');
      lines = parsed;
      await _rematch();
    } on StatementFormatException catch (e) {
      error = app.t('bank_err_${e.message}');
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  /// Statement lines from the books start on, against our entries of the same days.
  Future<void> _rematch() async {
    final app = App.read(context);
    final all = lines!;
    final inBooks = all.where((l) => !Books.isHistory(l.date)).toList();
    final st = await app.ledgers.statement(widget.supplier.id, from: Books.start, to: all.last.date.compareTo(todayIso()) > 0 ? all.last.date : todayIso());
    final ours = [
      for (final r in st.rows)
        KhataEntry(r.voucherId, r.date, '${app.t('vt_${r.type.code}')}${r.details.isEmpty ? '' : ' · ${r.details}'}', r.credit, r.debit)
    ];
    final fresh = await app.ledgers.byId(widget.supplier.id);
    if (!mounted) return;
    setState(() {
      match = SupplierMatch.match(inBooks, ours);
      ourBalance = fresh?.balance ?? 0;
      ourOpening = fresh?.openingBalance ?? 0;
    });
  }

  /// Their balance just before our books start (+ = we owed them).
  int? get _theirOpening {
    final before = lines!.where((l) => Books.isHistory(l.date)).toList();
    return before.isEmpty ? null : before.last.balance;
  }

  Future<void> _addDiscount(SupplierLine l) async {
    final app = App.read(context);
    await app.vouchers.save(
        VoucherInput(type: VoucherType.payment, date: l.date, partyId: widget.supplier.id, discount: l.credit, narration: '${app.t('co_discount_short')} – ${l.text}'),
        app.actor);
  }

  Future<void> _addAllDiscounts() async {
    final t = App.read(context).t;
    final list = match!.missing.where((l) => l.kind == 'discount').toList();
    if (!await confirm(context, t('sm_all_discounts_q').replaceAll('{n}', '${list.length}').replaceAll('{amt}', Money.fmt(list.fold(0, (s, l) => s + l.credit))))) return;
    setState(() => busy = true);
    try {
      for (final l in list) {
        await _addDiscount(l);
      }
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    await _rematch();
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final m = match;
    String bal(int theirs) => '₹${Money.fmt(theirs.abs())} ${theirs >= 0 ? t('we_owe') : t('sm_advance')}';
    return Scaffold(
      appBar: AppBar(title: Text('${t('sm_title')} · ${widget.supplier.name}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('sm_help'), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('sm_pick'),
                onPressed: busy ? null : _pick,
                icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.picture_as_pdf),
                label: Text(t(lines == null ? 'sm_pick' : 'sm_pick_again')),
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: AppColors.due))),
            ]),
          ),
        ),
        if (m != null && lines != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${shortDate(lines!.first.date)} – ${shortDate(lines!.last.date)} · ${lines!.length} ${t('sm_lines')}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                _cmp(t('sm_closing'), bal(lines!.last.balance), bal(-ourBalance), lines!.last.balance == -ourBalance),
                if (_theirOpening case final o?) _cmp(t('sm_opening').replaceAll('{date}', shortDate(Books.start)), bal(o), bal(-ourOpening), o == -ourOpening),
                _cmp(t('sm_billed'), '₹${Money.fmt(m.stBilled)}', '₹${Money.fmt(m.ourBought)}', m.stBilled == m.ourBought),
                _cmp(t('sm_credited'), '₹${Money.fmt(m.stCredited)}', '₹${Money.fmt(m.ourPaid)}', m.stCredited == m.ourPaid),
                const SizedBox(height: 6),
                Text(
                    m.missing.isEmpty && m.extra.isEmpty
                        ? '✓ ${t('sm_all_match').replaceAll('{n}', '${m.matched}')}'
                        : t('sm_result').replaceAll('{ok}', '${m.matched}').replaceAll('{a}', '${m.missing.length}').replaceAll('{b}', '${m.extra.length}'),
                    style: TextStyle(fontWeight: FontWeight.w700, color: m.missing.isEmpty && m.extra.isEmpty ? AppColors.paid : AppColors.haldi)),
              ]),
            ),
          ),
          if (m.missing.isNotEmpty) ...[
            SectionTitle('${t('sm_missing')} (${m.missing.length})'),
            if (m.missing.where((l) => l.kind == 'discount').length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    key: const Key('sm_all_discounts'),
                    onPressed: busy ? null : _addAllDiscounts,
                    icon: const Icon(Icons.done_all),
                    label: Text(t('sm_all_discounts'))),
              ),
            for (final l in m.missing)
              Card(
                child: ListTile(
                  dense: true,
                  title: Text('${shortDate(l.date)} · ${t('sm_kind_${l.kind}')}${l.qty > 0 ? ' · ${fmtQty(l.qty)}' : ''}'),
                  subtitle: Text(l.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(Money.fmt(l.amount),
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: l.debit > 0 ? AppColors.due : AppColors.paid)),
                    if (l.kind != 'charge')
                      IconButton(
                        tooltip: t('sm_add'),
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: busy
                            ? null
                            : () async {
                                switch (l.kind) {
                                  case 'discount':
                                    await _addDiscount(l);
                                  case 'payment':
                                    await VoucherScreen.open(context, VoucherType.payment,
                                        partyId: widget.supplier.id, amount: l.credit, narration: l.text, date: l.date);
                                  default:
                                    await VoucherScreen.open(context, VoucherType.purchase, partyId: widget.supplier.id, date: l.date);
                                }
                                await _rematch();
                              },
                      ),
                  ]),
                ),
              ),
          ],
          if (m.extra.isNotEmpty) ...[
            SectionTitle('${t('sm_extra')} (${m.extra.length})'),
            for (final e in m.extra)
              Card(
                child: ListTile(
                  dense: true,
                  title: Text('${shortDate(e.date)} · ${e.text}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Text(Money.fmt(e.bought > 0 ? e.bought : e.paid),
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: e.bought > 0 ? AppColors.due : AppColors.paid)),
                  onTap: () async {
                    await VoucherScreen.edit(context, e.voucherId);
                    await _rematch();
                  },
                ),
              ),
          ],
        ],
      ]),
    );
  }

  Widget _cmp(String label, String theirs, String ours, bool same) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(same ? Icons.check_circle : Icons.error_outline, size: 18, color: same ? AppColors.paid : AppColors.haldi),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${App.of(context).t('sm_theirs')}: $theirs   ·   ${App.of(context).t('sm_ours')}: $ours', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ]),
      );
}
