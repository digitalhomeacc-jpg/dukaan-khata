/// Supabase project settings, passed at build time:
///
///   flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///               --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
///
/// (A legacy "anon" key works too.)
///
/// or put them in a JSON file and use `--dart-define-from-file=env.json`.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// When this copy of the app was built, shown in Settings (e.g. "13 Nov 14:50").
  static const build = String.fromEnvironment('BUILD', defaultValue: 'dev');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  /// Where each user's Gmail script sends bank emails.
  static String get ingestUrl => '$supabaseUrl/functions/v1/ingest-email';
}
