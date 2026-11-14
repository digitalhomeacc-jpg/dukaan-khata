import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';

/// Invite code from a link like …/expense-tracker/#invite-abc123 (web), read once at start.
String? pendingInviteCode;

/// Opened from the sign-in link in a "Forgot password?" email: ask for a new password once signed in.
bool openedFromEmailLink = false;

Future<void> main() async {
  final fragment = Uri.base.fragment;
  if (fragment.startsWith('invite-')) pendingInviteCode = fragment.substring('invite-'.length);
  openedFromEmailLink = fragment.contains('access_token=') || Uri.base.queryParameters.containsKey('code');
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.isConfigured) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseKey,
      // The link may open in Safari rather than the home-screen app: the implicit flow works in either.
      authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
  }
  runApp(const ExpenseApp());
}

class ExpenseApp extends StatelessWidget {
  const ExpenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00897B), brightness: b),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );
    return MaterialApp(
      title: 'Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en', 'IN'), Locale('en')],
      home: AppConfig.isConfigured ? const AuthGate() : const _NotConfigured(),
    );
  }
}

/// Shows the login screen or the app, following the Supabase session.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, _) {
        final session = auth.currentSession;
        if (session == null) return const LoginScreen();
        // A new key per user rebuilds all data when someone else signs in.
        final home = HomeShell(key: ValueKey(session.user.id));
        return openedFromEmailLink ? _AskNewPassword(child: home) : home;
      },
    );
  }
}

/// After signing in with an emailed link: set a new password straight away.
class _AskNewPassword extends StatefulWidget {
  const _AskNewPassword({required this.child});

  final Widget child;

  @override
  State<_AskNewPassword> createState() => _AskNewPasswordState();
}

class _AskNewPasswordState extends State<_AskNewPassword> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  Future<void> _ask() async {
    openedFromEmailLink = false;
    final c = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Set a new password'),
          content: AutofillGroup(
            child: TextField(
              controller: c,
              autofocus: true,
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(helperText: 'At least 8 characters', errorText: error),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
            FilledButton(
              onPressed: () async {
                if (c.text.length < 8) return setState(() => error = 'At least 8 characters');
                try {
                  await Supabase.instance.client.auth.updateUser(UserAttributes(password: c.text));
                  if (ctx.mounted) Navigator.pop(ctx);
                } on AuthException catch (e) {
                  setState(() => error = e.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Supabase is not configured.\n\nBuild with\n--dart-define=SUPABASE_URL=…\n--dart-define=SUPABASE_PUBLISHABLE_KEY=…',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}
