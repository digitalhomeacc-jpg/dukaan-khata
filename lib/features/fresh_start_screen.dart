import 'package:share_plus/share_plus.dart' show XFile;
import 'package:flutter/material.dart';

import '../accounting/fresh_start.dart';
import '../core/drive_backup.dart';
import '../core/money.dart';
import '../shared/export.dart';
import '../shared/widgets.dart';
import '../state/app_controller.dart';

/// नवीन सुरुवात – फक्त बाकी ठेवा: delete every entry, keep every balance.
/// Owner only. Backup first (required), then a typed confirmation.
class FreshStartScreen extends StatefulWidget {
  const FreshStartScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const FreshStartScreen()));

  @override
  State<FreshStartScreen> createState() => _FreshStartScreenState();
}

class _FreshStartScreenState extends State<FreshStartScreen> {
  int? entries;
  bool backupFile = false, backupDrive = false, busy = false;
  String? progress;
  final confirmCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final app = App.read(context);
    FreshStart(app.db, app.businessId!).entryCount().then((n) {
      if (mounted) setState(() => entries = n);
    });
  }

  bool get _backedUp => backupFile || backupDrive;
  String _word(AppController app) => app.t('fresh_word');

  Future<void> _backupFile() async {
    final app = App.read(context);
    setState(() => busy = true);
    try {
      final bytes = await app.exportBackup();
      final name = 'dukaan_khata_backup_before_fresh_start_${todayIso()}.json';
      await Exporter.shareFiles([XFile.fromData(bytes, mimeType: 'application/json', name: name)]);
      if (mounted) setState(() => backupFile = true);
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _backupDrive() async {
    final app = App.read(context);
    setState(() => busy = true);
    try {
      final r = await runDriveBackup(app.backupUrl);
      if (mounted) {
        toast(context, '${app.t('drive_ok')} · ${r.rows}');
        setState(() => backupDrive = true);
      }
    } catch (e) {
      if (mounted) toast(context, errText(context, e), error: true);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _run() async {
    final app = App.read(context);
    final t = app.t;
    setState(() {
      busy = true;
      progress = '0 / ${entries ?? 0}';
    });
    try {
      await FreshStart(app.db, app.businessId!).run(todayIso(), onProgress: (d, n) {
        if (mounted) setState(() => progress = '$d / $n');
      });
      await app.loadBooks();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('fresh_done_title')),
          content: Text(t('fresh_done').replaceAll('{n}', '${entries ?? 0}')),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('ok')))],
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        toast(context, errText(context, e), error: true);
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final t = app.t;
    final scheme = Theme.of(context).colorScheme;
    final ready = _backedUp && confirmCtl.text.trim() == _word(app) && !busy && entries != null;
    return Scaffold(
      appBar: AppBar(title: Text(t('fresh_title'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              t('fresh_what').replaceAll('{n}', '${entries ?? '…'}').replaceAll('{date}', shortDate(todayIso())),
              style: const TextStyle(height: 1.4),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('1. ${t('fresh_step_backup')}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 6),
        FilledButton.tonalIcon(
          key: const Key('fresh_backup_file'),
          icon: Icon(backupFile ? Icons.check_circle : Icons.save_alt),
          label: Text(t('full_backup')),
          onPressed: busy ? null : _backupFile,
        ),
        if (app.cloud && app.backupUrl.isNotEmpty) ...[
          const SizedBox(height: 6),
          FilledButton.tonalIcon(
            icon: Icon(backupDrive ? Icons.check_circle : Icons.add_to_drive),
            label: Text(t('drive_backup')),
            onPressed: busy ? null : _backupDrive,
          ),
        ],
        const SizedBox(height: 18),
        Text('2. ${t('fresh_step_type').replaceAll('{w}', _word(app))}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 6),
        TextField(
          key: const Key('fresh_confirm'),
          controller: confirmCtl,
          enabled: _backedUp && !busy,
          decoration: InputDecoration(border: const OutlineInputBorder(), hintText: _word(app)),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          key: const Key('fresh_go'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          icon: busy && progress != null
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.delete_sweep_outlined),
          label: Text(progress ?? t('fresh_go')),
          onPressed: ready ? _run : null,
        ),
        const SizedBox(height: 10),
        Text(t('fresh_note'), style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
