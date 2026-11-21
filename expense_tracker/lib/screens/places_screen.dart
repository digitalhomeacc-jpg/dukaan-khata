import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../logic/summary.dart';
import '../ui/category_picker.dart';
import '../ui/category_style.dart';
import '../ui/format.dart';
import '../ui/opening_difference.dart';
import '../ui/same_person_card.dart';
import '../ui/selection.dart';
import 'friends_screen.dart';
import 'txn_editor.dart';

enum _Period { month, three, year, all }

/// Where your money goes, grouped by place: visits, total, average, last visit.
class PlacesView extends StatefulWidget {
  const PlacesView({super.key, required this.data});

  final AppData data;

  @override
  State<PlacesView> createState() => _PlacesViewState();
}

class _PlacesViewState extends State<PlacesView> {
  var _period = _Period.three;
  var _byAmount = false;
  var _query = '';

  /// Only places with payments still to give a category.
  var _toSort = false;

  DateTime? get _from {
    final now = DateTime.now();
    return switch (_period) {
      _Period.month => DateTime(now.year, now.month),
      _Period.three => DateTime(now.year, now.month - 2),
      _Period.year => DateTime(now.year - 1, now.month, now.day),
      _Period.all => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    var groups = payeeGroups(
      data.transactions,
      from: _from,
      loanCategoryIds: data.loanCategoryIds,
      shares: data.shareTotalsNow,
      aliases: data.aliases,
    );
    if (_byAmount) groups.sort((a, b) => b.total.compareTo(a.total));
    int unsorted(PayeeGroup g) => g.txns.where((t) => t.categoryId == null).length;
    final withUnsorted = groups.where((g) => unsorted(g) > 0).toList();
    if (_toSort) {
      groups = withUnsorted
        ..sort((a, b) {
          double amt(PayeeGroup g) => g.txns.where((t) => t.categoryId == null).fold(0.0, (v, t) => v + t.amount);
          return amt(b).compareTo(amt(a));
        });
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      groups = groups
          .where(
            (g) =>
                g.name.toLowerCase().contains(q) ||
                (data.category(g.categoryId)?.name.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    final scheme = Theme.of(context).colorScheme;
    final nameCount = <String, int>{};
    for (final g in groups) {
      nameCount[g.name.toLowerCase()] = (nameCount[g.name.toLowerCase()] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: _toSort ? null : const Icon(Icons.help_outline, size: 18),
                  label: Text('To sort (${withUnsorted.length})'),
                  selected: _toSort,
                  onSelected: (v) => setState(() => _toSort = v),
                ),
              ),
              for (final p in _Period.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (p) {
                      _Period.month => 'This month',
                      _Period.three => '3 months',
                      _Period.year => '12 months',
                      _Period.all => 'All time',
                    }),
                    selected: _period == p,
                    onSelected: (_) => setState(() => _period = p),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search places',
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => setState(() => _byAmount = !_byAmount),
                icon: const Icon(Icons.sort, size: 18),
                label: Text(_byAmount ? 'By amount' : 'By visits'),
              ),
            ],
          ),
        ),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              _toSort ? 'Everything in this period has a category.' : 'No spending in this period.',
              textAlign: TextAlign.center,
            ),
          ),
        for (final (i, g) in groups.take(150).indexed)
          ListTile(
            leading: CategoryAvatar(data.category(g.categoryId)),
            title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (_toSort) '${unsorted(g)} to sort',
                '${g.count}× · avg ${money(g.average)} · last ${dayLabel(g.lastPaid)}',
                if ((nameCount[g.name.toLowerCase()] ?? 0) > 1 && g.vpas.isNotEmpty) 'UPI ••${g.vpas.first}',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('−${money(g.total)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                if (g.received > 0)
                  Text('+${money(g.received)}', style: TextStyle(fontSize: 12, color: Colors.green.shade700))
                else if (i < 3 && !_byAmount)
                  Text(['Most frequent', '2nd', '3rd'][i], style: TextStyle(fontSize: 11, color: scheme.primary)),
              ],
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ListenableBuilder(
                  listenable: data,
                  builder: (_, _) => PlaceDetailScreen(data: data, keys: g.keys, vpas: g.vpas),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One place or person as a ledger: who it is, how their money counts, money out / in / running net.
class PlaceDetailScreen extends StatelessWidget {
  const PlaceDetailScreen({super.key, required this.data, required this.keys, this.vpas = const {}, this.extra});

  final AppData data;
  final Set<String> keys;

  /// The place's UPI IDs: two businesses with the same name are told apart by these.
  final Set<String> vpas;

  /// Shown under the summary (a connected friend: what is shared but not in your bank).
  final Widget? extra;

  Future<void> _rename(BuildContext context, PayeeGroup g) async {
    final ctl = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Name this place'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'e.g. Hotel Vijay (nashta)'),
            ),
            const SizedBox(height: 8),
            Text(
              g.vpas.isEmpty
                  ? 'Used for all its payments, now and later.'
                  : 'Used for payments to UPI ••${g.vpas.join(', ••')}, now and later.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await data.renamePlace(vpas: g.vpas, names: g.vpas.isEmpty ? g.keys : const [], nickname: name);
    if (context.mounted) Navigator.pop(context);
  }

  PayeeGroup? _group() {
    // Include friends' ledger payments too, so the statement is complete.
    final all = payeeGroups(
      data.transactions,
      shares: data.shareTotalsNow,
      aliases: data.aliases,
      withMoneyInOnly: true,
    );
    return all.where((x) => vpas.isNotEmpty ? x.vpas.any(vpas.contains) : x.keys.any(keys.contains)).firstOrNull ??
        all.where((x) => x.keys.any(keys.contains)).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final g = _group();
    if (g == null) return const Scaffold(body: Center(child: Text('No payments here any more.')));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final role = data.people[AppData.keyOf(g.name)] ?? (looksLikePerson(g.name) ? null : 'shop');
    final friendsCat = data.loanCategory;
    final inLedger = friendsCat != null && g.txns.isNotEmpty && g.txns.every((t) => t.categoryId == friendsCat.id);
    final ledger = placeLedger(g.txns, shares: data.shareTotalsNow);
    final person = looksLikePerson(g.name);
    // A friend not connected: the statement counts exactly what their balance counts (one formula), from the
    // fresh start's opening balance, with older history and your own spends with them shown but not counted.
    final friendName = data.aliases[AppData.keyOf(g.name)] ?? g.name;
    final friendKey = AppData.keyOf(friendName);
    final asFriend =
        data.linkFor(friendName) == null &&
        (data.people[friendKey] == 'friend' ||
            data.ledgerStarts.containsKey(friendKey) ||
            data.friendBalances.any((b) => AppData.keyOf(b.person) == friendKey));
    final statement = asFriend
        ? friendStatement(
            friendName,
            data.transactions,
            data.loanCategoryIds,
            shares: data.shares,
            aliases: data.aliases,
            starts: data.ledgerStarts,
          )
        : const <FriendLine>[];
    final months = g.byMonth.reversed.take(12).toList();
    final maxMonth = months.fold(0.0, (m, e) => e.value > m ? e.value : m);

    Widget stat(String label, String value, {Color? color}) => Expanded(
      child: Column(
        children: [
          FittedBox(
            child: Text(
              value,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );

    return SelectionHost(
      data: data,
      builder: (context, bar) => Scaffold(
        appBar:
            bar(g.txns.map((t) => t.id)) ??
            AppBar(
              title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _rename(context, g),
                ),
                if (looksLikePerson(g.name))
                  IconButton(
                    tooltip: 'Also known as…',
                    icon: const Icon(Icons.person_add_alt),
                    onPressed: () => showAlsoKnownAs(context, data, g.name),
                  ),
              ],
            ),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              sliver: SliverList.list(
                children: [
                  // Summary card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [scheme.primaryContainer, scheme.secondaryContainer]),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CategoryAvatar(data.category(g.categoryId), size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(g.name, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                                  Text(
                                    [
                                      if (g.vpas.isNotEmpty) 'UPI ••${g.vpas.join(', ••')}',
                                      'since ${DateFormat('MMM yyyy').format(g.first)}',
                                    ].join(' · '),
                                    style: text.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            stat('money out', money(g.total), color: scheme.error),
                            stat('money in', money(g.received), color: Colors.green.shade700),
                            stat(g.net >= 0 ? 'net in' : 'net out', money(g.net.abs())),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${g.count} payments · avg ${money(g.average)} · about '
                          '${g.perMonth >= 1 ? g.perMonth.toStringAsFixed(g.perMonth >= 10 ? 0 : 1) : '<1'}× a month · last ${dayLabel(g.lastPaid)}',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  LinkedNamesCard(data: data, person: g.name),
                  if (looksLikePerson(g.name)) SamePersonCard(data: data, person: g.name),
                  const SizedBox(height: 16),
                  ?extra,
                  // Who is this?
                  Text('Who is this?', style: text.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'shop', label: Text('Shop')),
                      ButtonSegment(value: 'friend', label: Text('Friend')),
                      ButtonSegment(value: 'family', label: Text('Family')),
                      ButtonSegment(value: 'me', label: Text('Me')),
                    ],
                    emptySelectionAllowed: true,
                    selected: {?role},
                    onSelectionChanged: (s) async {
                      if (s.isEmpty) return;
                      final r = s.first;
                      await data.setPersonRole(g.name, r);
                      if (r == 'me') await data.markOwnAccount(g.keys);
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(switch (role) {
                    'shop' => 'A shop, restaurant or service (delivery, driver…): payments are your spending.',
                    'friend' =>
                      'A friend. Choose below whether their payments are your spends or go to your balance with them.',
                    'family' =>
                      'Family: money from them is income (Money from home), money to them is Family spending.',
                    'me' => 'Your own account: money to and from it is a move, not spending or income.',
                    _ => 'Tell the app who this is: it then counts their money the right way.',
                  }, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  if (role == 'friend') ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ListenableBuilder(
                            listenable: data,
                            builder: (_, _) => FriendDetailScreen(
                              data: data,
                              person: data.personNames[AppData.keyOf(g.name)] ?? g.name,
                            ),
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                      label: Text('Balance with ${g.name.split(' ').first}: opening, settle up'),
                    ),
                  ],
                  if (role == 'friend' && friendsCat != null) ...[
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('My spends'),
                          icon: Icon(Icons.shopping_bag_outlined, size: 18),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('Friends ledger'),
                          icon: Icon(Icons.handshake_outlined, size: 18),
                        ),
                      ],
                      selected: {inLedger},
                      onSelectionChanged: (s) =>
                          data.categorizeGroup(g.txns, s.first ? friendsCat.id : null, names: g.keys, vpas: g.vpas),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      inLedger
                          ? 'All payments with them count as owed (lent / borrowed). You can still change single ones.'
                          : 'Payments to them are things they bought for you: give each a category (Quick sort helps).',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (role != 'me' && !inLedger) ...[
                    const SizedBox(height: 16),
                    Text(
                      role == 'friend' ? 'Category for all their payments (optional)' : 'Category for all its payments',
                      style: text.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    CategoryField(
                      data: data,
                      categoryId: g.categoryId,
                      hint: [
                        'All ${g.txns.length} payments',
                        if (g.vpas.difference(sharedVpaTails(data.transactions)) case final own when own.isNotEmpty)
                          'and new ones to ${own.map((v) => '••$v').join(', ')}'
                        else
                          'and new ones by this name',
                      ].join(' '),
                      onTap: () async {
                        final pick = await pickCategory(context, data, selected: g.categoryId, title: g.name);
                        if (pick == null || !context.mounted) return;
                        // Some already sorted one by one? Then ask whether to keep them.
                        final unsorted = g.txns.where((t) => t.categoryId == null).toList();
                        var which = g.txns;
                        if (unsorted.isNotEmpty && unsorted.length < g.txns.length) {
                          final onlyRest = await showDialog<bool>(
                            context: context,
                            builder: (c) => SimpleDialog(
                              title: const Text('Which payments?'),
                              children: [
                                SimpleDialogOption(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: ListTile(
                                    title: Text('Only the ${unsorted.length} with no category'),
                                    subtitle: const Text('Keeps the ones you already sorted'),
                                  ),
                                ),
                                SimpleDialogOption(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: ListTile(title: Text('All ${g.txns.length} payments')),
                                ),
                              ],
                            ),
                          );
                          if (onlyRest == null) return;
                          if (onlyRest) which = unsorted;
                        }
                        await data.categorizeGroup(
                          which,
                          pick.id,
                          vpas: g.vpas,
                          names: g.vpas.isEmpty || !looksLikePerson(g.name) ? g.keys : const {},
                        );
                      },
                    ),
                  ],
                  if (months.length > 1) ...[
                    const SizedBox(height: 20),
                    Text('Money out by month', style: text.titleSmall),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 90,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final m in months.reversed)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 2),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.bottomCenter,
                                        child: FractionallySizedBox(
                                          heightFactor: maxMonth == 0 ? 0.02 : (m.value / maxMonth).clamp(0.02, 1.0),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: scheme.primary,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(DateFormat('MMM').format(m.key), style: const TextStyle(fontSize: 10)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (asFriend) ...[
                    FriendStatementHeader(data: data, person: friendName, statement: statement),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(child: Text(asFriend ? 'Statement' : 'Ledger', style: text.titleSmall)),
                      SizedBox(
                        width: 74,
                        child: Text(person ? 'You gave' : 'Out', textAlign: TextAlign.end, style: text.labelSmall),
                      ),
                      SizedBox(
                        width: 74,
                        child: Text(person ? 'You got' : 'In', textAlign: TextAlign.end, style: text.labelSmall),
                      ),
                      SizedBox(
                        width: 86,
                        child: Text('Balance', textAlign: TextAlign.end, style: text.labelSmall),
                      ),
                    ],
                  ),
                  const Divider(),
                ],
              ),
            ),
            if (asFriend)
              FriendStatementList(data: data, statement: statement)
            else
              SliverList.builder(
                itemCount: ledger.length,
                itemBuilder: (context, i) {
                  final l = ledger[i];
                  final newMonth =
                      i == 0 ||
                      ledger[i - 1].txn.txnAt.month != l.txn.txnAt.month ||
                      ledger[i - 1].txn.txnAt.year != l.txn.txnAt.year;
                  final cat = data.category(l.txn.categoryId);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (newMonth)
                        Container(
                          width: double.infinity,
                          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: Text(DateFormat('MMMM yyyy').format(l.txn.txnAt), style: text.labelMedium),
                        ),
                      Builder(
                        builder: (context) {
                          final sel = TxnSelection.maybeOf(context);
                          final picked = sel?.ids.contains(l.txn.id) ?? false;
                          return InkWell(
                            onTap: () => sel?.active == true
                                ? sel!.toggle(l.txn.id)
                                : openTxnEditor(context, data, existing: l.txn),
                            onLongPress: sel == null ? null : () => sel.toggle(l.txn.id),
                            child: Container(
                              color: picked ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  if (sel?.active == true) SelectTick(selected: picked),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(DateFormat('d MMM, h:mm a').format(l.txn.txnAt), style: text.bodyMedium),
                                        Text(
                                          [
                                            cat?.isLoan == true ? 'Friends ledger' : (cat?.name ?? 'No category'),
                                            if (l.txn.bankName != null) 'as ${l.txn.bankName}',
                                            if ((l.txn.note ?? '').isNotEmpty) l.txn.note!,
                                          ].join(' · '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: text.bodySmall?.copyWith(
                                            color: cat == null ? scheme.error : scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(
                                    width: 74,
                                    child: Text(
                                      l.out > 0 ? money(l.out) : '',
                                      textAlign: TextAlign.end,
                                      style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 74,
                                    child: Text(
                                      l.into > 0 ? money(l.into) : '',
                                      textAlign: TextAlign.end,
                                      style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 86,
                                    child: Text(
                                      '${l.net < 0 ? '−' : ''}${money(l.net.abs())}',
                                      textAlign: TextAlign.end,
                                      style: text.bodySmall?.copyWith(
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
}

/// The balance with a friend in words, as on their page (it is the same number).
class FriendStatementHeader extends StatelessWidget {
  const FriendStatementHeader({super.key, required this.data, required this.person, required this.statement});

  final AppData data;
  final String person;
  final List<FriendLine> statement;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final now = statement.map((l) => l.balance).nonNulls.firstOrNull ?? 0;
    final first = person.split(' ').first;
    final notCounted = statement.where((l) => l.status == 'notCounted' && l.txn?.categoryId == null).length;
    final opening = statement.where((l) => l.status == 'opening').firstOrNull;
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              now.abs() < 0.005 ? 'All settled with $first' : (now > 0 ? 'You owe $first' : '$first owes you'),
              style: text.titleSmall,
            ),
            Text(
              money(now.abs()),
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: now.abs() < 0.005 ? null : (now > 0 ? scheme.error : Colors.green.shade700),
              ),
            ),
            Text(
              [
                if (opening != null)
                  'From your opening balance on ${momentLabel(opening.at)} '
                      '(opening ${opening.amount.abs() < 0.005 ? '₹0' : '${money(opening.amount.abs())} ${opening.amount > 0 ? 'you owed' : 'owed to you'}'})',
                'Only Friends-ledger payments and shares count; the balance column ends at this number.',
              ].join('. '),
              style: text.bodySmall,
            ),
            if (opening != null)
              if (friendHistoryTotal(
                    person,
                    data.transactions,
                    data.loanCategoryIds,
                    shares: data.shares,
                    aliases: data.aliases,
                    starts: data.ledgerStarts,
                  )
                  case final h?)
                OpeningDifference(history: h, opening: opening.amount, person: person),
            if (notCounted > 0) ...[
              const SizedBox(height: 6),
              Text(
                '$notCounted payment${notCounted == 1 ? '' : 's'} with $first not counted (no category): '
                'tap one to put it in the Friends ledger if it was money between you.',
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A friend's statement: newest first, with the running balance.
class FriendStatementList extends StatelessWidget {
  const FriendStatementList({super.key, required this.data, required this.statement});

  final AppData data;
  final List<FriendLine> statement;

  String _what(FriendLine l) {
    final t = l.txn;
    final note = (t?.note ?? '').isEmpty ? null : t!.note;
    return switch (l.kind) {
      'opening' => 'Opening balance · fresh start',
      'share' => ['Their share of ${t?.title ?? 'a bill'} you paid', ?note].join(' · '),
      'paidBy' => ['${t?.title ?? 'A bill'} · they paid for you', ?note].join(' · '),
      'spend' => ['${data.category(t?.categoryId)?.name ?? 'No category'} · not counted', ?note].join(' · '),
      _ => ['Friends ledger', ?note].join(' · '),
    };
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SliverList.builder(
      itemCount: statement.length,
      itemBuilder: (context, i) {
        final l = statement[i];
        final newMonth = i == 0 || statement[i - 1].at.month != l.at.month || statement[i - 1].at.year != l.at.year;
        final faded = l.status == 'history' || l.status == 'notCounted';
        final b = l.balance;
        final row = Opacity(
          opacity: faded ? 0.6 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.kind == 'opening' ? momentLabel(l.at) : DateFormat('d MMM, h:mm a').format(l.at),
                        style: text.bodyMedium,
                      ),
                      Text(
                        l.status == 'history' ? 'History (before fresh start) · ${_what(l)}' : _what(l),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: l.kind == 'spend' && l.txn?.categoryId == null
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    l.kind != 'opening' && l.amount < 0 ? money(-l.amount) : '',
                    textAlign: TextAlign.end,
                    style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    l.kind != 'opening' && l.amount > 0 ? money(l.amount) : '',
                    textAlign: TextAlign.end,
                    style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(
                  width: 86,
                  child: b == null
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              money(b.abs()),
                              style: text.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                            Text(
                              b.abs() < 0.005 ? 'settled' : (b > 0 ? 'you owe' : 'owes you'),
                              style: text.labelSmall?.copyWith(
                                color: b.abs() < 0.005 ? null : (b > 0 ? scheme.error : Colors.green.shade700),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (newMonth)
              Container(
                width: double.infinity,
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(DateFormat('MMMM yyyy').format(l.at), style: text.labelMedium),
              ),
            if (l.txn == null)
              row
            else
              InkWell(
                onTap: () => openTxnEditor(context, data, existing: l.txn),
                child: row,
              ),
          ],
        );
      },
    );
  }
}
