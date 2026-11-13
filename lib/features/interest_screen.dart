import 'package:flutter/material.dart';

import '../accounting/interest.dart';
import '../accounting/models.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';

/// व्याज for one party: rate, period, day-by-day working, one tap to put it on the khata.
class InterestScreen extends StatefulWidget {
  final String partyId;
  const InterestScreen({super.key, required this.partyId});
  static Future<void> open(BuildContext context, String partyId) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => InterestScreen(partyId: partyId)));
  @override
  State<InterestScreen> createState() => _InterestScreenState();
}

class _InterestScreenState extends State<InterestScreen> {
  Ledger? party;
  String? lastCharged;
  late String to = todayIso();
  String from = todayIso();
  final rate = TextEditingController();
  bool remember = true;
  InterestCalc? calc;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    party = await app.ledgers.byId(widget.partyId);
    lastCharged = await app.interest.lastCharged(widget.partyId);
    from = await app.interest.defaultFrom(widget.partyId, to);
    if (party!.interestRate > 0) rate.text = fmtRate(party!.interestRate);
    await _calc();
  }

  Future<void> _calc() async {
    final app = App.read(context);
    final c = await app.interest.calculate(widget.partyId, from: from, to: to, rate: parseRate(rate.text));
    if (mounted) setState(() => calc = c);
  }

  void _setFrom(String d) {
    from = d.compareTo(Books.start) < 0 ? Books.start : d;
    _calc();
  }

  Future<void> _post() async {
    final app = App.read(context);
    final t = app.t;
    final c = calc!;
    setState(() => saving = true);
    try {
      final r = parseRate(rate.text);
      if (remember && r != party!.interestRate) await app.ledgers.setInterestRate(party!.id, r);
      await app.interest.post(app.vouchers, app.actor, c, note: interestNote(t, c));
      if (!mounted) return;
      toast(context, '${t('saved')} · ${t('interest')} ₹${Money.fmt(c.interest)}');
      Navigator.pop(context);
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
    final p = party;
    final c = calc;
    final r = parseRate(rate.text);
    const num = [FontFeature.tabularFigures()];
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);

    return Scaffold(
      appBar: AppBar(title: Text(t('interest'))),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 110), children: [
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(p.pageNo ?? p.name.characters.first)),
                      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(lastCharged == null
                          ? t('interest_never')
                          : t('interest_last').replaceAll('{date}', shortDate(lastCharged!))),
                      trailing: BalanceText(p.balance, supplier: p.group == LedgerGroup.supplier),
                      onTap: () => KhataScreen.open(context, p.id),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: 150,
                      child: TextField(
                        key: const Key('interest_rate'),
                        controller: rate,
                        autofocus: p.interestRate == 0,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: t('interest_rate'),
                          suffixText: '%',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          helperText: r > 0 ? t('interest_yearly').replaceAll('{r}', fmtRate(r * 12)) : null,
                        ),
                        onChanged: (_) => _calc(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: remember,
                        title: Text(t('interest_remember'), style: const TextStyle(fontSize: 13)),
                        onChanged: (v) => setState(() => remember = v ?? true),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  DateField(
                    date: from,
                    label: t('from'),
                    first: Books.start,
                    last: to,
                    onChanged: _setFrom,
                  ),
                  const SizedBox(height: 10),
                  DateField(
                    date: to,
                    label: t('to'),
                    first: Books.start,
                    last: todayIso(),
                    onChanged: (d) {
                      to = d;
                      _calc();
                    },
                  ),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, children: [
                    if (lastCharged != null)
                      ActionChip(
                        label: Text(t('interest_since_last')),
                        onPressed: () => _setFrom(isoDate(parseIso(lastCharged!).add(const Duration(days: 1)))),
                      ),
                    for (final (label, months) in [(t('months_1'), 1), (t('months_3'), 3), (t('months_6'), 6), (t('months_12'), 12)])
                      ActionChip(
                        label: Text(label),
                        onPressed: () {
                          final e = parseIso(to);
                          _setFrom(isoDate(DateTime(e.year, e.month - months, e.day).add(const Duration(days: 1))));
                        },
                      ),
                  ]),
                  const SizedBox(height: 12),
                  if (c != null)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(children: [
                        Container(
                          color: scheme.surfaceContainerHigh,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(children: [
                            Expanded(flex: 4, child: Text(t('period'), style: muted)),
                            Expanded(flex: 3, child: Text(t('balance'), style: muted, textAlign: TextAlign.right)),
                            Expanded(flex: 2, child: Text(t('days'), style: muted, textAlign: TextAlign.right)),
                            Expanded(flex: 3, child: Text(t('interest'), style: muted, textAlign: TextAlign.right)),
                          ]),
                        ),
                        if (c.slabs.isEmpty)
                          Padding(padding: const EdgeInsets.all(16), child: Text(t('interest_nothing'), style: muted)),
                        for (final s in c.slabs)
                          Container(
                            decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)))),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            child: Row(children: [
                              Expanded(flex: 4, child: Text('${shortDate(s.from)} – ${shortDate(s.to)}', style: const TextStyle(fontSize: 13))),
                              Expanded(
                                flex: 3,
                                child: Text(s.balance > 0 ? Money.fmt(s.balance) : '${Money.fmt(s.balance.abs())} ${t('advance_short')}',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(fontFeatures: num, color: s.balance > 0 ? null : scheme.onSurfaceVariant)),
                              ),
                              Expanded(flex: 2, child: Text('${s.days}', textAlign: TextAlign.right, style: const TextStyle(fontFeatures: num))),
                              Expanded(
                                flex: 3,
                                child: Text(s.interest == 0 ? '–' : (s.interest / 100).toStringAsFixed(2),
                                    textAlign: TextAlign.right, style: const TextStyle(fontFeatures: num)),
                              ),
                            ]),
                          ),
                        Container(
                          color: scheme.primaryContainer.withValues(alpha: 0.45),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(children: [
                            Expanded(child: Text('${t('interest')} · ${c.days} ${t('days')}', style: const TextStyle(fontWeight: FontWeight.w700))),
                            Text('₹${Money.fmt(c.interest)}',
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.due, fontFeatures: num)),
                          ]),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 8),
                  Text(t('interest_help'), style: muted),
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const Key('interest_post'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || c == null || c.interest <= 0 || !app.actor.isOwner ? null : _post,
            icon: const Icon(Icons.add),
            label: Text(c == null || c.interest <= 0
                ? t('interest_post')
                : t('interest_post_amt').replaceAll('{amt}', Money.fmt(c.interest))),
          ),
        ),
      ),
    );
  }
}

/// Narration written on the khata: "व्याज 1/10/26 – 30/10/26 · 1.5% दरमहा".
String interestNote(String Function(String) t, InterestCalc c) =>
    '${t('interest')} ${shortDate(c.from)} – ${shortDate(c.to)} · ${fmtRate(c.rate)}% ${t('per_month')}';

/// Every party with an interest rate: what is due since their last interest
/// entry – tap one to check, or put it on all khatas at once.
class InterestListScreen extends StatefulWidget {
  const InterestListScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const InterestListScreen()));
  @override
  State<InterestListScreen> createState() => _InterestListScreenState();
}

class _InterestListScreenState extends State<InterestListScreen> {
  int reload = 0;
  bool saving = false;

  Future<List<(Ledger, InterestCalc)>> _load() async {
    final app = App.read(context);
    final to = todayIso();
    final out = <(Ledger, InterestCalc)>[];
    for (final l in await app.ledgers.list([LedgerGroup.customer, LedgerGroup.supplier])) {
      if (l.interestRate <= 0) continue;
      final from = await app.interest.defaultFrom(l.id, to);
      out.add((l, await app.interest.calculate(l.id, from: from, to: to, rate: l.interestRate)));
    }
    out.sort((a, b) => b.$2.interest.compareTo(a.$2.interest));
    return out;
  }

  Future<void> _postAll(List<(Ledger, InterestCalc)> list) async {
    final app = App.read(context);
    final t = app.t;
    final due = list.where((e) => e.$2.interest > 0).toList();
    final total = due.fold(0, (s, e) => s + e.$2.interest);
    if (!await confirm(context, t('interest_all_q').replaceAll('{n}', '${due.length}').replaceAll('{amt}', Money.fmt(total)))) return;
    setState(() => saving = true);
    try {
      for (final (_, c) in due) {
        await app.interest.post(app.vouchers, app.actor, c, note: interestNote(t, c));
      }
      if (mounted) toast(context, '${t('saved')} · ₹${Money.fmt(total)}');
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => (saving = false, reload++));
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return LiveBuilder<List<(Ledger, InterestCalc)>>(
      reloadKey: reload,
      load: _load,
      builder: (context, list) {
        final total = list.fold(0, (s, e) => s + e.$2.interest);
        return Scaffold(
          appBar: AppBar(title: Text(t('interest_list'))),
          floatingActionButton: total > 0 && app.actor.isOwner
              ? FloatingActionButton.extended(
                  heroTag: 'interest_all',
                  onPressed: saving ? null : () => _postAll(list),
                  icon: const Icon(Icons.playlist_add_check),
                  label: Text(t('interest_post_all').replaceAll('{amt}', Money.fmt(total))),
                )
              : null,
          body: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t('interest_list_empty'), textAlign: TextAlign.center),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final (l, c) = list[i];
                    return ListTile(
                      leading: CircleAvatar(child: Text(l.pageNo ?? l.name.characters.first, style: const TextStyle(fontSize: 13))),
                      title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${fmtRate(l.interestRate)}% ${t('per_month')} · '
                        '${c.slabs.isEmpty ? t('interest_upto_date') : '${shortDate(c.from)} – ${shortDate(c.to)}'}',
                      ),
                      trailing: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(c.interest > 0 ? '₹${Money.fmt(c.interest)}' : '–',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.interest > 0 ? AppColors.due : scheme.onSurfaceVariant)),
                          BalanceText(l.balance, size: 12),
                        ]),
                      ),
                      onTap: () async {
                        await InterestScreen.open(context, l.id);
                        if (mounted) setState(() => reload++);
                      },
                    );
                  },
                ),
        );
      },
    );
  }
}
