import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import '../data/app_data.dart';
import '../models.dart';
import '../ui/format.dart';

Future<void> openImportStatement(BuildContext context, AppData data, {Account? account}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ImportStatementScreen(data: data, account: account),
    ));

/// Pick a bank statement, see what it contains, then import it.
class ImportStatementScreen extends StatefulWidget {
  const ImportStatementScreen({super.key, required this.data, this.account});

  final AppData data;
  final Account? account;

  @override
  State<ImportStatementScreen> createState() => _ImportStatementScreenState();
}

class _ImportStatementScreenState extends State<ImportStatementScreen> {
  Uint8List? _bytes;
  String? _name;
  Map<String, dynamic>? _preview;
  Map<String, dynamic>? _done;
  var _busy = false;
  var _setOpening = true;
  String? _error;

  String _message(Object e) {
    if (e is FunctionException) {
      final d = e.details;
      if (d is Map && d['error'] != null) return '${d['error']}';
      return 'The server said ${e.status}';
    }
    return e.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xls', 'xlsx', 'csv', 'txt'],
    );
    if (files.isEmpty) return;
    final f = files.first;
    final bytes = await f.readAsBytes();
    setState(() {
      _bytes = bytes;
      _name = f.name;
      _preview = null;
      _done = null;
      _error = null;
      _busy = true;
    });
    try {
      final p = await widget.data.importStatement(_bytes!, _name!, accountId: widget.account?.id, dryRun: true);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.data.importStatement(_bytes!, _name!,
          accountId: widget.account?.id, dryRun: false, setOpening: _setOpening);
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(Object? iso) {
    if (iso is! String) return '?';
    final d = DateTime.tryParse(iso);
    return d == null ? iso : dayLabel(d);
  }

  double? _num(Object? v) => v is num ? v.toDouble() : null;

  @override
  Widget build(BuildContext context) {
    final p = _preview, done = _done;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Import bank statement')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (done == null) ...[
            const Text(
              'In NetBanking, download your account statement as XLS (Excel) or Delimited (CSV), not PDF. '
              'Choose any dates, e.g. from 1 April. Payments the app already has from bank emails are not added twice.',
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.upload_file),
              label: Text(_name == null ? 'Choose statement file' : 'Choose another file'),
            ),
          ],
          if (_busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: TextStyle(color: scheme.error))),
          if (p != null && done == null && !_busy) ...[
            const SizedBox(height: 16),
            Card.outlined(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${p['account']}', style: text.titleMedium),
                    Text('${_date(p['from'])} – ${_date(p['to'])} · $_name', style: text.bodySmall),
                    const Divider(height: 24),
                    fact('Transactions in the file', '${p['rows']} (${p['debits']} out, ${p['credits']} in)'),
                    fact('Already in the app from emails', '${p['alreadyFromEmails']}'),
                    if ((p['alreadyImported'] as num? ?? 0) > 0) fact('Imported before', '${p['alreadyImported']}'),
                    fact('New, will be added', '${p['new']}'),
                    if (_num(p['openingBalance']) != null) fact('Opening balance', money(_num(p['openingBalance'])!)),
                    if (_num(p['closingBalance']) != null) fact('Closing balance', money(_num(p['closingBalance'])!)),
                  ],
                ),
              ),
            ),
            if (_num(p['openingBalance']) != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _setOpening,
                onChanged: (v) => setState(() => _setOpening = v ?? true),
                title: Text('Start this account from ${_date(p['from'])} at ${money(_num(p['openingBalance'])!)}'),
                subtitle: const Text('Earlier transactions stay as history but do not change the balance'),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: (p['new'] as num? ?? 0) == 0 && !_setOpening ? null : _import,
              child: Text((p['new'] as num? ?? 0) == 0 ? 'Nothing new: just set the balance' : 'Import ${p['new']} transactions'),
            ),
          ],
          if (done != null) ...[
            const SizedBox(height: 8),
            Icon(Icons.check_circle, color: Colors.green.shade700, size: 56),
            const SizedBox(height: 8),
            Text('${done['added']} transactions added to ${done['account']}',
                textAlign: TextAlign.center, style: text.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Categories, friends and loan payments are filled in where the app could tell. '
              'Check “No category” on the Home tab for the rest; each one you set is remembered for that payee.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        ],
      ),
    );
  }
}
