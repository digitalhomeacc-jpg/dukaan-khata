double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

class Category {
  const Category({required this.id, required this.name, required this.icon, required this.color});

  final String id;
  final String name;
  final String icon;
  final int color;

  factory Category.fromMap(Map<String, dynamic> m) => Category(
        id: m['id'] as String,
        name: m['name'] as String,
        icon: (m['icon'] as String?) ?? 'label',
        color: (m['color'] as num?)?.toInt() ?? 0xFF607D8B,
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
    this.source = 'manual',
    this.emailSubject,
    this.excluded = false,
    this.needsReview = false,
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
  final String source;
  final String? emailSubject;
  final bool excluded;
  final bool needsReview;

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
        source: (m['source'] as String?) ?? 'manual',
        emailSubject: m['email_subject'] as String?,
        excluded: m['excluded'] == true,
        needsReview: m['needs_review'] == true,
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
