import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum _Mode { signIn, signUp, forgot }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  var _mode = _Mode.signIn;
  var _busy = false;
  var _codeSent = false;
  var _hidePassword = true;
  String? _error;
  String? _info;

  GoTrueClient get _auth => Supabase.instance.client.auth;

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final email = _email.text.trim();
    try {
      switch (_mode) {
        case _Mode.signIn:
          await _auth.signInWithPassword(email: email, password: _password.text);
        case _Mode.signUp:
          final res = await _auth.signUp(
            email: email,
            password: _password.text,
            data: {'display_name': _name.text.trim()},
          );
          if (res.session == null) {
            _info = 'Account created. Open the confirmation email we sent to $email, then sign in.';
            _mode = _Mode.signIn;
          }
        case _Mode.forgot:
          if (!_codeSent) {
            await _auth.signInWithOtp(email: email, shouldCreateUser: false);
            _codeSent = true;
            _info = 'We emailed a 6-digit code to $email.';
          } else {
            await _auth.verifyOTP(email: email, token: _code.text.trim(), type: OtpType.email);
            await _auth.updateUser(UserAttributes(password: _password.text));
          }
      }
    } on AuthException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Something went wrong: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _switch(_Mode m) => setState(() {
        _mode = m;
        _codeSent = false;
        _error = null;
        _info = null;
      });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final needsPassword = _mode != _Mode.forgot || _codeSent;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.account_balance_wallet_rounded, size: 64, color: scheme.primary),
                    const SizedBox(height: 12),
                    Text('Expense Tracker',
                        textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 4),
                    Text(
                      switch (_mode) {
                        _Mode.signIn => 'Sign in to your account',
                        _Mode.signUp => 'Create your account',
                        _Mode.forgot => 'Reset your password',
                      },
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    if (_mode == _Mode.signUp) ...[
                      TextFormField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Your name', prefixIcon: Icon(Icons.person)),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your name' : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _email,
                      enabled: !_codeSent,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email)),
                      validator: (v) => RegExp(r'^\S+@\S+\.\S+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
                    ),
                    if (_mode == _Mode.forgot && _codeSent) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Code from the email', prefixIcon: Icon(Icons.pin)),
                        validator: (v) => (v ?? '').trim().length < 6 ? 'Enter the code' : null,
                      ),
                    ],
                    if (needsPassword) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _hidePassword,
                        autofillHints: [_mode == _Mode.signIn ? AutofillHints.password : AutofillHints.newPassword],
                        decoration: InputDecoration(
                          labelText: _mode == _Mode.forgot ? 'New password' : 'Password',
                          prefixIcon: const Icon(Icons.lock),
                          suffixIcon: IconButton(
                            icon: Icon(_hidePassword ? Icons.visibility : Icons.visibility_off),
                            onPressed: () => setState(() => _hidePassword = !_hidePassword),
                          ),
                        ),
                        onFieldSubmitted: (_) => _submit(),
                        validator: (v) => (v ?? '').length < 8 ? 'At least 8 characters' : null,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: scheme.error)),
                    ],
                    if (_info != null) ...[
                      const SizedBox(height: 12),
                      Text(_info!, style: TextStyle(color: scheme.primary)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(switch (_mode) {
                              _Mode.signIn => 'Sign in',
                              _Mode.signUp => 'Create account',
                              _Mode.forgot => _codeSent ? 'Set new password' : 'Email me a code',
                            }),
                    ),
                    const SizedBox(height: 8),
                    if (_mode == _Mode.signIn) ...[
                      TextButton(onPressed: () => _switch(_Mode.signUp), child: const Text('New here? Create an account')),
                      TextButton(onPressed: () => _switch(_Mode.forgot), child: const Text('Forgot password?')),
                    ] else
                      TextButton(onPressed: () => _switch(_Mode.signIn), child: const Text('Back to sign in')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
