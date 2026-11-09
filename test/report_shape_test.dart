import 'package:dukaan_khata/accounting/reports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t = ReportTable(
    title: 'Receivable',
    columns: const [ReportColumn('Page', flex: 1), ReportColumn('Name'), ReportColumn('Last'), ReportColumn.num('Balance')],
    rows: [
      ['135', 'प्रकाश गायकवाड', '1/10/26', '4,200'],
      ['25', 'अजय शिंदे', '—', '12,500'],
      ['69', 'संजय माने', '9/11/26', '532'],
      ['', 'No page', '15/9/26', '1,04,594'],
    ],
    rowRefs: ['a', 'b', 'c', 'd'],
    highlight: {1},
    totals: ['', 'Total', '', '1,21,826'],
  );

  test('page numbers sort by value, empty last', () {
    final s = shapeReport(t, sortCol: 0);
    expect(s.rows.map((r) => r[0]), ['25', '69', '135', '']);
    expect(s.rowRefs, ['b', 'c', 'a', 'd']);
    expect(s.highlight, {0}); // Ajay's highlight follows the row
    final d = shapeReport(t, sortCol: 0, ascending: false);
    expect(d.rows.map((r) => r[0]), ['135', '69', '25', '']);
  });

  test('amounts with Indian commas and dates sort by value', () {
    expect(shapeReport(t, sortCol: 3, ascending: false).rows.first[1], 'No page');
    expect(shapeReport(t, sortCol: 3).rows.first[1], 'संजय माने');
    expect(shapeReport(t, sortCol: 2).rows.map((r) => r[2]), ['15/9/26', '1/10/26', '9/11/26', '—']);
  });

  test('filter by name, page, Marathi digits; totals re-added', () {
    final f = shapeReport(t, query: 'संजय');
    expect(f.rows.single[0], '69');
    expect(f.totals![3], '532');
    expect(f.subtitle, contains('1 / 4'));
    expect(shapeReport(t, query: '१३५').rows.single[1], 'प्रकाश गायकवाड');
    expect(shapeReport(t, query: 'ajay').rows, isEmpty);
    expect(shapeReport(t).totals![3], '1,21,826'); // unfiltered: original total
  });
}
