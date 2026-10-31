import os
import shutil
import tempfile
import unittest
from collections.abc import Callable
from datetime import date, datetime, timezone
from typing import Any
from unittest import mock

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError, StorageError
from ledger.export import export_aging_csv, export_statement_csv
from ledger.transactions import Posting

NOW = datetime(2040, 7, 1, 9, 0, tzinfo=timezone.utc)
AGING_HEADER = "customer,current,days_1_30,days_31_60,days_over_60,total\n"


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
    ledger.open_account("zeta", AccountKind.ASSET)
    ledger.open_account("acme", AccountKind.ASSET)
    ledger.post(date(2040, 6, 2), "later, with comma", [Posting("cash", 150), Posting("sales", -150)])
    ledger.post(date(2040, 6, 1), "first", [Posting("cash", 1205), Posting("sales", -1205)])
    ledger.post(date(2040, 6, 3), "refund", [Posting("cash", -2000), Posting("sales", 2000)])
    return ledger


def read_bytes(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.mkdtemp(dir=".")
        self.addCleanup(shutil.rmtree, self.directory)
        self.path = os.path.join(self.directory, "out.csv")

    def seed_target(self) -> None:
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write("previous content")

    def assert_target_survives(self, call: Callable[..., Any], *args: Any) -> None:
        self.seed_target()
        with mock.patch("os.replace", side_effect=OSError("disk full")):
            with self.assertRaises(StorageError):
                call(*args)
        self.assertEqual(read_bytes(self.path), b"previous content")
        self.assertEqual(os.listdir(self.directory), ["out.csv"])


class StatementExportTests(Base):
    def test_exact_content(self) -> None:
        count = export_statement_csv(make_ledger(), "cash", self.path)
        self.assertEqual(count, 3)
        expected = (
            "date,txn_id,memo,amount,balance\n"
            "2040-06-01,2,first,12.05,12.05\n"
            '2040-06-02,1,"later, with comma",1.50,13.55\n'
            "2040-06-03,3,refund,-20.00,-6.45\n"
        )
        self.assertEqual(read_bytes(self.path).decode("utf-8"), expected)

    def test_no_transactions_writes_header_only(self) -> None:
        self.assertEqual(export_statement_csv(make_ledger(), "acme", self.path), 0)
        self.assertEqual(read_bytes(self.path), b"date,txn_id,memo,amount,balance\n")

    def test_replaces_existing_file(self) -> None:
        self.seed_target()
        export_statement_csv(make_ledger(), "acme", self.path)
        self.assertEqual(read_bytes(self.path), b"date,txn_id,memo,amount,balance\n")

    def test_unknown_account_creates_no_file(self) -> None:
        rejected(self, export_statement_csv, make_ledger(), "nope", self.path)
        self.assertEqual(os.listdir(self.directory), [])

    def test_missing_directory(self) -> None:
        target = os.path.join(self.directory, "absent", "out.csv")
        rejected(self, export_statement_csv, make_ledger(), "cash", target)

    def test_failed_write_keeps_old_file(self) -> None:
        self.assert_target_survives(export_statement_csv, make_ledger(), "cash", self.path)

    def test_export_is_not_a_state_change(self) -> None:
        ledger = make_ledger()
        before = len(ledger.audit)
        export_statement_csv(ledger, "cash", self.path)
        self.assertEqual(len(ledger.audit), before)


class AgingExportTests(Base):
    def aged(self) -> Ledger:
        ledger = make_ledger()
        ledger.issue_invoice("zeta", "sales", 120, date(2040, 7, 1))
        ledger.issue_invoice("acme", "sales", 12345, date(2040, 7, 2))
        return ledger

    def test_exact_content(self) -> None:
        self.assertEqual(export_aging_csv(self.aged(), self.path), 2)
        expected = AGING_HEADER + "acme,123.45,0.00,0.00,0.00,123.45\nzeta,1.20,0.00,0.00,0.00,1.20\n"
        self.assertEqual(read_bytes(self.path).decode("utf-8"), expected)

    def test_no_open_invoices_writes_header_only(self) -> None:
        self.assertEqual(export_aging_csv(make_ledger(), self.path), 0)
        self.assertEqual(read_bytes(self.path).decode("utf-8"), AGING_HEADER)

    def test_missing_directory(self) -> None:
        target = os.path.join(self.directory, "absent", "out.csv")
        rejected(self, export_aging_csv, self.aged(), target)

    def test_failed_write_keeps_old_file(self) -> None:
        self.assert_target_survives(export_aging_csv, self.aged(), self.path)
