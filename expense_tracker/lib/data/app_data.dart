import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../logic/goals.dart';
import '../logic/recurring.dart';
import '../logic/summary.dart'
    show
        LoanBalance,
        ShareTotals,
        allocateSettle,
        groupPairwise,
        loanBalances,
        samePersonCandidates,
        shareTotals,
        splitEqually;
import '../models.dart';

/// Live copy of the signed-in user's data, kept up to date by Supabase Realtime.
/// Row Level Security on the server guarantees only this user's rows arrive.
class AppData extends ChangeNotifier {
  AppData(SupabaseClient db) : _client = db {
    _subs = [
      db.from('transactions').stream(primaryKey: ['id']).order('txn_at').limit(10000).listen((rows) {
        transactions = rows.map(Txn.fromMap).toList()..sort((a, b) => b.txnAt.compareTo(a.txnAt));
        loaded = true;
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('goals').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        goals = rows.map(Goal.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('recurring').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        recurring = rows.map(Recurring.fromMap).toList();
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('recurring_runs').stream(primaryKey: ['id']).listen((rows) {
        recurringRuns = rows.map(RecurringRun.fromMap).toList();
        _runsLoaded = true;
        notifyListeners();
        _scheduleRecurring();
      }, onError: _onError),
      db.from('categories').stream(primaryKey: ['id']).order('name', ascending: true).listen((rows) {
        categories = rows.map(Category.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('accounts').stream(primaryKey: ['id']).order('created_at', ascending: true).listen((rows) {
        accounts = rows.map(Account.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('loans').stream(primaryKey: ['id']).order('created_at', ascending: true).listen((rows) {
        loans = rows.map(Loan.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('loan_events').stream(primaryKey: ['id']).order('event_at').listen((rows) {
        loanEvents = rows.map(LoanEvent.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('balance_readings').stream(primaryKey: ['id']).order('as_of').listen((rows) {
        balanceReadings = rows.map(BalanceReading.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('groups').stream(primaryKey: ['id']).order('created_at').listen((rows) {
        groups = rows.map(Group.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('group_expenses').stream(primaryKey: ['id']).order('at').listen((rows) {
        groupExpenses = rows.map(GroupExpense.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('txn_parts').stream(primaryKey: ['id']).listen((rows) {
        parts = rows.map(TxnPart.fromMap).toList();
        _shareTotals = null;
        notifyListeners();
      }, onError: _onError),
      db.from('txn_shares').stream(primaryKey: ['id']).listen((rows) {
        shares = rows.map(TxnShare.fromMap).toList();
        _shareTotals = null;
        notifyListeners();
      }, onError: _onError),
      db.from('budgets').stream(primaryKey: ['id']).listen((rows) {
        budgets = rows.map(Budget.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('friend_links').stream(primaryKey: ['id']).listen((rows) {
        links = rows.map(FriendLink.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('shared_entries').stream(primaryKey: ['id']).order('at').listen((rows) {
        sharedEntries = rows.map(SharedEntry.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('match_questions').stream(primaryKey: ['id']).listen((rows) {
        questions = rows.map(MatchQuestion.fromMap).toList();
        notifyListeners();
      }, onError: _onError),
      db.from('friend_aliases').stream(primaryKey: ['user_id', 'alias_key']).listen((rows) {
        aliases = {for (final r in rows) r['alias_key'] as String: r['friend_name'] as String};
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
                from: DateTime.parse(r['ledger_from'] as String),
                opening: ((r['opening'] as num?) ?? 0).toDouble(),
              ),
        };
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
    this.loanEvents = const [],
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
  }) : _client = null,
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
  List<LoanEvent> loanEvents = const [];
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
    final day = DateTime(from.year, from.month, from.day);
    ledgerStarts = {
      ...ledgerStarts,
      for (final MapEntry(:key, :value) in names.entries) key: (name: value, from: day, opening: opening[key] ?? 0),
    };
    notifyListeners();
    final d = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    await _db.from('people').upsert([
      for (final MapEntry(:key, :value) in names.entries)
        {
          'name_key': key,
          'name': value,
          'role': people[key] ?? 'friend',
          'ledger_from': d,
          'opening': opening[key] ?? 0,
        },
    ], onConflict: 'user_id,name_key');
  }

  /// How each person's name is written, by name key.
  Map<String, String> personNames = const {};

  /// Payee name (lower case) → friend name: "Also known as".
  Map<String, String> aliases = const {};

  /// Signed-in user id (set directly in previews).
  String? myId;
  String? get me => myId ?? user?.id;

  /// The active connection with this friend (by the name in my list), if any.
  FriendLink? linkFor(String person) {
    final k = keyOf(person);
    for (final l in links) {
      if (l.active && me != null && keyOf(l.nameFor(me!)) == k) return l;
    }
    return null;
  }

  /// An invite I sent to this friend that is not accepted yet.
  FriendLink? pendingInviteFor(String person) {
    final k = keyOf(person);
    for (final l in links) {
      if (!l.active && l.a == me && keyOf(l.aNameForB) == k) return l;
    }
    return null;
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
      await _db.from('goals').insert(row);
    } else {
      await _db.from('goals').update(row).eq('id', id);
    }
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
      await _db.from('transactions').update({'category_id': r.categoryId, 'needs_review': false}).eq('id', txn.id);
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
          await _db.from('transactions').update({'category_id': categoryId, 'needs_review': false}).eq('id', txnId);
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

  void _onError(Object e) {
    error = e;
    notifyListeners();
  }

  // ------------------------------------------------------------ transactions

  /// Saves a payment; returns its id.
  Future<String> saveTxn(Txn t, {required bool isNew, bool rememberCategory = false}) async {
    final row = t.toWriteMap();
    if (isNew) {
      final r = await _db.from('transactions').insert({...row, 'source': 'manual'}).select('id').single();
      return r['id'] as String;
    }
    // `edited` keeps a later re-read of the bank email from overwriting the user's changes.
    await _db.from('transactions').update({...row, 'edited': true}).eq('id', t.id);
    if (rememberCategory && t.categoryId != null) {
      await _db.rpc('set_category', params: {'p_txn': t.id, 'p_category': t.categoryId, 'p_remember': true});
    }
    return t.id;
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
  }) async {
    final row = {
      'name': name.trim(),
      'kind': kind.name,
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

  Future<void> deleteLoanEvent(String id) => _db.from('loan_events').delete().eq('id', id);

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
  List<SharedEntry> get waitingForMe => [
    for (final e in sharedEntries)
      if (e.waiting && e.changedBy != null && e.changedBy != me && !_answering.contains(e.id)) e,
  ];

  /// "Also known as": payments from this payee name count as that friend.
  /// Payee names you said are not the same person as a friend.
  Set<String> get notSame => {...((profile['not_same'] as List?) ?? const []).cast<String>()};

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
    await _db.rpc(
      'categorize_place',
      params: {'p_ids': ids, 'p_vpas': vpas.toList(), 'p_names': names.toList(), 'p_category': categoryId},
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
      unread = rows.map(UnreadEmail.fromMap).toList();
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
