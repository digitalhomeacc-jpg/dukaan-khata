import 'dart:async';
import 'dart:convert' show base64Encode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../logic/summary.dart' show ShareTotals, shareTotals;
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
      db.from('txn_shares').stream(primaryKey: ['id']).listen((rows) {
        shares = rows.map(TxnShare.fromMap).toList();
        _shareTotals = null;
        notifyListeners();
      }, onError: _onError),
      db.from('budgets').stream(primaryKey: ['id']).listen((rows) {
        budgets = rows.map(Budget.fromMap).toList();
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
    this.unread = const [],
    this.profile = const {},
  })  : _client = null,
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
  ShareTotals? _shareTotals;

  /// Friends' parts of group payments, for the totals.
  ShareTotals get shareTotalsNow => _shareTotals ??= shareTotals(shares);

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

  Set<String> get loanCategoryIds => {for (final c in categories) if (c.isLoan) c.id};
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

  Future<void> saveTxn(Txn t, {required bool isNew, bool rememberCategory = false}) async {
    final row = t.toWriteMap();
    if (isNew) {
      await _db.from('transactions').insert({...row, 'source': 'manual'});
      return;
    }
    // `edited` keeps a later re-read of the bank email from overwriting the user's changes.
    await _db.from('transactions').update({...row, 'edited': true}).eq('id', t.id);
    if (rememberCategory && t.categoryId != null) {
      await _db.rpc('set_category', params: {'p_txn': t.id, 'p_category': t.categoryId, 'p_remember': true});
    }
  }

  Future<void> deleteTxn(String id) => _db.from('transactions').delete().eq('id', id);

  // -------------------------------------------------------------- categories

  Future<void> saveCategory(
      {String? id, required String name, required String icon, required int color, bool isLoan = false}) async {
    final row = {'name': name.trim(), 'icon': icon, 'color': color, 'kind': isLoan ? 'loan' : 'normal'};
    if (id == null) {
      await _db.from('categories').insert(row);
    } else {
      await _db.from('categories').update(row).eq('id', id);
    }
  }

  Future<void> deleteCategory(String id) => _db.from('categories').delete().eq('id', id);

  /// Makes the "Personal loans" category if the user deleted it.
  Future<Category> ensureLoanCategory() async {
    final existing = loanCategory;
    if (existing != null) return existing;
    final row = await _db
        .from('categories')
        .upsert({'name': 'Personal loans', 'icon': 'handshake', 'color': 0xFF3F51B5, 'kind': 'loan'},
            onConflict: 'user_id,name')
        .select()
        .single();
    final c = Category.fromMap(row);
    categories = [...categories.where((x) => x.id != c.id), c];
    notifyListeners();
    return c;
  }

  // ---------------------------------------------------------------- accounts

  Future<void> saveAccount(
      {String? id, required String name, required AccountKind kind, required double openingBalance, bool archived = false, DateTime? openingDate}) async {
    final row = {
      'name': name.trim(), 'kind': kind.name, 'opening_balance': openingBalance, 'archived': archived,
      'opening_date': openingDate == null ? null : '${openingDate.year.toString().padLeft(4, '0')}-${openingDate.month.toString().padLeft(2, '0')}-${openingDate.day.toString().padLeft(2, '0')}',
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
  Future<void> setOwed(String loanId, double owed) => _db.from('loans').update({
        'outstanding': owed,
        'outstanding_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', loanId);

  // ---------------------------------------------------------------- friends

  Category? get friendsCategory => loanCategory;

  static String keyOf(String name) => name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Payees already decided: friends (by category) and "not a friend".
  Set<String> get decidedPeople => {
        for (final t in transactions)
          if (t.merchant != null && loanCategoryIds.contains(t.categoryId)) keyOf(t.merchant!),
        ...((profile['not_friends'] as List?) ?? const []).cast<String>(),
      };

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
      final row = await _db.from('transactions').insert({
        'amount': total, 'direction': 'debit', 'merchant': description, 'method': 'other',
        'txn_at': at.toUtc().toIso8601String(), 'category_id': categoryId, 'account_id': accountId, 'source': 'manual',
      }).select('id').single();
      for (final e in friendShares.entries) {
        if (e.value > 0) await addShare(row['id'] as String, e.key, e.value);
      }
    } else {
      await _db.from('transactions').insert({
        'amount': myShare, 'direction': 'debit', 'merchant': description, 'method': 'other',
        'txn_at': at.toUtc().toIso8601String(), 'category_id': categoryId, 'source': 'manual',
        'paid_by': paidBy.trim(), 'note': '$paidBy paid ₹${total.toStringAsFixed(total == total.roundToDouble() ? 0 : 2)} in total',
      });
    }
  }

  /// Settle up outside the bank (cash): you paid them, or they paid you.
  Future<void> settleUp(String person, double amount, {required bool iPaid, String? accountId}) async {
    final cat = friendsCategory?.id;
    await _db.from('transactions').insert({
      'amount': amount, 'direction': iPaid ? 'debit' : 'credit', 'merchant': person, 'method': 'cash',
      'txn_at': DateTime.now().toUtc().toIso8601String(), 'category_id': cat, 'account_id': accountId ?? cashAccount?.id,
      'source': 'manual', 'note': 'Settle up',
    });
  }

  // ------------------------------------------------------- bank statements

  /// Reads a bank statement on the server. With [dryRun] nothing is saved: it says what would be imported.
  Future<Map<String, dynamic>> importStatement(Uint8List bytes, String fileName,
      {String? accountId, required bool dryRun, bool setOpening = false}) async {
    final res = await _db.functions.invoke('import-statement', body: {
      'file': base64Encode(bytes),
      'fileName': fileName,
      'accountId': accountId,
      'dryRun': dryRun,
      'setOpening': setOpening,
    });
    final data = res.data;
    if (data is Map<String, dynamic>) {
      if (data['error'] != null) throw Exception(data['error']);
      return data;
    }
    throw Exception('Unexpected answer from the server');
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
  Future<void> markSharePaid(String id, {String? paidTxnId}) => _db.from('txn_shares').update({
        'paid_txn_id': paidTxnId,
        'paid_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', id);

  // ------------------------------------------------------------- bank balance

  /// Shifts the opening balance so the app agrees with the bank's latest balance.
  Future<void> matchBankBalance(Account a, double difference) =>
      _db.from('accounts').update({'opening_balance': a.openingBalance + difference}).eq('id', a.id);

  // ------------------------------------------------------------- Gmail sync

  Future<void> refreshUnread() async {
    try {
      final rows = await _db.from('unparsed_emails').select().eq('kind', 'unreadable').order('received_at', ascending: false).limit(200);
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
