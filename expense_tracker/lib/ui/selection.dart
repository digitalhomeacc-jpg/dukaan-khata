import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import 'category_picker.dart';

/// Payments picked for a change made to all of them at once (long-press one to start).
class TxnSelection extends ChangeNotifier {
  final ids = <String>{};

  bool get active => ids.isNotEmpty;

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void selectAll(Iterable<String> all) {
    ids.addAll(all);
    notifyListeners();
  }

  void clear() {
    ids.clear();
    notifyListeners();
  }

  static TxnSelection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SelectionScope>()?.notifier;
}

class _SelectionScope extends InheritedNotifier<TxnSelection> {
  const _SelectionScope({required TxnSelection super.notifier, required super.child});
}

/// Keeps a selection for the screen below it (across data refreshes) and swaps in a selection app bar.
class SelectionHost extends StatefulWidget {
  const SelectionHost({super.key, required this.data, required this.builder});

  final AppData data;

  /// Builds the screen; [bar] is the selection app bar while something is selected, else null.
  final Widget Function(BuildContext context, PreferredSizeWidget? Function(Iterable<String> all) bar) builder;

  @override
  State<SelectionHost> createState() => _SelectionHostState();
}

class _SelectionHostState extends State<SelectionHost> {
  final _sel = TxnSelection();

  @override
  void dispose() {
    _sel.dispose();
    super.dispose();
  }

  Future<void> _setCategory(BuildContext context) async {
    final data = widget.data;
    final ids = _sel.ids.toList();
    final pick = await pickCategory(context, data, allowFriends: true, title: 'Category for ${ids.length} payments');
    if (pick == null || !context.mounted) return;
    // Remember what each had, for Undo.
    final before = <String?, List<String>>{};
    for (final id in ids) {
      (before[data.txn(id)?.categoryId] ??= []).add(id);
    }
    _sel.clear();
    final messenger = ScaffoldMessenger.of(context);
    await data.categorizeTxns(ids, pick.id);
    final name = pick.id == null ? 'No category' : (data.category(pick.id)?.name ?? 'category');
    messenger.showSnackBar(
      SnackBar(
        content: Text('${ids.length} payment${ids.length == 1 ? '' : 's'} → $name'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            for (final e in before.entries) {
              await data.categorizeTxns(e.value, e.key);
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _SelectionScope(
    notifier: _sel,
    child: ListenableBuilder(
      listenable: _sel,
      builder: (context, _) => PopScope(
        canPop: !_sel.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _sel.clear();
        },
        child: widget.builder(
          context,
          (all) => !_sel.active
              ? null
              : AppBar(
                  leading: IconButton(tooltip: 'Done', icon: const Icon(Icons.close), onPressed: _sel.clear),
                  title: Text('${_sel.ids.length} selected'),
                  actions: [
                    IconButton(
                      tooltip: 'Select all',
                      icon: const Icon(Icons.select_all),
                      onPressed: () => _sel.selectAll(all),
                    ),
                    Builder(
                      builder: (context) => FilledButton.icon(
                        onPressed: () => _setCategory(context),
                        icon: const Icon(Icons.category_outlined, size: 18),
                        label: const Text('Category'),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
        ),
      ),
    ),
  );
}

/// A tick in front of a row while choosing several.
class SelectTick extends StatelessWidget {
  const SelectTick({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Icon(
      selected ? Icons.check_circle : Icons.radio_button_unchecked,
      color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
    ),
  );
}
