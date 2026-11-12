import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../accounting/models.dart';
import '../core/money.dart';
import '../state/app_controller.dart';

/// Re-runs [load] whenever the given tables change (local edits or sync).
class LiveBuilder<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;
  final List<String> tables;
  final Object? reloadKey;
  const LiveBuilder({
    super.key,
    required this.load,
    required this.builder,
    this.tables = const ['vouchers', 'voucher_lines', 'inventory_lines', 'ledgers', 'items'],
    this.reloadKey,
  });
  @override
  State<LiveBuilder<T>> createState() => _LiveBuilderState<T>();
}

class _LiveBuilderState<T> extends State<LiveBuilder<T>> {
  T? _data;
  Object? _error;
  dynamic _sub;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= App.read(context).db.onChange(widget.tables).listen((_) => _reload());
  }

  @override
  void didUpdateWidget(covariant LiveBuilder<T> old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _reload();
  }

  Future<void> _reload() async {
    try {
      final d = await widget.load();
      if (mounted) setState(() {
        _data = d;
        _error = null;
      });
    } catch (e, st) {
      debugPrint('$e\n$st');
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text('$_error')));
    if (_data == null) return const Center(child: CircularProgressIndicator());
    return widget.builder(context, _data as T);
  }
}

/// Balance shown Khatabook-style: red "येणे" if they owe us, green "देणे" if we owe.
class BalanceText extends StatelessWidget {
  final int balance;
  final bool supplier;
  final double size;
  /// Days since this balance was last paid towards (shown small, when given).
  final int? days;
  const BalanceText(this.balance, {super.key, this.supplier = false, this.size = 16, this.days});
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    if (balance == 0) {
      return Text(app.t('settled'), style: TextStyle(color: Colors.grey.shade600, fontSize: size * 0.8));
    }
    final owesUs = balance > 0;
    final color = owesUs ? Colors.red.shade700 : Colors.green.shade700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('₹${Money.fmt(balance, abs: true)}',
            style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.bold)),
        Text(owesUs ? app.t('they_owe') : app.t('we_owe'), style: TextStyle(color: color, fontSize: size * 0.7)),
        if (days != null && days! > 0)
          Text(app.t('days_unpaid').replaceAll('{n}', '$days'),
              style: TextStyle(
                  fontSize: 11,
                  // quiet until it is old: grey → amber after a month → red after two
                  color: days! > 60 ? Colors.red.shade400 : days! > 30 ? Colors.orange.shade700 : Colors.grey.shade600)),
      ],
    );
  }
}

class AmountField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  const AmountField({super.key, required this.controller, required this.label, this.autofocus = false, this.onChanged, this.focusNode});
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,०-९]'))],
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        decoration: InputDecoration(labelText: label, prefixText: '₹ ', border: const OutlineInputBorder()),
      );
}

class DateButton extends StatelessWidget {
  final String date;
  final ValueChanged<String> onChanged;
  final bool enabled;
  const DateButton({super.key, required this.date, required this.onChanged, this.enabled = true});
  @override
  Widget build(BuildContext context) {
    final d = parseIso(date);
    final isToday = date == todayIso();
    return OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today, size: 18),
      label: Text(isToday ? '${App.of(context).t('today')} ${shortDate(date)}' : shortDate(date)),
      onPressed: !enabled
          ? null
          : () async {
              final start = parseIso(Books.start);
              final p = await showDatePicker(
                context: context,
                initialDate: d,
                firstDate: d.isBefore(start) ? d : start,
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (p != null) onChanged(isoDate(p));
            },
    );
  }
}

/// Date you can type (14/9/26, 140926, 14/9 …) or pick from the calendar.
/// Enter moves to the next field, like Tally.
class DateField extends StatefulWidget {
  final String date;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final String? first; // earliest allowed (YYYY-MM-DD)
  final String? last; // latest allowed; also decides the year when it is not typed
  final String? label;
  final bool autofocus;
  const DateField({
    super.key,
    required this.date,
    required this.onChanged,
    this.enabled = true,
    this.first,
    this.last,
    this.label,
    this.autofocus = false,
  });
  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  late final _c = TextEditingController(text: shortDate(widget.date));
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length); // type over it
      } else if (_error == null) {
        _c.text = shortDate(widget.date);
      }
    });
  }

  @override
  void didUpdateWidget(covariant DateField old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date && !_focus.hasFocus) _c.text = shortDate(widget.date);
  }

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  bool _inRange(String iso) =>
      (widget.first == null || iso.compareTo(widget.first!) >= 0) && (widget.last == null || iso.compareTo(widget.last!) <= 0);

  void _typed(String text) {
    final t = App.read(context).t;
    final iso = parseTypedDate(text, latest: widget.last);
    setState(() {
      if (iso == null) {
        _error = text.trim().isEmpty ? null : t('date_hint');
      } else if (!_inRange(iso)) {
        _error = widget.first != null && widget.last != null
            ? t('date_between').replaceAll('{a}', shortDate(widget.first!)).replaceAll('{b}', shortDate(widget.last!))
            : widget.last != null
            ? t('date_on_or_before').replaceAll('{d}', shortDate(widget.last!))
            : t('date_on_or_after').replaceAll('{d}', shortDate(widget.first!));
      } else {
        _error = null;
        widget.onChanged(iso);
      }
    });
  }

  Future<void> _pick() async {
    final d = parseIso(widget.date);
    final first = widget.first == null ? DateTime(2000) : parseIso(widget.first!);
    final last = widget.last == null ? DateTime.now().add(const Duration(days: 365)) : parseIso(widget.last!);
    final p = await showDatePicker(
      context: context,
      initialDate: d.isBefore(first) ? first : (d.isAfter(last) ? last : d),
      firstDate: first,
      lastDate: last,
      initialEntryMode: DatePickerEntryMode.calendar,
    );
    if (p != null) {
      final iso = isoDate(p);
      _c.text = shortDate(iso);
      setState(() => _error = null);
      widget.onChanged(iso);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = App.of(context).t;
    final isToday = widget.date == todayIso();
    return TextField(
      key: const Key('date_field'),
      controller: _c,
      focusNode: _focus,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.datetime,
      textInputAction: TextInputAction.next,
      onChanged: _typed,
      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
      decoration: InputDecoration(
        labelText: widget.label ?? t('date'),
        isDense: true,
        prefixIcon: const Icon(Icons.event, size: 20),
        suffixText: isToday && _error == null ? t('today') : null,
        errorText: _error,
        suffixIcon: IconButton(
          tooltip: t('calendar'),
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: widget.enabled ? _pick : null,
        ),
      ),
    );
  }
}

/// Day stepper: ◀ 5/11/26 ▶
class DayStepper extends StatelessWidget {
  final String date;
  final ValueChanged<String> onChanged;
  const DayStepper({super.key, required this.date, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final d = parseIso(date);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => onChanged(isoDate(d.subtract(const Duration(days: 1))))),
      DateButton(date: date, onChanged: onChanged),
      IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => onChanged(isoDate(d.add(const Duration(days: 1))))),
    ]);
  }
}

/// Big round chips for payment accounts: रोख C, फोनपे H, … plus "उधार".
class PayModeChips extends StatelessWidget {
  final List<Ledger> accounts;
  final String? selected; // ledger id, or null = udhar (credit)
  final ValueChanged<String?> onSelected;
  final bool allowCredit;
  final String? creditLabel;
  const PayModeChips(
      {super.key, required this.accounts, required this.selected, required this.onSelected, this.allowCredit = true, this.creditLabel});
  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (allowCredit)
        ChoiceChip(
          label: Text(creditLabel ?? app.t('udhar')),
          selected: selected == null,
          selectedColor: Colors.orange.shade200,
          onSelected: (_) => onSelected(null),
        ),
      for (final a in accounts)
        ChoiceChip(
          avatar: a.shortCode == null ? null : CircleAvatar(child: Text(a.shortCode!, style: const TextStyle(fontSize: 12))),
          label: Text(a.display(app.english)),
          selected: selected == a.id,
          onSelected: (_) => onSelected(a.id),
        ),
    ]);
  }
}

/// Searchable party picker – search by name (Marathi/English), page no., phone.
Future<Ledger?> pickLedger(BuildContext context, {required List<LedgerGroup> groups, LedgerGroup? createAs}) {
  return showModalBottomSheet<Ledger>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LedgerPicker(groups: groups, createAs: createAs),
  );
}

class _LedgerPicker extends StatefulWidget {
  final List<LedgerGroup> groups;
  final LedgerGroup? createAs;
  const _LedgerPicker({required this.groups, this.createAs});
  @override
  State<_LedgerPicker> createState() => _LedgerPickerState();
}

class _LedgerPickerState extends State<_LedgerPicker> {
  final _q = TextEditingController();
  List<Ledger> _results = [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    final app = App.read(context);
    final r = _q.text.trim().isEmpty ? await app.ledgers.list(widget.groups) : await app.ledgers.search(_q.text, groups: widget.groups);
    if (mounted) setState(() => _results = r);
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => _search(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: app.t('search_party'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (widget.createAs != null)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_add)),
              title: Text(_q.text.trim().isEmpty ? app.t('new_ledger') : '${app.t('add')} "${_q.text.trim()}"'),
              onTap: () async {
                final name = _q.text.trim();
                if (name.isEmpty) return;
                final id = await app.ledgers.create(name: name, group: widget.createAs!);
                final l = await app.ledgers.byId(id);
                if (context.mounted) Navigator.pop(context, l);
              },
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final l = _results[i];
                return ListTile(
                  leading: CircleAvatar(child: Text(l.pageNo ?? l.name.characters.first)),
                  title: Text(l.name),
                  subtitle: Text([if (l.nameEn != null) l.nameEn!, if (l.phone != null) l.phone!].join(' · ')),
                  trailing: l.group.isParty ? BalanceText(l.balance, supplier: l.group == LedgerGroup.supplier, size: 14) : null,
                  onTap: () => Navigator.pop(context, l),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// Turns any error into a sentence in the user's language.
String errText(BuildContext context, Object e) {
  final t = App.read(context).t;
  final key = switch (e) {
    ArgumentError a => '${a.message}',
    Exception x when x.toString().startsWith('err_') => x.toString(),
    _ => e.toString(),
  };
  return t(key).replaceAll('{date}', shortDate(Books.start));
}

void toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Colors.red.shade700 : null,
    duration: const Duration(seconds: 2),
  ));
}

Future<bool> confirm(BuildContext context, String msg) async {
  final app = App.read(context);
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          content: Text(msg),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(app.t('no'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(app.t('yes'))),
          ],
        ),
      ) ??
      false;
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// क्लाउड जागा: how much of the free 500 MB database is used.
class StorageMeter extends StatelessWidget {
  final bool compact; // home-screen warning style
  const StorageMeter({super.key, this.compact = false});

  static String mb(int b) => b >= 1024 * 1024 ? '${(b / 1024 / 1024).toStringAsFixed(b < 10 * 1024 * 1024 ? 1 : 0)} MB' : '${(b / 1024).round()} KB';

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final s = app.storage;
    final scheme = Theme.of(context).colorScheme;
    final f = s?.fraction ?? 0;
    final color = f >= 0.9 ? Colors.red.shade700 : f >= 0.7 ? Colors.orange.shade800 : Colors.green.shade700;
    if (compact) {
      return Material(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          key: const Key('storage_warning'),
          leading: Icon(Icons.storage, color: color),
          title: Text(t('storage_warn').replaceAll('{p}', '${(f * 100).round()}'), style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(t('storage_warn_sub')),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.storage, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(t('storage_title'), style: const TextStyle(fontWeight: FontWeight.w700))),
            IconButton(
              tooltip: t('refresh'),
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => app.refreshStorage(),
            ),
          ]),
          if (s == null)
            TextButton(onPressed: () => app.refreshStorage(), child: Text(t('storage_check')))
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: f.clamp(0.0, 1.0),
                minHeight: 12,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${mb(s.usedBytes)} / 500 MB  ·  ${(f * 100).toStringAsFixed(f < 0.1 ? 1 : 0)}%${s.exact ? '' : '  (${t('storage_estimate')})'}',
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
            Text(
              t('storage_detail')
                  .replaceAll('{entries}', '${s.entries}')
                  .replaceAll('{hist}', '${s.historyRows}')
                  .replaceAll('{hsize}', mb(s.historyBytes)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!s.exact && app.cloud)
              Text(t('storage_need_sql'), style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
            if (f >= 0.7) Text(t('storage_warn_sub'), style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }
}
