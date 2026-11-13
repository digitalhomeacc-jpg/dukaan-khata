import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_data.dart';
import '../ui/format.dart';

class GmailSetupScreen extends StatelessWidget {
  const GmailSetupScreen({super.key, required this.data});

  final AppData data;

  Future<void> _copyScript(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (data.ingestToken == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Still loading your account, try again in a moment')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: await data.personalScript()));
    messenger.showSnackBar(const SnackBar(content: Text('Script copied. Paste it into script.google.com')));
  }

  Future<void> _newToken(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Make a new secret key?'),
        content: const Text(
            'Your current Gmail script will stop working. Afterwards copy the script again and replace the old one in script.google.com.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Make new key')),
        ],
      ),
    );
    if (yes != true) return;
    await data.regenerateToken();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('New key made. Copy the script again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final sync = data.lastSync;
        return Scaffold(
          appBar: AppBar(title: const Text('Gmail sync')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card.filled(
                child: ListTile(
                  leading: Icon(sync == null ? Icons.sync_disabled : Icons.check_circle,
                      color: sync == null ? null : Colors.green.shade700),
                  title: Text(sync == null ? 'Not connected yet' : 'Connected'),
                  subtitle: Text(sync == null
                      ? 'Follow the steps below once. It takes about 3 minutes.'
                      : 'Last checked ${ago(sync)}. New bank emails show up within 5 minutes.'),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'A small script runs in your own Google account. Every 5 minutes it looks for '
                'HDFC, ICICI, SBI and Axis alert emails and sends only those to your Expense Tracker. '
                'Nothing else in your Gmail is read.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 20),
              _Step(
                n: 1,
                title: 'Copy your script',
                body: 'It already contains your personal secret key. Do not share it.',
                action: FilledButton.icon(
                  onPressed: () => _copyScript(context),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy script'),
                ),
              ),
              _Step(
                n: 2,
                title: 'Open Google Apps Script',
                body: 'Sign in with the Gmail account that gets your bank emails, tap "New project", '
                    'delete the sample code and paste the script. Press the save icon.\n\n'
                    'Tip: this is easiest on a computer. On a phone, use Chrome with "Desktop site" ticked.',
                action: OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse('https://script.google.com/home/projects/create'),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open script.google.com'),
                ),
              ),
              const _Step(
                n: 3,
                title: 'Run "setup" once',
                body: 'Pick "setup" in the function menu at the top and press Run. Google asks for permission: '
                    'choose your account → Advanced → "Go to … (unsafe)" → Allow. Google shows this warning '
                    'for every personal script; the script is yours and only you can run it.',
              ),
              const _Step(
                n: 4,
                title: 'Done',
                body: 'The last 30 days of bank emails are imported now, and new ones every 5 minutes. '
                    'This page shows "Connected" after the first check.',
              ),
              const Divider(height: 40),
              Text('Other functions in the script', style: text.titleSmall),
              const SizedBox(height: 4),
              const Text('• resyncLast30Days: send the last 30 days again (duplicates are skipped)\n'
                  '• stopSync: switch the automatic check off'),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => _newToken(context),
                icon: const Icon(Icons.key),
                label: const Text('Make a new secret key'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.body, this.action});

  final int n;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(radius: 14, child: Text('$n', style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body),
                  if (action != null) ...[const SizedBox(height: 8), action!],
                ],
              ),
            ),
          ],
        ),
      );
}
