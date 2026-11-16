import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';

/// A photo of the bill on a payment: add, see, replace or remove it.
class ReceiptSection extends StatefulWidget {
  const ReceiptSection({super.key, required this.data, required this.txn});

  final AppData data;
  final Txn txn;

  @override
  State<ReceiptSection> createState() => _ReceiptSectionState();
}

class _ReceiptSectionState extends State<ReceiptSection> {
  var _busy = false;
  String? _url;
  String? _urlFor;

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      final f = files.first;
      setState(() => _busy = true);
      await widget.data.attachReceipt(widget.txn, await f.readAsBytes(), f.name);
      messenger.showSnackBar(const SnackBar(content: Text('Receipt added')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add the receipt: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.data.txn(widget.txn.id) ?? widget.txn;
    final path = t.receiptPath;
    if (path != null && _urlFor != path) {
      _urlFor = path;
      _url = null;
      widget.data.receiptUrl(path).then((u) {
        if (mounted) setState(() => _url = u);
      }, onError: (_) {});
    }
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('Receipt', style: Theme.of(context).textTheme.titleSmall)),
                if (_busy)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  TextButton(onPressed: _add, child: Text(path == null ? 'Add photo' : 'Replace')),
                  if (path != null)
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => widget.data.removeReceipt(t),
                    ),
                ],
              ],
            ),
            if (path != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _url == null
                    ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                    : GestureDetector(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(child: InteractiveViewer(child: Image.network(_url!))),
                        ),
                        child: Image.network(_url!, height: 180, width: double.infinity, fit: BoxFit.cover),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
