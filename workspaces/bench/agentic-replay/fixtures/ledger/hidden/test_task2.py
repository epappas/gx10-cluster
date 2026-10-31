import unittest
from collections.abc import Callable
from datetime import date, datetime, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError
from ledger.transactions import Posting

NOW = datetime(2031, 6, 1, 8, 30, tzinfo=timezone.utc)
DAY = date(2031, 5, 10)


def rejected(case: unittest.TestCase, call: Callable[..., Any], *args: Any) -> LedgerError:
    with case.assertRaises(LedgerError) as ctx:
        call(*args)
    error = ctx.exception
    case.assertIsNot(type(error), LedgerError)
    case.assertRegex(error.code, r"^[a-z][a-z0-9_]*$")
    case.assertNotEqual(error.code, LedgerError.code)
    return error


def make_ledger() -> Ledger:
    ledger = Ledger(clock=lambda: NOW)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.open_account("sales", AccountKind.INCOME)
    ledger.open_account("tax", AccountKind.LIABILITY)
    lines = [Posting("cash", 1200), Posting("sales", -1000), Posting("tax", -200)]
    ledger.post(DAY, "sale", lines)
    return ledger


class ReverseTests(unittest.TestCase):
    def test_mirrors_postings_in_order(self) -> None:
        reversal = make_ledger().reverse(1, DAY)
        self.assertEqual(
            reversal.postings,
            (Posting("cash", -1200), Posting("sales", 1000), Posting("tax", 200)),
        )

    def test_new_transaction_fields(self) -> None:
        ledger = make_ledger()
        reversal = ledger.reverse(1, date(2031, 5, 20))
        self.assertEqual(reversal.id, 2)
        self.assertEqual(reversal.on, date(2031, 5, 20))
        self.assertEqual(reversal.reverses, 1)
        self.assertEqual(reversal.memo, "reversal of 1")
        self.assertEqual(ledger.transaction(2), reversal)

    def test_custom_memo(self) -> None:
        self.assertEqual(make_ledger().reverse(1, DAY, "typo").memo, "typo")

    def test_plain_transaction_reverses_nothing(self) -> None:
        self.assertIsNone(make_ledger().transaction(1).reverses)

    def test_balances_return_to_zero(self) -> None:
        ledger = make_ledger()
        ledger.reverse(1, DAY)
        for name in ("cash", "sales", "tax"):
            self.assertEqual(ledger.balance(name), 0)

    def test_is_reversed(self) -> None:
        ledger = make_ledger()
        self.assertFalse(ledger.is_reversed(1))
        ledger.reverse(1, DAY)
        self.assertTrue(ledger.is_reversed(1))
        self.assertFalse(ledger.is_reversed(2))

    def test_is_reversed_unknown_id(self) -> None:
        rejected(self, make_ledger().is_reversed, 42)

    def test_rejects_unknown_id(self) -> None:
        rejected(self, make_ledger().reverse, 42, DAY)

    def test_rejects_second_reversal(self) -> None:
        ledger = make_ledger()
        ledger.reverse(1, DAY)
        rejected(self, ledger.reverse, 1, DAY)

    def test_rejects_reversing_a_reversal(self) -> None:
        ledger = make_ledger()
        ledger.reverse(1, DAY)
        rejected(self, ledger.reverse, 2, DAY)

    def test_rejects_date_before_original(self) -> None:
        rejected(self, make_ledger().reverse, 1, date(2031, 5, 9))

    def test_records_one_event(self) -> None:
        ledger = make_ledger()
        before = len(ledger.audit)
        ledger.reverse(1, DAY)
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "reverse")
        self.assertEqual(ledger.audit[-1].at, NOW)

    def test_failure_changes_nothing(self) -> None:
        ledger = make_ledger()
        audit = list(ledger.audit)
        transactions = list(ledger.transactions)
        rejected(self, ledger.reverse, 1, date(2031, 1, 1))
        rejected(self, ledger.reverse, 42, DAY)
        self.assertEqual(ledger.audit, audit)
        self.assertEqual(ledger.transactions, transactions)
