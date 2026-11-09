import 'dart:io';

import 'package:dukaan_khata/accounting/models.dart';
import 'package:dukaan_khata/shared/party_import.dart';
import 'package:dukaan_khata/shared/statement_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the shop's sheet: empty Marathi names, numbers from Excel, bracket = advance", () {
    // exactly as it comes out of the Google Sheets .xlsx download
    final table = [
      ['name', 'page_no', 'phone', 'balance', 'name_en', 'type'],
      ['', '3.0', '', '812345.0', 'Sample Traders', 'customer'],
      ['', '5.0', '', '21000.0', 'Test Customer (Village)', 'customer'],
      ['', '12.0', '9000000001.0', '-65000.0', 'Demo Advance Customer', 'customer'],
      ['', '', '', '', '', ''],
    ];
    final s = PartyImport.parse(table);
    expect(s.rows.length, 3);
    expect(s.skipped, isEmpty);
    final hina = s.rows[0];
    expect(hina.name, 'Sample Traders');
    expect(hina.pageNo, '3');
    expect(hina.balance, 81234500);
    expect(hina.group, LedgerGroup.customer);
    final gopal = s.rows[2];
    expect(gopal.phone, '9000000001');
    expect(gopal.balance, -6500000); // advance: we owe him
  });

  test('balances as text: brackets, minus, Cr / जमा, Indian commas', () {
    expect(PartyImport.parseBalance('(65,000.00)'), -6500000);
    expect(PartyImport.parseBalance('-65000'), -6500000);
    expect(PartyImport.parseBalance('65000 Cr'), -6500000);
    expect(PartyImport.parseBalance('६५००० जमा'), -6500000);
    expect(PartyImport.parseBalance('8,12,345.00'), 81234500);
    expect(PartyImport.parseBalance('1200 Dr'), 120000);
    expect(PartyImport.parseBalance(''), 0);
  });

  test('columns in any order, Marathi + English names, supplier sign', () {
    final s = PartyImport.parse([
      ['Type', 'Name_EN', 'Name', 'Balance', 'Page No'],
      ['supplier', 'Laxmi Agency', 'लक्ष्मी एजन्सी', '150000', ''],
      ['customer', 'Suresh Jadhav', 'सुरेश जाधव', '31250', '29'],
      ['customer', '', '', '100', '30'],
    ]);
    expect(s.rows.length, 2);
    expect(s.skipped, ['4']);
    expect(s.rows[0].name, 'लक्ष्मी एजन्सी');
    expect(s.rows[0].nameEn, 'Laxmi Agency');
    expect(s.rows[0].group, LedgerGroup.supplier);
    expect(s.rows[0].balance, -15000000); // we owe the supplier
    expect(s.rows[1].pageNo, '29');
  });

  test('real .xlsx shaped like the shop sheet imports all 7 rows', () {
    final bytes = File('test/fixtures/import_sample.xlsx').readAsBytesSync();
    final s = PartyImport.parse(StatementParser.rowsFromBytes(bytes, 'import sample.xlsx'));
    expect(s.rows.length, 7);
    expect(s.rows.first.name, 'Sample Traders');
    expect(s.rows.first.balance, 81234500);
    expect(s.rows.last.phone, '9000000001');
    expect(s.rows.last.balance, -6500000);
  });
}
