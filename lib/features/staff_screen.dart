import 'package:flutter/material.dart';

import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';
import 'parties_screen.dart';
import 'voucher_screen.dart';

/// कर्मचारी: monthly-salaried staff (not hamals) – salary, advances (उचल) and
/// what is still to be recovered.
class StaffScreen extends StatelessWidget {
  const StaffScreen({super.key});
  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffScreen()));

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    return LiveBuilder<List<Ledger>>(
      load: () => app.ledgers.list([LedgerGroup.staff]),
      builder: (context, list) {
        final advance = list.fold<int>(0, (s, l) => s + (l.balance > 0 ? l.balance : 0));
        return Scaffold(
          appBar: AppBar(title: Text(t('staff'))),
          floatingActionButton: app.actor.isOwner
              ? FloatingActionButton.extended(
                  heroTag: 'staff_add',
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(t('staff_new')),
                  onPressed: () => StaffForm.open(context),
                )
              : null,
          body: list.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t('staff_empty'), textAlign: TextAlign.center)))
              : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                  Container(
                    color: scheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Text('${list.length} ${t('staff')}'),
                      const Spacer(),
                      Text('${t('advance_due')}: '),
                      Text('₹${Money.fmt(advance)}', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.due)),
                    ]),
                  ),
                  for (final l in list) ...[
                    ListTile(
                      leading: CircleAvatar(child: Text(l.name.characters.first)),
                      title: Text(l.name, style: const TextStyle(fontSize: 17)),
                      subtitle: Text([
                        if (l.salary > 0) '${t('salary')} ₹${Money.fmt(l.salary)}',
                        if (l.salaryCut > 0) '${t('salary_cut')} ₹${Money.fmt(l.salaryCut)}',
                        if (l.phone != null) l.phone!,
                      ].join(' · ')),
                      trailing: _StaffBalance(l.balance),
                      onTap: () => KhataScreen.open(context, l.id),
                    ),
                    const Divider(height: 1),
                  ],
                ]),
        );
      },
    );
  }
}

/// + = advance still with them (उचल बाकी), − = salary we still owe.
class _StaffBalance extends StatelessWidget {
  final int balance;
  const _StaffBalance(this.balance);
  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    if (balance == 0) return Text(t('settled'), style: TextStyle(color: Colors.grey.shade600));
    final adv = balance > 0;
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text('₹${Money.fmt(balance.abs())}',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: adv ? AppColors.due : AppColors.haldi)),
      Text(t(adv ? 'advance_due' : 'salary_due'), style: TextStyle(fontSize: 11, color: adv ? AppColors.due : AppColors.haldi)),
    ]);
  }
}

class StaffForm extends StatefulWidget {
  final Ledger? existing;
  const StaffForm({super.key, this.existing});
  static Future<void> open(BuildContext context, {Ledger? existing}) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => StaffForm(existing: existing)));
  @override
  State<StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends State<StaffForm> {
  late final e = widget.existing;
  late final name = TextEditingController(text: e?.name);
  late final nameEn = TextEditingController(text: e?.nameEn);
  late final phone = TextEditingController(text: e?.phone);
  late final salary = TextEditingController(text: (e?.salary ?? 0) == 0 ? '' : Money.fmt(e!.salary).replaceAll(',', ''));
  late final cut = TextEditingController(text: (e?.salaryCut ?? 0) == 0 ? '' : Money.fmt(e!.salaryCut).replaceAll(',', ''));
  late final opening = TextEditingController(
      text: (e?.openingBalance ?? 0) == 0 ? '' : Money.fmt(e!.openingBalance.abs()).replaceAll(',', ''));

  Future<void> _save() async {
    final app = App.read(context);
    if (name.text.trim().isEmpty) return toast(context, app.t('err_required'), error: true);
    String id;
    if (e == null) {
      id = await app.ledgers.create(
        name: name.text,
        nameEn: nameEn.text,
        group: LedgerGroup.staff,
        phone: phone.text,
        openingBalance: Money.parse(opening.text) ?? 0,
      );
    } else {
      id = e!.id;
      await app.ledgers.update(id,
          name: name.text, nameEn: nameEn.text, phone: phone.text, openingBalance: Money.parse(opening.text) ?? 0);
    }
    await app.ledgers.setStaffPay(id, salary: Money.parse(salary.text) ?? 0, cut: Money.parse(cut.text) ?? 0);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    InputDecoration d(String l, {String? help, bool money = false}) =>
        InputDecoration(labelText: l, helperText: help, prefixText: money ? '₹ ' : null, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(e?.name ?? t('staff_new'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, autofocus: e == null, decoration: d(t('name'))),
        const SizedBox(height: 12),
        TextField(controller: nameEn, decoration: d(t('name_en'))),
        const SizedBox(height: 12),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: d(t('phone'))),
        const SizedBox(height: 12),
        TextField(key: const Key('staff_salary'), controller: salary, keyboardType: TextInputType.number, decoration: d(t('salary_monthly'), money: true)),
        const SizedBox(height: 12),
        TextField(
          key: const Key('staff_cut'),
          controller: cut,
          keyboardType: TextInputType.number,
          decoration: d(t('salary_cut_monthly'), help: t('salary_cut_help'), money: true),
        ),
        const SizedBox(height: 12),
        TextField(controller: opening, keyboardType: TextInputType.number, decoration: d(t('advance_opening'), help: t('advance_opening_help'), money: true)),
        const SizedBox(height: 24),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _save, child: Text(t('save'))),
      ]),
    );
  }
}

/// पगार द्या: month's salary, advance recovered, cash handed over.
class SalaryScreen extends StatefulWidget {
  final String staffId;
  const SalaryScreen({super.key, required this.staffId});
  static Future<void> open(BuildContext context, String staffId) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => SalaryScreen(staffId: staffId)));
  @override
  State<SalaryScreen> createState() => _SalaryScreenState();
}

class _SalaryScreenState extends State<SalaryScreen> {
  Ledger? staff;
  List<Ledger> moneyAccounts = [];
  String? payId;
  String date = todayIso();
  late DateTime month = () {
    final n = DateTime.now();
    // salary is usually paid in the first days of the next month
    return n.day <= 10 ? DateTime(n.year, n.month - 1) : DateTime(n.year, n.month);
  }();
  final salary = TextEditingController();
  final cut = TextEditingController();
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = App.read(context);
    staff = await app.ledgers.byId(widget.staffId);
    moneyAccounts = await app.ledgers.list([LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank]);
    payId = app.vouchers.sys('cash');
    final s = staff!;
    if (s.salary > 0) salary.text = Money.fmt(s.salary).replaceAll(',', '');
    final adv = s.balance > 0 ? s.balance : 0;
    final c = s.salaryCut > 0 ? (s.salaryCut < adv ? s.salaryCut : adv) : 0;
    if (c > 0) cut.text = Money.fmt(c).replaceAll(',', '');
    if (mounted) setState(() {});
  }

  int get sal => Money.parse(salary.text) ?? 0;
  int get ded => Money.parse(cut.text) ?? 0;
  int get net => sal - ded;

  String _monthName(DateTime m, AppController app) {
    const mr = ['जानेवारी', 'फेब्रुवारी', 'मार्च', 'एप्रिल', 'मे', 'जून', 'जुलै', 'ऑगस्ट', 'सप्टेंबर', 'ऑक्टोबर', 'नोव्हेंबर', 'डिसेंबर'];
    const en = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${(app.english ? en : mr)[m.month - 1]} ${m.year}';
  }

  Future<void> _save() async {
    final app = App.read(context);
    final t = app.t;
    if (sal <= 0) return toast(context, t('err_amount'), error: true);
    if (ded < 0 || ded > sal) return toast(context, t('err_salary_cut'), error: true);
    setState(() => saving = true);
    try {
      await app.vouchers.save(
        VoucherInput(
          type: VoucherType.salary,
          date: date,
          partyId: staff!.id,
          payLedgerId: payId,
          amount: sal,
          paid: net,
          narration: '${t('salary')} ${_monthName(month, app)}${ded > 0 ? ' · ${t('salary_cut')} ₹${Money.fmt(ded)}' : ''}',
        ),
        app.actor,
      );
      if (!mounted) return;
      toast(context, '${t('saved')} · ${t('salary_hand')} ₹${Money.fmt(net)}');
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
    final s = staff;
    final adv = s == null ? 0 : (s.balance > 0 ? s.balance : 0);
    const num = [FontFeature.tabularFigures()];
    Widget row(String label, String value, {Color? color, bool bold = false, double size = 16}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))),
            Text(value, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: color, fontFeatures: num)),
          ]),
        );
    final months = [for (var i = -2; i <= 1; i++) DateTime(DateTime.now().year, DateTime.now().month + i)];
    return Scaffold(
      appBar: AppBar(title: Text('${t('salary_pay')}${s == null ? '' : ' · ${s.name}'}')),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 110), children: [
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final m in months)
                      ChoiceChip(
                        label: Text(_monthName(m, app)),
                        selected: m.year == month.year && m.month == month.month,
                        onSelected: (_) => setState(() => month = m),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  AmountField(controller: salary, label: t('salary_month'), onChanged: (_) => setState(() {})),
                  const SizedBox(height: 12),
                  Card(
                    color: AppColors.due.withValues(alpha: 0.06),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        row(t('advance_due'), '₹${Money.fmt(adv)}', color: adv > 0 ? AppColors.due : null),
                        const SizedBox(height: 8),
                        AmountField(controller: cut, label: t('salary_cut_now'), onChanged: (_) => setState(() {})),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, children: [
                          if (adv > 0)
                            ActionChip(
                              label: Text(t('cut_all')),
                              onPressed: () => setState(() => cut.text = Money.fmt(adv < sal ? adv : sal).replaceAll(',', '')),
                            ),
                          if (s.salaryCut > 0 && adv > 0)
                            ActionChip(
                              label: Text('₹${Money.fmt(s.salaryCut)}'),
                              onPressed: () => setState(() => cut.text = Money.fmt(s.salaryCut < adv ? s.salaryCut : adv).replaceAll(',', '')),
                            ),
                          ActionChip(label: Text(t('cut_none')), onPressed: () => setState(() => cut.clear())),
                        ]),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(children: [
                        row(t('salary'), '₹${Money.fmt(sal)}'),
                        row('− ${t('salary_cut')}', '₹${Money.fmt(ded)}'),
                        const Divider(),
                        row(t('salary_hand'), '₹${Money.fmt(net)}', bold: true, size: 22, color: net < 0 ? AppColors.due : AppColors.paid),
                        row(t('advance_left'), '₹${Money.fmt(adv - ded > 0 ? adv - ded : 0)}'),
                      ]),
                    ),
                  ),
                  SectionTitle(t('pay_mode')),
                  PayModeChips(accounts: moneyAccounts, selected: payId, allowCredit: false, onSelected: (id) => setState(() => payId = id)),
                  const SizedBox(height: 12),
                  DateField(date: date, label: t('date'), first: Books.start, onChanged: (d) => setState(() => date = d)),
                ]),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            key: const Key('salary_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: saving || s == null || !app.actor.isOwner || sal <= 0 || net < 0 ? null : _save,
            icon: const Icon(Icons.payments_outlined),
            label: Text(t('salary_pay_amt').replaceAll('{amt}', Money.fmt(net))),
          ),
        ),
      ),
    );
  }
}

/// Khata page banner for a staff member: salary, advance, quick actions.
class StaffKhataActions extends StatelessWidget {
  final Ledger staff;
  const StaffKhataActions({super.key, required this.staff});
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    return Row(children: [
      Expanded(
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.due, minimumSize: const Size.fromHeight(52)),
          onPressed: () => VoucherScreen.open(context, VoucherType.payment, partyId: staff.id, narration: t('advance_given')),
          child: Text(t('advance_give'), style: const TextStyle(fontSize: 17)),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.paid, minimumSize: const Size.fromHeight(52)),
          onPressed: app.actor.isOwner ? () => SalaryScreen.open(context, staff.id) : null,
          child: Text(t('salary_pay'), style: const TextStyle(fontSize: 17)),
        ),
      ),
    ]);
  }
}
