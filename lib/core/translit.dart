/// Marathi (Devanagari) → English letters, for PDFs: the PDF engine cannot
/// join Devanagari letters, so printouts are kept in English.
/// "सुरेश जाधव" → "Suresh Jadhav", "साई बिल्डिंग" → "Sai Bilding".
library;

const _cons = {
  'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'n', //
  'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'n', //
  'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n', //
  'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n', //
  'प': 'p', 'फ': 'ph', 'ब': 'b', 'भ': 'bh', 'म': 'm', //
  'य': 'y', 'र': 'r', 'ल': 'l', 'ळ': 'l', 'व': 'v', //
  'श': 'sh', 'ष': 'sh', 'स': 's', 'ह': 'h', 'ऱ': 'r', //
};

const _vowels = {
  'अ': 'a', 'आ': 'a', 'इ': 'i', 'ई': 'i', 'उ': 'u', 'ऊ': 'u', 'ऋ': 'ru', //
  'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au', 'ॲ': 'a', 'ऑ': 'o', 'ऍ': 'e',
};

const _matras = {
  'ा': 'a', 'ि': 'i', 'ी': 'i', 'ु': 'u', 'ू': 'u', 'ृ': 'ru', //
  'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au', 'ॅ': 'a', 'ॉ': 'o',
};

const _virama = '्';
const _nukta = '़';

final _deva = RegExp(r'[ऀ-ॿ]');

bool hasDevanagari(String s) => _deva.hasMatch(s);

/// Transliterates every Devanagari word in [s]; Latin text, digits and
/// symbols are kept as they are.
String toLatin(String s) {
  if (!hasDevanagari(s)) return s;
  final out = StringBuffer();
  final chars = s.replaceAll('‌', '').replaceAll('‍', '').split('');
  var wordStart = true;
  for (var i = 0; i < chars.length; i++) {
    final c = chars[i];
    String? piece;
    final code = c.codeUnitAt(0);
    if (code >= 0x0966 && code <= 0x096F) {
      piece = String.fromCharCode(0x30 + code - 0x0966); // ० → 0
    } else if (c == 'ज' && i + 2 < chars.length && chars[i + 1] == _virama && chars[i + 2] == 'ञ') {
      // ज्ञ is "dny" in Marathi (ज्ञानेश्वर → Dnyaneshwar)
      piece = 'dny';
      i += 2;
      piece += _vowelAfter(chars, i, (n) => i = n);
    } else if (_cons.containsKey(c)) {
      piece = _cons[c]! + _vowelAfter(chars, i, (n) => i = n);
    } else if (_vowels.containsKey(c)) {
      piece = _vowels[c];
    } else if (c == 'ं' || c == 'ँ') {
      final next = i + 1 < chars.length ? chars[i + 1] : '';
      piece = const {'प', 'फ', 'ब', 'भ', 'म'}.contains(next) ? 'm' : 'n';
    } else if (c == 'ः') {
      piece = 'h';
    } else if (c == _virama || c == _nukta || c == 'ऽ') {
      piece = '';
    } else if (c == '।' || c == '॥') {
      piece = '.';
    }
    if (piece == null) {
      out.write(c);
      wordStart = !RegExp(r'[A-Za-z0-9]').hasMatch(c);
      continue;
    }
    if (piece.isEmpty) continue;
    out.write(wordStart ? piece[0].toUpperCase() + piece.substring(1) : piece);
    wordStart = false;
  }
  return out.toString();
}

/// The vowel sound after the consonant at [i]: its matra, nothing after a
/// virama, or the inherent "a" – dropped at the end of a word (जाधव → Jadhav).
String _vowelAfter(List<String> chars, int i, void Function(int) moveTo) {
  var j = i + 1;
  if (j < chars.length && chars[j] == _nukta) j++;
  if (j < chars.length && _matras.containsKey(chars[j])) {
    moveTo(j);
    return _matras[chars[j]]!;
  }
  if (j < chars.length && chars[j] == _virama) {
    moveTo(j);
    return '';
  }
  moveTo(j - 1);
  final next = j < chars.length ? chars[j] : '';
  final endOfWord = next.isEmpty || !hasDevanagari(next) || next == '।';
  // a one-letter word keeps its "a" (व → Va)
  final prev = i > 0 ? chars[i - 1] : '';
  final alone = prev.isEmpty || !hasDevanagari(prev);
  if (endOfWord && !alone) return '';
  return 'a';
}
