import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';
import '../ui/category_style.dart';

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key, required this.data});

  final AppData data;

  Future<void> _edit(BuildContext context, [Category? c]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategoryForm(data: data, existing: c),
    );
  }

  Future<void> _delete(BuildContext context, Category c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete “${c.name}”?'),
        content: const Text('Its transactions stay, with no category.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) await data.deleteCategory(c.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Categories')),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(context), child: const Icon(Icons.add)),
        body: ListView(
          children: [
            for (final (:cat, :inGroup) in groupedCategories(data.categories))
              ListTile(
                contentPadding: EdgeInsets.only(left: inGroup ? 40 : 16, right: 8),
                leading: CategoryAvatar(cat, size: inGroup ? 32 : 40),
                title: Text(cat.name),
                subtitle: cat.isLoan
                    ? const Text('Friends ledger: lent, borrowed, settle-ups')
                    : cat.isInvestment
                    ? const Text('Not counted as spending or income')
                    : null,
                onTap: () => _edit(context, cat),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, cat)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens the category form (new when [existing] is null); returns the saved category's id.
Future<String?> openCategoryForm(BuildContext context, AppData data, {Category? existing, String? name}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CategoryForm(data: data, existing: existing, initialName: name),
    );

class _CategoryForm extends StatefulWidget {
  const _CategoryForm({required this.data, this.existing, this.initialName});

  final AppData data;
  final Category? existing;
  final String? initialName;

  @override
  State<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<_CategoryForm> {
  late final _name = TextEditingController(text: widget.existing?.name ?? widget.initialName ?? '');
  late String _icon = widget.existing?.icon ?? 'label';
  late int _color = widget.existing?.color ?? categoryColors.first;
  late bool _isLoan = widget.existing?.isLoan ?? false;
  late String? _parentId = widget.existing?.parentId;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter a name');
    try {
      final id = await widget.data.saveCategory(
        id: widget.existing?.id,
        name: name,
        icon: _icon,
        color: _color,
        isLoan: _isLoan,
        parentId: _parentId,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      setState(() => _error = e.toString().contains('duplicate') ? 'You already have “$name”' : 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Scrolls on small screens; Save stays at the top so it is always reachable.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.existing == null ? 'New category' : 'Edit category',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Name', errorText: _error),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in categoryColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Color(c),
                    child: _color == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final e in categoryIcons.entries)
                IconButton(
                  isSelected: _icon == e.key,
                  style: IconButton.styleFrom(
                    backgroundColor: _icon == e.key ? Color(_color).withValues(alpha: 0.2) : null,
                  ),
                  icon: Icon(e.value, color: _icon == e.key ? Color(_color) : null),
                  onPressed: () => setState(() => _icon = e.key),
                ),
            ],
          ),
          Builder(
            builder: (context) {
              final groups = widget.data.categories
                  .where((c) => c.parentId == null && !c.isLoan && !c.isInvestment && c.id != widget.existing?.id)
                  .toList();
              final isGroupItself =
                  widget.existing != null && widget.data.categories.any((c) => c.parentId == widget.existing!.id);
              if (isGroupItself) {
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'This is a group: ${widget.data.categories.where((c) => c.parentId == widget.existing!.id).map((c) => c.name).join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text('Part of a group? (optional)', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('No group'),
                        selected: _parentId == null,
                        onSelected: (_) => setState(() => _parentId = null),
                      ),
                      for (final g in groups)
                        ChoiceChip(
                          label: Text(g.name),
                          selected: _parentId == g.id,
                          onSelected: (_) => setState(() => _parentId = g.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'e.g. Cigarettes and Alcohol in “Smoking & alcohol”, Chai and Nashta in “Chai & nashta”.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isLoan,
            onChanged: (v) => setState(() => _isLoan = v),
            title: const Text('Loans with friends'),
            subtitle: const Text('Shown in the Loans tab, not counted as spending or income'),
          ),
        ],
      ),
    );
  }
}
