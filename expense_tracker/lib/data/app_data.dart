import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../logic/duplicates.dart';
import '../logic/goals.dart';
import '../logic/recurring.dart';
import '../logic/summary.dart'
    show
        LoanBalance,
        accountBalances,
        ShareTotals,
        allocateSettle,
        groupPairwise,
        loanBalances,
        loanEventsWithPayments,
        samePersonCandidates,
        shareTotals,
        sharedBalance,
        sharedVpaTails,
        splitEqually;
import '../models.dart';

/// Live copy of the signed-in user's data, kept up to date by Supabase Realtime.
/// Row Level Security on the server guarantees only this user's rows arrive.
class AppData extends ChangeNotifier {
  AppData(SupabaseClient db) : _client = db {
    _subs = [
      db.from('transactions').stream(primaryKey: ['id']).order('txn_at').limit(10000).listen((rows) {
        transactions = _parse(rows, Txn.fromMap)..sort((a, b) => b.txnAt.compareTo(a.txnAt));
        loaded = true;
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('goals').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        goals = _parse(rows, Goal.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('recurring').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        recurring = _parse(rows, Recurring.fromMap);
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('recurring_runs').stream(primaryKey: ['id']).listen((rows) {
        recurringRuns = _parse(rows, RecurringRun.fromMap);
        _runsLoaded = true;
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('categories').stream(primaryKey: ['id']).order('name', ascending: true).listen((rows) {
        categories = _parse(rows, Category.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('accounts').stream(primaryKey: ['id']).order('created_at', ascending: true).listen((rows) {
        accounts = _parse(rows, Account.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('loans').stream(primaryKey: ['id']).order('created_at', ascending: true).listen((rows) {
        loans = _parse(rows, Loan.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('loan_events').stream(primaryKey: ['id']).order('event_at').listen((rows) {
        storedLoanEvents = _parse(rows, LoanEvent.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('balance_readings').stream(primaryKey: ['id']).order('as_of').listen((rows) {
        balanceReadings = _parse(rows, BalanceReading.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('groups').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        groups = _parse(rows, Group.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('group_expenses').stream(primaryKey: ['id']).order('at').listen((rows) {
        groupExpenses = _parse(rows, GroupExpense.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('txn_parts').stream(primaryKey: ['id']).listen((rows) {
        parts = _parse(rows, TxnPart.fromMap);
        _shareTotals = null;
        notifyListeners();
      }, onError: _onError),
      db.from('txn_shares').stream(primaryKey: ['id']).listen((rows) {
        shares = _parse(rows, TxnShare.fromMap);
        _shareTotals = null;
        notifyListeners();
      }, onError: _onError),
      db.from('budgets').stream(primaryKey: ['id']).listen((rows) {
        budgets = _parse(rows, Budget.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('friend_links').stream(primaryKey: ['id']).listen((rows) {
        links = _parse(rows, FriendLink.fromMap);
        _streamsIn.add('links');
        _carryOpenings();
        notifyListeners();
      }, onError: _onError),
      db.from('shared_entries').stream(primaryKey: ['id']).order('at').listen((rows) {
        sharedEntries = _parse(rows, SharedEntry.fromMap);
        notifyListeners();
      }, onError: _onError),
      // Opening balances with connected friends (ignored quietly until the database has the table).
      db.from('friend_openings').stream(primaryKey: ['id']).listen((rows) {
        openings = _parse(rows, FriendOpening.fromMap);
        _streamsIn.add('openings');
        _carryOpenings();
        notifyListeners();
      }, onError: (_) {}),
      db.from('match_questions').stream(primaryKey: ['id']).listen((rows) {
        questions = _parse(rows, MatchQuestion.fromMap);
        notifyListeners();
      }, onError: _onError),
      db.from('friend_aliases').stream(primaryKey: ['user_id', 'alias_key']).listen((rows) {
        aliases = {for (final r in rows) r['alias_key'] as String: r['friend_name'] as String};
        _streamsIn.add('aliases');
        _carryOpenings();
        notifyListeners();
      }, onError: _onError),
      db.from('people').stream(primaryKey: ['user_id', 'name_key']).listen((rows) {
        people = {for (final r in rows) r['name_key'] as String: r['role'] as String};
        personNames = {for (final r in rows) r['name_key'] as String: r['name'] as String};
        ledgerStarts = {
          for (final r in rows)
            if (r['ledger_from'] != null)
              r['name_key'] as String: (
                name: r['name'] as String,
                // The exact moment you set it; older ones have only the day (from its start).
                from: r['ledger_at'] != null
                    ? DateTime.parse(r['ledger_at'] as String).toLocal()
                    : DateTime.parse(r['ledger_from'] as String),
                opening: double.tryParse('${r['opening'] ?? 0}') ?? 0,
              ),
        };
        _streamsIn.add('people');
        _carryOpenings();
        notifyListeners();
      }, onError: _onError),
      db.from('profiles').stream(primaryKey: ['id']).listen((rows) {
        if (rows.isNotEmpty) profile = rows.first;
        notifyListeners();
      }, onError: _onError),
    ];
    refreshUnread();
  }

  /// Offline copy with fixed data, for widget tests.
  @visibleForTesting
  AppData.preview({
    required this.transactions,
    required this.categories,
    this.accounts = const [],
    this.loans = const [],
    List<LoanEvent> loanEvents = const [],
    this.balanceReadings = const [],
    this.shares = const [],
    this.budgets = const [],
    this.links = const [],
    this.sharedEntries = const [],
    this.questions = const [],
    this.aliases = const {},
    this.myId,
    this.unread = const [],
    this.profile = const {},
    this.recurring = const [],
    this.recurringRuns = const [],
    this.goals = const [],
    this.openings = const [],
  }) : storedLoanEvents = loanEvents,
       _client = null,
       loaded = true {
    _subs = [];
  }

  final SupabaseClient? _client;
  SupabaseClient get _db => _client!;
  late final List<StreamSubscription<dynamic>> _subs;

  bool loaded = false;
  Object? error;
  List<Txn> transactions = const [];
  List<Category> categories = const [];
  List<Account> accounts = const [];
  List<Loan> loans = const [];

  /// Loan events as stored (lender emails, payments a server rule linked).
  List<LoanEvent> storedLoanEvents = const [];

  /// Every loan event, including payments linked to a loan that the server has not turned into events yet.
  List<LoanEvent> get loanEvents {
    final from = _eventsFrom;
    if (from == null ||
        !identical(from.$1, storedLoanEvents) ||
        !identical(from.$2, transactions) ||
        !identical(from.$3, loans)) {
      _events = loanEventsWithPayments(storedLoanEvents, transactions, loans);
      _eventsFrom = (storedLoanEvents, transactions, loans);
    }
    return _events;
  }

  (List<LoanEvent>, List<Txn>, List<Loan>)? _eventsFrom;
  List<LoanEvent> _events = const [];
  List<BalanceReading> balanceReadings = const [];
  List<TxnShare> shares = const [];
  List<Budget> budgets = const [];
  List<FriendLink> links = const [];
  List<SharedEntry> sharedEntries = const [];
  List<MatchQuestion> questions = const [];

  /// Person (lower-case name) → role: friend, family, me or shop.
  Map<String, String> people = const {};

  /// Friends started fresh: from that day, with an opening balance (positive: you owe them).
  Map<String, ({String name, DateTime from, double opening})> ledgerStarts = const {};

  /// Balance with each friend, honouring fresh starts.
  List<LoanBalance> get friendBalances =>
      loanBalances(transactions, loanCategoryIds, shares: shares, aliases: aliases, starts: ledgerStarts);

  /// Starts [names] fresh from [from]: older entries become history. [opening] by name key (positive: you owe).
  Future<void> startFresh(Map<String, String> names, DateTime from, {Map<String, double> opening = const {}}) async {
    // The opening stands for everything up to this exact moment (not the whole day): payments earlier that day are
    // history, later ones count on top.
    ledgerStarts = {
      ...ledgerStarts,
      for (final MapEntry(:key, :value) in names.entries) key: (name: value, from: from, opening: opening[key] ?? 0),
    };
    notifyListeners();
    final d = '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    List<Map<String, dynamic>> rows({required bool exact}) => [
      for (final MapEntry(:key, :value) in names.entries)
        {
          'name_key': key,
          'name': value,
          'role': people[key] ?? 'friend',
          'ledger_from': d,
          if (exact) 'ledger_at': from.toUtc().toIso8601String(),
          'opening': opening[key] ?? 0,
        },
    ];
    try {
      await _db.from('people').upsert(rows(exact: true), onConflict: 'user_id,name_key');
    } on PostgrestException catch (e) {
      // Before RUN_IN_SUPABASE_5.sql the database keeps only the day.
      if (!e.message.contains('ledger_at')) rethrow;
      await _db.from('people').upsert(rows(exact: false), onConflict: 'user_id,name_key');
    }
  }

  /// How each person's name is written, by name key.
  Map<String, String> personNames = const {};

  /// Payee name (lower case) → friend name: "Also known as".
  Map<String, String> aliases = const {};

  /// Signed-in user id (set directly in previews).
  String? myId;
  String? get me => myId ?? user?.id;

  /// The key of the name a person is shown as ("Also known as" names go to the main name).
  String canonKey(String name) => keyOf(aliases[keyOf(name)] ?? name);

  /// The active connection with this friend, if any: by the name in my list or any other name of theirs.
  FriendLink? linkFor(String person) {
    final k = canonKey(person);
    for (final l in links) {
      if (l.active && me != null && l.nameFor(me!).isNotEmpty && canonKey(l.nameFor(me!)) == k) return l;
    }
    return null;
  }

  /// The category a payee's payments almost always have (at least 2, 4 in 5 of them), by any of their names; null
  /// if there is no clear habit. [except]: the payment being edited.
  String? usualCategoryOf(String name, {String? except}) {
    if (name.trim().isEmpty) return null;
    final k = canonKey(name);
    final counts = <String, int>{};
    var all = 0;
    for (final t in transactions) {
      if (t.id == except || t.categoryId == null || canonKey(t.title) != k) continue;
      all++;
      counts[t.categoryId!] = (counts[t.categoryId!] ?? 0) + 1;
    }
    if (all < 2) return null;
    final best = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first;
    return best.value * 5 >= all * 4 ? best.key : null;
  }

  /// "Not lent and returned": the other half goes back to unsorted (kept as your choice, so it is not paired
  /// again) for you to say what it was.
  Future<void> unpairRoundTrip(Txn other) async {
    final r = await _db
        .from('transactions')
        .update({'category_id': null, 'needs_review': true, 'edited': true})
        .eq('id', other.id)
        .select()
        .maybeSingle();
    if (r != null) _showNow(r);
  }

  /// Your friends' names, the ones you deal with most first (balances, connections, people you marked friends).
  List<String> get friendNames {
    final seen = <String>{};
    final out = <String>[];
    void add(String n) {
      final name = aliases[keyOf(n)] ?? n.trim();
      if (name.isNotEmpty && seen.add(keyOf(name))) out.add(name);
    }

    for (final b in friendBalances) {
      add(b.person);
    }
    for (final l in links) {
      if (l.active && me != null && l.nameFor(me!).isNotEmpty) add(l.nameFor(me!));
    }
    for (final MapEntry(:key, :value) in people.entries) {
      if (value == 'friend') add(personNames[key] ?? key);
    }
    return out;
  }

  /// An invite I sent to this friend that is not accepted yet.
  FriendLink? pendingInviteFor(String person) {
    final k = canonKey(person);
    for (final l in links) {
      if (!l.active && l.a == me && canonKey(l.aNameForB) == k) return l;
    }
    return null;
  }

  final Set<String> _streamsIn = {};
  final Set<String> _carried = {};

  /// A friend you started fresh with before you connected: that start becomes the opening balance you both see,
  /// so their older records do not change what is owed. Only when the connection has no opening balance yet.
  Future<void> _carryOpenings() async {
    if (!_streamsIn.containsAll(const {'links', 'openings', 'people', 'aliases'}) || me == null) return;
    for (final l in links) {
      if (!l.active || _carried.contains(l.id) || openings.any((o) => o.linkId == l.id)) continue;
      final name = l.nameFor(me!);
      if (name.isEmpty) continue;
      final start = ledgerStarts[canonKey(name)] ?? ledgerStarts[keyOf(name)];
      if (start == null) continue;
      _carried.add(l.id);
      try {
        await proposeOpening(
          l,
          start.from.subtract(const Duration(microseconds: 1)),
          start.opening,
          'From your fresh start before connecting',
        );
      } catch (_) {
        _carried.remove(l.id);
      }
    }
  }

  ShareTotals? _shareTotals;

  /// Friends' parts of group payments, for the totals.
  ShareTotals get shareTotalsNow => _shareTotals ??= shareTotals(shares, parts: parts);

  // ------------------------------------------------------------------ goals

  List<Goal> goals = const [];

  GoalProgress progressOf(Goal g) => goalProgress(
    g,
    txns: transactions,
    accounts: accounts,
    categories: categories,
    notSpendingIds: notSpendingCategoryIds,
    shares: shareTotalsNow,
  );

  Future<void> saveGoal({
    String? id,
    required String kind,
    required String name,
    String? emoji,
    required DateTime startsOn,
    double? targetAmount,
    DateTime? deadline,
    String? accountId,
    String? categoryId,
    double? cutPct,
  }) async {
    String? d(DateTime? x) => x == null ? null : _date(x);
    final row = {
      'kind': kind,
      'name': name.trim(),
      'emoji': emoji,
      'starts_on': d(startsOn),
      'target_amount': kind == 'save' ? targetAmount : null,
      'deadline': kind == 'save' ? d(deadline) : null,
      'account_id': kind == 'save' ? accountId : null,
      'category_id': kind == 'cut' ? categoryId : null,
      'cut_pct': kind == 'cut' ? cutPct : null,
    };
    if (id == null) {
      final r = await _db.from('goals').insert(row).select().single();
      goals = [...goals.where((g) => g.id != r['id']), Goal.fromMap(r)];
    } else {
      final r = await _db.from('goals').update(row).eq('id', id).select().single();
      goals = [for (final g in goals) g.id == id ? Goal.fromMap(r) : g];
    }
    notifyListeners();
  }

  Future<void> archiveGoal(String id, {bool archived = true}) =>
      _db.from('goals').update({'archived': archived}).eq('id', id);

  // ------------------------------------------------------------------ repeats

  List<Recurring> recurring = const [];
  List<RecurringRun> recurringRuns = const [];
  var _runsLoaded = false;
  Timer? _recurringTimer;
  var _recurringBusy = false;

  Recurring? recurringById(String? id) => recurring.where((r) => r.id == id).firstOrNull;

  /// What is due and what to do now (see [planRecurring]).
  RecurringPlan get recurringPlan => planRecurring(recurring, recurringRuns, transactions, DateTime.now());

  /// The repeat a payment settled, if any.
  RecurringRun? runForTxn(String txnId) => recurringRuns.where((r) => r.txnId == txnId).firstOrNull;

  void _scheduleRecurring() {
    if (_client == null || !loaded || !_runsLoaded || recurring.isEmpty) return;
    _recurringTimer?.cancel();
    _recurringTimer = Timer(const Duration(seconds: 2), runRecurring);
  }

  /// Files bank payments under their repeats and adds cash repeats that are due. Safe to run any time, from
  /// any number of phones: each due date is claimed once in the database.
  Future<void> runRecurring() async {
    if (_recurringBusy) return;
    _recurringBusy = true;
    try {
      final plan = recurringPlan;
      for (final m in plan.matches) {
        await settleDue(m.recurring, m.due, kind: 'matched', txn: m.txn);
      }
      for (final a in plan.autoAdds) {
        await settleDue(a.recurring, a.due, kind: 'added');
      }
    } catch (e) {
      error = e;
    } finally {
      _recurringBusy = false;
    }
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Settles one due date: 'matched' to a payment you have, 'added' (enters it, in cash unless the repeat has
  /// an account), or 'skipped'. Returns false if it was already settled (by another phone, say).
  Future<bool> settleDue(Recurring r, DateTime due, {required String kind, Txn? txn, String? accountId}) async {
    String? txnId = txn?.id;
    if (kind == 'added') {
      // A fixed key per repeat and date: the entry exists at most once, whoever adds it.
      final key = 'recur:${r.id}:${_date(due)}';
      final account = accountId ?? r.accountId ?? cashAccount?.id;
      final isCash = account != null && account == cashAccount?.id;
      await _db
          .from('transactions')
          .upsert(
            {
              'amount': r.amount,
              'direction': r.isDebit ? 'debit' : 'credit',
              'merchant': r.name,
              'method': isCash ? 'cash' : 'other',
              'txn_at': DateTime(due.year, due.month, due.day, 9).toUtc().toIso8601String(),
              'category_id': r.categoryId,
              'account_id': account,
              'source': 'manual',
              'email_id': key,
              'note': 'Repeats ${r.everyLabel}',
            },
            onConflict: 'user_id,email_id',
            ignoreDuplicates: true,
          );
      final row = await _db.from('transactions').select('id').eq('email_id', key).maybeSingle();
      txnId = row?['id'] as String?;
      if (txnId == null) return false;
    }
    try {
      await _db.from('recurring_runs').insert({
        'recurring_id': r.id,
        'due_on': _date(due),
        'kind': kind,
        'txn_id': txnId,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') return false; // already settled
      rethrow;
    }
    recurringRuns = [
      ...recurringRuns,
      RecurringRun(id: 'local', recurringId: r.id, dueOn: due, kind: kind, txnId: txnId),
    ];
    if (kind == 'matched' && txn != null && txn.categoryId == null && r.categoryId != null) {
      await _db
          .from('transactions')
          .update({'category_id': r.categoryId, 'needs_review': false, 'edited': true})
          .eq('id', txn.id);
    }
    // A shared bill: split it in its group, like any group expense you paid.
    final g = group(r.groupId);
    if (g != null && txnId != null && r.isDebit && kind != 'skipped') {
      final amount = txn?.amount ?? r.amount;
      await addGroupExpense(
        group: g,
        description: r.name,
        amount: amount,
        paidBy: 'me',
        shares: splitEqually(amount, ['me', ...g.members]),
        at: txn?.txnAt ?? DateTime(due.year, due.month, due.day, 9),
        categoryId: r.categoryId,
        linkTxnId: txnId,
      );
    }
    notifyListeners();
    return true;
  }

  /// Takes back a settled due date: it is due again. An entry the repeat added is removed with it; a bank
  /// payment it was matched to stays as it is.
  Future<void> unsettle(RecurringRun run) async {
    final r = recurringById(run.recurringId);
    if (run.kind == 'added' && run.txnId != null) {
      final ge = groupExpenses.where((e) => e.txnId == run.txnId).toList();
      for (final e in ge) {
        await deleteGroupExpense(e);
      }
      await _db.from('transactions').delete().eq('id', run.txnId!);
    } else if (r?.groupId != null && run.txnId != null) {
      for (final e in groupExpenses.where((e) => e.txnId == run.txnId && e.groupId == r!.groupId)) {
        await deleteGroupExpense(e);
      }
    }
    await _db.from('recurring_runs').delete().eq('id', run.id);
    recurringRuns = recurringRuns.where((x) => x.id != run.id).toList();
    notifyListeners();
  }

  Future<void> saveRecurring({
    String? id,
    required String name,
    required double amount,
    required bool isDebit,
    required String every,
    required DateTime startsOn,
    bool varies = false,
    bool autoAdd = false,
    String? categoryId,
    String? accountId,
    String? groupId,
  }) async {
    final row = {
      'name': name.trim(),
      'amount': amount,
      'direction': isDebit ? 'debit' : 'credit',
      'every': every,
      'starts_on': _date(startsOn),
      'varies': varies,
      'auto_add': autoAdd,
      'category_id': categoryId,
      'account_id': accountId,
      'group_id': groupId,
    };
    if (id == null) {
      await _db.from('recurring').insert(row);
    } else {
      await _db.from('recurring').update(row).eq('id', id);
    }
  }

  /// Stops a repeat; what it already settled stays.
  Future<void> stopRecurring(String id) => _db.from('recurring').update({'active': false}).eq('id', id);

  // ------------------------------------------------------------------ groups

  List<Group> groups = const [];
  List<GroupExpense> groupExpenses = const [];
  Group? group(String? id) => id == null ? null : groups.where((g) => g.id == id).firstOrNull;
  List<GroupExpense> expensesOf(String groupId) =>
      groupExpenses.where((e) => e.groupId == groupId).toList()..sort((a, b) => b.at.compareTo(a.at));

  Future<String> saveGroup({String? id, required String name, String? emoji, required List<String> members}) async {
    final row = {'name': name.trim(), 'emoji': emoji, 'members': members.map((m) => m.trim()).toSet().toList()};
    if (id != null) {
      await _db.from('groups').update(row).eq('id', id);
      return id;
    }
    final r = await _db.from('groups').insert(row).select('id').single();
    return r['id'] as String;
  }

  Future<void> archiveGroup(String id, {bool archived = true}) =>
      _db.from('groups').update({'archived': archived}).eq('id', id);

  /// A group expense, and your own side of it in your records: your payment with the others' shares (so only
  /// your part is your spending and they owe you theirs), or "[paidBy] paid, you owe your part".
  Future<void> addGroupExpense({
    required Group group,
    required String description,
    required double amount,
    required String paidBy,
    required Map<String, double> shares,
    required DateTime at,
    String? categoryId,
    String? accountId,
    String? linkTxnId,
  }) async {
    String? txnId;
    var created = false;
    final others = {
      for (final e in shares.entries)
        if (e.key != 'me' && e.value > 0) e.key: e.value,
    };
    if (paidBy == 'me') {
      if (linkTxnId != null) {
        txnId = linkTxnId;
        if (categoryId != null) {
          await _db
              .from('transactions')
              .update({'category_id': categoryId, 'needs_review': false, 'edited': true})
              .eq('id', txnId);
        }
      } else {
        final r = await _db
            .from('transactions')
            .insert({
              'amount': amount,
              'direction': 'debit',
              'merchant': description,
              'method': 'other',
              'txn_at': at.toUtc().toIso8601String(),
              'category_id': categoryId,
              'account_id': accountId,
              'source': 'manual',
              'note': '${group.name} (group)',
            })
            .select('id')
            .single();
        txnId = r['id'] as String;
        created = true;
      }
      final existing = sharesOf(txnId).map((s) => keyOf(s.person)).toSet();
      for (final e in others.entries) {
        if (!existing.contains(keyOf(e.key))) await addShare(txnId, e.key, e.value);
      }
    } else if ((shares['me'] ?? 0) > 0) {
      final r = await _db
          .from('transactions')
          .insert({
            'amount': shares['me'],
            'direction': 'debit',
            'merchant': description,
            'method': 'other',
            'txn_at': at.toUtc().toIso8601String(),
            'category_id': categoryId,
            'source': 'manual',
            'paid_by': paidBy,
            'note': '$paidBy paid ${money0(amount)} · ${group.name} (group)',
          })
          .select('id')
          .single();
      txnId = r['id'] as String;
      created = true;
    }
    await _db.from('group_expenses').insert({
      'group_id': group.id,
      'kind': 'expense',
      'description': description,
      'amount': amount,
      'paid_by': paidBy,
      'shares': shares,
      'at': at.toUtc().toIso8601String(),
      'category_id': categoryId,
      'txn_id': txnId,
      'txn_created': created,
    });
  }

  /// Someone paid someone back in the group. When you are one of them it also goes into your Friends ledger,
  /// counted for the right friends (see [allocateSettle]). [byCash]: the money moved in cash, so your cash
  /// changes; otherwise it went through the bank and that payment comes in by itself from the bank email.
  Future<void> addGroupSettle({
    required Group group,
    required String from,
    required String to,
    required double amount,
    required DateTime at,
    bool byCash = false,
  }) async {
    final ids = <String>[];
    var counted = <String, double>{};
    if (from == 'me' || to == 'me') {
      final other = from == 'me' ? to : from;
      final toMe = to == 'me';
      counted = allocateSettle(
        pairwise: groupPairwise(expensesOf(group.id), group.members),
        other: other,
        toMe: toMe,
        amount: amount,
      );
      final cat = friendsCategory?.id ?? (await ensureLoanCategory()).id;
      Future<void> add(String person, double v, {required bool credit, String? accountId, required String note}) async {
        final r = await _db
            .from('transactions')
            .insert({
              'amount': v,
              'direction': credit ? 'credit' : 'debit',
              'merchant': person,
              'method': accountId == null ? 'other' : 'cash',
              'txn_at': at.toUtc().toIso8601String(),
              'category_id': cat,
              'account_id': accountId,
              'source': 'manual',
              'note': note,
            })
            .select('id')
            .single();
        ids.add(r['id'] as String);
      }

      if (byCash) {
        await add(other, amount, credit: toMe, accountId: cashAccount?.id, note: 'Settle up');
      }
      // Money routed through [other] for someone else: move it to whom it was really for.
      for (final e in counted.entries.where((e) => e.key != other)) {
        final v = e.value;
        await add(other, v, credit: !toMe, note: '${money0(v)} of it was for ${e.key} · ${group.name}');
        await add(
          e.key,
          v,
          credit: toMe,
          note: toMe
              ? '$other paid ${money0(v)} for you · ${group.name}'
              : 'You paid ${money0(v)} to $other for them · ${group.name}',
        );
      }
    }
    await _db.from('group_expenses').insert({
      'group_id': group.id,
      'kind': 'settle',
      'description': byCash ? 'Settle up (cash)' : 'Settle up',
      'amount': amount,
      'paid_by': from,
      'paid_to': to,
      'shares': counted,
      'at': at.toUtc().toIso8601String(),
      'txn_ids': ids,
    });
  }

  /// Removes a group expense and what it added to your records (never a bank payment it was linked to).
  Future<void> deleteGroupExpense(GroupExpense e) async {
    if (e.txnIds.isNotEmpty) await _db.from('transactions').delete().inFilter('id', e.txnIds);
    if (e.txnId != null) {
      if (e.txnCreated) {
        await _db.from('transactions').delete().eq('id', e.txnId!);
      } else {
        final people = {
          for (final k in e.shares.keys)
            if (k != 'me') keyOf(k),
        };
        for (final sh in sharesOf(e.txnId!)) {
          if (people.contains(keyOf(sh.person))) await deleteShare(sh.id);
        }
      }
    }
    await _db.from('group_expenses').delete().eq('id', e.id);
  }

  /// Payments split across your own categories.
  List<TxnPart> parts = const [];
  List<TxnPart> partsOf(String txnId) => parts.where((p) => p.txnId == txnId).toList();

  /// Adds a part of a payment in another category (never more than what is left of it).
  Future<void> addPart(String txnId, String? categoryId, double amount) async {
    final row = await _db
        .from('txn_parts')
        .insert({'txn_id': txnId, 'category_id': categoryId, 'amount': amount})
        .select()
        .single();
    parts = [...parts, TxnPart.fromMap(row)];
    _shareTotals = null;
    notifyListeners();
  }

  Future<void> removePart(String id) async {
    await _db.from('txn_parts').delete().eq('id', id);
    parts = parts.where((p) => p.id != id).toList();
    _shareTotals = null;
    notifyListeners();
  }

  List<TxnShare> sharesOf(String txnId) => shares.where((s) => s.txnId == txnId).toList();
  List<TxnShare> sharesPaidBy(String txnId) => shares.where((s) => s.paidTxnId == txnId).toList();

  Txn? txn(String? id) {
    if (id == null) return null;
    for (final t in transactions) {
      if (t.id == id) return t;
    }
    return null;
  }

  List<UnreadEmail> unread = const [];
  Map<String, dynamic> profile = const {};

  User? get user => _client?.auth.currentUser;
  String get displayName => (profile['display_name'] as String?) ?? user?.email ?? '';
  String? get ingestToken => profile['ingest_token'] as String?;
  DateTime? get lastSync =>
      profile['last_sync_at'] == null ? null : DateTime.parse(profile['last_sync_at'] as String).toLocal();

  Category? category(String? id) {
    if (id == null) return null;
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  Set<String> get loanCategoryIds => {
    for (final c in categories)
      if (c.isLoan) c.id,
  };
  Set<String> get investmentCategoryIds => {
    for (final c in categories)
      if (c.isInvestment) c.id,
  };

  /// Categories whose money is neither spending nor income: friends and investments.
  Set<String> get notSpendingCategoryIds => {...loanCategoryIds, ...investmentCategoryIds};
  Category? get loanCategory => categories.where((c) => c.isLoan).firstOrNull;

  Account? account(String? id) {
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  List<Account> get activeAccounts => accounts.where((a) => !a.archived).toList();
  Account? get cashAccount => accounts.where((a) => a.kind == AccountKind.cash && !a.archived).firstOrNull;

  /// Rows read one by one: a row that cannot be read is skipped (and reported), never stopping the rest of the
  /// list from updating.
  List<T> _parse<T>(List<Map<String, dynamic>> rows, T Function(Map<String, dynamic>) read) {
    final out = <T>[];
    for (final r in rows) {
      try {
        out.add(read(r));
      } catch (e) {
        error = 'Could not read one ${T.toString().toLowerCase()}: $e';
      }
    }
    return out;
  }

  void _onError(Object e) {
    error = e;
    notifyListeners();
  }

  // ------------------------------------------------------------ transactions

  /// Saves a payment; returns its id.
  Future<String> saveTxn(Txn t, {required bool isNew, bool rememberCategory = false}) async {
    final row = t.toWriteMap();
    if (isNew) {
      final r = await _db.from('transactions').insert({...row, 'source': 'manual'}).select().single();
      _showNow(r);
      return r['id'] as String;
    }
    // `edited` keeps a later re-read of the bank email from overwriting the user's changes.
    final r = await _db.from('transactions').update({...row, 'edited': true}).eq('id', t.id).select().maybeSingle();
    if (r == null) throw StateError('This payment was not found any more (deleted on another phone?)');
    _showNow(r);
    if (rememberCategory && t.categoryId != null) {
      await _db.rpc('set_category', params: {'p_txn': t.id, 'p_category': t.categoryId, 'p_remember': true});
    }
    return t.id;
  }

  /// A saved payment as the server has it, on screen at once (not only when the live update arrives).
  void _showNow(Map<String, dynamic> row) {
    final t = Txn.fromMap(row);
    transactions = [
      t,
      for (final x in transactions)
        if (x.id != t.id) x,
    ]..sort((a, b) => b.txnAt.compareTo(a.txnAt));
    notifyListeners();
  }

  /// Everything fetched again, e.g. when the app comes back to the screen (a phone can drop the live updates
  /// while the app is in the background).
  Future<void> refresh() async {
    if (_client == null) return;
    try {
      final rows = await _db.from('transactions').select().order('txn_at').limit(10000);
      transactions = _parse(rows, Txn.fromMap)..sort((a, b) => b.txnAt.compareTo(a.txnAt));
      notifyListeners();
      await _reloadFriendsData();
    } catch (_) {
      // Offline: the live copy stays as it is.
    }
  }

  Future<void> deleteTxn(String id) => _db.from('transactions').delete().eq('id', id);

  // -------------------------------------------------------------- categories

  /// Saves a category; returns its id.
  Future<String> saveCategory({
    String? id,
    required String name,
    required String icon,
    required int color,
    bool isLoan = false,
    String? parentId,
  }) async {
    final row = {
      'name': name.trim(),
      'icon': icon,
      'color': color,
      'kind': isLoan ? 'loan' : 'normal',
      'parent_id': parentId,
    };
    if (id == null) {
      final r = await _db.from('categories').insert(row).select().single();
      final c = Category.fromMap(r);
      categories = [...categories, c];
      notifyListeners();
      return c.id;
    }
    await _db.from('categories').update(row).eq('id', id);
    return id;
  }

  /// Category → its group, for rolling spending up.
  Map<String, String?> get parentOf => {for (final c in categories) c.id: c.parentId};

  Future<void> deleteCategory(String id) => _db.from('categories').delete().eq('id', id);

  /// Makes the "Personal loans" category if the user deleted it.
  Future<Category> ensureLoanCategory() async {
    final existing = loanCategory;
    if (existing != null) return existing;
    final row = await _db
        .from('categories')
        .upsert({
          'name': 'Personal loans',
          'icon': 'handshake',
          'color': 0xFF3F51B5,
          'kind': 'loan',
        }, onConflict: 'user_id,name')
        .select()
        .single();
    final c = Category.fromMap(row);
    categories = [...categories.where((x) => x.id != c.id), c];
    notifyListeners();
    return c;
  }

  // ---------------------------------------------------------------- accounts

  Future<void> saveAccount({
    String? id,
    required String name,
    required AccountKind kind,
    required double openingBalance,
    bool archived = false,
    DateTime? openingDate,
    String? bank,
    String? last4,
  }) async {
    final b = bank?.trim() ?? '', l = last4?.trim() ?? '';
    final row = {
      'name': name.trim(),
      'kind': kind.name,
      'bank': b.isEmpty ? null : b,
      'last4': l.length == 4 ? l : null,
      'opening_balance': openingBalance,
      'archived': archived,
      'opening_date': openingDate == null
          ? null
          : '${openingDate.year.toString().padLeft(4, '0')}-${openingDate.month.toString().padLeft(2, '0')}-${openingDate.day.toString().padLeft(2, '0')}',
    };
    if (id == null) {
      await _db.from('accounts').insert(row);
    } else {
      await _db.from('accounts').update(row).eq('id', id);
    }
  }

  Future<void> deleteAccount(String id) => _db.from('accounts').delete().eq('id', id);

  /// Moves every payment (and balance check, repeat, goal) of account [from] into [into], then removes [from].
  Future<void> mergeAccount(String from, String into) async {
    await _db.from('transactions').update({'account_id': into}).eq('account_id', from);
    await _db.from('transactions').update({'counter_account_id': into}).eq('counter_account_id', from);
    await _db.from('balance_readings').update({'account_id': into}).eq('account_id', from);
    await _db.from('recurring').update({'account_id': into}).eq('account_id', from);
    await _db.from('goals').update({'account_id': into}).eq('account_id', from);
    final a = account(from), b = account(into);
    // Keep the bank digits so future emails find the account you kept.
    if (a?.last4 != null && b?.last4 == null) {
      await _db.from('accounts').update({'bank': a!.bank, 'last4': a.last4}).eq('id', into);
      await _db.from('accounts').update({'last4': null}).eq('id', from);
    }
    await _db.from('accounts').delete().eq('id', from);
  }

  // ------------------------------------------------------------- lender loans

  Loan? loan(String? id) {
    if (id == null) return null;
    for (final l in loans) {
      if (l.id == id) return l;
    }
    return null;
  }

  Future<void> saveLoan(Map<String, dynamic> row, {String? id}) async {
    if (id == null) {
      await _db.from('loans').insert(row);
    } else {
      await _db.from('loans').update(row).eq('id', id);
    }
    // Bank payments to this lender become repayments (and stop counting as spending).
    await _db.rpc('link_loan_transactions', params: {'p_user': user!.id});
  }

  /// A credit line's spending power left, as the lender shows it now.
  Future<void> setCreditLeft(String loanId, double amount) => _db
      .from('loans')
      .update({'available_credit': amount, 'available_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', loanId);

  /// The lender's repayment schedule (replaces the old one).
  Future<void> saveSchedule(String loanId, List<({DateTime date, double amount})> schedule) => _db
      .from('loans')
      .update({
        'schedule': [
          for (final e in schedule)
            {
              'date':
                  '${e.date.year}-${e.date.month.toString().padLeft(2, '0')}-${e.date.day.toString().padLeft(2, '0')}',
              'amount': e.amount,
            },
        ],
      })
      .eq('id', loanId);

  Future<void> deleteLoan(String id) => _db.from('loans').delete().eq('id', id);

  /// Records a repayment (or extra borrowing) by hand.
  Future<void> addLoanEvent(String loanId, LoanEventKind kind, double amount, DateTime at, {String? note}) =>
      _db.from('loan_events').insert({
        'loan_id': loanId,
        'kind': kind.name,
        'amount': amount,
        'event_at': at.toUtc().toIso8601String(),
        'note': note,
      });

  /// Removes a loan event. One that is a bank payment is unlinked from the loan (the payment stays).
  Future<void> deleteLoanEvent(String id) async {
    final e = loanEvents.where((x) => x.id == id).firstOrNull;
    if (e?.txnId != null) {
      await _db.from('transactions').update({'loan_id': null, 'loan_role': null, 'edited': true}).eq('id', e!.txnId!);
    }
    if (!id.startsWith('txn:')) await _db.from('loan_events').delete().eq('id', id);
  }

  /// "I owe ₹X now": later borrowing and repayments are counted from here.
  Future<void> setOwed(String loanId, double owed) => _db
      .from('loans')
      .update({'outstanding': owed, 'outstanding_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', loanId);

  // ---------------------------------------------------------------- friends

  Category? get friendsCategory => loanCategory;

  static String keyOf(String name) => name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Payees already decided: a role set, friends (by category) and "not a friend".
  Set<String> get decidedPeople => {
    ...people.keys,
    for (final t in transactions)
      if (t.merchant != null && loanCategoryIds.contains(t.categoryId)) keyOf(t.merchant!),
    ...((profile['not_friends'] as List?) ?? const []).cast<String>(),
  };

  /// Friend, family, me (own account) or shop. Family money in is income; "me" is a move.
  Future<void> setPersonRole(String name, String role) async {
    people = {...people, keyOf(name): role};
    personNames = {...personNames, keyOf(name): name.trim()};
    notifyListeners();
    await _db.rpc('set_person_role', params: {'p_name': name, 'p_role': role});
  }

  /// Your own name for a place, by its UPI IDs (or names when it has none), now and later.
  Future<void> renamePlace({
    required Iterable<String> vpas,
    required Iterable<String> names,
    required String nickname,
  }) async {
    // "Also known as" links follow the new name (the server does the same).
    final olds = {for (final n in names) keyOf(n)};
    final nk = keyOf(nickname);
    aliases = {
      for (final e in aliases.entries)
        if (e.key != nk) e.key: (olds.contains(keyOf(e.value)) ? nickname.trim() : e.value),
    };
    notifyListeners();
    await _db.rpc(
      'rename_place',
      params: {'p_vpas': vpas.toList(), 'p_names': names.toList(), 'p_nickname': nickname.trim()},
    );
  }

  /// Names linked to [person] with "Also known as", and names the bank used for their payments.
  List<String> linkedNamesOf(String person) {
    final k = keyOf(person);
    final out = <String>{};
    for (final e in aliases.entries) {
      if (keyOf(e.value) == k) {
        final shown = transactions.where((t) => t.bankName != null && keyOf(t.bankName!) == e.key).firstOrNull;
        out.add(shown?.bankName ?? e.key);
      }
    }
    return out.toList()..sort();
  }

  /// The latest changes to payments and rules, newest first (see change_log).
  /// The change log, newest first, a page at a time ([beforeId]: older than that row). [mineOnly]: your and your
  /// friends' changes, not automatic ones (bank emails, imports).
  Future<List<Map<String, dynamic>>> loadHistory({int limit = 800, int? beforeId, bool mineOnly = false}) async {
    var q = _db.from('change_log').select();
    if (beforeId != null) q = q.lt('id', beforeId);
    if (mineOnly) q = q.or('by_user.eq.true,actor.not.is.null');
    final rows = await q.order('id', ascending: false).limit(limit);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Everything that ever happened to one payment: its own changes, its splits with friends and into
  /// categories, and its group expense.
  Future<List<Map<String, dynamic>>> loadEntryHistory(String txnId) async {
    final rows = await _db.from('change_log').select().eq('txn_id', txnId).order('id', ascending: false).limit(300);
    return rows.cast<Map<String, dynamic>>();
  }

  /// Puts back single changes (not the rest of the action they were part of). Later changes are kept.
  Future<int> undoChangeRows(List<int> ids) async {
    final n = await _db.rpc('undo_change_rows', params: {'p_ids': ids});
    return (n as num?)?.toInt() ?? 0;
  }

  /// Puts back everything one action changed. Returns how many rows changed back.
  Future<int> undoChange(int batch) async {
    final n = await _db.rpc('undo_change', params: {'p_batch': batch});
    return (n as num?)?.toInt() ?? 0;
  }

  /// Undoes "Also known as": that name's payments show under it again.
  Future<void> removeAlias(String name) async {
    final k = keyOf(name);
    aliases = {...aliases}..remove(k);
    transactions = [
      for (final t in transactions)
        t.bankName != null && keyOf(t.bankName!) == k
            ? Txn(
                id: t.id,
                amount: t.amount,
                isDebit: t.isDebit,
                txnAt: t.txnAt,
                merchant: t.bankName,
                note: t.note,
                bank: t.bank,
                accountLast4: t.accountLast4,
                method: t.method,
                categoryId: t.categoryId,
                accountId: t.accountId,
                counterAccountId: t.counterAccountId,
                source: t.source,
                emailSubject: t.emailSubject,
                excluded: t.excluded,
                needsReview: t.needsReview,
                loanId: t.loanId,
                loanRole: t.loanRole,
                emailBody: t.emailBody,
                paidBy: t.paidBy,
                payeeVpa: t.payeeVpa,
                details: t.details,
              )
            : t,
    ];
    notifyListeners();
    await _db.rpc('remove_friend_alias', params: {'p_alias': name});
  }

  /// Marks a payee as a friend (or not): their money then goes to your balance with them.
  Future<void> markFriend(String name, {bool friend = true}) async {
    await _db.rpc('mark_friend', params: {'p_merchant_key': keyOf(name), 'p_friend': friend});
  }

  Future<void> markNotFriend(String name) async {
    final list = {...((profile['not_friends'] as List?) ?? const []).cast<String>(), keyOf(name)}.toList();
    profile = {...profile, 'not_friends': list};
    notifyListeners();
    await _db.from('profiles').update({'not_friends': list}).eq('id', user!.id);
  }

  /// An expense shared with friends. Paid by you: the whole amount from your account,
  /// friends' parts owed to you. Paid by a friend: only your share, owed to them.
  Future<void> addSharedExpense({
    required String description,
    required double total,
    required DateTime at,
    required String? categoryId,
    required String? paidBy,
    required String? accountId,
    required double myShare,
    required Map<String, double> friendShares,
  }) async {
    if (paidBy == null) {
      final row = await _db
          .from('transactions')
          .insert({
            'amount': total,
            'direction': 'debit',
            'merchant': description,
            'method': 'other',
            'txn_at': at.toUtc().toIso8601String(),
            'category_id': categoryId,
            'account_id': accountId,
            'source': 'manual',
          })
          .select('id')
          .single();
      for (final e in friendShares.entries) {
        if (e.value > 0) await addShare(row['id'] as String, e.key, e.value);
      }
    } else {
      await _db.from('transactions').insert({
        'amount': myShare,
        'direction': 'debit',
        'merchant': description,
        'method': 'other',
        'txn_at': at.toUtc().toIso8601String(),
        'category_id': categoryId,
        'source': 'manual',
        'paid_by': paidBy.trim(),
        'note': '$paidBy paid ₹${total.toStringAsFixed(total == total.roundToDouble() ? 0 : 2)} in total',
      });
    }
  }

  /// Settle up outside the bank (cash): you paid them, or they paid you.
  Future<void> settleUp(String person, double amount, {required bool iPaid, String? accountId}) async {
    final cat = friendsCategory?.id;
    await _db.from('transactions').insert({
      'amount': amount,
      'direction': iPaid ? 'debit' : 'credit',
      'merchant': person,
      'method': 'cash',
      'txn_at': DateTime.now().toUtc().toIso8601String(),
      'category_id': cat,
      'account_id': accountId ?? cashAccount?.id,
      'source': 'manual',
      'note': 'Settle up',
    });
  }

  /// Changes what you owe a friend (positive: you owe more) without touching any account, e.g. part of the
  /// money they sent was for things you bought for them.
  // ------------------------------------------------------------ opening balances with connected friends

  List<FriendOpening> openings = const [];

  /// The agreed opening balance in force (the latest day), if any.
  FriendOpening? openingFor(String linkId) {
    final agreed = openings.where((o) => o.linkId == linkId && o.agreed).toList()
      ..sort((a, b) {
        final c = b.cutoff.compareTo(a.cutoff);
        return c != 0 ? c : b.confirmedAt!.compareTo(a.confirmedAt!);
      });
    return agreed.firstOrNull;
  }

  /// A proposal waiting for an answer, if any.
  FriendOpening? pendingOpening(String linkId) => openings.where((o) => o.linkId == linkId && o.waiting).firstOrNull;

  /// Proposals from friends waiting for your OK.
  List<FriendOpening> get openingsWaitingForMe => const [];

  /// The balance with a connected friend that you both see (positive: you owe).
  double balanceWith(FriendLink link) =>
      me == null ? 0 : sharedBalance(sharedEntries, link.id, me!, opening: openingFor(link.id));

  /// Proposes what was owed at the end of [asOf] (positive [owed]: you owe them). It counts once they OK it.
  Future<void> proposeOpening(FriendLink link, DateTime asOf, double owed, String note) async {
    final friendId = link.a == me ? link.b! : link.a;
    final d = '${asOf.year}-${asOf.month.toString().padLeft(2, '0')}-${asOf.day.toString().padLeft(2, '0')}';
    try {
      // The exact moment (RUN_IN_SUPABASE_5.sql); without it, the end of that day.
      await _db.rpc(
        'propose_friend_opening_at',
        params: {
          'p_link': link.id,
          'p_at': asOf.toUtc().toIso8601String(),
          'p_owed_by': owed.abs() < 0.005 ? null : (owed > 0 ? me : friendId),
          'p_amount': double.parse(owed.abs().toStringAsFixed(2)),
          'p_note': note,
        },
      );
      return;
    } on PostgrestException catch (e) {
      if (e.code != 'PGRST202' && !e.message.contains('propose_friend_opening_at')) rethrow;
    }
    try {
      await _db.rpc(
        'propose_friend_opening',
        params: {
          'p_link': link.id,
          'p_as_of': d,
          'p_owed_by': owed.abs() < 0.005 ? null : (owed > 0 ? me : friendId),
          'p_amount': double.parse(owed.abs().toStringAsFixed(2)),
          'p_note': note,
        },
      );
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || (e.message).contains('propose_friend_opening')) {
        throw StateError('The database needs the opening-balance update first (0038_friend_openings.sql).');
      }
      rethrow;
    }
  }

  Future<void> answerOpening(String id, {required bool ok}) async {
    final done = await _db.rpc('answer_friend_opening', params: {'p_id': id, 'p_ok': ok});
    if (done != true) throw StateError('not saved, please try again');
  }

  /// Whether this payment is in one of your accounts: false only for one known to have none (added by hand).
  bool inAnAccount(String txnId) {
    final t = txn(txnId);
    return t == null || t.accountId != null;
  }

  Future<void> correctFriendBalance(String person, double change, String reason) async {
    final cat = friendsCategory?.id ?? (await ensureLoanCategory()).id;
    await _db.from('transactions').insert({
      'amount': double.parse(change.abs().toStringAsFixed(2)),
      'direction': change > 0 ? 'credit' : 'debit',
      'merchant': person,
      'method': 'other',
      'txn_at': DateTime.now().toUtc().toIso8601String(),
      'category_id': cat,
      'account_id': null,
      'source': 'manual',
      'note': reason,
    });
  }

  // ------------------------------------------------------- bank statements

  /// Reads a bank statement on the server. With [dryRun] nothing is saved: it says what would be imported.
  Future<Map<String, dynamic>> importStatement(
    Uint8List bytes,
    String fileName, {
    String? accountId,
    required bool dryRun,
    bool setOpening = false,
    bool matchExactly = false,
  }) async {
    final res = await _db.functions.invoke(
      'import-statement',
      body: {
        'file': base64Encode(bytes),
        'fileName': fileName,
        'accountId': accountId,
        'dryRun': dryRun,
        'setOpening': setOpening,
        'matchExactly': matchExactly,
      },
    );
    final data = res.data;
    if (data is Map<String, dynamic>) {
      if (data['error'] != null) throw Exception(data['error']);
      return data;
    }
    throw Exception('Unexpected answer from the server');
  }

  // ------------------------------------------------------ connected friends

  /// Makes an invite for this friend; returns the code to send them.
  Future<String> inviteFriend(String person) async {
    final existing = pendingInviteFor(person);
    if (existing != null) return existing.code;
    final row = await _db.from('friend_links').insert({'a_name_for_b': person.trim()}).select('code').single();
    return row['code'] as String;
  }

  /// Accepts a friend's invite; their payments with you then show in both apps.
  Future<void> acceptInvite(String code, String friendName) async {
    await _db.rpc(
      'accept_friend_invite',
      params: {'p_code': code.trim().toLowerCase(), 'p_name_for_inviter': friendName.trim()},
    );
    await markFriend(friendName);
  }

  Future<void> disconnect(String linkId) => _db.from('friend_links').delete().eq('id', linkId);

  /// Answers "same payment?". The card goes at once (Yes also settles the entry's other questions);
  /// if the server refuses, it comes back and the error is thrown.
  Future<void> answerMatch(String questionId, bool yes) async {
    final before = questions;
    final q = questions.where((x) => x.id == questionId).firstOrNull;
    if (q == null) return; // already answered (a second tap)
    questions = [
      for (final x in questions)
        if (x.id != questionId && !(yes && x.entryId == q.entryId)) x,
    ];
    notifyListeners();
    try {
      final ok = await _db.rpc('answer_match', params: {'p_question': questionId, 'p_yes': yes});
      if (ok != true) throw StateError('not saved, please try again');
      await _reloadFriendsData();
    } catch (_) {
      questions = before;
      notifyListeners();
      rethrow;
    }
  }

  /// Reads shared entries and questions again right after an answer, not waiting for the live feed.
  Future<void> _reloadFriendsData() async {
    final entries = await _db.from('shared_entries').select().order('at');
    final qs = await _db.from('match_questions').select();
    sharedEntries = entries.map(SharedEntry.fromMap).toList();
    questions = qs.map(MatchQuestion.fromMap).toList();
    notifyListeners();
  }

  /// Asks to remove a shared entry: it goes once the other person says OK (one not yet agreed goes at once).
  Future<void> deleteSharedEntry(String id) async {
    final done = await _db.rpc('request_remove_shared', params: {'p_entry': id});
    if (done != true) throw StateError('not saved, please try again');
    await _reloadFriendsData();
  }

  /// OK or no to a change a connected friend made to an entry between you.
  /// Changes a shared entry for both of you: amount, what it was for, date, and who paid ([iPaid]).
  Future<void> editSharedEntry(
    SharedEntry e, {
    required double amount,
    String? description,
    DateTime? at,
    required bool iPaid,
  }) async {
    final friend = e.creditor == me ? e.debtor : e.creditor;
    final ok = await _db.rpc(
      'edit_shared',
      params: {
        'p_entry': e.id,
        'p_amount': double.parse(amount.toStringAsFixed(2)),
        'p_description': description,
        'p_at': at?.toUtc().toIso8601String(),
        'p_creditor': iPaid ? me : friend,
      },
    );
    if (ok != true) throw StateError('not saved, please try again');
    await _reloadFriendsData();
  }

  /// "This is in my bank": links a shared entry your friend's bank made to your own payment [t]. The payment goes
  /// to your Friends ledger, and nothing counts twice.
  Future<void> linkSharedToTxn(SharedEntry e, Txn t) async {
    try {
      final ok = await _db.rpc('link_shared_txn', params: {'p_entry': e.id, 'p_txn': t.id});
      if (ok != true) throw StateError('not linked, please try again');
    } on PostgrestException catch (err) {
      if (err.code == 'PGRST202' || err.message.contains('link_shared_txn')) {
        throw StateError('The database needs RUN_IN_SUPABASE_4.sql first (Supabase → SQL Editor).');
      }
      throw StateError(err.message);
    }
    final row = await _db.from('transactions').select().eq('id', t.id).maybeSingle();
    if (row != null) _showNow(row);
    await _reloadFriendsData();
  }

  Future<void> answerShared(String id, {required bool ok}) async {
    if (!_answering.add(id)) return; // a second tap while saving
    notifyListeners();
    try {
      final done = await _db.rpc('answer_shared', params: {'p_entry': id, 'p_ok': ok});
      if (done != true) throw StateError('not saved, please try again');
      await _reloadFriendsData();
    } catch (_) {
      _answering.remove(id);
      notifyListeners();
      rethrow;
    }
  }

  /// Answers sent but not yet back from the server: hidden from "waiting" meanwhile.
  final _answering = <String>{};

  /// Changes by friends waiting for your OK.
  List<SharedEntry> get waitingForMe => const [];

  /// "Also known as": payments from this payee name count as that friend.
  /// Payee names you said are not the same person as a friend.
  Set<String> get notSame => {...((profile['not_same'] as List?) ?? const []).cast<String>()};

  // ------------------------------------------------------------ tools

  /// Your UPI ID, for "pay me" links in reminders.
  String? get upiId => (profile['upi_id'] as String?)?.trim().isEmpty == true ? null : profile['upi_id'] as String?;

  Future<void> setUpiId(String v) async {
    profile = {...profile, 'upi_id': v.trim()};
    notifyListeners();
    await _db.from('profiles').update({'upi_id': v.trim().isEmpty ? null : v.trim()}).eq('id', user!.id);
  }

  /// Attaches a photo of the bill to a payment (in your private folder); replaces an earlier one.
  Future<void> attachReceipt(Txn t, Uint8List bytes, String fileName) async {
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'jpg';
    final path = '${user!.id}/${t.id}-${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from('receipts').uploadBinary(path, bytes);
    final old = t.receiptPath;
    final r = await _db.from('transactions').update({'receipt_path': path}).eq('id', t.id).select().maybeSingle();
    if (r != null) _showNow(r);
    if (old != null) await _db.storage.from('receipts').remove([old]).catchError((_) => <FileObject>[]);
  }

  Future<void> removeReceipt(Txn t) async {
    final old = t.receiptPath;
    final r = await _db.from('transactions').update({'receipt_path': null}).eq('id', t.id).select().maybeSingle();
    if (r != null) _showNow(r);
    if (old != null) await _db.storage.from('receipts').remove([old]).catchError((_) => <FileObject>[]);
  }

  /// A link to see a receipt for the next hour.
  Future<String> receiptUrl(String path) => _db.storage.from('receipts').createSignedUrl(path, 3600);

  /// Money in your bank accounts, wallets and cash now (cards and loans left out).
  double get spendableNow {
    final usable = accounts.where((a) => !a.archived && a.kind != AccountKind.card).toList();
    final b = accountBalances(transactions, usable);
    return usable.fold(0.0, (v, a) => v + (b[a.id] ?? 0));
  }

  /// Pairs you checked and said are not duplicates ("id1|id2"): saved in your profile, and kept on this phone
  /// too so a profile reload (every bank sync) never brings a pair back.
  Set<String> get notDuplicates => {
    ...((profile['not_duplicates'] as List?) ?? const []).cast<String>(),
    ..._notDupesHere,
  };
  final _notDupesHere = <String>{};

  /// Payments that may be one entered twice (see [suspectedDuplicates]).
  List<DuplicatePair> get duplicates => suspectedDuplicates(transactions, notDuplicates: notDuplicates);

  /// "These are all real payments": every pair among [ids] is not asked again. Throws if it could not be saved
  /// for good (the database needs the 0041 update); it is still remembered on this phone.
  Future<void> markNotDuplicates(List<String> ids) async {
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        _notDupesHere.add(pairKey(ids[i], ids[j]));
      }
    }
    notifyListeners();
    final list = notDuplicates.toList();
    await _db.from('profiles').update({'not_duplicates': list}).eq('id', user!.id);
    profile = {...profile, 'not_duplicates': list};
  }

  Future<void> markNotSame(String payeeName) async {
    final list = {...notSame, keyOf(payeeName)}.toList();
    profile = {...profile, 'not_same': list};
    notifyListeners();
    await _db.from('profiles').update({'not_same': list}).eq('id', user!.id);
  }

  /// Payees that may be [person] under another name (a parent's account, a UPI ID as the name).
  List<({String name, int count, double out, double into, String why})> otherNamesOf(String person) =>
      samePersonCandidates(
        transactions,
        person,
        skip: {
          ...notSame,
          ...aliases.keys,
          for (final e in people.entries)
            if (e.value != 'friend' && e.value != 'shop') e.key,
        },
      );

  Future<void> addAlias(String payeeName, String friendName) {
    final k = keyOf(payeeName);
    aliases = {
      for (final e in aliases.entries)
        if (e.key != keyOf(friendName)) e.key: (keyOf(e.value) == k ? friendName : e.value),
      k: friendName,
    };
    // Shown under the main name at once; the server renames them too.
    transactions = [
      for (final t in transactions)
        t.merchant != null && keyOf(t.merchant!) == k
            ? Txn(
                id: t.id,
                amount: t.amount,
                isDebit: t.isDebit,
                txnAt: t.txnAt,
                merchant: friendName,
                note: t.note,
                bank: t.bank,
                accountLast4: t.accountLast4,
                method: t.method,
                categoryId: t.categoryId,
                accountId: t.accountId,
                counterAccountId: t.counterAccountId,
                source: t.source,
                emailSubject: t.emailSubject,
                excluded: t.excluded,
                needsReview: t.needsReview,
                loanId: t.loanId,
                loanRole: t.loanRole,
                emailBody: t.emailBody,
                paidBy: t.paidBy,
                payeeVpa: t.payeeVpa,
                details: t.details,
                bankName: t.bankName ?? t.merchant,
              )
            : t,
    ];
    notifyListeners();
    return _db.rpc('add_friend_alias', params: {'p_alias': payeeName, 'p_friend': friendName});
  }

  // ----------------------------------------------------------------- places

  /// Shows a new category on these transactions at once; the server confirms in the background.
  void _showCategory(Set<String> ids, String? categoryId) {
    transactions = [
      for (final t in transactions)
        ids.contains(t.id)
            ? Txn(
                id: t.id,
                amount: t.amount,
                isDebit: t.isDebit,
                txnAt: t.txnAt,
                merchant: t.merchant,
                note: t.note,
                bank: t.bank,
                accountLast4: t.accountLast4,
                method: t.method,
                categoryId: categoryId,
                accountId: t.accountId,
                counterAccountId: t.counterAccountId,
                source: t.source,
                emailSubject: t.emailSubject,
                excluded: t.excluded,
                needsReview: false,
                loanId: t.loanId,
                loanRole: t.loanRole,
                emailBody: t.emailBody,
                paidBy: t.paidBy,
                payeeVpa: t.payeeVpa,
                details: t.details,
                bankName: t.bankName,
              )
            : t,
    ];
    notifyListeners();
  }

  /// Sets the category of these transactions only (quick sort, one by one or a whole payee).
  Future<void> categorizeTxns(Iterable<String> ids, String? categoryId) async {
    final list = ids.toList();
    _showCategory(list.toSet(), categoryId);
    for (var i = 0; i < list.length; i += 200) {
      await _db
          .from('transactions')
          .update({'category_id': categoryId, 'needs_review': false, 'edited': true})
          .inFilter('id', list.sublist(i, i + 200 > list.length ? list.length : i + 200));
    }
  }

  /// Files these payments under a category and remembers it for new ones: by their UPI IDs, and by name
  /// for [names] (businesses). Payments you changed by hand keep their category.
  Future<void> categorizeGroup(
    Iterable<Txn> txns,
    String? categoryId, {
    Set<String> vpas = const {},
    Set<String> names = const {},
  }) async {
    final ids = [for (final t in txns) t.id];
    _showCategory(ids.toSet(), categoryId);
    // A UPI ID ending other people share ("2002@o") would sort their payments too: remember the names instead.
    final shared = sharedVpaTails(transactions);
    final clean = vpas.difference(shared);
    final byName = clean.length < vpas.length
        ? {
            ...names,
            for (final t in txns)
              if (t.merchant != null) keyOf(t.merchant!),
          }
        : names;
    await _db.rpc(
      'categorize_place',
      params: {'p_ids': ids, 'p_vpas': clean.toList(), 'p_names': byName.toList(), 'p_category': categoryId},
    );
  }

  /// "These are my own accounts": every payment with this place is a move, not spending or income.
  Future<void> markOwnAccount(Iterable<String> merchantKeys) => _db
      .from('transactions')
      .update({'excluded': true, 'needs_review': false})
      .inFilter('merchant_key', merchantKeys.toList())
      .eq('edited', false);

  /// Files every payment to this place (all its spellings) under a category, now and later.
  Future<void> categorizePlace(Iterable<String> merchantKeys, String? categoryId) async {
    final keys = merchantKeys.toList();
    await _db
        .from('transactions')
        .update({'category_id': categoryId, 'needs_review': false})
        .inFilter('merchant_key', keys)
        .eq('edited', false);
    if (categoryId == null) {
      await _db.from('merchant_rules').delete().inFilter('merchant_key', keys);
    } else {
      await _db.from('merchant_rules').upsert([
        for (final k in keys) {'merchant_key': k, 'category_id': categoryId},
      ], onConflict: 'user_id,merchant_key');
    }
  }

  // ---------------------------------------------------------------- budgets

  Future<void> saveBudget(String? categoryId, double amount) async {
    final existing = budgets.where((b) => b.categoryId == categoryId).firstOrNull;
    if (existing != null) {
      await _db.from('budgets').update({'amount': amount}).eq('id', existing.id);
    } else {
      await _db.from('budgets').insert({'category_id': categoryId, 'amount': amount});
    }
  }

  Future<void> deleteBudget(String id) => _db.from('budgets').delete().eq('id', id);

  // ------------------------------------------------------- shared payments

  /// [credit] was a friend's money for you to spend for them, and [debit] is what you paid for them ([amount] of
  /// it). Their money stays in your Friends ledger (not income; you owe it to them), and the purchase gets their
  /// part (not your spending; they owe it): together you are even.
  Future<void> spendThrough(Txn credit, Txn debit, double amount) async {
    final friends = friendsCategory ?? await ensureLoanCategory();
    if (credit.categoryId != friends.id) {
      final r = await _db
          .from('transactions')
          .update({'category_id': friends.id, 'needs_review': false, 'edited': true})
          .eq('id', credit.id)
          .select()
          .maybeSingle();
      if (r != null) _showNow(r);
    }
    final person = aliases[keyOf(credit.title)] ?? credit.title.trim();
    await addShare(debit.id, person, double.parse(amount.toStringAsFixed(2)));
  }

  Future<void> addShare(String txnId, String person, double amount, {String? paidTxnId}) =>
      _db.from('txn_shares').insert({
        'txn_id': txnId,
        'person': person.trim(),
        'amount': amount,
        'paid_txn_id': paidTxnId,
        if (paidTxnId != null) 'paid_at': DateTime.now().toUtc().toIso8601String(),
      });

  Future<void> deleteShare(String id) => _db.from('txn_shares').delete().eq('id', id);

  /// The friend paid their part, with this money received (or in cash when null).
  Future<void> markSharePaid(String id, {String? paidTxnId}) => _db
      .from('txn_shares')
      .update({'paid_txn_id': paidTxnId, 'paid_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', id);

  // ------------------------------------------------------------- bank balance

  /// Shifts the opening balance so the app agrees with the bank's latest balance.
  Future<void> matchBankBalance(Account a, double difference) =>
      _db.from('accounts').update({'opening_balance': a.openingBalance + difference}).eq('id', a.id);

  // ------------------------------------------------------------- Gmail sync

  Future<void> refreshUnread() async {
    try {
      final rows = await _db
          .from('unparsed_emails')
          .select()
          .eq('kind', 'unreadable')
          .order('received_at', ascending: false)
          .limit(200);
      unread = _parse(rows, UnreadEmail.fromMap);
      notifyListeners();
    } catch (e) {
      _onError(e);
    }
  }

  Future<void> dismissUnread(String id) async {
    await _db.from('unparsed_emails').delete().eq('id', id);
    unread = unread.where((u) => u.id != id).toList();
    notifyListeners();
  }

  Future<String> regenerateToken() async {
    final token = await _db.rpc('regenerate_ingest_token') as String;
    profile = {...profile, 'ingest_token': token};
    notifyListeners();
    return token;
  }

  /// The Gmail script with this user's URL and token filled in, ready to paste.
  Future<String> personalScript() async {
    final template = await rootBundle.loadString('apps_script/Code.gs');
    return template
        .replaceFirst('__INGEST_URL__', AppConfig.ingestUrl)
        .replaceFirst('__INGEST_TOKEN__', ingestToken ?? '')
        .replaceFirst('__SUPABASE_KEY__', AppConfig.supabaseKey);
  }

  // ----------------------------------------------------------------- account

  Future<void> rename(String name) async {
    await _db.from('profiles').update({'display_name': name.trim()}).eq('id', user!.id);
  }

  Future<void> changePassword(String password) => _db.auth.updateUser(UserAttributes(password: password));

  Future<void> signOut() => _db.auth.signOut();

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// "₹900" / "₹900.50" for notes.
String money0(double v) => '₹${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}';
