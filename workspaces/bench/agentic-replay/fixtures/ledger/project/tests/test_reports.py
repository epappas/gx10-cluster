import unittest
from datetime import date

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import UnknownAccountError
from ledger.reports import account_statement, trial_balance
from ledger.transactions import Posting


def make_ledger() -> Ledger:
    ledger = Ledger()
    ledger.open_account("sales", AccountKind.INCOME)
    ledger.open_account("cash", AccountKind.ASSET)
    ledger.post(date(2031, 1, 2), "b", [Posting("cash", 300), Posting("sales", -300)])
    ledger.post(date(2031, 1, 1), "a", [Posting("cash", 100), Posting("sales", -100)])
    return ledger


class ReportTests(unittest.TestCase):
    def test_statement_running_balance(self) -> None:
        lines = account_statement(make_ledger(), "cash")
        self.assertEqual(
            [(x.txn_id, x.amount, x.balance) for x in lines], [(2, 100, 100), (1, 300, 400)]
        )

    def test_statement_unknown_account(self) -> None:
        with self.assertRaises(UnknownAccountError):
            account_statement(make_ledger(), "nope")

    def test_trial_balance(self) -> None:
        self.assertEqual(trial_balance(make_ledger()), [("cash", 400), ("sales", -400)])
