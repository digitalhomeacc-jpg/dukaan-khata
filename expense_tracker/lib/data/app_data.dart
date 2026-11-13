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
    await _db.from('transactions').update(row).eq('id', t.id);
    if (rememberCategory && t.categoryId != null) {
      await _db.rpc('set_category', params: {'p_txn': t.id, 'p_category': t.categoryId, 'p_remember': true});
    }
  }

  Future<void> deleteTxn(String id) => _db.from('transactions').delete().eq('id', id);

  // -------------------------------------------------------------- categories

  Future<void> saveCategory({String? id, required String name, required String icon, required int color}) async {
    final row = {'name': name.trim(), 'icon': icon, 'color': color};
    if (id == null) {
      await _db.from('categories').insert(row);
    } else {
      await _db.from('categories').update(row).eq('id', id);
    }
  }

  Future<void> deleteCategory(String id) => _db.from('categories').delete().eq('id', id);

  // ------------------------------------------------------------- Gmail sync

  Future<void> refreshUnread() async {
    try {
      final rows = await _db.from('unparsed_emails').select().order('received_at', ascending: false).limit(200);
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
        .replaceFirst('__INGEST_TOKEN__', ingestToken ?? '');
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
