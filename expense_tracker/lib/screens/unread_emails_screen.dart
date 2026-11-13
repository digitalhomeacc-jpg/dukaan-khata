import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';
import '../ui/format.dart';
import 'txn_editor.dart';

/// Bank emails that mention money but the parser could not read.
class UnreadEmailsScreen extends StatefulWidget {
  const UnreadEmailsScreen({super.key, required this.data});

  final AppData data;

  @override
  State<UnreadEmailsScreen> createState() => _UnreadEmailsScreenState();
}

class _UnreadEmailsScreenState extends State<UnreadEmailsScreen> {
  @override
  void initState() {
    super.initState();
    widget.data.refreshUnread();
  }

  Future<void> _open(UnreadEmail e) async {
    final data = widget.data;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(e.subject, style: Theme.of(c).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(e.from, style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 16),
            SelectableText(e.body),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(c, 'dismiss'),
                    child: const Text('Not a payment'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: () => Navigator.pop(c, 'add'), child: const Text('Add by hand')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'add') {
      await openTxnEditor(
        context,
        data,
        prefill: Txn(
          id: '',
          amount: _guessAmount(e.body) ?? 0,
          isDebit: true,
          txnAt: e.receivedAt ?? DateTime.now(),
          method: 'other',
        ),
      );
    }
    await data.dismissUnread(e.id);
  }

  static double? _guessAmount(String body) {
    final m = RegExp(r'(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', caseSensitive: false).firstMatch(body);
    return m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.data,
      builder: (context, _) {
        final list = widget.data.unread;
        return Scaffold(
          appBar: AppBar(title: const Text("Emails we couldn't read")),
          body: list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('All bank emails were read.', textAlign: TextAlign.center),
                  ),
                )
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    return ListTile(
                      title: Text(
                        e.subject.isEmpty ? '(no subject)' : e.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${e.receivedAt == null ? '' : '${dayLabel(e.receivedAt!)} · '}${e.body.replaceAll(RegExp(r'\s+'), ' ')}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _open(e),
                    );
                  },
                ),
        );
      },
    );
  }
}
