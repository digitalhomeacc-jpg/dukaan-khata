import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../data/app_data.dart';
import '../ui/format.dart';
import 'budgets_screen.dart';
import 'categories_screen.dart';
import 'change_history_screen.dart';
import 'gmail_setup_screen.dart';
import 'unread_emails_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.data});

  final AppData data;

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: data.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await data.rename(name);
  }

  Future<void> _changePassword(BuildContext context) async {
    final c = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New password'),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(helperText: 'At least 8 characters'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Change')),
        ],
      ),
    );
    if (pw == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (pw.length < 8) {
      messenger.showSnackBar(const SnackBar(content: Text('Password must be at least 8 characters')));
      return;
    }
    try {
      await data.changePassword(pw);
      messenger.showSnackBar(const SnackBar(content: Text('Password changed')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not change password: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = data.lastSync;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(child: Text(data.displayName.isEmpty ? '?' : data.displayName[0].toUpperCase())),
            title: Text(data.displayName),
            subtitle: Text(data.user?.email ?? ''),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _rename(context),
          ),
          const Divider(),
          _Section('Bank emails'),
          ListTile(
            leading: Icon(Icons.mark_email_read_outlined, color: sync == null ? null : Colors.green.shade700),
            title: const Text('Gmail sync'),
            subtitle: Text(sync == null ? 'Not set up yet' : 'Last checked ${ago(sync)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(context, GmailSetupScreen(data: data)),
          ),
          ListTile(
            leading: Badge(
              isLabelVisible: data.unread.isNotEmpty,
              label: Text('${data.unread.length}'),
              child: const Icon(Icons.report_outlined),
            ),
            title: const Text("Emails we couldn't read"),
            subtitle: const Text('Add them by hand in one tap'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(context, UnreadEmailsScreen(data: data)),
          ),
          const Divider(),
          _Section('Organise'),
          ListTile(
            leading: const Icon(Icons.savings_outlined),
            title: const Text('Budgets'),
            subtitle: Text(data.budgets.isEmpty ? 'Set a monthly limit' : '${data.budgets.length} set'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(
              context,
              ListenableBuilder(
                listenable: data,
                builder: (_, _) => BudgetsScreen(data: data),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.category_outlined),
            title: const Text('Categories'),
            subtitle: Text('${data.categories.length} categories'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _push(context, CategoriesScreen(data: data)),
          ),
          const Divider(),
          _Section('Account'),
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('Change password'),
            onTap: () => _changePassword(context),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Change history'),
            subtitle: const Text('Every change, before and after. Undo any of them'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeHistoryScreen(data: data))),
          ),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: data.signOut),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Version ${AppConfig.build}',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      title,
      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
    ),
  );
}
