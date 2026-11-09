/// Cloud settings. The Supabase URL and publishable key are designed to be
/// shipped inside apps (row-level security protects the data), so the shop's
/// values are the defaults here. Any of them can be overridden at build time:
///
///   flutter build web --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=... --dart-define=POWERSYNC_URL=...
///
/// Sync turns on only when all three are set; otherwise the app runs in
/// "this device only" mode. Build with --dart-define=CLOUD=false to force that.
class AppConfig {
  /// Build date/time stamped by tool/build_web.sh (shown under More).
  static const build = String.fromEnvironment('BUILD', defaultValue: 'dev');

  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://kbbhqurgkyimghvrhjts.supabase.co');
  static const supabaseKey =
      String.fromEnvironment('SUPABASE_KEY', defaultValue: 'sb_publishable_4beW7RKDIIKCiig-Ry0mwQ_6x-xyT_X');
  static const powersyncUrl =
      String.fromEnvironment('POWERSYNC_URL', defaultValue: 'https://6af0849b4d7433c8099a597f.powersync.journeyapps.com');
  static const _cloud = bool.fromEnvironment('CLOUD', defaultValue: true);

  static bool get cloudEnabled =>
      _cloud && supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty && powersyncUrl.isNotEmpty;
}
