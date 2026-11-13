import 'package:expense_tracker/logic/summary.dart';
import 'package:expense_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

LoanEvent ev(LoanEventKind k, double a, DateTime at, {String loan = 'L'}) =>
    LoanEvent(id: '$k$a$at', loanId: loan, kind: k, amount: a, at: at);

void main() {
  final now = DateTime(2026, 11, 13);

  test('credit line: borrowed and bought minus repaid; reminder already paid', () {
    const loan = Loan(
      id: 'L',
      lender: 'slice',
      name: 'Slice borrow',
      kind: LoanKind.creditLine,
      nextDueAmount: 506.54,
      nextDueDate: null,
    );
    final events = [
      ev(LoanEventKind.borrow, 1450, DateTime(2026, 10, 18)),
      ev(LoanEventKind.borrow, 1500, DateTime(2026, 10, 18)),
      ev(LoanEventKind.spend, 136, DateTime(2026, 11, 7)),
      ev(LoanEventKind.repay, 506.54, DateTime(2026, 11, 5, 10)),
      ev(LoanEventKind.borrow, 99, DateTime(2026, 11, 1), loan: 'other'),
    ];
    final s = loanStatus(
      const Loan(id: 'L', lender: 'slice', name: 'Slice borrow', kind: LoanKind.creditLine),
      events,
      now: now,
    );
    expect(s.borrowed, 3086);
    expect(s.repaid, 506.54);
    expect(s.owed, 2579.46);
    expect(s.emisPaid, isNull);

    final withDue = loanStatus(
      Loan(
        id: 'L',
        lender: 'slice',
        name: 'x',
        kind: LoanKind.creditLine,
        nextDueAmount: loan.nextDueAmount,
        nextDueDate: DateTime(2026, 11, 5),
      ),
      events,
      now: now,
    );
    expect(withDue.nextDuePaid, true);
  });

  test('owed set by the user is the starting point', () {
    final s = loanStatus(
      Loan(
        id: 'L',
        lender: 'slice',
        name: 'x',
        kind: LoanKind.creditLine,
        outstanding: 2000,
        outstandingAt: DateTime(2026, 11, 1),
      ),
      [
        ev(LoanEventKind.borrow, 1500, DateTime(2026, 10, 18)), // before: already in the 2000
        ev(LoanEventKind.spend, 136, DateTime(2026, 11, 7)),
        ev(LoanEventKind.repay, 500, DateTime(2026, 11, 8)),
      ],
      now: now,
    );
    expect(s.owed, 1636);
  });

  test('EMI loan: EMIs paid, left, amount to pay and next EMI date', () {
    const loan = Loan(
      id: 'L',
      lender: 'kreditbee',
      name: 'KreditBee',
      principal: 20000,
      emiAmount: 2100,
      tenureMonths: 12,
      emisPaidBefore: 3,
      dueDay: 5,
      interestRate: 24,
    );
    final s = loanStatus(loan, [
      ev(LoanEventKind.repay, 2100, DateTime(2026, 10, 5)),
      ev(LoanEventKind.repay, 2100, DateTime(2026, 11, 5)),
    ], now: now);
    expect(s.emisPaid, 5);
    expect(s.emisLeft, 7);
    expect(s.owed, 14700);
    expect(s.owedIsEmiBased, true);
    expect(s.nextDueDate, DateTime(2026, 12, 5)); // November's EMI is paid
    expect(s.nextDueAmount, 2100);
    expect(s.nextDuePaid, false);
  });

  test('EMI not yet paid this month is due this month', () {
    const loan = Loan(id: 'L', lender: 'fibe', name: 'Fibe', emiAmount: 1500, tenureMonths: 6, dueDay: 20);
    final s = loanStatus(loan, const [], now: now);
    expect(s.nextDueDate, DateTime(2026, 11, 20));
    expect(s.emisLeft, 6);
  });

  test('due day 31 in a short month', () {
    expect(nextDueOn(31, DateTime(2026, 11, 13)), DateTime(2026, 11, 30));
    expect(nextDueOn(31, DateTime(2027, 2, 1)), DateTime(2027, 2, 28));
    expect(nextDueOn(5, DateTime(2026, 12, 6)), DateTime(2027, 1, 5));
  });

  test('fully paid loan has nothing due', () {
    const loan = Loan(
      id: 'L',
      lender: 'fibe',
      name: 'Fibe',
      emiAmount: 1000,
      tenureMonths: 2,
      emisPaidBefore: 2,
      dueDay: 3,
    );
    final s = loanStatus(loan, const [], now: now);
    expect(s.owed, 0);
    expect(s.nextDueDate, isNull);
  });

  test('borrowed money and repayments are not income or spending', () {
    final txns = [
      Txn(id: '1', amount: 590, isDebit: false, txnAt: DateTime(2026, 11, 2), loanRole: 'borrow'),
      Txn(id: '2', amount: 506, isDebit: true, txnAt: DateTime(2026, 11, 5), loanRole: 'repay'),
      Txn(id: '3', amount: 136, isDebit: true, txnAt: DateTime(2026, 11, 7), loanRole: 'spend'),
    ];
    final s = summarize(txns, DateTime(2026, 11));
    expect(s.spent, 136);
    expect(s.received, 0);
  });

  test('payments from before the loan was added are not counted twice', () {
    final loan = Loan(
      id: 'L',
      lender: 'kreditbee',
      name: 'KreditBee',
      emiAmount: 4161,
      tenureMonths: 10,
      emisPaidBefore: 4,
      dueDay: 10,
      outstanding: 24477,
      outstandingAt: DateTime(2026, 11, 13, 16),
      createdAt: DateTime(2026, 11, 13, 16),
      nextDueAmount: 4161,
      nextDueDate: DateTime(2026, 12, 10),
    );
    final s = loanStatus(loan, [ev(LoanEventKind.repay, 4161, DateTime(2026, 11, 10))], now: now);
    expect(s.emisPaid, 4);
    expect(s.emisLeft, 6);
    expect(s.owed, 24477);
    expect(s.nextDueDate, DateTime(2026, 12, 10));
    expect(s.nextDuePaid, false);
    final after = loanStatus(loan, [ev(LoanEventKind.repay, 4161, DateTime(2026, 12, 9))], now: DateTime(2026, 12, 11));
    expect(after.emisPaid, 5);
    expect(after.owed, 20316);
    expect(after.nextDueDate, DateTime(2027, 1, 10));
  });
}
