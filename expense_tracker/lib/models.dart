double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

class Category {
  const Category({required this.id, required this.name, required this.icon, required this.color, this.isLoan = false});

  final String id;
  final String name;
  final String icon;
  final int color;

  /// Money borrowed from / lent to friends: kept out of spending and income.
  final bool isLoan;

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        id: m['id'] as String,
        name: m['name'] as String,
        icon: (m['icon'] as String?) ?? 'label',
        color: (m['color'] as num?)?.toInt() ?? 0xFF607D8B,
        isLoan: m['kind'] == 'loan',
      );
}

enum AccountKind { cash, bank, card, wallet }

class Account {
  const Account({
    required this.id,
    required this.name,
    this.kind = AccountKind.bank,
    this.bank,
    this.last4,
    this.openingBalance = 0,
    this.archived = false,
  });

  final String id;
  final String name;
  final AccountKind kind;
  final String? bank;
  final String? last4;

  /// Money in the account before the app's first transaction (negative = owed, for cards).
  final double openingBalance;
  final bool archived;

  factory Account.fromMap(Map<String, dynamic> m) => Account(
        id: m['id'] as String,
        name: m['name'] as String,
        kind: AccountKind.values.asNameMap()[m['kind']] ?? AccountKind.bank,
        bank: m['bank'] as String?,
        last4: m['last4'] as String?,
        openingBalance: _num(m['opening_balance']),
        archived: m['archived'] == true,
      );
}

class Txn {
  const Txn({
    required this.id,
    required this.amount,
    required this.isDebit,
    required this.txnAt,
    this.merchant,
    this.note,
    this.bank,
    this.accountLast4,
    this.method = 'other',
    this.categoryId,
    this.accountId,
    this.counterAccountId,
    this.source = 'manual',
    this.emailSubject,
    this.excluded = false,
    this.needsReview = false,
    this.loanId,
    this.loanRole,
    this.emailBody,
  });

  final String id;
  final double amount;
  final bool isDebit;
  final DateTime txnAt; // local time
  final String? merchant;
  final String? note;
  final String? bank;
  final String? accountLast4;
  final String method;
  final String? categoryId;

  /// Where the money left (spent) or arrived (received).
  final String? accountId;

  /// For a move between your own accounts: the other side (e.g. Cash for an ATM withdrawal).
  final String? counterAccountId;
  final String source;
  final String? emailSubject;
  final bool excluded;
  final bool needsReview;

  /// Linked lender loan: 'borrow' (money from it), 'repay' (paying it back) or 'spend' (bought with it).
  final String? loanId;
  final String? loanRole;
  final String? emailBody;

  /// Borrowed money and loan repayments are neither income nor spending.
  bool get isLoanTransfer => loanRole == 'borrow' || loanRole == 'repay';

  bool get fromEmail => source == 'email';

  String get title {
    final m = merchant?.trim();
    if (m != null && m.isNotEmpty) return m;
    final n = note?.trim();
    if (n != null && n.isNotEmpty) return n;
    return isDebit ? 'Payment' : 'Money received';
  }

  factory Txn.fromMap(Map<String, dynamic> m) => Txn(
        id: m['id'] as String,
        amount: _num(m['amount']),
        isDebit: m['direction'] == 'debit',
        txnAt: DateTime.parse(m['txn_at'] as String).toLocal(),
        merchant: m['merchant'] as String?,
        note: m['note'] as String?,
        bank: m['bank'] as String?,
        accountLast4: m['account_last4'] as String?,
        method: (m['method'] as String?) ?? 'other',
        categoryId: m['category_id'] as String?,
        accountId: m['account_id'] as String?,
        counterAccountId: m['counter_account_id'] as String?,
        source: (m['source'] as String?) ?? 'manual',
        emailSubject: m['email_subject'] as String?,
        excluded: m['excluded'] == true,
        needsReview: m['needs_review'] == true,
        loanId: m['loan_id'] as String?,
        loanRole: m['loan_role'] as String?,
        emailBody: m['email_body'] as String?,
      );

  /// Columns a user may write (id, user_id and source are set by the database).
  Map<String, dynamic> toWriteMap() => {
        'amount': amount,
        'direction': isDebit ? 'debit' : 'credit',
        'merchant': (merchant?.trim().isEmpty ?? true) ? null : merchant!.trim(),
        'note': (note?.trim().isEmpty ?? true) ? null : note!.trim(),
        'method': method,
        'txn_at': txnAt.toUtc().toIso8601String(),
        'category_id': categoryId,
        'account_id': accountId,
        'counter_account_id': excluded ? counterAccountId : null,
        'excluded': excluded,
        'needs_review': false,
      };
}

class UnreadEmail {
  const UnreadEmail({required this.id, required this.from, required this.subject, required this.body, this.receivedAt});

  final String id;
  final String from;
  final String subject;
  final String body;
  final DateTime? receivedAt;

  factory UnreadEmail.fromMap(Map<String, dynamic> m) => UnreadEmail(
        id: m['id'] as String,
        from: (m['from_addr'] as String?) ?? '',
        subject: (m['subject'] as String?) ?? '',
        body: (m['body'] as String?) ?? '',
        receivedAt: m['received_at'] == null ? null : DateTime.parse(m['received_at'] as String).toLocal(),
      );
}

enum LoanKind { emi, creditLine }

/// A loan from a lender (Slice borrow, KreditBee, Fibe…).
class Loan {
  const Loan({
    required this.id,
    required this.lender,
    required this.name,
    this.kind = LoanKind.emi,
    this.principal,
    this.emiAmount,
    this.tenureMonths,
    this.emisPaidBefore = 0,
    this.interestRate,
    this.dueDay,
    this.nextDueAmount,
    this.nextDueDate,
    this.outstanding,
    this.outstandingAt,
    this.aliases = const [],
    this.accountId,
    this.closed = false,
  });

  final String id;
  final String lender;
  final String name;
  final LoanKind kind;
  final double? principal;
  final double? emiAmount;
  final int? tenureMonths;
  final int emisPaidBefore;
  final double? interestRate;
  final int? dueDay;
  final double? nextDueAmount;
  final DateTime? nextDueDate;
  final double? outstanding;
  final DateTime? outstandingAt;
  final List<String> aliases;
  final String? accountId;
  final bool closed;

  factory Loan.fromMap(Map<String, dynamic> m) {
    double? n(Object? v) => v == null ? null : _num(v);
    return Loan(
      id: m['id'] as String,
      lender: m['lender'] as String,
      name: m['name'] as String,
      kind: m['kind'] == 'credit_line' ? LoanKind.creditLine : LoanKind.emi,
      principal: n(m['principal']),
      emiAmount: n(m['emi_amount']),
      tenureMonths: (m['tenure_months'] as num?)?.toInt(),
      emisPaidBefore: (m['emis_paid_before'] as num?)?.toInt() ?? 0,
      interestRate: n(m['interest_rate']),
      dueDay: (m['due_day'] as num?)?.toInt(),
      nextDueAmount: n(m['next_due_amount']),
      nextDueDate: m['next_due_date'] == null ? null : DateTime.parse(m['next_due_date'] as String),
      outstanding: n(m['outstanding']),
      outstandingAt: m['outstanding_at'] == null ? null : DateTime.parse(m['outstanding_at'] as String).toLocal(),
      aliases: ((m['aliases'] as List?) ?? const []).cast<String>(),
      accountId: m['account_id'] as String?,
      closed: m['closed'] == true,
    );
  }
}

enum LoanEventKind { borrow, spend, repay }

class LoanEvent {
  const LoanEvent({required this.id, required this.loanId, required this.kind, required this.amount, required this.at, this.note, this.fromEmail = false});

  final String id;
  final String loanId;
  final LoanEventKind kind;
  final double amount;
  final DateTime at;
  final String? note;
  final bool fromEmail;

  factory LoanEvent.fromMap(Map<String, dynamic> m) => LoanEvent(
        id: m['id'] as String,
        loanId: m['loan_id'] as String,
        kind: LoanEventKind.values.byName(m['kind'] as String),
        amount: _num(m['amount']),
        at: DateTime.parse(m['event_at'] as String).toLocal(),
        note: m['note'] as String?,
        fromEmail: m['email_id'] != null,
      );
}
