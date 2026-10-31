import os
import shutil
import tempfile
import unittest
from collections.abc import Callable
from datetime import date, datetime, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError
from ledger.transactions import Posting

NOW = datetime(2041, 3, 20, 9, 0, tzinfo=timezone.utc)
HEADER = "date,description,amount\n"
GOOD_ROWS = (
    "2041-03-03,Coffee refund,12.50\n"
    '2041-03-01,"Rent, March",-800\n'
    "2041-03-01,Salary,2000.05\n"
)


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
    ledger.open_account("suspense", AccountKind.LIABILITY)
    ledger.open_account("sales", AccountKind.INCOME)
    ledger.post(date(2041, 2, 1), "opening", [Posting("cash", 100), Posting("sales", -100)])
    return ledger


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.mkdtemp(dir=".")
        self.addCleanup(shutil.rmtree, self.directory)
        self.path = os.path.join(self.directory, "bank.csv")

    def write(self, text: str) -> str:
        with open(self.path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        return self.path

    def assert_refused(self, ledger: Ledger, text: str) -> None:
        audit = list(ledger.audit)
        transactions = list(ledger.transactions)
        rejected(self, ledger.import_bank_csv, self.write(text), "cash", "suspense")
        self.assertEqual(ledger.audit, audit)
        self.assertEqual(ledger.transactions, transactions)


class ImportTests(Base):
    def test_postings_follow_sign(self) -> None:
        ledger = make_ledger()
        created = ledger.import_bank_csv(self.write(HEADER + GOOD_ROWS), "cash", "suspense")
        by_memo = {txn.memo: txn for txn in created}
        self.assertEqual(
            by_memo["Salary"].postings, (Posting("cash", 200005), Posting("suspense", -200005))
        )
        self.assertEqual(
            by_memo["Rent, March"].postings, (Posting("cash", -80000), Posting("suspense", 80000))
        )

    def test_balances(self) -> None:
        ledger = make_ledger()
        ledger.import_bank_csv(self.write(HEADER + GOOD_ROWS), "cash", "suspense")
        self.assertEqual(ledger.balance("cash"), 100 + 1250 - 80000 + 200005)
        self.assertEqual(ledger.balance("suspense"), -(1250 - 80000 + 200005))

    def test_ids_follow_file_rows(self) -> None:
        ledger = make_ledger()
        ledger.import_bank_csv(self.write(HEADER + GOOD_ROWS), "cash", "suspense")
        self.assertEqual(
            [txn.memo for txn in ledger.transactions[1:]],
            ["Coffee refund", "Rent, March", "Salary"],
        )
        self.assertEqual([txn.id for txn in ledger.transactions[1:]], [2, 3, 4])

    def test_returned_list_is_by_date_then_id(self) -> None:
        ledger = make_ledger()
        created = ledger.import_bank_csv(self.write(HEADER + GOOD_ROWS), "cash", "suspense")
        self.assertEqual([txn.id for txn in created], [3, 4, 2])

    def test_one_event_for_the_whole_file(self) -> None:
        ledger = make_ledger()
        before = len(ledger.audit)
        ledger.import_bank_csv(self.write(HEADER + GOOD_ROWS), "cash", "suspense")
        self.assertEqual(len(ledger.audit), before + 1)
        self.assertEqual(ledger.audit[-1].action, "import_bank_csv")
        self.assertEqual(ledger.audit[-1].at, NOW)

    def test_header_only_file_changes_nothing(self) -> None:
        ledger = make_ledger()
        before = len(ledger.audit)
        self.assertEqual(ledger.import_bank_csv(self.write(HEADER), "cash", "suspense"), [])
        self.assertEqual(len(ledger.audit), before)
        self.assertEqual(len(ledger.transactions), 1)


class RefusedFileTests(Base):
    def test_missing_file(self) -> None:
        ledger = make_ledger()
        missing = os.path.join(self.directory, "absent.csv")
        rejected(self, ledger.import_bank_csv, missing, "cash", "suspense")

    def test_unknown_account(self) -> None:
        ledger = make_ledger()
        path = self.write(HEADER + GOOD_ROWS)
        rejected(self, ledger.import_bank_csv, path, "nope", "suspense")
        rejected(self, ledger.import_bank_csv, path, "cash", "nope")
        self.assertEqual(len(ledger.transactions), 1)

    def test_bad_header(self) -> None:
        self.assert_refused(make_ledger(), "day,text,value\n" + GOOD_ROWS)

    def test_empty_file(self) -> None:
        self.assert_refused(make_ledger(), "")

    def test_bad_date_in_last_row(self) -> None:
        self.assert_refused(make_ledger(), HEADER + GOOD_ROWS + "soon,Lunch,5.00\n")

    def test_bad_amount_in_last_row(self) -> None:
        self.assert_refused(make_ledger(), HEADER + GOOD_ROWS + "2041-03-04,Lunch,5.005\n")

    def test_zero_amount(self) -> None:
        self.assert_refused(make_ledger(), HEADER + GOOD_ROWS + "2041-03-04,Lunch,0.00\n")

    def test_short_row(self) -> None:
        self.assert_refused(make_ledger(), HEADER + GOOD_ROWS + "2041-03-04,Lunch\n")

    def test_row_in_closed_period(self) -> None:
        ledger = make_ledger()
        ledger.close_period(date(2041, 3, 1))
        self.assert_refused(ledger, HEADER + "2041-03-05,Fine,1.00\n2041-03-01,Late,2.00\n")

    def test_not_utf8(self) -> None:
        ledger = make_ledger()
        with open(self.path, "wb") as handle:
            handle.write(b"\xff\xfe\x00bad")
        rejected(self, ledger.import_bank_csv, self.path, "cash", "suspense")
        self.assertEqual(len(ledger.transactions), 1)
