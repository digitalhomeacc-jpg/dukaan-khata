import '../accounting/bookings.dart';
import '../accounting/ledger_repo.dart';
import '../accounting/recurring.dart';
import '../accounting/models.dart';
import '../accounting/voucher_service.dart';
import '../inventory/stock_repo.dart';
import 'money.dart';

/// Sample data copied from the paper registers – for trying the app.
/// Enabled with --dart-define=DEMO=true (owner PIN 1234, staff PIN 5678).
const demoMode = bool.fromEnvironment('DEMO');

Future<void> loadDemoData(VoucherService vs, LedgerRepo lr, StockRepo sr) async {
  const owner = Actor(userId: 'owner', name: 'Demo', isOwner: true);
  int rs(num r) => Money.fromRupees(r);
  final items = {for (final i in await sr.list()) i.shortCode!: i};
  final stockOpen = {'W': 147, 'M': 240, 'U': 222, 'S': 120, 'A': 28, '6': 128.8, '8': 2880.1, '10': 1642.3, '12': 2997.3, '16': 812.0};
  for (final e in stockOpen.entries) {
    final i = items[e.key]!;
    await sr.save(
      id: i.id, name: i.name, nameEn: i.nameEn, category: i.category, unit: i.unit, shortCode: i.shortCode,
      saleRate: i.saleRate, purchaseRate: (i.saleRate * 0.92).round(), openingQty: e.value.toDouble(),
      openingRate: (i.saleRate * 0.92).round(), lowStock: i.category == 'cement' ? 50 : 200,
    );
  }
  await vs.db.execute('UPDATE ledgers SET opening_balance = ? WHERE id = ?', [rs(250000), vs.sys('bank')]);
  await vs.db.execute('UPDATE ledgers SET opening_balance = ? WHERE id = ?', [rs(18000), vs.sys('cash')]);
  final today = todayIso();
  final d = parseIso(today);
  String ago(int n) => isoDate(d.subtract(Duration(days: n)));

  final suresh = await lr.create(name: 'सुरेश जाधव', nameEn: 'Suresh Jadhav', group: LedgerGroup.customer, pageNo: '29', phone: '9800000029', openingBalance: rs(31250), creditLimit: rs(60000));
  final ajay = await lr.create(name: 'अजय शिंदे', nameEn: 'Ajay Shinde', group: LedgerGroup.customer, pageNo: '25', openingBalance: rs(12500));
  await lr.create(name: 'विजय कदम', nameEn: 'Vijay Kadam', group: LedgerGroup.customer, pageNo: '37', openingBalance: rs(8400));
  final mukesh = await lr.create(name: 'संजय माने', nameEn: 'Sanjay Mane', group: LedgerGroup.customer, pageNo: '69', phone: '9800000069');
  await lr.create(name: 'प्रकाश गायकवाड', nameEn: 'Prakash Gaikwad', group: LedgerGroup.customer, pageNo: '135', openingBalance: rs(4200));
  await lr.create(name: 'रमेश काका', nameEn: 'Ramesh Kaka', group: LedgerGroup.customer, pageNo: '81');
  final deepak = await lr.create(name: 'दीपक साळुंखे', nameEn: 'Deepak Salunkhe', group: LedgerGroup.customer, pageNo: '15', openingBalance: rs(15000));
  await lr.setInterestRate(deepak, 150); // व्याज 1.5 % दरमहा – has not paid for months
  await vs.db.execute("UPDATE businesses SET name_en = 'Sai Building Material' WHERE id = ?", [vs.businessId]);
  final agency = await lr.create(name: 'लक्ष्मी सिमेंट एजन्सी', nameEn: 'Laxmi Cement Agency', group: LedgerGroup.supplier, openingBalance: -rs(150000));

  // Old khata entries from before the books start (no effect on cash or stock)
  await vs.save(VoucherInput(type: VoucherType.history, date: ago(90), partyId: suresh, amount: rs(12000), narration: 'M 42×285'), owner);
  await vs.save(VoucherInput(type: VoucherType.history, date: ago(80), partyId: suresh, paid: rs(12000), narration: 'जमा रोख'), owner);
  final m = items['M']!;
  Future<void> sale(String date, double q, int rate, {String? party, String item = 'M', String? pay, int? paid}) => vs.save(
      VoucherInput(type: VoucherType.sale, date: date, partyId: party ?? suresh, payLedgerId: pay == null ? null : vs.sys(pay),
          items: [ItemLine(items[item]!.id, q, rs(rate))], paid: paid ?? 0),
      owner);
  // Suresh Jadhav's page
  await sale(ago(55), 5, 273);
  await sale(ago(50), 10, 278);
  await sale(ago(48), 2, 278);
  await sale(ago(46), 2, 278);
  await sale(ago(45), 8, 278);
  await sale(ago(37), 10, 278);
  await sale(ago(35), 12, 275);
  await sale(ago(34), 7, 283);
  await vs.save(VoucherInput(type: VoucherType.receipt, date: ago(33), partyId: suresh, payLedgerId: vs.sys('cash'), amount: rs(30000)), owner);
  await sale(ago(30), 10, 283);
  await sale(ago(28), 7, 283);
  await sale(ago(27), 4, 283);
  await sale(ago(20), 4, 283);
  await sale(ago(15), 15, 283);
  await sale(ago(3), 3, 283);

  // Purchase from agency by RTGS (GST bill needed)
  await vs.save(
      VoucherInput(type: VoucherType.purchase, date: ago(2), partyId: agency, payLedgerId: vs.sys('bank'),
          items: [ItemLine(items['U']!.id, 200, rs(262)), ItemLine(items['A']!.id, 100, rs(268))], paid: rs(50000), gstBillNeeded: true, refNo: '6207'),
      owner);

  // बुकिंग: Sanjay booked 200 bags U at ₹275 with ₹20,000 advance; we booked 500 U from the agency
  final bookings = BookingService(vs.db, vs.businessId);
  await bookings.save(vs, owner, date: ago(5), partyId: mukesh, customer: true,
      items: [ItemLine(items['U']!.id, 200, rs(275))], advance: rs(20000), advanceLedgerId: vs.sys('cash'), note: 'स्लॅब काम');
  await bookings.save(vs, owner, date: ago(4), partyId: agency, customer: false,
      items: [ItemLine(items['U']!.id, 500, rs(262))], advance: rs(40000), advanceLedgerId: vs.sys('bank'));

  // दरमहा आकार: the restaurant next door pays rent + water every month
  final hotel = await lr.create(name: 'हॉटेल सह्याद्री', nameEn: 'Hotel Sahyadri', group: LedgerGroup.customer, pageNo: '90');
  final rent = await sr.save(name: 'दुकान भाडे', nameEn: 'Shop rent', category: serviceCategory, unit: 'job', saleRate: rs(8000));
  final water = await sr.save(name: 'पाणी बिल', nameEn: 'Water charges', category: serviceCategory, unit: 'job');
  await RecurringService(vs.db, vs.businessId)
      .save(vs, owner, partyId: hotel, startMonth: today.substring(0, 7), lines: [ItemLine(rent, 1, rs(8000)), ItemLine(water, 1, 0)]);

  // दरमहा देणे: loan interest paid every month
  await lr.create(name: 'कर्ज – रमेश पाटील', nameEn: 'Loan - Ramesh Patil', group: LedgerGroup.loan, openingBalance: -rs(500000));
  final interestPaid = await lr.create(name: 'व्याज खर्च', nameEn: 'Interest paid', group: LedgerGroup.expense);
  await RecurringService(vs.db, vs.businessId).savePayment(vs, owner,
      ledgerId: interestPaid, payFromId: vs.sys('cash'), startMonth: today.substring(0, 7), amount: rs(5000), note: 'रमेश पाटील – कर्ज व्याज');

  // कर्मचारी: Raju, ₹12,000 a month, took ₹5,000 advance
  final raju = await lr.create(name: 'राजू पवार', nameEn: 'Raju Pawar', group: LedgerGroup.staff, phone: '9800000044');
  await lr.setStaffPay(raju, salary: rs(12000), cut: rs(2000));
  await vs.save(VoucherInput(type: VoucherType.payment, date: ago(6), partyId: raju, payLedgerId: vs.sys('cash'), amount: rs(5000), narration: 'उचल'), owner);

  // Today – like the 5/11 stock register page
  await sale(today, 15, 275, party: mukesh, item: 'U', pay: 'cash', paid: rs(4125));
  await sale(today, 10, 275, item: 'U', party: mukesh);
  await vs.save(VoucherInput(type: VoucherType.sale, date: today, items: [ItemLine(items['8']!.id, 120, rs(62)), ItemLine(m.id, 4, rs(285))]), owner);
  await sale(today, 50, 285, party: suresh, item: 'W', pay: 'upi_h', paid: rs(5000));
  await vs.save(VoucherInput(type: VoucherType.sale, date: today, payLedgerId: vs.sys('upi_h'), items: [ItemLine(items['U']!.id, 10, rs(280))]), owner);
  await vs.save(VoucherInput(type: VoucherType.receipt, date: today, partyId: suresh, payLedgerId: vs.sys('upi_h'), amount: rs(849)), owner);
  final ganesh = await lr.create(name: 'गणेश ट्रान्सपोर्ट', nameEn: 'Ganesh Transport', group: LedgerGroup.transporter, phone: '9800000011');
  await lr.create(name: 'सागर टेम्पो', nameEn: 'Sagar Tempo', group: LedgerGroup.transporter);
  // 30 bags + 136 kg 8mm with hamali, own vehicle
  await vs.save(
      VoucherInput(type: VoucherType.sale, date: today, partyId: mukesh,
          items: [ItemLine(items['M']!.id, 30, rs(285)), ItemLine(items['8']!.id, 136, rs(62))],
          hamali: rs(300), transport: rs(500)),
      owner);
  // outside transporter: charged 800, Ganesh's fare 700
  await vs.save(
      VoucherInput(type: VoucherType.sale, date: today, partyId: suresh, items: [ItemLine(items['U']!.id, 20, rs(280))],
          hamali: rs(200), transport: rs(800), transporterId: ganesh, transporterFare: rs(700)),
      owner);
  await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: vs.sys('hamali'), payLedgerId: vs.sys('cash'), amount: rs(400), narration: 'अनलोडिंग'), owner);
  // उसना माल: 30 bags lent to Ajay, to come back as bags
  await vs.save(VoucherInput(type: VoucherType.goodsOut, date: today, partyId: ajay, items: [ItemLine(items['W']!.id, 30, 0)], haste: 'मुलगा'), owner);
  // वराई handed over by the company's truck driver
  await vs.save(VoucherInput(type: VoucherType.receipt, date: today, partyId: vs.sys('varhai'), payLedgerId: vs.sys('cash'), amount: rs(300), narration: 'लक्ष्मी सिमेंट गाडी'), owner);
  await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: vs.sys('tea'), payLedgerId: vs.sys('cash'), amount: rs(80)), owner);
  await vs.save(VoucherInput(type: VoucherType.payment, date: today, partyId: vs.sys('freight'), payLedgerId: vs.sys('cash'), amount: rs(2400), narration: 'ट्रॅक्टर भाडे'), owner);
  await vs.save(VoucherInput(type: VoucherType.contra, date: today, partyId: vs.sys('bank'), payLedgerId: vs.sys('cash'), amount: rs(5000), narration: 'बँकेत भरले'), owner);
}
