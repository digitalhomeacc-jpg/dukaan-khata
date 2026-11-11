import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/shared/item_match.dart';
import 'package:flutter_test/flutter_test.dart';

Item it(String id, String name, {String? en, String? code, String? sub}) =>
    Item.fromRow({'id': id, 'name': name, 'name_en': en, 'short_code': code, 'subcategory': sub, 'category': 'other', 'unit': 'nos'});

void main() {
  final items = [
    it('1', 'रेती', en: 'Sand'),
    it('2', '3"Valve 90mm', sub: 'व्हॉल्व'),
    it('3', '2"pvc pipe 63mm', sub: 'पाईप'),
    it('4', 'सिमेंट', en: 'Cement', code: 'M'),
    it('5', 'चुना'),
  ];
  List<String> m(String q) => matchItems(items, q).map((i) => i.id).toList();

  test('finds items by any spelling, code, english, words in any order', () {
    expect(m('reti').first, '1');
    expect(m('retee').first, '1');
    expect(m('sand'), ['1']);
    expect(m('रेती'), ['1']);
    expect(m('M').first, '4');
    expect(m('pipe pvc'), ['3']);
    expect(m('valve'), ['2']);
    expect(m('chuna'), ['5']);
    expect(m('xyz'), isEmpty);
  });

  test('a number is the quantity unless it is part of the name', () {
    expect(m('reti 3'), ['1']);
    expect(itemQty('reti 3', items[0]), 3);
    expect(itemQty('valve 90 4', items[1]), 4);
    expect(itemQty('valve 90', items[1]), isNull);
    expect(m('90mm'), ['2']);
    expect(itemWords('new thing 5'), 'new thing');
  });
}
