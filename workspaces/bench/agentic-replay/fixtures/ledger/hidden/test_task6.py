import unittest
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError
from ledger.reports import AgingRow, aging, top_debtors

ISSUED = datetime(2042, 1, 1, 9, 0, tzinfo=timezone.utc)
TODAY = datetime(2042, 6, 1, 9, 0, tzinfo=timezone.utc)
EARLY_NOW = datetime(1999, 1, 1, 9, 0, tzinfo=timezone.utc)


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


def make_ledger(*customers: str) -> tuple[Ledger, StepClock]:
    clock = StepClock(ISSUED)
    ledger = Ledger(clock=clock)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.open_account("sales", AccountKind.INCOME)
    ledger.open_account("fees", AccountKind.INCOME)
    for customer in customers:
        ledger.open_account(customer, AccountKind.ASSET)
    return ledger, clock


def issue(ledger: Ledger, customer: str, amount: int, days_overdue: int = 0) -> int:
    due = TODAY.date() - timedelta(days=days_overdue)
    return ledger.issue_invoice(customer, "sales", amount, due).id


class AgingTests(unittest.TestCase):
    def test_empty_ledger(self) -> None:
        ledger, _ = make_ledger()
        self.assertEqual(aging(ledger), [])

    def test_row_shape(self) -> None:
        ledger, clock = make_ledger("acme")
        issue(ledger, "acme", 100, 0)
        clock.now = TODAY
        self.assertEqual(aging(ledger), [AgingRow("acme", 100, 0, 0, 0, 100)])

    def test_bucket_boundaries(self) -> None:
        ledger, clock = make_ledger("acme")
        for amount, days in ((1, -5), (2, 0), (4, 1), (8, 30), (16, 31), (32, 60), (64, 61)):
            issue(ledger, "acme", amount, days)
        clock.now = TODAY
        self.assertEqual(aging(ledger), [AgingRow("acme", 3, 12, 48, 64, 127)])

    def test_buckets_follow_ledger_time(self) -> None:
        ledger, clock = make_ledger("acme")
        issue(ledger, "acme", 100, 10)
        clock.now = TODAY - timedelta(days=20)
        self.assertEqual(aging(ledger)[0].current, 100)
        clock.now = TODAY + timedelta(days=60)
        self.assertEqual(aging(ledger)[0].days_over_60, 100)

    def test_early_clock_shows_all_as_current(self) -> None:
        ledger, clock = make_ledger("acme")
        issue(ledger, "acme", 100, 10)
        clock.now = EARLY_NOW
        self.assertEqual(aging(ledger)[0].current, 100)

    def test_excludes_paid_and_voided(self) -> None:
        ledger, clock = make_ledger("acme", "bolt")
        issue(ledger, "acme", 100)
        issue(ledger, "acme", 200)
        issue(ledger, "bolt", 300)
        ledger.pay_invoice(1, "cash")
        ledger.void_invoice(3)
        clock.now = TODAY
        self.assertEqual(aging(ledger), [AgingRow("acme", 200, 0, 0, 0, 200)])

    def test_includes_late_fee(self) -> None:
        ledger, clock = make_ledger("acme")
        issue(ledger, "acme", 1000, 10)
        clock.now = TODAY
        ledger.assess_late_fees(1000, "fees")
        self.assertEqual(aging(ledger), [AgingRow("acme", 0, 1100, 0, 0, 1100)])

    def test_rows_follow_customer_name(self) -> None:
        ledger, clock = make_ledger("zeta", "acme", "mesa")
        issue(ledger, "zeta", 500)
        issue(ledger, "acme", 100)
        issue(ledger, "mesa", 900)
        clock.now = TODAY
        self.assertEqual([r.customer for r in aging(ledger)], ["acme", "mesa", "zeta"])


class TopDebtorsTests(unittest.TestCase):
    def test_largest_first(self) -> None:
        ledger, clock = make_ledger("acme", "bolt", "core")
        issue(ledger, "acme", 100)
        issue(ledger, "bolt", 300)
        issue(ledger, "core", 200)
        clock.now = TODAY
        self.assertEqual(
            top_debtors(ledger, 3), [("bolt", 300), ("core", 200), ("acme", 100)]
        )

    def test_limit_cuts_the_list(self) -> None:
        ledger, clock = make_ledger("acme", "bolt", "core")
        issue(ledger, "acme", 100)
        issue(ledger, "bolt", 300)
        issue(ledger, "core", 200)
        clock.now = TODAY
        self.assertEqual(top_debtors(ledger, 2), [("bolt", 300), ("core", 200)])
        self.assertEqual(len(top_debtors(ledger, 50)), 3)

    def test_ties_follow_name_whatever_the_issue_order(self) -> None:
        ledger, clock = make_ledger("zeta", "mesa", "acme")
        issue(ledger, "zeta", 500)
        issue(ledger, "mesa", 500)
        issue(ledger, "acme", 500)
        clock.now = TODAY
        self.assertEqual(
            top_debtors(ledger, 3), [("acme", 500), ("mesa", 500), ("zeta", 500)]
        )

    def test_ties_with_a_larger_debtor(self) -> None:
        ledger, clock = make_ledger("zeta", "acme", "mesa")
        issue(ledger, "zeta", 200)
        issue(ledger, "acme", 200)
        issue(ledger, "mesa", 900)
        clock.now = TODAY
        self.assertEqual(
            top_debtors(ledger, 2), [("mesa", 900), ("acme", 200)]
        )

    def test_totals_sum_open_invoices_only(self) -> None:
        ledger, clock = make_ledger("acme")
        issue(ledger, "acme", 100)
        issue(ledger, "acme", 250)
        issue(ledger, "acme", 400)
        ledger.pay_invoice(3, "cash")
        clock.now = TODAY
        self.assertEqual(top_debtors(ledger, 1), [("acme", 350)])

    def test_rejects_bad_limit(self) -> None:
        ledger, _ = make_ledger()
        for limit in (0, -1, 1.5, "2", True):
            rejected(self, top_debtors, ledger, limit)
