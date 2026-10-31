import unittest
from datetime import date, datetime, timezone

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import (
    DuplicateAccountError,
    InvalidAmountError,
    InvalidTransactionError,
    UnknownAccountError,
    UnknownTransactionError,
)
from ledger.transactions import Posting

NOW = datetime(2031, 1, 10, 9, 0, tzinfo=timezone.utc)


def make_ledger() -> Ledger:
    ledger = Ledger(clock=lambda: NOW)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.open_account("sales", AccountKind.INCOME)
    return ledger


class LedgerTests(unittest.TestCase):
    def test_post_updates_balances(self) -> None:
        ledger = make_ledger()
        txn = ledger.post(date(2031, 1, 5), "sale", [Posting("cash", 500), Posting("sales", -500)])
        self.assertEqual(txn.id, 1)
        self.assertEqual(ledger.balance("cash"), 500)
        self.assertEqual(ledger.balance("sales"), -500)
        self.assertEqual(ledger.transaction(1), txn)

    def test_post_rejects_bad_input(self) -> None:
        ledger = make_ledger()
        day = date(2031, 1, 5)
        with self.assertRaises(InvalidTransactionError):
            ledger.post(day, "x", [Posting("cash", 5), Posting("sales", -4)])
        with self.assertRaises(InvalidTransactionError):
            ledger.post(day, "x", [Posting("cash", 5)])
        with self.assertRaises(InvalidTransactionError):
            ledger.post("2031-01-05", "x", [Posting("cash", 5), Posting("sales", -5)])
        with self.assertRaises(InvalidAmountError):
            ledger.post(day, "x", [Posting("cash", 0.5), Posting("sales", -0.5)])
        with self.assertRaises(UnknownAccountError):
            ledger.post(day, "x", [Posting("cash", 5), Posting("nope", -5)])
        self.assertEqual(ledger.transactions, [])

    def test_duplicate_account(self) -> None:
        with self.assertRaises(DuplicateAccountError):
            make_ledger().open_account("cash", AccountKind.ASSET)

    def test_unknown_lookups(self) -> None:
        ledger = make_ledger()
        with self.assertRaises(UnknownAccountError):
            ledger.balance("nope")
        with self.assertRaises(UnknownTransactionError):
            ledger.transaction(99)

    def test_transactions_for_is_by_date_then_id(self) -> None:
        ledger = make_ledger()
        lines = [Posting("cash", 5), Posting("sales", -5)]
        ledger.post(date(2031, 1, 7), "late", lines)
        ledger.post(date(2031, 1, 6), "early", lines)
        self.assertEqual([t.id for t in ledger.transactions_for("cash")], [2, 1])

    def test_audit(self) -> None:
        ledger = make_ledger()
        ledger.post(date(2031, 1, 5), "sale", [Posting("cash", 5), Posting("sales", -5)])
        self.assertEqual(
            [e.action for e in ledger.audit], ["open_account", "open_account", "post"]
        )
        self.assertEqual(ledger.audit[-1].at, NOW)
