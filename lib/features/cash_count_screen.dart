import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';

/// रोख मोजणी: count the cash in the drawer, compare with the books and post
/// the difference to "रोख फरक" (short = loss, extra = income) in one tap.
class CashCountScreen extends StatefulWidget {
  final String? date;
  const CashCountScreen({super.key, this.date});
  static Future<void> open(BuildContext context, {String? date}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => CashCountScreen(date: date)));
  @override
  State<CashCountScreen> createState() => _CashCountScreenState();
}

const _notes = [500, 200, 100, 50, 20, 10];

class _CashCountScreenState extends State<CashCountScreen> {
  late String date = widget.date ?? todayIso();
  int? book; // cash as per the books, up to and including [date]
  final counts = {for (final n in _notes) n: TextEditingController()};
  final coins = TextEditingController(); // coins / loose change in ₹
  final total = TextEditingController(); // typed directly instead of notes
  bool totalTyped = false;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  Future<void> _loadBook() async {
    final app = App.read(context);
    final b = await app.ledgers.balanceAt(app.vouchers.sys('cash'), date: date);
    if (mounted) setState(() => book = b);
  }

  int _n(TextEditingController c) => int.tryParse(normalizeDigits(c.text.trim())) ?? 0;

  /// Counted cash in paise.
  int get counted {
    if (totalTyped) return Money.parse(total.text) ?? 0;
    var s = 0;
    for (final n in _notes) {
      s += _n(counts[n]!) * n * 100;
    }
    return s + (Money.parse(coins.text) ?? 0);
  }

  bool get anything => totalTyped ? total.text.trim().isNotEmpty : (_notes.any((n) => _n(counts[n]!) > 0) || coins.text.trim().isNotEmpty);

  String get _breakdown => totalTyped
      ? ''
      : [
          for (final n in _notes)
            if (_n(counts[n]!) > 0) '$n×${_n(counts[n]!)}',
          if ((Money.parse(coins.text) ?? 0) > 0) '${App.read(context).t('coins')} ${Money.fmt(Money.parse(coins.text)!)}',
        ].join(', ');

  Future<void> _save() async {
    final app = App.read(context);
    final t = app.t;
    final diff = counted - (book ?? 0);
    if (diff == 0) {
      await app.ledgers.markCounted(date, counted, 0);
      if (!mounted) return;
      toast(context, t('cash_ok'));
      Navigator.pop(context, true);
      return;
    }
    setState(() => saving = true);
    try {
      final note = [
        '${t('cash_count')}: ₹${Money.fmt(counted)}',
        if (_breakdown.isNotEmpty) '($_breakdown)',
      ].join(' ');
      // short → paid out of cash into रोख फरक; extra → came into cash from it
      await app.vouchers.save(
        VoucherInput(
          type: diff < 0 ? VoucherType.payment : VoucherType.receipt,
          date: date,
          partyId: app.vouchers.sys('cash_diff'),
          payLedgerId: app.vouchers.sys('cash'),
          amount: diff.abs(),
          narration: note,
        ),
        app.actor,
      );
      await app.ledgers.markCounted(date, counted, diff);
      if (!mounted) return;
      toast(context, '${t('saved')} · ${t(diff < 0 ? 'cash_short' : 'cash_extra')} ₹${Money.fmt(diff.abs())}');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        toast(context, errText(context, e), error: true);
        setState(() => saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final diff = counted - (book ?? 0);
    const num = [FontFeature.tabularFigures()];
    Widget figure(String label, int v, {Color? color, double size = 17, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))),
            Text('₹${Money.fmt(v)}', style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: color, fontFeatures: num)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text(t('cash_count'))),
      body: book == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
                  DateField(
                    date: date,
                    label: t('date'),
                    first: Books.start,
                    last: todayIso(),
                    onChanged: (d) {
                      setState(() {
                        date = d;
                        book = null;
                      });
                      _loadBook();
                    },
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(t('count_notes'))),
                      ButtonSegment(value: true, label: Text(t('count_total'))),
                    ],
                    selected: {totalTyped},
                    onSelectionChanged: (s) => setState(() => totalTyped = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (totalTyped)
                    AmountField(controller: total, label: t('counted_cash'), autofocus: true, onChanged: (_) => setState(() {}))
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        child: Column(children: [
                          for (final n in _notes)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(children: [
                                SizedBox(
                                  width: 70,
                                  child: Text('₹$n', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, fontFeatures: num)),
                                ),
                                Text('×', style: TextStyle(color: scheme.onSurfaceVariant)),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 90,
                                  child: TextField(
                                    key: Key('note_$n'),
                                    controller: counts[n],
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(isDense: true, hintText: '0'),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    _n(counts[n]!) == 0 ? '' : '₹${Money.fmt(_n(counts[n]!) * n * 100)}',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: num),
                                  ),
                                ),
                              ]),
                            ),
                          const SizedBox(height: 6),
                          AmountField(controller: coins, label: t('coins_loose'), onChanged: (_) => setState(() {})),
                        ]),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(children: [
                        figure(t('cash_as_per_books'), book!, color: scheme.onSurfaceVariant),
                        figure(t('counted_cash'), counted),
                        const Divider(height: 16),
                        if (!anything)
                          Text(t('cash_count_help'), style: TextStyle(color: scheme.onSurfaceVariant))
                        else if (diff == 0)
                          Row(children: [
                            const Icon(Icons.check_circle, color: AppColors.paid),
                            const SizedBox(width: 8),
                            Text(t('cash_ok'), style: const TextStyle(color: AppColors.paid, fontWeight: FontWeight.w700, fontSize: 16)),
                          ])
                        else
                          figure(t(diff < 0 ? 'cash_short' : 'cash_extra'), diff.abs(),
                              color: diff < 0 ? AppColors.due : AppColors.paid, size: 22, bold: true),
                      ]),
                    ),
                  ),
                  if (anything && diff != 0) ...[
                    const SizedBox(height: 8),
                    Text(t('cash_check_first'), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const Key('cash_count_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || book == null || !anything ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(!anything || diff == 0 ? t('save') : t('cash_book_diff').replaceAll('{amt}', Money.fmt(diff.abs()))),
          ),
        ),
      ),
    );
  }
}
