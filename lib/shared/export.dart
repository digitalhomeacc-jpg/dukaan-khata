import 'package:excel/excel.dart' as xl;
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../state/app_controller.dart';

/// Turns any [ReportTable] into a PDF or Excel file and shares it
/// (WhatsApp, email, Drive… via the system share sheet).
class Exporter {
  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<void> _fonts() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansDevanagari-Bold.ttf'));
  }

  static Future<Uint8List> pdf(ReportTable t, {String shop = ''}) async {
    await _fonts();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _regular, bold: _bold));
    final flex = {for (var i = 0; i < t.columns.length; i++) i: pw.FlexColumnWidth(t.columns[i].flex.toDouble())};
    pw.Alignment al(int i) => t.columns[i].align == ColAlign.right ? pw.Alignment.centerRight : pw.Alignment.centerLeft;
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (shop.isNotEmpty) pw.Text(shop, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text(t.title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        if (t.subtitle.isNotEmpty) pw.Text(t.subtitle, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 6),
      ]),
      footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${c.pageNumber}/${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      ),
      build: (_) => [
        pw.Table(
          columnWidths: flex,
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (var i = 0; i < t.columns.length; i++)
                  pw.Container(
                    alignment: al(i),
                    padding: const pw.EdgeInsets.all(3),
                    child: pw.Text(t.columns[i].title, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  ),
              ],
            ),
            for (var r = 0; r < t.rows.length; r++)
              pw.TableRow(
                decoration: t.highlight.contains(r) ? const pw.BoxDecoration(color: PdfColors.amber50) : null,
                children: [
                  for (var i = 0; i < t.columns.length; i++)
                    pw.Container(
                      alignment: al(i),
                      padding: const pw.EdgeInsets.all(3),
                      child: pw.Text(i < t.rows[r].length ? t.rows[r][i] : '', style: const pw.TextStyle(fontSize: 9)),
                    ),
                ],
              ),
            if (t.totals != null)
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  for (var i = 0; i < t.columns.length; i++)
                    pw.Container(
                      alignment: al(i),
                      padding: const pw.EdgeInsets.all(3),
                      child: pw.Text(t.totals![i], style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ),
                ],
              ),
          ],
        ),
      ],
    ));
    return doc.save();
  }

  static Uint8List excel(List<ReportTable> tables) {
    final book = xl.Excel.createExcel();
    final defaultSheet = book.getDefaultSheet();
    for (final t in tables) {
      final name = t.title.replaceAll(RegExp(r'[\\/*?:\[\]]'), ' ');
      final sheetName = name.length > 30 ? name.substring(0, 30) : name;
      final s = book[sheetName];
      s.appendRow([xl.TextCellValue(t.title)]);
      if (t.subtitle.isNotEmpty) s.appendRow([xl.TextCellValue(t.subtitle)]);
      s.appendRow([for (final c in t.columns) xl.TextCellValue(c.title)]);
      for (final r in t.rows) {
        s.appendRow([
          for (var i = 0; i < r.length; i++)
            if (t.columns[i].align == ColAlign.right && double.tryParse(r[i].replaceAll(',', '')) != null)
              xl.DoubleCellValue(double.parse(r[i].replaceAll(',', '')))
            else
              xl.TextCellValue(r[i])
        ]);
      }
      if (t.totals != null) s.appendRow([for (final c in t.totals!) xl.TextCellValue(c)]);
    }
    if (defaultSheet != null && tables.isNotEmpty) book.delete(defaultSheet);
    return Uint8List.fromList(book.encode()!);
  }

  static String _fileName(String title, String ext) =>
      '${title.replaceAll(RegExp(r'[^\wऀ-ॿ]+'), '_')}_${DateTime.now().millisecondsSinceEpoch}.$ext';

  static Future<void> sharePdf(ReportTable t, {String shop = '', String? text}) async {
    final bytes = await pdf(t, shop: shop);
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/pdf', name: _fileName(t.title, 'pdf'))],
      fileNameOverrides: [_fileName(t.title, 'pdf')],
      text: text,
    ));
  }

  static Future<void> shareBill(AppController app, Voucher v, List<ItemLine> lines, List<Item> items, Ledger? party,
      List<Ledger> transporters) async {
    final bytes = await BillPdf.build(app, v, lines, items, party, transporters);
    final name = _fileName('${party?.name ?? 'bill'}_${v.vno}', 'pdf');
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/pdf', name: name)],
      fileNameOverrides: [name],
    ));
  }

  static Future<void> printPdf(ReportTable t, {String shop = ''}) =>
      Printing.layoutPdf(onLayout: (_) => pdf(t, shop: shop), name: t.title);

  static Future<void> shareExcel(List<ReportTable> tables, String title) async {
    final bytes = excel(tables);
    final name = _fileName(title, 'xlsx');
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', name: name)],
      fileNameOverrides: [name],
    ));
  }

  static Future<void> shareImage(Uint8List png, String title, {String? text}) async {
    final name = _fileName(title, 'png');
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(png, mimeType: 'image/png', name: name)],
      fileNameOverrides: [name],
      text: text,
    ));
  }
}

/// Sale / purchase bill as a PDF (tax invoice when it carries GST).
extension BillPdf on Exporter {
  static Future<Uint8List> build(AppController app, Voucher v, List<ItemLine> lines, List<Item> items, Ledger? party,
      List<Ledger> transporters) async {
    await Exporter._fonts();
    final t = app.t;
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: Exporter._regular, bold: Exporter._bold));
    final isGst = v.gst > 0;
    String itemName(String id) => items.where((i) => i.id == id).map((i) => i.display(app.english)).firstOrNull ?? '?';
    String unit(String id) => items.where((i) => i.id == id).map((i) => t('unit_${i.unit}')).firstOrNull ?? '';
    final goods = lines.fold<int>(0, (s, l) => s + l.amount);
    final transporter = transporters.where((x) => x.id == v.transporterId).map((x) => x.name).firstOrNull;
    pw.Widget cell(String s, {bool bold = false, pw.Alignment align = pw.Alignment.centerLeft}) => pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(s, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
        );
    const r = pw.Alignment.centerRight;
    pw.Widget sumRow(String l, int amt, {bool bold = false}) => pw.Row(children: [
          pw.Expanded(child: pw.Text(l, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null))),
          pw.Text(Money.fmt(amt), style: pw.TextStyle(fontSize: bold ? 12 : 10, fontWeight: bold ? pw.FontWeight.bold : null)),
        ]);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(20),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Text(app.businessName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
        if (app.shopAddress.isNotEmpty) pw.Text(app.shopAddress, style: const pw.TextStyle(fontSize: 9), textAlign: pw.TextAlign.center),
        pw.Text([if (app.shopPhone.isNotEmpty) app.shopPhone, if (isGst && app.shopGstin.isNotEmpty) 'GSTIN ${app.shopGstin}'].join(' · '),
            style: const pw.TextStyle(fontSize: 9), textAlign: pw.TextAlign.center),
        pw.SizedBox(height: 6),
        pw.Text(isGst ? 'TAX INVOICE' : (v.type == VoucherType.purchase ? t('purchase') : t('sale')),
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
        pw.Divider(),
        pw.Row(children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(party?.name ?? t('cash_sale'), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              if (party?.address != null) pw.Text(party!.address!, style: const pw.TextStyle(fontSize: 9)),
              if (party?.phone != null) pw.Text(party!.phone!, style: const pw.TextStyle(fontSize: 9)),
              if (isGst && party?.gstin != null) pw.Text('GSTIN ${party!.gstin}', style: const pw.TextStyle(fontSize: 9)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('No. ${v.vno}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text(shortDate(v.date), style: const pw.TextStyle(fontSize: 10)),
          ]),
        ]),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
          columnWidths: const {0: pw.FlexColumnWidth(4), 1: pw.FlexColumnWidth(2), 2: pw.FlexColumnWidth(2), 3: pw.FlexColumnWidth(2)},
          children: [
            pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
              cell(t('item'), bold: true),
              cell(t('qty'), bold: true, align: r),
              cell(t('rate'), bold: true, align: r),
              cell(t('amount'), bold: true, align: r),
            ]),
            for (final l in lines)
              pw.TableRow(children: [
                cell(itemName(l.itemId)),
                cell('${fmtQty(l.qty)} ${unit(l.itemId)}', align: r),
                cell(Money.fmt(l.rate), align: r),
                cell(Money.fmt(l.amount), align: r),
              ]),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Container(
          alignment: pw.Alignment.centerRight,
          child: pw.SizedBox(
            width: 200,
            child: pw.Column(children: [
              if (lines.isNotEmpty) sumRow(t('goods_total'), goods),
              if (isGst) ...[
                sumRow('CGST ${v.gstRate / 200}%', v.gst ~/ 2),
                sumRow('SGST ${v.gstRate / 200}%', v.gst - v.gst ~/ 2),
              ],
              if (v.hamali != 0) sumRow(t('hamali'), v.hamali),
              if (v.transport != 0) sumRow('${t('transport')} (${transporter ?? t('own_vehicle')})', v.transport),
              if (lines.isNotEmpty && v.amount - goods - v.hamali - v.transport - v.gst != 0)
                sumRow(t('round_off'), v.amount - goods - v.hamali - v.transport - v.gst),
              pw.Divider(),
              sumRow(t('bill_total'), v.amount, bold: true),
              if (v.paid != 0) sumRow(t('paid'), v.paid),
              if (v.amount - v.paid != 0) sumRow(t('due'), v.amount - v.paid, bold: true),
            ]),
          ),
        ),
        pw.Spacer(),
        if (v.haste != null) pw.Text('${t('haste')}: ${v.haste}', style: const pw.TextStyle(fontSize: 9)),
        pw.Text(v.narration ?? '', style: const pw.TextStyle(fontSize: 9)),
      ]),
    ));
    return doc.save();
  }
}

/// WhatsApp helpers – free, no API: opens WhatsApp with a ready message.
class WhatsApp {
  static String _normalise(String phone) {
    var p = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (p.length == 10) p = '91$p';
    if (p.startsWith('0')) p = '91${p.substring(1)}';
    return p;
  }

  static Future<bool> send(String? phone, String message) async {
    final uri = phone == null || phone.isEmpty
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}')
        : Uri.parse('https://wa.me/${_normalise(phone)}?text=${Uri.encodeComponent(message)}');
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool> call(String phone) => launchUrl(Uri.parse('tel:$phone'));
}
