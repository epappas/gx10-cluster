import unittest
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError
from ledger.transactions import Posting

FUTURE_NOW = datetime(2050, 3, 15, 12, 0, tzinfo=timezone.utc)
PAST_NOW = datetime(2001, 3, 15, 12, 0, tzinfo=timezone.utc)
LINES = [Posting("cash", 500), Posting("sales", -500)]


def rejected(case: unittest.TestCase, call: Callable[..., Any], *args: Any) -> LedgerError:
    with case.assertRaises(LedgerError) as ctx:
        call(*args)
    error = ctx.exception
    case.assertIsNot(type(error), LedgerError)
    case.assertRegex(error.code, r"^[a-z][a-z0-9_]*$")
    case.assertNotEqual(error.code, LedgerError.code)
    return error


def make_ledger(now: datetime = FUTURE_NOW) -> Ledger:
    ledger = Ledger(clock=lambda: now)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.open_account("sales", AccountKind.INCOME)
    return ledger


class ClosePeriodTests(unittest.TestCase):
    def test_new_ledger_has_no_closed_period(self) -> None:
        self.assertIsNone(make_ledger().closed_through)

    def test_close_sets_closed_through(self) -> None:
        ledger = make_ledger()
        self.assertIsNone(ledger.close_period(date(2050, 1, 31)))
        self.assertEqual(ledger.closed_through, date(2050, 1, 31))

    def test_yesterday_can_be_closed_in_any_era(self) -> None:
        ledger = make_ledger(PAST_NOW)
        ledger.close_period(PAST_NOW.date() - timedelta(days=1))
        self.assertEqual(ledger.closed_through, date(2001, 3, 14))

    def test_today_cannot_be_closed(self) -> None:
        rejected(self, make_ledger().close_period, FUTURE_NOW.date())

    def test_later_than_today_cannot_be_closed(self) -> None:
        rejected(self, make_ledger(PAST_NOW).close_period, date(2001, 3, 16))
        rejected(self, make_ledger(PAST_NOW).close_period, date(2020, 1, 1))

    def test_close_must_advance(self) -> None:
        ledger = make_ledger()
        ledger.close_period(date(2050, 1, 31))
        rejected(self, ledger.close_period, date(2050, 1, 31))
        rejected(self, ledger.close_period, date(2050, 1, 1))
        ledger.close_period(date(2050, 2, 28))
        self.assertEqual(ledger.closed_through, date(2050, 2, 28))

    def test_post_rejected_on_and_before_the_closed_date(self) -> None:
        ledger = make_ledger()
        ledger.close_period(date(2050, 1, 31))
        rejected(self, ledger.post, date(2050, 1, 31), "x", LINES)
        rejected(self, ledger.post, date(2049, 12, 1), "x", LINES)
        self.assertEqual(ledger.transactions, [])

    def test_post_allowed_after_the_closed_date(self) -> None:
        ledger = make_ledger()
        ledger.close_period(date(2050, 1, 31))
        ledger.post(date(2050, 2, 1), "x", LINES)
        self.assertEqual(ledger.balance("cash"), 500)

    def test_reverse_rejected_into_closed_period(self) -> None:
        ledger = make_ledger()
        ledger.post(date(2050, 1, 10), "x", LINES)
        ledger.close_period(date(2050, 1, 31))
        rejected(self, ledger.reverse, 1, date(2050, 1, 20))
        self.assertFalse(ledger.is_reversed(1))
        self.assertEqual(ledger.balance("cash"), 500)

    def test_closed_transaction_reversed_in_open_period(self) -> None:
        ledger = make_ledger()
        ledger.post(date(2050, 1, 10), "x", LINES)
        ledger.close_period(date(2050, 1, 31))
        ledger.reverse(1, date(2050, 2, 1))
        self.assertEqual(ledger.balance("cash"), 0)

    def test_closing_keeps_balances(self) -> None:
        ledger = make_ledger()
        ledger.post(date(2050, 1, 10), "x", LINES)
        ledger.close_period(date(2050, 1, 31))
        self.assertEqual(ledger.balance("cash"), 500)

    def test_records_one_event(self) -> None:
        ledger = make_ledger()
        before = len(ledger.audit)
        ledger.close_period(date(2050, 1, 31))
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "close_period")
        self.assertEqual(ledger.audit[-1].at, FUTURE_NOW)

    def test_failed_close_changes_nothing(self) -> None:
        ledger = make_ledger()
        ledger.close_period(date(2050, 1, 31))
        audit = list(ledger.audit)
        rejected(self, ledger.close_period, date(2050, 1, 1))
        rejected(self, ledger.close_period, date(2051, 1, 1))
        rejected(self, ledger.post, date(2050, 1, 1), "x", LINES)
        self.assertEqual(ledger.audit, audit)
        self.assertEqual(ledger.closed_through, date(2050, 1, 31))
