import 'package:material_ui/material_ui.dart';

import '../data/app_data.dart';
import '../models.dart';
import '../screens/categories_screen.dart';
import 'category_style.dart';
import 'format.dart';

/// What was picked: a category id, or null for "no category". The sheet returns null when closed.
typedef CategoryPick = ({String? id});

/// "Smoking › Cigarettes", or just the name for a category with no group.
String categoryPath(AppData data, Category c) {
  final parent = c.parentId == null ? null : data.categories.where((p) => p.id == c.parentId).firstOrNull;
  return parent == null ? c.name : '${parent.name} › ${c.name}';
}

/// One clean place to choose a category: search, groups with their details, and creating a detail
/// ("Cigarettes") inside a group ("Smoking") without leaving the payment.
Future<CategoryPick?> pickCategory(
  BuildContext context,
  AppData data, {
  String? selected,
  bool allowFriends = false,
  bool allowNone = true,
  String title = 'Category',
}) => showModalBottomSheet<CategoryPick>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => ListenableBuilder(
    listenable: data,
    builder: (_, _) =>
        _CategorySheet(data: data, selected: selected, allowFriends: allowFriends, allowNone: allowNone, title: title),
  ),
);

class _CategorySheet extends StatefulWidget {
  const _CategorySheet({
    required this.data,
    required this.selected,
    required this.allowFriends,
    required this.allowNone,
    required this.title,
  });

  final AppData data;
  final String? selected;
  final bool allowFriends;
  final bool allowNone;
  final String title;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  final _search = TextEditingController();
  var _busy = false;

  AppData get data => widget.data;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _done(String? id) {
    if (_busy) return;
    _busy = true; // one tap is one choice: a quick second tap does nothing
    Navigator.pop(context, (id: id));
  }

  /// Makes a detail inside [group] (or a new group when null) and picks it.
  Future<void> _create(String name, {Category? group}) async {
    if (_busy || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final id = await data.saveCategory(
        name: name.trim(),
        icon: group?.icon ?? 'label',
        color: group?.color ?? categoryColors.first,
        parentId: group?.id,
      );
      if (mounted) Navigator.pop(context, (id: id));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add “$name”: $e')));
    }
  }

  /// Asks which group a new detail goes in.
  Future<void> _createAsk(String name) async {
    final groups = _groups();
    final picked = await showDialog<({Category? group})>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('Where does “${name.trim()}” go?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, (group: null)),
            child: const ListTile(
              leading: Icon(Icons.create_new_folder_outlined),
              title: Text('Its own group'),
              subtitle: Text('A main category'),
            ),
          ),
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, (group: g)),
              child: ListTile(
                leading: Icon(iconFor(g), color: colorFor(g)),
                title: Text('Inside ${g.name}'),
              ),
            ),
        ],
      ),
    );
    if (picked != null) await _create(name, group: picked.group);
  }

  Future<void> _addDetail(Category group) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('New detail in ${group.name}'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Cigarettes, Chai, Petrol'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Add')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) await _create(name, group: group);
  }

  List<Category> _groups() {
    final ids = {for (final c in data.categories) c.id};
    return data.categories.where((c) => !c.isLoan && (c.parentId == null || !ids.contains(c.parentId))).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    final friends = data.loanCategory;
    final groups = _groups();
    List<Category> detailsOf(Category g) =>
        data.categories.where((c) => c.parentId == g.id).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    Widget selectedMark(String? id) =>
        id == widget.selected ? Icon(Icons.check_circle, color: scheme.primary) : const SizedBox(width: 24);

    final matches = q.isEmpty
        ? const <Category>[]
        : (data.categories.where((c) => !c.isLoan && categoryPath(data, c).toLowerCase().contains(q)).toList()
            ..sort((a, b) => a.name.toLowerCase().indexOf(q).compareTo(b.name.toLowerCase().indexOf(q))));
    final exact = data.categories.any((c) => c.name.toLowerCase() == q);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(child: Text(widget.title, style: text.titleLarge)),
                if (widget.allowNone && widget.selected != null)
                  TextButton(onPressed: () => _done(null), child: const Text('No category')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search or add (e.g. Cigarettes)',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(_search.clear)),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (matches.isNotEmpty) {
                  _done(matches.first.id);
                } else if (q.isNotEmpty) {
                  _createAsk(_search.text);
                }
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (q.isNotEmpty) ...[
                  for (final c in matches)
                    ListTile(
                      leading: Icon(iconFor(c), color: colorFor(c)),
                      title: Text(categoryPath(data, c)),
                      trailing: selectedMark(c.id),
                      onTap: () => _done(c.id),
                    ),
                  if (!exact)
                    ListTile(
                      leading: Icon(Icons.add_circle_outline, color: scheme.primary),
                      title: Text('Add “${_search.text.trim()}”'),
                      subtitle: const Text('Choose its group next'),
                      onTap: () => _createAsk(_search.text),
                    ),
                ] else ...[
                  if (widget.allowFriends && friends != null)
                    ListTile(
                      leading: const Icon(Icons.handshake_outlined),
                      title: const Text('Friends ledger'),
                      subtitle: const Text('Lent / borrowed / settle up: not spending'),
                      trailing: selectedMark(friends.id),
                      onTap: () => _done(friends.id),
                    ),
                  for (final g in groups) ...[
                    ListTile(
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: colorFor(g).withValues(alpha: 0.15),
                        child: Icon(iconFor(g), size: 20, color: colorFor(g)),
                      ),
                      title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          selectedMark(g.id),
                          IconButton(
                            tooltip: 'Add a detail in ${g.name}',
                            icon: const Icon(Icons.add, size: 20),
                            onPressed: () => _addDetail(g),
                          ),
                        ],
                      ),
                      onTap: () => _done(g.id),
                    ),
                    if (detailsOf(g).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(68, 0, 16, 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final d in detailsOf(g))
                              GestureDetector(
                                onLongPress: () => moveCategory(context, data, d),
                                child: ChoiceChip(
                                  label: Text(d.name),
                                  selected: d.id == widget.selected,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (_) => _done(d.id),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                  ListTile(
                    leading: Icon(Icons.create_new_folder_outlined, color: scheme.primary),
                    title: const Text('New group'),
                    onTap: () async {
                      final id = await openCategoryForm(context, data);
                      if (id != null && context.mounted) _done(id);
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row that shows the chosen category and opens [pickCategory].
class CategoryField extends StatelessWidget {
  const CategoryField({super.key, required this.data, required this.categoryId, required this.onTap, this.hint});

  final AppData data;
  final String? categoryId;
  final VoidCallback onTap;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final cat = data.categories.where((c) => c.id == categoryId).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: colorFor(cat).withValues(alpha: 0.15),
                child: Icon(cat == null ? Icons.category_outlined : iconFor(cat), size: 20, color: colorFor(cat)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat == null ? 'Choose a category' : (cat.isLoan ? 'Friends ledger' : categoryPath(data, cat)),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Moves a category into another group, or out to be a main category of its own.
Future<void> moveCategory(BuildContext context, AppData data, Category cat) async {
  final hasDetails = data.categories.any((c) => c.parentId == cat.id);
  final groups = data.categories.where((c) => c.parentId == null && !c.isLoan && c.id != cat.id).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  if (hasDetails) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('“${cat.name}” is a group'),
        content: const Text(
          'It has details inside it. Move those details out first, then it can go into another group.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
    return;
  }
  final picked = await showDialog<({String? parent})>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text('Move “${cat.name}” to'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, (parent: null)),
          child: ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Its own group'),
            subtitle: const Text('A main category'),
            trailing: cat.parentId == null ? const Icon(Icons.check) : null,
          ),
        ),
        for (final g in groups)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, (parent: g.id)),
            child: ListTile(
              leading: Icon(iconFor(g), color: colorFor(g)),
              title: Text(g.name),
              trailing: cat.parentId == g.id ? const Icon(Icons.check) : null,
            ),
          ),
      ],
    ),
  );
  if (picked == null || picked.parent == cat.parentId) return;
  await data.saveCategory(
    id: cat.id,
    name: cat.name,
    icon: cat.icon,
    color: cat.color,
    isLoan: cat.isLoan,
    parentId: picked.parent,
  );
}

/// One payment across several of your categories: "₹300 Groceries + ₹200 Cigarettes".
/// The parts never add up to more than your share of the payment; the rest stays in its category.
class CategoryPartsSection extends StatelessWidget {
  const CategoryPartsSection({super.key, required this.data, required this.payment});

  final AppData data;
  final Txn payment;

  Future<void> _add(BuildContext context, double left) async {
    final pick = await pickCategory(context, data, allowNone: false, title: 'Which category is part of it?');
    if (pick?.id == null || !context.mounted) return;
    final ctl = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('How much was ${data.category(pick!.id)?.name ?? 'it'}?'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(prefixText: '₹ ', helperText: 'Up to ${money(left)}'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctl.text.replaceAll(',', ''));
              if (v != null && v > 0 && v <= left + 0.001) Navigator.pop(c, v);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (amount == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await data.addPart(payment.id, pick!.id, amount);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final parts = data.partsOf(payment.id);
    final mine = data.shareTotalsNow.own(payment);
    final used = parts.fold(0.0, (v, p) => v + p.amount);
    final left = (mine - used) < 0 ? 0.0 : mine - used;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final main = data.category(payment.categoryId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Split into categories', style: text.titleSmall)),
            if (left > 0.004)
              TextButton.icon(
                onPressed: () => _add(context, left),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add a part'),
              ),
          ],
        ),
        if (parts.isEmpty)
          Text(
            'Bought different things in one payment? E.g. ₹300 Groceries + ₹200 Cigarettes.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          )
        else ...[
          for (final p in parts)
            Row(
              children: [
                CategoryAvatar(data.category(p.categoryId), size: 28),
                const SizedBox(width: 10),
                Expanded(child: Text(data.category(p.categoryId)?.name ?? 'No category')),
                Text(money(p.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                IconButton(
                  tooltip: 'Remove this part',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => data.removePart(p.id),
                ),
              ],
            ),
          Row(
            children: [
              CategoryAvatar(main, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text('Rest: ${main?.name ?? 'No category'} (the category above)')),
              Text(money(left), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 48),
            ],
          ),
        ],
      ],
    );
  }
}
