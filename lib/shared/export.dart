import 'package:excel/excel.dart' as xl;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../accounting/models.dart';
import '../accounting/reports.dart';
import '../core/money.dart';
import '../core/i18n.dart';
import '../core/translit.dart';
import '../state/app_controller.dart';
import 'user_agent.dart';

/// Turns any [ReportTable] into a PDF or Excel file and shares it
/// (WhatsApp, email, Drive… via the system share sheet).
class Exporter {
  static pw.Font? _regular;
  static pw.Font? _bold;

  /// Marathi name → English name (accounts, items), set before a PDF is made.
  static Map<String, String> englishNames = {};

  /// PDFs are English only: known names become their English names, any
  /// other Marathi word is spelt in English letters.
  static String latin(String s) {
    // signs the PDF font cannot draw
    s = s.replaceAll('✓', 'OK').replaceAll('✗', 'X').replaceAll('⚠', '!');
    if (!hasDevanagari(s)) return s;
    var out = s;
    if (englishNames.isNotEmpty) {
      final keys = englishNames.keys.where(out.contains).toList()..sort((a, b) => b.length.compareTo(a.length));
      for (final k in keys) {
        out = out.replaceAll(k, englishNames[k]!);
      }
    }
    return toLatin(out);
  }

  /// The app's navigator – lets a phone browser show the "ready" box below.
  static final navigatorKey = GlobalKey<NavigatorState>();

  /// A phone's browser (iPhone / Android) – told the same way the printing
  /// library tells it, so the two never disagree.
  static bool get _phoneBrowser {
    if (!kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) return true;
    final ua = browserUserAgent;
    return ua.contains('Mobile') || ua.contains('iPhone') || ua.contains('iPad') || ua.contains('Android');
  }

  /// Shares files. A phone browser only opens the share sheet straight after
  /// a tap, and making the file takes a moment – so there the file is made
  /// first and a small "ready" box asks for one more tap (its share sheet also
  /// has Print). Elsewhere it opens at once. No share sheet: downloads it.
  static Future<void> shareFiles(List<XFile> files, {String? text}) async {
    Future<void> go() async {
      try {
        await SharePlus.instance.share(ShareParams(files: files, fileNameOverrides: [for (final f in files) f.name], text: text));
      } catch (_) {
        for (final f in files) {
          await Printing.sharePdf(bytes: await f.readAsBytes(), filename: f.name);
        }
      }
    }

    final ctx = navigatorKey.currentContext;
    if (!_phoneBrowser || ctx == null || !ctx.mounted) return go();
    final t = App.read(ctx).t;
    await showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(t('file_ready')),
        content: Text(files.map((f) => f.name).join('\n'), style: Theme.of(c).textTheme.bodySmall),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(t('cancel'))),
          FilledButton.icon(
            key: const Key('file_share_now'),
            icon: const Icon(Icons.ios_share),
            label: Text(t('file_share_print')),
            onPressed: () {
              go(); // started inside this tap, so the browser allows it
              Navigator.pop(c);
            },
          ),
        ],
      ),
    );
  }

  /// Prints a PDF: the print window on a laptop; on a phone browser the
  /// share sheet (choose Print, or a printer app).
  static Future<void> _printPdf(Uint8List bytes, String name, {PdfPageFormat format = PdfPageFormat.a4}) async {
    if (_phoneBrowser) return shareFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: _fileName(name, 'pdf'))]);
    try {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: latin(name), format: format);
    } catch (_) {
      await shareFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: _fileName(name, 'pdf'))]);
    }
  }

  static Future<void> _fonts() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansDevanagari-Bold.ttf'));
  }

  static Future<Uint8List> pdf(ReportTable t, {String shop = '', bool roll = false}) => pdfMulti([t], shop: shop, roll: roll);

  /// The small billing printer's paper: 80 mm wide (about 72 mm printed), as long as needed.
  static const roll80 = PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 3 * PdfPageFormat.mm);

  /// Several tables one below the other (रोजमेळ: cash, PhonePe, bank, उधारी),
  /// each with its own title and totals.
  /// [roll]: for the 80 mm billing printer – small type, one long strip.
  static Future<Uint8List> pdfMulti(List<ReportTable> tables, {String shop = '', String? heading, bool roll = false}) async {
    await _fonts();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: _regular, bold: _bold));
    final single = tables.length == 1 && heading == null;
    final wide = tables.any((t) => t.columns.length > 8);
    final fs = roll ? 6.5 : 9.0, pad = roll ? 1.5 : 3.0;
    pw.Widget table(ReportTable t) {
      final flex = {for (var i = 0; i < t.columns.length; i++) i: pw.FlexColumnWidth(t.columns[i].flex.toDouble())};
      pw.Alignment al(int i) => t.columns[i].align == ColAlign.right ? pw.Alignment.centerRight : pw.Alignment.centerLeft;
      // multi-line cells ("15\n@275") keep every line under the same edge
      pw.TextAlign ta(int i) => t.columns[i].align == ColAlign.right ? pw.TextAlign.right : pw.TextAlign.left;
      return pw.Table(
        columnWidths: flex,
        // thermal paper: lines between rows only (no grey fills, which print as smudges)
        border: roll
            ? const pw.TableBorder(
                top: pw.BorderSide(width: 0.6),
                bottom: pw.BorderSide(width: 0.6),
                horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey600))
            : pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        children: [
          pw.TableRow(
            decoration: roll ? null : const pw.BoxDecoration(color: PdfColors.grey200),
            children: [
              for (var i = 0; i < t.columns.length; i++)
                pw.Container(
                  alignment: al(i),
                  padding: pw.EdgeInsets.all(pad),
                  child: pw.Text(latin(t.columns[i].title), textAlign: ta(i), style: pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold)),
                ),
            ],
          ),
          for (var r = 0; r < t.rows.length; r++)
            pw.TableRow(
              decoration: t.highlight.contains(r) && !roll ? const pw.BoxDecoration(color: PdfColors.amber50) : null,
              children: [
                for (var i = 0; i < t.columns.length; i++)
                  pw.Container(
                    alignment: al(i),
                    padding: pw.EdgeInsets.all(pad),
                    child: pw.Text(i < t.rows[r].length ? latin(t.rows[r][i]) : '', textAlign: ta(i),
                        style: pw.TextStyle(fontSize: fs, fontWeight: t.highlight.contains(r) && roll ? pw.FontWeight.bold : null)),
                  ),
              ],
            ),
          if (t.totals != null)
            pw.TableRow(
              decoration: roll ? null : const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (var i = 0; i < t.columns.length; i++)
                  pw.Container(
                    alignment: al(i),
                    padding: pw.EdgeInsets.all(pad),
                    child: pw.Text(latin(t.totals![i]), textAlign: ta(i), style: pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold)),
                  ),
              ],
            ),
        ],
      );
    }

    if (roll) {
      // one long strip, the way the billing printer feeds paper
      doc.addPage(pw.Page(
        pageFormat: roll80,
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          if (shop.isNotEmpty)
            pw.Text(latin(shop), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          if (single) ...[
            pw.Text(latin(tables.first.title), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            if (tables.first.subtitle.isNotEmpty)
              pw.Text(latin(tables.first.subtitle), textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 6.5)),
          ] else if (heading != null)
            pw.Text(latin(heading), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          for (final t in tables) ...[
            if (!single) ...[
              pw.SizedBox(height: 5),
              pw.Text(latin(t.title), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              if (t.subtitle.isNotEmpty) pw.Text(latin(t.subtitle), style: const pw.TextStyle(fontSize: 6.5)),
              pw.SizedBox(height: 2),
            ],
            table(t),
          ],
          pw.SizedBox(height: 10),
        ]),
      ));
      return doc.save();
    }
    doc.addPage(pw.MultiPage(
      // a long khata (hundreds of old entries) runs to many pages – the library stops at 20 by default
      maxPages: 2000,
      // wide tables (daily stock register: one column per item) print sideways
      pageFormat: wide ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (shop.isNotEmpty) pw.Text(latin(shop), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        if (single) ...[
          pw.Text(latin(tables.first.title), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          if (tables.first.subtitle.isNotEmpty) pw.Text(latin(tables.first.subtitle), style: const pw.TextStyle(fontSize: 9)),
        ] else if (heading != null)
          pw.Text(latin(heading), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
      ]),
      footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${c.pageNumber}/${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      ),
      build: (_) => [
        for (final t in tables) ...[
          if (!single) ...[
            pw.SizedBox(height: 8),
            pw.Text(latin(t.title), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            if (t.subtitle.isNotEmpty) pw.Text(latin(t.subtitle), style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 3),
          ],
          table(t),
        ],
      ],
    ));
    return doc.save();
  }

  static Future<void> sharePdfMulti(List<ReportTable> tables, {required String heading, String shop = ''}) async {
    final bytes = await pdfMulti(tables, shop: shop, heading: heading);
    await shareFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: _fileName(heading, 'pdf'))]);
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
    await shareFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: _fileName(t.title, 'pdf'))], text: text);
  }

  static Future<void> shareBill(AppController app, Voucher v, List<ItemLine> lines, List<Item> items, Ledger? party,
      List<Ledger> transporters) async {
    await app.loadPdfNames();
    final bytes = await BillPdf.build(app, v, lines, items, party, transporters);
    final name = _fileName('${party?.name ?? 'bill'}_${v.date}_${v.shownNo}', 'pdf');
    await shareFiles([XFile.fromData(bytes, mimeType: 'application/pdf', name: name)]);
  }

  static Future<void> printPdfMulti(List<ReportTable> tables, {required String heading, String shop = ''}) async {
    if (tables.length == 1) return printPdf(tables.single, shop: shop);
    final roll = await _askPaper();
    if (roll == null) return;
    await _printPdf(await pdfMulti(tables, shop: shop, heading: heading, roll: roll), heading, format: roll ? roll80 : PdfPageFormat.a4);
  }

  static Future<void> printPdf(ReportTable t, {String shop = ''}) async {
    final roll = await _askPaper();
    if (roll == null) return;
    await _printPdf(await pdf(t, shop: shop, roll: roll), t.title, format: roll ? roll80 : PdfPageFormat.a4);
  }

  /// Which printer: the small 80 mm billing printer (true) or A4 paper (false).
  /// The last choice comes first. null = cancelled.
  static Future<bool?> _askPaper() async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final app = App.read(ctx);
    final t = app.t;
    final last = app.prefStr('print_paper') == 'roll';
    final r = await showDialog<bool>(
      context: ctx,
      builder: (c) => SimpleDialog(
        title: Text(t('print_which')),
        children: [
          for (final roll in last ? const [true, false] : const [false, true])
            SimpleDialogOption(
              key: Key(roll ? 'paper_roll' : 'paper_a4'),
              onPressed: () => Navigator.pop(c, roll),
              child: ListTile(
                leading: Icon(roll ? Icons.receipt_long : Icons.description_outlined),
                title: Text(t(roll ? 'print_roll' : 'print_a4')),
                subtitle: Text(t(roll ? 'print_roll_sub' : 'print_a4_sub')),
              ),
            ),
        ],
      ),
    );
    if (r != null) await app.setPrefStr('print_paper', r ? 'roll' : 'a4');
    return r;
  }

  static Future<void> shareExcel(List<ReportTable> tables, String title) async {
    final bytes = excel(tables);
    final name = _fileName(title, 'xlsx');
    await shareFiles([XFile.fromData(bytes, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', name: name)]);
  }

  static Future<void> shareImage(Uint8List png, String title, {String? text}) async {
    final name = _fileName(title, 'png');
    await shareFiles([XFile.fromData(png, mimeType: 'image/png', name: name)], text: text);
  }
}

/// Sale / purchase bill as a PDF (tax invoice when it carries GST).
extension BillPdf on Exporter {
  static Future<Uint8List> build(AppController app, Voucher v, List<ItemLine> lines, List<Item> items, Ledger? party,
      List<Ledger> transporters) async {
    await Exporter._fonts();
    // bills are printed in English (see Exporter.latin)
    String t(String k) => const Strings(true).t(k);
    final l = Exporter.latin;
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: Exporter._regular, bold: Exporter._bold));
    final isGst = v.gst > 0;
    String itemName(String id) => items.where((i) => i.id == id).map((i) => l(i.display(true))).firstOrNull ?? '?';
    String unit(String id) => items.where((i) => i.id == id).map((i) => t('unit_${i.unit}')).firstOrNull ?? '';
    final goods = lines.fold<int>(0, (s, l) => s + l.amount);
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
        pw.Text(l(app.pdfShopName), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
        if (app.shopAddress.isNotEmpty) pw.Text(l(app.shopAddress), style: const pw.TextStyle(fontSize: 9), textAlign: pw.TextAlign.center),
        pw.Text([if (app.shopPhone.isNotEmpty) app.shopPhone, if (isGst && app.shopGstin.isNotEmpty) 'GSTIN ${app.shopGstin}'].join(' · '),
            style: const pw.TextStyle(fontSize: 9), textAlign: pw.TextAlign.center),
        pw.SizedBox(height: 6),
        pw.Text(isGst ? 'TAX INVOICE' : (v.type == VoucherType.purchase ? t('purchase') : t('sale')),
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
        pw.Divider(),
        pw.Row(children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(party == null ? t('cash_sale') : l(party.nameEn ?? party.name), style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              if (party?.address != null) pw.Text(l(party!.address!), style: const pw.TextStyle(fontSize: 9)),
              if (party?.phone != null) pw.Text(party!.phone!, style: const pw.TextStyle(fontSize: 9)),
              if (isGst && party?.gstin != null) pw.Text('GSTIN ${party!.gstin}', style: const pw.TextStyle(fontSize: 9)),
            ]),
          ),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('No. ${v.shownNo}', style: const pw.TextStyle(fontSize: 10)),
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
              // the bill goes to the customer: whose vehicle went is ours to know
              if (v.transport != 0) sumRow(t('transport'), v.transport),
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
        if (v.haste != null) pw.Text('${t('haste')}: ${l(v.haste!)}', style: const pw.TextStyle(fontSize: 9)),
        pw.Text(l(v.narration ?? ''), style: const pw.TextStyle(fontSize: 9)),
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

/// पावती for an 80 mm thermal printer (3-inch roll): sale, purchase, जमा,
/// payment and returns. Printed through the phone's / laptop's print dialog
/// (or shared to a printer app). English, like every printed bill.
extension ReceiptPdf on Exporter {
  static Future<Uint8List> build(AppController app, String voucherId) async {
    await app.loadPdfNames();
    final (v, lines) = await app.vouchers.load(voucherId);
    // every item, hidden ones too (an old bill may use one)
    final items = [for (final r in await app.db.getAll('SELECT * FROM items WHERE business_id = ?', [app.businessId])) Item.fromRow(r)];
    final party = v.partyId == null ? null : await app.ledgers.byId(v.partyId!);
    final pay = v.payLedgerId == null ? null : await app.ledgers.byId(v.payLedgerId!);
    final balance = party != null && party.group.isParty ? await app.ledgers.balanceAt(party.id) : null;
    return render(
        shop: app.pdfShopName, address: app.shopAddress, phone: app.shopPhone, gstin: app.shopGstin,
        v: v, lines: lines, items: items, party: party, pay: pay, balance: balance);
  }

  /// The receipt itself, from the entry's data (no database needed).
  static Future<Uint8List> render({
    required String shop,
    String address = '',
    String phone = '',
    String gstin = '',
    required Voucher v,
    required List<ItemLine> lines,
    required List<Item> items,
    Ledger? party,
    Ledger? pay,
    int? balance,
    int itemsPerSlip = 12,
  }) async {
    await Exporter._fonts();
    String t(String k) => const Strings(true).t(k);
    final l = Exporter.latin;
    String name(Ledger x) => l(x.nameEn ?? x.name);
    String itemName(String id) => items.where((i) => i.id == id).map((i) => l(i.display(true))).firstOrNull ?? '?';
    String unit(String id) => items.where((i) => i.id == id).map((i) => t('unit_${i.unit}')).firstOrNull ?? '';
    final bill = const {VoucherType.sale, VoucherType.purchase, VoucherType.salesReturn, VoucherType.purchaseReturn}.contains(v.type);
    final goods = lines.fold<int>(0, (s, x) => s + x.amount);
    final isGst = v.gst > 0;
    final time = DateTime.tryParse(v.createdAt ?? '')?.toLocal();
    final title = switch (v.type) {
      VoucherType.sale => isGst ? 'TAX INVOICE' : 'SALE RECEIPT',
      VoucherType.purchase => 'PURCHASE',
      VoucherType.salesReturn => 'SALES RETURN',
      VoucherType.purchaseReturn => 'PURCHASE RETURN',
      VoucherType.receipt => 'PAYMENT RECEIVED',
      VoucherType.payment => 'PAYMENT GIVEN',
      _ => l(t('vt_${v.type.code}')).toUpperCase(),
    };

    const small = pw.TextStyle(fontSize: 8);
    const normal = pw.TextStyle(fontSize: 9);
    final bold = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
    pw.Widget dash() => pw.Divider(height: 8, thickness: 0.6, borderStyle: pw.BorderStyle.dashed);
    pw.Widget two(String a, String b, {pw.TextStyle? style}) => pw.Row(children: [
          pw.Expanded(child: pw.Text(a, style: style ?? normal)),
          pw.Text(b, style: style ?? normal),
        ]);

    // a long bill goes on several slips (पावती 1/2, 2/2 …): each repeats the
    // header, number, date and customer; the totals come on the last one
    final parts = <List<ItemLine>>[];
    for (var i = 0; i < lines.length; i += itemsPerSlip) {
      parts.add(lines.sublist(i, i + itemsPerSlip > lines.length ? lines.length : i + itemsPerSlip));
    }
    if (parts.isEmpty) parts.add(const []);
    final n = parts.length;

    final doc = pw.Document(theme: pw.ThemeData.withFont(base: Exporter._regular, bold: Exporter._bold));
    for (var k = 0; k < n; k++) {
      final part = parts[k];
      final last = k == n - 1;
      final partTotal = part.fold<int>(0, (s, x) => s + x.amount);
      doc.addPage(pw.Page(
        // 80 mm roll: about 72 mm printable; each slip is as long as it needs
        pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
        build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Text(l(shop), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
          if (address.isNotEmpty) pw.Text(l(address), style: small, textAlign: pw.TextAlign.center),
          if (phone.isNotEmpty || (isGst && gstin.isNotEmpty))
            pw.Text([if (phone.isNotEmpty) 'Ph $phone', if (isGst && gstin.isNotEmpty) 'GSTIN $gstin'].join('  '),
                style: small, textAlign: pw.TextAlign.center),
          pw.SizedBox(height: 3),
          pw.Text(title, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
          dash(),
          two('No. ${v.shownNo}${n > 1 ? '   (${k + 1}/$n)' : ''}',
              '${shortDate(v.date)}${time == null ? '' : '  ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'}',
              style: n > 1 ? bold : null),
          pw.Text(party == null ? (v.type == VoucherType.purchase ? t('cash_purchase') : t('cash_sale')) : name(party), style: bold),
          if (party?.phone != null) pw.Text(party!.phone!, style: small),
          if (isGst && party?.gstin != null) pw.Text('GSTIN ${party!.gstin}', style: small),
          dash(),
          if (bill) ...[
            for (final x in part) ...[
              pw.Text(itemName(x.itemId), style: normal),
              two('  ${fmtQty(x.qty)} ${unit(x.itemId)} x ${Money.fmt(x.rate)}', Money.fmt(x.amount)),
            ],
            if (part.isNotEmpty) dash(),
            if (!last) ...[
              // not the end of the bill yet
              two('This slip (${part.length} items)', Money.fmt(partTotal), style: bold),
              pw.SizedBox(height: 2),
              pw.Text('Continued on slip ${k + 2}/$n ...', style: small, textAlign: pw.TextAlign.center),
            ] else ...[
              if (n > 1) two('${t('goods_total')} (${lines.length} items, $n slips)', Money.fmt(goods))
              else if (lines.isNotEmpty && (isGst || v.hamali != 0 || v.transport != 0)) two(t('goods_total'), Money.fmt(goods)),
              if (isGst) ...[
                two('CGST ${v.gstRate / 200}%', Money.fmt(v.gst ~/ 2)),
                two('SGST ${v.gstRate / 200}%', Money.fmt(v.gst - v.gst ~/ 2)),
              ],
              if (v.hamali != 0) two(t('hamali'), Money.fmt(v.hamali)),
              // the customer's copy never says whose vehicle went
              if (v.transport != 0) two(t('transport'), Money.fmt(v.transport)),
              if (lines.isNotEmpty && v.amount - goods - v.hamali - v.transport - v.gst != 0)
                two(t('round_off'), Money.fmt(v.amount - goods - v.hamali - v.transport - v.gst)),
              two('TOTAL', 'Rs ${Money.fmt(v.amount)}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              if (v.paid != 0) two('${t('paid')}${pay == null ? '' : ' (${name(pay)})'}', Money.fmt(v.paid)),
              if (v.amount - v.paid != 0) two(t('due'), Money.fmt(v.amount - v.paid), style: bold),
            ],
          ] else ...[
            two('AMOUNT', 'Rs ${Money.fmt(v.amount)}', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            if (pay != null) two(t('pay_mode'), name(pay)),
          ],
          if (last) ...[
            if (balance != null) ...[
              dash(),
              // where the account stands now, from this customer's / supplier's side
              two(balance >= 0 ? 'Total due from you' : 'Total due to you', 'Rs ${Money.fmt(balance, abs: true)}', style: bold),
            ],
            if (v.haste != null) pw.Text('${t('haste')}: ${l(v.haste!)}', style: small),
            if ((v.narration ?? '').isNotEmpty) pw.Text(l(v.narration!), style: small),
            dash(),
            pw.Text('Thank you!', style: normal, textAlign: pw.TextAlign.center),
          ],
          pw.SizedBox(height: 10),
        ]),
      ));
    }
    return doc.save();
  }

  /// 80 mm receipt: the print window on a laptop (choose the thermal
  /// printer); on a phone the share sheet (Print, or a printer app like RawBT).
  static Future<void> print(AppController app, String voucherId) async => Exporter._printPdf(
        await build(app, voucherId),
        'receipt',
        format: Exporter.roll80,
      );

  /// Sends the receipt to another app (e.g. a Bluetooth printer app).
  static Future<void> share(AppController app, String voucherId) async =>
      Exporter.shareFiles([XFile.fromData(await build(app, voucherId), mimeType: 'application/pdf', name: Exporter._fileName('receipt', 'pdf'))]);
}
