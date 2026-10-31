import unittest
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError

START = datetime(2038, 4, 1, 9, 0, tzinfo=timezone.utc)
LATER = datetime(2038, 6, 1, 9, 0, tzinfo=timezone.utc)


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
    ledger.open_account("fees", AccountKind.INCOME)
    return ledger, clock


def issue(ledger: Ledger, amount: int, due: date) -> int:
    return ledger.issue_invoice("receivable", "sales", amount, due).id


class LateFeeTests(unittest.TestCase):
    def test_charges_overdue_invoice(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        clock.now = LATER
        charged = ledger.assess_late_fees(250, "fees")
        self.assertEqual([invoice.id for invoice in charged], [1])
        self.assertEqual(charged[0].late_fee, 250)
        self.assertEqual(ledger.invoices[1].late_fee, 250)
        self.assertEqual(ledger.balance("fees"), -250)
        self.assertEqual(ledger.balance("receivable"), 10250)

    def test_fee_transaction(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        clock.now = LATER
        invoice = ledger.assess_late_fees(250, "fees")[0]
        txn = ledger.transaction(invoice.fee_txn_id)
        self.assertEqual(txn.on, LATER.date())
        self.assertEqual(txn.memo, "late fee invoice 1")

    def test_new_invoice_has_no_fee(self) -> None:
        ledger, _ = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        self.assertEqual(ledger.invoices[1].late_fee, 0)
        self.assertIsNone(ledger.invoices[1].fee_txn_id)

    def test_fee_half_cent_goes_up(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 50, date(2038, 5, 1))
        clock.now = LATER
        self.assertEqual(ledger.assess_late_fees(500, "fees")[0].late_fee, 3)

    def test_fee_is_exact_on_huge_amount(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10**18 + 3, date(2038, 5, 1))
        clock.now = LATER
        self.assertEqual(ledger.assess_late_fees(5000, "fees")[0].late_fee, 5 * 10**17 + 2)

    def test_overdue_means_strictly_before_today(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, LATER.date())
        issue(ledger, 10000, LATER.date() - timedelta(days=1))
        clock.now = LATER
        self.assertEqual([i.id for i in ledger.assess_late_fees(100, "fees")], [2])

    def test_uses_ledger_time_not_wall_time(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        self.assertEqual(ledger.assess_late_fees(100, "fees"), [])
        clock.now = date_time(2038, 5, 2)
        self.assertEqual(len(ledger.assess_late_fees(100, "fees")), 1)

    def test_skips_paid_voided_and_already_charged(self) -> None:
        ledger, clock = make_ledger()
        for _ in range(3):
            issue(ledger, 10000, date(2038, 5, 1))
        ledger.pay_invoice(1, "cash")
        ledger.void_invoice(2)
        clock.now = LATER
        self.assertEqual([i.id for i in ledger.assess_late_fees(100, "fees")], [3])
        self.assertEqual(ledger.assess_late_fees(100, "fees"), [])
        self.assertEqual(ledger.balance("fees"), -100)

    def test_zero_fee_is_skipped_and_unmarked(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10, date(2038, 5, 1))
        clock.now = LATER
        self.assertEqual(ledger.assess_late_fees(1, "fees"), [])
        self.assertEqual(ledger.invoices[1].late_fee, 0)
        self.assertEqual(len(ledger.transactions), 1)

    def test_result_is_by_due_date_then_id(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 1000, date(2038, 5, 20))
        issue(ledger, 1000, date(2038, 5, 1))
        issue(ledger, 1000, date(2038, 5, 20))
        issue(ledger, 1000, date(2038, 5, 1))
        clock.now = LATER
        charged = ledger.assess_late_fees(100, "fees")
        self.assertEqual([invoice.id for invoice in charged], [2, 4, 1, 3])

    def test_one_event_for_many_charges(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 1000, date(2038, 5, 1))
        issue(ledger, 2000, date(2038, 5, 2))
        clock.now = LATER
        before = len(ledger.audit)
        ledger.assess_late_fees(100, "fees")
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "assess_late_fees")
        self.assertEqual(ledger.audit[-1].at, LATER)

    def test_no_event_when_nothing_charged(self) -> None:
        ledger, _ = make_ledger()
        before = len(ledger.audit)
        self.assertEqual(ledger.assess_late_fees(100, "fees"), [])
        self.assertEqual(len(ledger.audit), before)

    def test_rejects_bad_arguments_even_when_nothing_is_due(self) -> None:
        ledger, _ = make_ledger()
        rejected(self, ledger.assess_late_fees, 1.5, "fees")
        rejected(self, ledger.assess_late_fees, -1, "fees")
        rejected(self, ledger.assess_late_fees, 100, "nope")
        rejected(self, ledger.assess_late_fees, 100, "cash")

    def test_bad_arguments_change_nothing(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 1000, date(2038, 5, 1))
        clock.now = LATER
        audit = list(ledger.audit)
        rejected(self, ledger.assess_late_fees, 1.5, "fees")
        rejected(self, ledger.assess_late_fees, 100, "cash")
        self.assertEqual(ledger.audit, audit)
        self.assertEqual(len(ledger.transactions), 1)
        self.assertEqual(ledger.invoices[1].late_fee, 0)


class FeeInteractionTests(unittest.TestCase):
    def test_payment_covers_the_fee(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        clock.now = LATER
        ledger.assess_late_fees(250, "fees")
        ledger.pay_invoice(1, "cash")
        self.assertEqual(ledger.balance("cash"), 10250)
        self.assertEqual(ledger.balance("receivable"), 0)

    def test_void_reverses_the_fee_too(self) -> None:
        ledger, clock = make_ledger()
        issue(ledger, 10000, date(2038, 5, 1))
        clock.now = LATER
        invoice = ledger.assess_late_fees(250, "fees")[0]
        before = len(ledger.audit)
        ledger.void_invoice(1)
        self.assertTrue(ledger.is_reversed(invoice.txn_id))
        self.assertTrue(ledger.is_reversed(invoice.fee_txn_id))
        self.assertEqual(ledger.balance("receivable"), 0)
        self.assertEqual(ledger.balance("sales"), 0)
        self.assertEqual(ledger.balance("fees"), 0)
        self.assertEqual(len(ledger.audit), before + 1)


def date_time(year: int, month: int, day: int) -> datetime:
    return datetime(year, month, day, 9, 0, tzinfo=timezone.utc)
