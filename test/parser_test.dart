import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/core/money.dart';
import 'package:dukaan_khata/shared/shortcode_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final items = [
    Item(id: 'm', name: 'M सिमेंट', nameEn: 'M Cement', shortCode: 'M', saleRate: 28500),
    Item(id: 'u', name: 'अल्ट्राटेक', nameEn: 'Ultratech', shortCode: 'U', saleRate: 30000),
    Item(id: 's8', name: 'सळई 8mm', nameEn: 'TMT 8mm', shortCode: '8', unit: 'kg', saleRate: 6200),
    Item(id: 'b9', name: 'ब्लॉक 9"', nameEn: 'Block 9"', shortCode: 'B9', saleRate: 5500),
  ];
  final p = ShortcodeParser(items);

  test('qty/rate with default item', () {
    final r = p.parse('15/275', defaultItem: items[1])!;
    expect(r.item!.id, 'u');
    expect(r.qty, 15);
    expect(r.ratePaise, 27500);
    expect(r.amount, 412500);
  });

  test('register shorthand M.12×285 and variants', () {
    for (final s in ['M.12×285', 'M.12x285', 'm 12*285', 'M-12/285', 'M 12 x 285']) {
      final r = p.parse(s)!;
      expect(r.item?.id, 'm', reason: s);
      expect(r.qty, 12, reason: s);
      expect(r.ratePaise, 28500, reason: s);
    }
  });

  test('steel in kg with decimals', () {
    final r = p.parse('8mm 120.5kg/62')!;
    expect(r.item!.id, 's8');
    expect(r.qty, 120.5);
    expect(r.ratePaise, 6200);
    expect(r.amount, 747100);
  });

  test('default rate when only qty given; name prefix lookup', () {
    final r = p.parse('ultra 10')!;
    expect(r.item!.id, 'u');
    expect(r.ratePaise, 30000);
    expect(p.parse('B9 100/52')!.item!.id, 'b9');
  });

  test('Devanagari digits and multiple lines', () {
    final all = p.parseAll('M १०×२८५, U 5/300\n8 50/62');
    expect(all.length, 3);
    expect(all[0].qty, 10);
    expect(all[0].ratePaise, 28500);
    expect(all[2].item!.id, 's8');
  });

  test('garbage returns null', () {
    expect(p.parse('hello world'), isNull);
  });

  test('money formatting in Indian style', () {
    expect(Money.fmt(123456700), '12,34,567');
    expect(Money.fmt(12345), '123.45');
    expect(Money.parse('1,500'), 150000);
    expect(Money.parse('१५००'), 150000);
    expect(shortDate('2026-11-05'), '5/11/26');
    expect(fyStart('2026-02-10'), '2025-04-01');
  });

  test('qty = total works out the rate and keeps the total exact', () {
    final r = p.parse('M 7=2000')!;
    expect(r.item!.id, 'm');
    expect(r.qty, 7);
    expect(r.ratePaise, 28571);
    expect(r.amount, 200000);
    final line = ItemLine.fromTotal('m', 7, 200000);
    expect(line.amount, 200000);
    expect(line.rate, 28571);
  });

  test('typed dates, Tally style', () {
    expect(parseTypedDate('14/9/26'), '2026-09-14');
    expect(parseTypedDate('14-9-2026'), '2026-09-14');
    expect(parseTypedDate('14.09.26'), '2026-09-14');
    expect(parseTypedDate('14 9 26'), '2026-09-14');
    expect(parseTypedDate('140926'), '2026-09-14');
    expect(parseTypedDate('14092026'), '2026-09-14');
    expect(parseTypedDate('१४/९/२६'), '2026-09-14');
    // no year: latest such date not after the limit
    expect(parseTypedDate('14/9', latest: '2026-11-07'), '2026-09-14');
    expect(parseTypedDate('1412', latest: '2026-11-07'), '2025-12-14');
    expect(parseTypedDate('31/2/26'), isNull);
    expect(parseTypedDate('32/1/26'), isNull);
    expect(parseTypedDate('hello'), isNull);
    expect(parseTypedDate('123'), isNull);
  });
}
