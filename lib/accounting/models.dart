/// Ledger groups – the Tally "groups", kept fixed so the app stays simple.
enum LedgerGroup {
  customer('customer', Nature.asset),
  supplier('supplier', Nature.liability),
  transporter('transporter', Nature.liability), // outside tempo/truck owners, paid at day end
  cash('cash', Nature.asset),
  upi('upi', Nature.asset), // PhonePe / GPay accounts
  bank('bank', Nature.asset), // RTGS / NEFT / cheque
  sales('sales', Nature.income),
  salesReturn('sales_return', Nature.income), // contra-income (debit balance)
  purchase('purchase', Nature.expense),
  purchaseReturn('purchase_return', Nature.expense), // contra-expense
  directExpense('direct_expense', Nature.expense), // भाडे, हमाली on purchases
  expense('expense', Nature.expense), // light bill, salary, chaha-pani…
  income('income', Nature.income), // other income, discount received
  gst('gst', Nature.liability), // single GST ledger – no GST maths
  capital('capital', Nature.liability), // owner capital / drawings
  loan('loan', Nature.liability),
  otherAsset('other_asset', Nature.asset), // deposits, advances, fixed assets
  otherLiability('other_liability', Nature.liability);

  final String code;
  final Nature nature;
  const LedgerGroup(this.code, this.nature);

  static LedgerGroup fromCode(String? c) =>
      LedgerGroup.values.firstWhere((g) => g.code == c, orElse: () => LedgerGroup.otherAsset);

  bool get isMoney => this == cash || this == upi || this == bank;
  bool get isParty => this == customer || this == supplier;
}

enum Nature { asset, liability, income, expense }

/// Built-in ledgers the posting rules write to. They can be renamed but never
/// deleted or moved to another group, or the accounts would stop adding up.
const coreLedgerKeys = {
  'cash', 'sales', 'sales_return', 'purchase', 'purchase_return', 'gst', 'capital', 'history_adj',
  'hamali_income', 'transport_income', 'freight', 'hamali', 'discount_given', 'discount_recd', 'stock_adj',
  'round_off', 'varhai',
};

const _moneyGroups = [LedgerGroup.cash, LedgerGroup.upi, LedgerGroup.bank];
const _partyGroups = [LedgerGroup.customer, LedgerGroup.supplier, LedgerGroup.transporter];

enum VoucherType {
  sale('sale'),
  receipt('receipt'), // जमा
  purchase('purchase'),
  payment('payment'), // to supplier / expense
  salesReturn('sales_return'),
  purchaseReturn('purchase_return'),
  contra('contra'), // cash ↔ bank / PhonePe
  journal('journal'),
  stockAdjust('stock_adjust'),
  history('history'), // old khata entry before the books start: reference only, posts nothing
  promise('promise'), // customer's promised payment date (वायदा): reminder only, posts nothing
  opening('opening'); // reserved – opening balances live on the ledger/item rows

  final String code;
  const VoucherType(this.code);
  static VoucherType fromCode(String c) => VoucherType.values.firstWhere((v) => v.code == c);

  /// Stock direction for item lines on this voucher type.
  int get stockDirection => switch (this) {
        sale || purchaseReturn => -1,
        purchase || salesReturn => 1,
        _ => 0,
      };
}

class Ledger {
  final String id;
  final String name;
  final String? nameEn;
  final LedgerGroup group;
  final String? phone;
  final String? address;
  final String? pageNo;
  final String? shortCode;
  final String? gstin;
  final int openingBalance;
  final int creditLimit;
  final bool system;
  final bool archived;
  final int balance; // computed: opening + Σ(debit − credit)
  /// Customer who also sells to us (or supplier who also buys) – one khata, one net balance.
  final bool dual;

  Ledger({
    required this.id,
    required this.name,
    this.nameEn,
    required this.group,
    this.phone,
    this.address,
    this.pageNo,
    this.shortCode,
    this.gstin,
    this.openingBalance = 0,
    this.creditLimit = 0,
    this.system = false,
    this.archived = false,
    this.balance = 0,
    this.dual = false,
  });

  factory Ledger.fromRow(Map<String, Object?> r) => Ledger(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        nameEn: r['name_en'] as String?,
        group: LedgerGroup.fromCode(r['grp'] as String?),
        phone: r['phone'] as String?,
        address: r['address'] as String?,
        pageNo: r['page_no'] as String?,
        shortCode: r['short_code'] as String?,
        gstin: r['gstin'] as String?,
        openingBalance: (r['opening_balance'] as int?) ?? 0,
        creditLimit: (r['credit_limit'] as int?) ?? 0,
        system: (r['system'] as int?) == 1,
        archived: (r['archived'] as int?) == 1,
        balance: (r['balance'] as num?)?.toInt() ?? 0,
        dual: (r['dual'] as int?) == 1,
      );

  String display(bool english) =>
      english && (nameEn?.isNotEmpty ?? false) ? nameEn! : name;

  /// Built-in key ("upi_d", "sales" …) for system ledgers, else null.
  String? get systemKey => system ? id.split(':').last : null;

  bool get isCore => systemKey != null && coreLedgerKeys.contains(systemKey);

  /// Groups this account may be moved to (PhonePe ⇄ bank, customer ⇄ supplier …).
  List<LedgerGroup> get allowedGroups {
    if (isCore) return [group];
    if (_moneyGroups.contains(group)) return _moneyGroups;
    if (_partyGroups.contains(group)) return _partyGroups;
    return LedgerGroup.values.where((g) => !_partyGroups.contains(g) && !_moneyGroups.contains(g)).toList();
  }
}

class Item {
  final String id;
  final String name;
  final String? nameEn;
  final String category;
  final String unit;
  final String? shortCode;
  final int saleRate;
  final int purchaseRate;
  final double openingQty;
  final int openingRate;
  final double lowStock;
  final int sortOrder;
  final bool archived;
  final double stock; // computed

  Item({
    required this.id,
    required this.name,
    this.nameEn,
    this.category = 'other',
    this.unit = 'nos',
    this.shortCode,
    this.saleRate = 0,
    this.purchaseRate = 0,
    this.openingQty = 0,
    this.openingRate = 0,
    this.lowStock = 0,
    this.sortOrder = 0,
    this.archived = false,
    this.stock = 0,
  });

  factory Item.fromRow(Map<String, Object?> r) => Item(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        nameEn: r['name_en'] as String?,
        category: (r['category'] as String?) ?? 'other',
        unit: (r['unit'] as String?) ?? 'nos',
        shortCode: r['short_code'] as String?,
        saleRate: (r['sale_rate'] as int?) ?? 0,
        purchaseRate: (r['purchase_rate'] as int?) ?? 0,
        openingQty: (r['opening_qty'] as num?)?.toDouble() ?? 0,
        openingRate: (r['opening_rate'] as int?) ?? 0,
        lowStock: (r['low_stock'] as num?)?.toDouble() ?? 0,
        sortOrder: (r['sort_order'] as int?) ?? 0,
        archived: (r['archived'] as int?) == 1,
        stock: (r['stock'] as num?)?.toDouble() ?? 0,
      );

  String display(bool english) =>
      english && (nameEn?.isNotEmpty ?? false) ? nameEn! : name;
}

/// One item row on a sale/purchase bill.
class ItemLine {
  final String itemId;
  final double qty;
  final int rate; // paise per unit
  final int? _amount; // exact total when typed (rate is then worked out)
  ItemLine(this.itemId, this.qty, this.rate, {int? amount}) : _amount = amount;

  /// "7 bags for ₹2,000": rate = ₹285.71, but the line stays exactly ₹2,000.
  factory ItemLine.fromTotal(String itemId, double qty, int amountPaise) =>
      ItemLine(itemId, qty, qty == 0 ? 0 : (amountPaise / qty).round(), amount: amountPaise);

  int get amount => _amount ?? (qty * rate).round();
}

/// One raw debit/credit line (journal / contra).
class MoneyLine {
  final String ledgerId;
  final int debit;
  final int credit;
  MoneyLine(this.ledgerId, {this.debit = 0, this.credit = 0});
}

class Voucher {
  final String id;
  final VoucherType type;
  final int vno;
  final String date;
  final String? partyId;
  final String? payLedgerId;
  final int amount;
  final int paid;
  final String? narration;
  final String? refNo;
  final bool gstBillNeeded;
  final String? createdBy;
  final bool deleted;
  final int version;
  // joined for display
  final String? partyName;
  final String? payCode;
  // bill charges (sale)
  final int hamali; // labour charged to customer
  final int transport; // transport charged to customer
  final String? transporterId; // null = own vehicle
  final int? transporterFare; // what we owe the outside transporter
  final int gstRate; // percent × 100, 0 = no GST bill
  final int gst; // GST amount (paise)
  final String? haste; // हस्ते – person who brought / took it
  final String? status; // promises: open | done | missed

  Voucher({
    required this.id,
    required this.type,
    required this.vno,
    required this.date,
    this.partyId,
    this.payLedgerId,
    this.amount = 0,
    this.paid = 0,
    this.narration,
    this.refNo,
    this.gstBillNeeded = false,
    this.createdBy,
    this.deleted = false,
    this.version = 1,
    this.partyName,
    this.payCode,
    this.hamali = 0,
    this.transport = 0,
    this.transporterId,
    this.transporterFare,
    this.gstRate = 0,
    this.gst = 0,
    this.haste,
    this.status,
  });

  factory Voucher.fromRow(Map<String, Object?> r) => Voucher(
        id: r['id'] as String,
        type: VoucherType.fromCode(r['vtype'] as String),
        vno: (r['vno'] as int?) ?? 0,
        date: r['vdate'] as String,
        partyId: r['party_id'] as String?,
        payLedgerId: r['pay_ledger_id'] as String?,
        amount: (r['amount'] as int?) ?? 0,
        paid: (r['paid'] as int?) ?? 0,
        narration: r['narration'] as String?,
        refNo: r['ref_no'] as String?,
        gstBillNeeded: (r['gst_bill_needed'] as int?) == 1,
        createdBy: r['created_by'] as String?,
        deleted: (r['deleted'] as int?) == 1,
        version: (r['version'] as int?) ?? 1,
        partyName: r['party_name'] as String?,
        payCode: r['pay_code'] as String?,
        hamali: (r['hamali'] as int?) ?? 0,
        transport: (r['transport'] as int?) ?? 0,
        transporterId: r['transporter_id'] as String?,
        transporterFare: r['transporter_fare'] as int?,
        gstRate: (r['gst_rate'] as int?) ?? 0,
        gst: (r['gst'] as int?) ?? 0,
        haste: r['haste'] as String?,
        status: r['status'] as String?,
      );

  int get due => amount - paid;
}
