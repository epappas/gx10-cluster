import unittest
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import InvalidAmountError, LedgerError
from ledger.invoices import Invoice

START = datetime(2038, 4, 10, 15, 0, tzinfo=timezone.utc)
TODAY = START.date()
DUE = date(2038, 5, 10)


class StepClock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


def rejected(case: unittest.TestCase, call: Callable[..., Any], *args: Any) -> LedgerError:
    with case.assertRaises(LedgerError) as ctx:
        call(*args)
    error = ctx.exception
    case.assertIsNot(type(error), LedgerError)
    case.assertRegex(error.code, r"^[a-z][a-z0-9_]*$")
    case.assertNotEqual(error.code, LedgerError.code)
    return error


def make_ledger() -> tuple[Ledger, StepClock]:
    clock = StepClock(START)
    ledger = Ledger(clock=clock)
    ledger.open_account("receivable", AccountKind.ASSET)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.open_account("sales", AccountKind.INCOME)
    ledger.open_account("loan", AccountKind.LIABILITY)
    return ledger, clock


class IssueTests(unittest.TestCase):
    def test_invoice_fields(self) -> None:
        ledger, _ = make_ledger()
        invoice = ledger.issue_invoice("receivable", "sales", 7500, DUE)
        self.assertIsInstance(invoice, Invoice)
        self.assertEqual(invoice.id, 1)
        self.assertEqual(invoice.customer, "receivable")
        self.assertEqual(invoice.income, "sales")
        self.assertEqual(invoice.amount, 7500)
        self.assertEqual(invoice.issued, TODAY)
        self.assertEqual(invoice.due, DUE)
        self.assertIsNone(invoice.paid_on)
        self.assertFalse(invoice.voided)

    def test_posts_dated_transaction(self) -> None:
        ledger, _ = make_ledger()
        invoice = ledger.issue_invoice("receivable", "sales", 7500, DUE)
        txn = ledger.transaction(invoice.txn_id)
        self.assertEqual(txn.on, TODAY)
        self.assertEqual(txn.memo, "invoice 1")
        self.assertEqual(ledger.balance("receivable"), 7500)
        self.assertEqual(ledger.balance("sales"), -7500)

    def test_ids_are_sequential_and_stored(self) -> None:
        ledger, _ = make_ledger()
        first = ledger.issue_invoice("receivable", "sales", 100, DUE)
        second = ledger.issue_invoice("receivable", "sales", 200, DUE)
        self.assertEqual(second.id, 2)
        self.assertEqual(ledger.invoices, {1: first, 2: second})

    def test_due_today_is_allowed(self) -> None:
        ledger, _ = make_ledger()
        self.assertEqual(ledger.issue_invoice("receivable", "sales", 1, TODAY).due, TODAY)

    def test_rejects_due_before_today(self) -> None:
        ledger, _ = make_ledger()
        rejected(self, ledger.issue_invoice, "receivable", "sales", 100, TODAY - timedelta(days=1))

    def test_rejects_non_cents_amount(self) -> None:
        ledger, _ = make_ledger()
        for amount in (12.5, 100.0, True):
            with self.assertRaises(InvalidAmountError):
                ledger.issue_invoice("receivable", "sales", amount, DUE)

    def test_rejects_non_positive_amount(self) -> None:
        ledger, _ = make_ledger()
        rejected(self, ledger.issue_invoice, "receivable", "sales", 0, DUE)
        rejected(self, ledger.issue_invoice, "receivable", "sales", -5, DUE)

    def test_rejects_wrong_accounts(self) -> None:
        ledger, _ = make_ledger()
        rejected(self, ledger.issue_invoice, "nope", "sales", 100, DUE)
        rejected(self, ledger.issue_invoice, "receivable", "nope", 100, DUE)
        rejected(self, ledger.issue_invoice, "loan", "sales", 100, DUE)
        rejected(self, ledger.issue_invoice, "receivable", "cash", 100, DUE)

    def test_records_one_event(self) -> None:
        ledger, _ = make_ledger()
        before = len(ledger.audit)
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "issue_invoice")
        self.assertEqual(ledger.audit[-1].at, START)

    def test_failure_changes_nothing(self) -> None:
        ledger, _ = make_ledger()
        audit = list(ledger.audit)
        rejected(self, ledger.issue_invoice, "receivable", "sales", 0, DUE)
        rejected(self, ledger.issue_invoice, "receivable", "nope", 100, DUE)
        self.assertEqual(ledger.audit, audit)
        self.assertEqual(ledger.transactions, [])
        self.assertEqual(ledger.invoices, {})


class PayTests(unittest.TestCase):
    def test_pay_moves_money_and_marks_paid(self) -> None:
        ledger, clock = make_ledger()
        ledger.issue_invoice("receivable", "sales", 7500, DUE)
        clock.now = START + timedelta(days=3)
        paid = ledger.pay_invoice(1, "cash")
        self.assertEqual(paid.paid_on, date(2038, 4, 13))
        self.assertEqual(ledger.invoices[1], paid)
        self.assertEqual(ledger.balance("cash"), 7500)
        self.assertEqual(ledger.balance("receivable"), 0)
        txn = ledger.transactions[-1]
        self.assertEqual(txn.on, date(2038, 4, 13))
        self.assertEqual(txn.memo, "payment of invoice 1")

    def test_rejects_bad_targets(self) -> None:
        ledger, _ = make_ledger()
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        rejected(self, ledger.pay_invoice, 9, "cash")
        rejected(self, ledger.pay_invoice, 1, "nope")
        rejected(self, ledger.pay_invoice, 1, "loan")

    def test_rejects_second_payment(self) -> None:
        ledger, _ = make_ledger()
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        ledger.pay_invoice(1, "cash")
        rejected(self, ledger.pay_invoice, 1, "cash")
        self.assertEqual(ledger.balance("cash"), 100)

    def test_records_one_event(self) -> None:
        ledger, clock = make_ledger()
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        before = len(ledger.audit)
        clock.now = START + timedelta(hours=2)
        ledger.pay_invoice(1, "cash")
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "pay_invoice")
        self.assertEqual(ledger.audit[-1].at, clock.now)


class VoidTests(unittest.TestCase):
    def test_void_reverses_invoice(self) -> None:
        ledger, clock = make_ledger()
        invoice = ledger.issue_invoice("receivable", "sales", 7500, DUE)
        clock.now = START + timedelta(days=1)
        voided = ledger.void_invoice(1)
        self.assertTrue(voided.voided)
        self.assertEqual(ledger.invoices[1], voided)
        self.assertTrue(ledger.is_reversed(invoice.txn_id))
        self.assertEqual(ledger.transactions[-1].on, date(2038, 4, 11))
        self.assertEqual(ledger.balance("receivable"), 0)
        self.assertEqual(ledger.balance("sales"), 0)

    def test_rejects_paid_voided_and_unknown(self) -> None:
        ledger, _ = make_ledger()
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        ledger.issue_invoice("receivable", "sales", 200, DUE)
        ledger.pay_invoice(1, "cash")
        ledger.void_invoice(2)
        rejected(self, ledger.void_invoice, 1)
        rejected(self, ledger.void_invoice, 2)
        rejected(self, ledger.void_invoice, 9)
        rejected(self, ledger.pay_invoice, 2, "cash")

    def test_records_one_event(self) -> None:
        ledger, _ = make_ledger()
        ledger.issue_invoice("receivable", "sales", 100, DUE)
        before = len(ledger.audit)
        ledger.void_invoice(1)
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "void_invoice")
