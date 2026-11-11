import '../accounting/models.dart';
import '../core/money.dart';
import '../core/translit.dart';

/// Free, offline item matching for the bill's item box: Marathi or English,
/// any spelling ("reti", "retee", "रेती"), short code, subcategory; words in
/// any order. Best matches first.
List<Item> matchItems(List<Item> items, String query) {
  final words = _tokens(query);
  if (words.isEmpty || words.every(_isNum)) return const [];
  final scored = <(int, Item)>[];
  for (final i in items) {
    final hay = _hay(i);
    final code = (i.shortCode ?? '').toLowerCase();
    var score = 0;
    for (final w in words) {
      final s = _score(hay, w, code);
      // a number not in the name is the quantity, not a miss
      if (s == 0 && !_isNum(w)) {
        score = 0;
        break;
      }
      score += s;
    }
    if (score > 0) scored.add((score, i));
  }
  scored.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : a.$2.sortOrder.compareTo(b.$2.sortOrder));
  return [for (final s in scored) s.$2];
}

List<String> _tokens(String q) => normalizeDigits(q)
    .toLowerCase()
    .replaceAll(RegExp(r'(?<=\d)\s*[×x*@]\s*(?=\d)'), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toList();
bool _isNum(String w) => RegExp(r'^\d+(\.\d+)?$').hasMatch(w);

/// The query's words that aren't plain numbers ("reti 3" → "reti") – for a new item's name.
String itemWords(String q) => _tokens(q).where((w) => !_isNum(w)).join(' ');

/// The quantity typed with the name: the first plain number that isn't part
/// of [item]'s name ("reti 3" → 3; "valve 90 4" for "Valve 90mm" → 4).
double? itemQty(String q, [Item? item]) {
  final hay = item == null ? '' : _hay(item);
  for (final w in _tokens(q)) {
    if (_isNum(w) && !hay.split(RegExp(r'[^0-9.]+')).contains(w)) return double.tryParse(w);
  }
  return null;
}

final _cache = <String, String>{};
String _hay(Item i) => _cache.putIfAbsent('${i.id}|${i.name}|${i.nameEn}|${i.subcategory}', () {
      final parts = [i.name, i.nameEn ?? '', toLatin(i.name), i.subcategory ?? '', toLatin(i.subcategory ?? '')];
      return parts.join(' ').toLowerCase();
    });

/// Spelling-insensitive form: no vowels, no doubled letters (retee → rt).
String _skel(String s) => s
    .replaceAll(RegExp(r'[aeiouyh\s"\x27.-]'), '')
    .replaceAll('w', 'v')
    .replaceAll('z', 'j')
    .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);

int _score(String hay, String w, String code) {
  if (code.isNotEmpty && code == w) return 100;
  final tokens = hay.split(RegExp(r'\s+'));
  if (tokens.any((t) => t == w)) return 60;
  if (tokens.any((t) => t.startsWith(w))) return 40;
  if (hay.contains(w)) return 25;
  if (RegExp(r'^\d').hasMatch(w)) return 0;
  final sw = _skel(w);
  if (sw.length >= 2 && tokens.any((t) => _skel(t).startsWith(sw))) return 15;
  return 0;
}
