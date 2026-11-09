import '../accounting/models.dart';
import '../core/money.dart';

/// Result of parsing one quick-entry line such as "M 12×285" or "15/275".
class ParsedLine {
  final String? itemCode; // as typed ("M", "8mm", "ultra")
  final Item? item; // resolved item, if found
  final double qty;
  final int? ratePaise; // null → use item's default rate
  final int? total; // exact line total when typed as "qty=amount"
  ParsedLine(this.itemCode, this.item, this.qty, this.ratePaise, {this.total});
  int? get amount => total ?? (ratePaise == null ? null : (qty * ratePaise!).round());
  @override
  String toString() => 'ParsedLine($itemCode→${item?.shortCode}, $qty × $ratePaise)';
}

/// Parses the shorthand used in the paper registers:
///
///   "15/275"           qty 15 at ₹275 (item = default)
///   "U 15/275"         item U (Ultratech)
///   "M.12×285" / "M.12x285" / "m 12*285"
///   "8mm 120kg/62"     item 8 (8mm steel), 120 kg at ₹62
///   "W 10"             10 bags at item W's default rate
///   "M 7=2000"         7 bags for ₹2,000 in total (rate worked out)
///   "१५/२७५"           Devanagari digits work too
///   Several lines separated by "," ";" "+" or new lines.
class ShortcodeParser {
  final List<Item> items;
  ShortcodeParser(this.items);

  static final _sep = RegExp(r'[,;+\n]');
  // [code] qty [unit] [ (/ x × *) rate ]
  static final _line = RegExp(
    r'^\s*(?:([A-Za-zऀ-ॿ][A-Za-z0-9ऀ-ॿ"]*?|\d{1,2}\s*mm|\d{1,2}(?=\s+\d))\s*[.\-:\s]\s*)?'
    r'(\d+(?:\.\d+)?)\s*(?:kg|किलो|bag|बॅग|nos|नग|ft|brass|ब्रास|ton|टन)?\s*'
    r'(?:([/x×*@=])\s*(\d+(?:\.\d+)?))?\s*$',
    caseSensitive: false,
  );

  List<ParsedLine> parseAll(String input, {Item? defaultItem}) => [
        for (final part in normalizeDigits(input).split(_sep))
          if (part.trim().isNotEmpty) parse(part, defaultItem: defaultItem),
      ].whereType<ParsedLine>().toList();

  ParsedLine? parse(String raw, {Item? defaultItem}) {
    final s = normalizeDigits(raw).trim();
    final m = _line.firstMatch(s);
    if (m == null) return null;
    final code = m.group(1)?.trim();
    final qty = double.parse(m.group(2)!);
    final op = m.group(3);
    final value = m.group(4) == null ? null : Money.fromRupees(double.parse(m.group(4)!));
    final item = code == null ? defaultItem : findItem(code);
    if (op == '=' && value != null) {
      // "M 7=2000": 7 bags for ₹2,000 in total – the rate is worked out
      return ParsedLine(code, item, qty, qty == 0 ? 0 : (value / qty).round(), total: value);
    }
    return ParsedLine(code, item, qty, value ?? item?.saleRate);
  }

  /// Finds an item by short code ("M", "8", "8mm", "B9") or name prefix ("ultra").
  Item? findItem(String code) {
    final c = code.toUpperCase().replaceAll(' ', '');
    final bare = c.replaceAll('MM', '');
    for (final i in items) {
      final sc = i.shortCode?.toUpperCase();
      if (sc != null && (sc == c || sc == bare)) return i;
    }
    final lc = code.toLowerCase();
    for (final i in items) {
      if (i.name.toLowerCase().startsWith(lc) || (i.nameEn?.toLowerCase().startsWith(lc) ?? false)) return i;
    }
    for (final i in items) {
      if (i.name.toLowerCase().contains(lc) || (i.nameEn?.toLowerCase().contains(lc) ?? false)) return i;
    }
    return null;
  }
}
