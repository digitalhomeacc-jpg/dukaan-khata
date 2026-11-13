import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
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
      {String? id, required String name, required AccountKind kind, required double openingBalance, bool archived = false}) async {
    final row = {'name': name.trim(), 'kind': kind.name, 'opening_balance': openingBalance, 'archived': archived};
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
