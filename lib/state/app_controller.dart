import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared/export.dart';
import '../accounting/ledger_repo.dart';
import '../accounting/bookings.dart';
import '../accounting/interest.dart';
import '../accounting/recurring.dart';
import '../accounting/reports.dart';
import '../accounting/voucher_service.dart';
import '../core/audit.dart';
import '../core/backup.dart';
import '../core/config.dart';
import '../core/demo.dart';
import '../core/i18n.dart';
import '../core/ids.dart';
import '../core/money.dart';
import '../core/schema.dart';
import '../core/seed.dart';
import '../core/supabase_connector.dart';
import '../inventory/stock_repo.dart';

enum Stage { loading, setupLocal, login, createShop, locked, ready, error }

/// App-wide state: database, logged-in shop, role, language, PIN lock.
class AppController extends ChangeNotifier {
  late SharedPreferences _prefs;
  PowerSyncDatabase? _db;
  Stage stage = Stage.loading;
  String? error;
  Strings strings = const Strings(false);

  String? businessId;
  String businessName = '';
  Actor _actor = const Actor(userId: 'local', name: '', isOwner: false);
  Actor get actor => _actor;
  /// Whoever unlocked the app – every change in the history is signed with it.
  set actor(Actor a) {
    _actor = a;
    AuditLog.actor = a;
  }
  SyncStatus? syncStatus;
  StreamSubscription<SyncStatus>? _statusSub;

  VoucherService? _vouchers;
  LedgerRepo? _ledgers;
  StockRepo? _stock;

  PowerSyncDatabase get db => _db!;
  VoucherService get vouchers => _vouchers!;
  LedgerRepo get ledgers => _ledgers!;
  StockRepo get stock => _stock!;
  InterestService get interest => InterestService(db, businessId!);
  BookingService get bookings => BookingService(db, businessId!);
  RecurringService get recurring => RecurringService(db, businessId!);
  Reports get reports => Reports(db, businessId!, (_pdfEnglish ? const Strings(true) : strings).t);
  bool _pdfEnglish = false;

  /// Builds a report in English for a PDF / print (the PDF engine cannot join
  /// Marathi letters). Names are swapped for their English names, or spelt in
  /// English letters, when the PDF is drawn.
  Future<ReportTable> pdfTable(Future<ReportTable> Function() build) async {
    await loadPdfNames();
    _pdfEnglish = true;
    try {
      return await build();
    } finally {
      _pdfEnglish = false;
    }
  }

  /// Marathi name → English name of every account and item, for PDFs.
  Future<void> loadPdfNames() async {
    final names = <String, String>{};
    for (final r in await db.getAll(
        "SELECT name, name_en FROM ledgers WHERE business_id = ? AND COALESCE(name_en, '') <> '' "
        "UNION ALL SELECT name, name_en FROM items WHERE business_id = ? AND COALESCE(name_en, '') <> ''",
        [businessId, businessId])) {
      names[r['name'] as String] = r['name_en'] as String;
    }
    Exporter.englishNames = names;
  }
  bool get cloud => AppConfig.cloudEnabled;
  bool get english => strings.english;
  String t(String k) => strings.t(k);

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      strings = Strings(_prefs.getString('lang') == 'en');
      final path = kIsWeb ? 'dukaan_khata.db' : '${(await getApplicationSupportDirectory()).path}/dukaan_khata.db';
      _db = PowerSyncDatabase(schema: buildPowerSyncSchema(), path: path);
      await _db!.initialize();
      if (cloud) {
        await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseKey);
      }
      await _route();
    } catch (e, st) {
      debugPrint('$e\n$st');
      error = '$e';
      stage = Stage.error;
      notifyListeners();
    }
  }

  Future<void> _route() async {
    businessId = _prefs.getString('business_id');
    businessName = _prefs.getString('business_name') ?? '';
    if (cloud) {
      final s = Supabase.instance.client.auth.currentSession;
      if (s == null) {
        stage = Stage.login;
      } else if (businessId == null) {
        await _loadMembership();
        return;
      } else {
        await _connectSync();
        stage = _prefs.getString('device_pin') == null ? Stage.ready : Stage.locked;
        if (stage == Stage.ready) _setActorFromPrefs(owner: _prefs.getString('role') == 'owner');
        _watchRole();
      }
    } else if (businessId == null && demoMode) {
      await setupLocal(
          shopName: 'साई बिल्डिंग मटेरियल', ownerName: 'Demo', ownerPin: '1234', staffPin: '5678',
          booksStart: isoDate(DateTime.now().subtract(const Duration(days: 70))));
      stage = Stage.loading; // keep the loading screen until the sample data is in
      notifyListeners();
      await loadDemoData(vouchers, ledgers, stock);
      stage = Stage.ready;
      notifyListeners();
      return;
    } else {
      stage = businessId == null ? Stage.setupLocal : Stage.locked;
    }
    _buildServices();
    notifyListeners();
  }

  void _buildServices() {
    if (businessId == null) return;
    _vouchers = VoucherService(db, businessId!);
    _ledgers = LedgerRepo(db, businessId!);
    _stock = StockRepo(db, businessId!);
    final bid = businessId!;
    if (cloud) {
      // Wait for this shop's data to arrive first. Only the owner may add
      // built-in ledgers introduced by an app update (staff would be refused).
      db.waitForFirstSync().then((_) async {
        await loadBooks();
        if (actor.isOwner && businessId == bid) {
          await db.writeTransaction((tx) => ensureSystemLedgers(tx, bid));
          await _vouchers?.detachHistoryLines(); // old entries are reference only
        }
      }).ignore();
      _booksSub ??= db.onChange(const ['businesses']).listen((_) => loadBooks());
    } else {
      db.writeTransaction((tx) => ensureSystemLedgers(tx, bid)).then((_) async => await _vouchers?.detachHistoryLines()).ignore();
    }
    loadBooks().ignore();
  }

  StreamSubscription<void>? _booksSub;
  StreamSubscription<void>? _roleSub;

  /// Cloud: follow this user's role in the synced member list, so making
  /// someone owner (or staff) takes effect on their phone without signing out.
  void _watchRole() {
    if (!cloud || businessId == null) return;
    final uid = _prefs.getString('user_id');
    if (uid == null) return;
    _roleSub?.cancel();
    _roleSub = db
        .watch('SELECT role FROM members WHERE business_id = ? AND user_id = ?', parameters: [businessId, uid])
        .listen((rows) async {
      if (rows.isEmpty) return;
      final role = rows.first['role'] as String?;
      if (role == null || role == _prefs.getString('role')) return;
      await _prefs.setString('role', role);
      if (actor.userId == uid) actor = Actor(userId: uid, name: actor.name, isOwner: role == 'owner');
      notifyListeners();
    });
  }

  // ---------------- shop details & book settings ----------------
  String shopAddress = '';
  String shopNameEn = '';

  /// Shop name on PDFs and bills (English – see Exporter.latin).
  String get pdfShopName => shopNameEn.isNotEmpty ? shopNameEn : businessName;
  String shopPhone = '';
  String shopGstin = '';

  /// Reads books start / FY month / shop details from the businesses row.
  Future<void> loadBooks() async {
    if (businessId == null) return;
    final r = await db.getOptional('SELECT * FROM businesses WHERE id = ?', [businessId]);
    if (r == null) return;
    Books.start = (r['books_start'] as String?) ?? ((r['created_at'] as String?)?.substring(0, 10) ?? Books.start);
    Books.fyStartMonth = (r['fy_start_month'] as int?) ?? 4;
    shopAddress = (r['address'] as String?) ?? '';
    shopNameEn = (r['name_en'] as String?) ?? '';
    shopPhone = (r['phone'] as String?) ?? '';
    shopGstin = (r['gstin'] as String?) ?? '';
    notifyListeners();
  }

  Future<void> saveShopDetails({
    required String name,
    String nameEn = '',
    required String address,
    required String phone,
    required String gstin,
    required String booksStart,
    required int fyStartMonth,
  }) async {
    final before = await _shopSnap();
    await db.execute(
      'UPDATE businesses SET name = ?, name_en = ?, address = ?, phone = ?, gstin = ?, books_start = ?, fy_start_month = ? WHERE id = ?',
      [name, nameEn.trim().isEmpty ? null : nameEn.trim(), address, phone, gstin.toUpperCase(), booksStart, fyStartMonth, businessId],
    );
    await _prefs.setString('business_name', name);
    businessName = name;
    await AuditLog.write(db,
        businessId: businessId!, recordId: businessId!, action: 'edit', kind: 'shop', title: name, before: before, after: await _shopSnap());
    await loadBooks();
  }

  Future<Map<String, Object?>> _shopSnap() async {
    final r = await db.getOptional('SELECT * FROM businesses WHERE id = ?', [businessId]);
    if (r == null) return {};
    return {
      'name': r['name'],
      'name_en': r['name_en'],
      'address': r['address'],
      'phone': r['phone'],
      'gstin': r['gstin'],
      'books_start': r['books_start'],
      'fy_start_month': r['fy_start_month'],
    };
  }

  /// One-line history note for changes that are not entries / accounts / items.
  Future<void> _logChange(String kind, String recordId, String action, String what) async {
    if (businessId == null) return;
    await AuditLog.write(db, businessId: businessId!, recordId: recordId, action: action, kind: kind, title: what);
  }

  void _setActorFromPrefs({required bool owner}) {
    actor = Actor(
      userId: _prefs.getString('user_id') ?? 'local',
      name: _prefs.getString(owner ? 'owner_name' : 'staff_name') ?? _prefs.getString('user_name') ?? '',
      isOwner: owner,
    );
  }

  // ---------------- language ----------------
  Future<void> setEnglish(bool v) async {
    strings = Strings(v);
    await _prefs.setString('lang', v ? 'en' : 'mr');
    notifyListeners();
  }

  // ---------------- local (single device) mode ----------------
  Future<void> setupLocal({
    required String shopName,
    required String ownerName,
    required String ownerPin,
    String? staffPin,
    bool withItems = true,
    String? booksStart,
    int fyStartMonth = 4,
  }) async {
    final id = newId();
    await db.writeTransaction((tx) async {
      await tx.execute(
          'INSERT INTO businesses (id, name, books_start, fy_start_month, created_at) VALUES (?, ?, ?, ?, ?)',
          [id, shopName, booksStart ?? todayIso(), fyStartMonth, nowIso()]);
      Books.start = booksStart ?? todayIso();
      Books.fyStartMonth = fyStartMonth;
      await seedBusiness(tx, id, withItems: withItems);
    });
    await _prefs.setString('business_id', id);
    await _prefs.setString('business_name', shopName);
    await _prefs.setString('owner_name', ownerName);
    await _prefs.setString('owner_pin', ownerPin);
    if (staffPin != null && staffPin.isNotEmpty) await _prefs.setString('staff_pin', staffPin);
    businessId = id;
    businessName = shopName;
    _buildServices();
    actor = Actor(userId: 'owner', name: ownerName, isOwner: true);
    stage = Stage.ready;
    notifyListeners();
  }

  /// New device: bring back every entry from a full backup file.
  Future<void> restoreLocal(Uint8List bytes, {required String ownerName, required String ownerPin, String? staffPin}) async {
    final (id, name) = await db.writeTransaction((tx) => Backup.restore(tx, bytes));
    await _prefs.setString('business_id', id);
    await _prefs.setString('business_name', name);
    await _prefs.setString('owner_name', ownerName);
    await _prefs.setString('owner_pin', ownerPin);
    if (staffPin != null && staffPin.isNotEmpty) await _prefs.setString('staff_pin', staffPin);
    businessId = id;
    businessName = name;
    _buildServices();
    await loadBooks();
    actor = Actor(userId: 'owner', name: ownerName, isOwner: true);
    stage = Stage.ready;
    notifyListeners();
  }

  Future<Uint8List> exportBackup() => Backup.export(db, businessId!);

  /// PIN unlock. Local mode: owner PIN → owner, staff PIN → staff.
  /// Cloud mode: device PIN only (role comes from the server membership).
  bool unlock(String pin) {
    if (cloud) {
      if (pin != _prefs.getString('device_pin')) return false;
      _setActorFromPrefs(owner: _prefs.getString('role') == 'owner');
    } else if (pin == _prefs.getString('owner_pin')) {
      actor = Actor(userId: 'owner', name: _prefs.getString('owner_name') ?? '', isOwner: true);
    } else if (pin == _prefs.getString('staff_pin')) {
      actor = Actor(userId: 'staff', name: _prefs.getString('staff_name') ?? 'Staff', isOwner: false);
    } else {
      return false;
    }
    stage = Stage.ready;
    notifyListeners();
    return true;
  }

  void lock() {
    if (!cloud || _prefs.getString('device_pin') != null) {
      stage = Stage.locked;
      notifyListeners();
    }
  }

  Future<void> setPins({String? ownerPin, String? staffPin, String? staffName, String? devicePin}) async {
    // the history notes that a PIN changed – never the PIN itself
    if (businessId != null && [ownerPin, staffPin, devicePin].any((p) => p != null && p.isNotEmpty) || staffName != null) {
      await _logChange('user', businessId ?? '', 'pin', [
        if (ownerPin?.isNotEmpty ?? false) 'owner PIN',
        if (staffPin?.isNotEmpty ?? false) 'staff PIN',
        if (devicePin?.isNotEmpty ?? false) 'device PIN',
        if (staffName != null) 'staff name: $staffName',
      ].join(', '));
    }
    if (ownerPin != null && ownerPin.isNotEmpty) await _prefs.setString('owner_pin', ownerPin);
    if (staffPin != null) {
      staffPin.isEmpty ? await _prefs.remove('staff_pin') : await _prefs.setString('staff_pin', staffPin);
    }
    if (staffName != null) await _prefs.setString('staff_name', staffName);
    if (devicePin != null) {
      devicePin.isEmpty ? await _prefs.remove('device_pin') : await _prefs.setString('device_pin', devicePin);
    }
  }

  bool get hasStaffPin => _prefs.getString('staff_pin') != null;

  Future<void> renameBusiness(String name) async {
    await _logChange('shop', businessId ?? '', 'edit', '$businessName → $name');
    await db.execute('UPDATE businesses SET name = ? WHERE id = ?', [name, businessId]);
    await _prefs.setString('business_name', name);
    businessName = name;
    notifyListeners();
  }

  // ---------------- cloud mode ----------------
  SupabaseClient get _sb => Supabase.instance.client;

  Future<void> signIn(String email, String password) async {
    await _sb.auth.signInWithPassword(email: email.trim(), password: password);
    await _loadMembership();
  }

  Future<void> signUp(String email, String password) async {
    final r = await _sb.auth.signUp(email: email.trim(), password: password);
    if (r.session == null) throw Exception('Check your email to confirm the account, then sign in.');
    await _loadMembership();
  }

  /// "I was invited – check again" on the create-shop screen.
  Future<void> recheckMembership() => _loadMembership();

  Future<void> _loadMembership() async {
    // Link any invitation made by an owner for this email.
    await _sb.rpc('claim_membership');
    final rows = await _sb.from('members').select('business_id, role, name, businesses(name)').eq('user_id', _sb.auth.currentUser!.id);
    if (rows.isEmpty) {
      stage = Stage.createShop;
      notifyListeners();
      return;
    }
    // If someone made their own shop by mistake before being invited, the
    // owner's shop (where they are staff) wins.
    final list = List<Map<String, dynamic>>.from(rows);
    list.sort((a, b) => (a['role'] == 'staff' ? 0 : 1).compareTo(b['role'] == 'staff' ? 0 : 1));
    final m = list.first;
    await _saveMembership(m['business_id'] as String, (m['businesses']?['name'] as String?) ?? '',
        m['role'] as String, (m['name'] as String?) ?? _sb.auth.currentUser!.email ?? '');
    await _connectSync();
    _buildServices();
    _watchRole();
    stage = Stage.ready;
    notifyListeners();
  }

  Future<void> _saveMembership(String bid, String bname, String role, String name) async {
    businessId = bid;
    businessName = bname;
    await _prefs.setString('business_id', bid);
    await _prefs.setString('business_name', bname);
    await _prefs.setString('role', role);
    await _prefs.setString('user_name', name);
    await _prefs.setString('user_id', _sb.auth.currentUser!.id);
    actor = Actor(userId: _sb.auth.currentUser!.id, name: name, isOwner: role == 'owner');
  }

  Future<void> createShop(String shopName, String ownerName,
      {bool withItems = true, String? booksStart, int fyStartMonth = 4}) async {
    final bid = await _sb.rpc('create_business', params: {'p_name': shopName, 'p_owner_name': ownerName}) as String;
    Books.start = booksStart ?? todayIso();
    Books.fyStartMonth = fyStartMonth;
    await _sb.from('businesses').update({'books_start': Books.start, 'fy_start_month': fyStartMonth}).eq('id', bid);
    await _saveMembership(bid, shopName, 'owner', ownerName);
    await _connectSync();
    // Seed built-in ledgers + starter items; they upload through PowerSync.
    await db.writeTransaction((tx) => seedBusiness(tx, bid, withItems: withItems));
    _buildServices();
    stage = Stage.ready;
    notifyListeners();
  }

  /// Invites someone by email as owner (मालक) or staff; they get access on
  /// first sign-in with that email. A shop may have several owners.
  Future<void> inviteMember(String email, String name, {String role = 'staff'}) async {
    await _sb.from('members').insert({
      'id': newId(),
      'business_id': businessId,
      'email': email.trim().toLowerCase(),
      'name': name,
      'role': role == 'owner' ? 'owner' : 'staff',
    });
    await _logChange('user', email.trim().toLowerCase(), 'create', '$name (${email.trim().toLowerCase()}) · $role');
  }

  Future<void> inviteStaff(String email, String name) => inviteMember(email, name);

  /// Owner ⇄ staff. The last owner can't be made staff (someone must stay owner).
  Future<void> setMemberRole(String id, String role) async {
    if (role != 'owner') {
      final owners = await _sb.from('members').select('id').eq('business_id', businessId!).eq('role', 'owner');
      if ((owners as List).length <= 1 && owners.any((o) => o['id'] == id)) throw PermissionDenied('err_last_owner');
    }
    await _sb.from('members').update({'role': role}).eq('id', id);
    final m = await _sb.from('members').select('name, email').eq('id', id).maybeSingle();
    await _logChange('user', id, 'edit', '${m?['name'] ?? ''} (${m?['email'] ?? ''}) → $role');
  }

  Future<List<Map<String, dynamic>>> listMembers() async =>
      List<Map<String, dynamic>>.from(await _sb.from('members').select().eq('business_id', businessId!));

  Future<void> removeMember(String id) async {
    final m = await _sb.from('members').select('name, email').eq('id', id).maybeSingle();
    await _sb.from('members').delete().eq('id', id);
    await _logChange('user', id, 'delete', '${m?['name'] ?? ''} (${m?['email'] ?? ''})');
  }

  Future<void> _connectSync() async {
    await db.connect(connector: SupabaseConnector(_sb));
    _statusSub ??= db.statusStream.listen((s) {
      syncStatus = s;
      notifyListeners();
    });
  }

  /// Entries saved on this device that have not reached the server yet.
  Future<int> pendingUploads() async {
    if (!cloud) return 0;
    final r = await db.get('SELECT COUNT(DISTINCT tx_id) AS n FROM ps_crud');
    return (r['n'] as int?) ?? 0;
  }

  Future<List<Map<String, Object?>>> syncErrors() async =>
      [for (final r in await db.getAll('SELECT * FROM sync_errors ORDER BY at DESC')) Map<String, Object?>.from(r)];

  Future<void> clearSyncErrors() => db.execute('DELETE FROM sync_errors');

  /// "Sync now": reconnects, which immediately uploads waiting entries and
  /// downloads anything new.
  Future<void> syncNow() async {
    if (!cloud) return;
    await db.disconnect();
    await db.connect(connector: SupabaseConnector(_sb));
  }

  Future<void> signOut() async {
    if (cloud) {
      if (await pendingUploads() > 0) throw PermissionDenied('err_pending_signout');
      await db.disconnectAndClear();
      await _sb.auth.signOut();
    }
    for (final k in ['business_id', 'business_name', 'role', 'user_name', 'user_id', 'device_pin']) {
      await _prefs.remove(k);
    }
    businessId = null;
    stage = cloud ? Stage.login : Stage.setupLocal;
    notifyListeners();
  }
}

/// Makes the controller available to every screen: `App.of(context)`.
class App extends InheritedNotifier<AppController> {
  const App({super.key, required AppController controller, required super.child}) : super(notifier: controller);

  static AppController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<App>()!.notifier!;
  static AppController read(BuildContext context) => context.getInheritedWidgetOfExactType<App>()!.notifier!;
}
