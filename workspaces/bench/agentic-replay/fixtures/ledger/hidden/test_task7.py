import json
import os
import shutil
import tempfile
import unittest
from collections.abc import Callable
from datetime import date, datetime, timezone
from typing import Any

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import LedgerError, StorageError
from ledger.storage import load_ledger, save_ledger
from ledger.transactions import Posting

START = datetime(2039, 2, 1, 9, 0, tzinfo=timezone.utc)
LATER = datetime(2039, 4, 1, 9, 0, tzinfo=timezone.utc)
DUE = date(2039, 3, 1)
V1_DOC: dict[str, Any] = {
    "version": 1,
    "accounts": [
        {"name": "cash", "kind": "asset"},
        {"name": "sales", "kind": "income"},
    ],
    "transactions": [
        {
            "id": 1,
            "on": "2039-01-05",
            "memo": "old sale",
            "postings": [
                {"account": "cash", "amount": 700},
                {"account": "sales", "amount": -700},
            ],
        }
    ],
    "audit": [
        {"action": "post", "at": "2039-01-05T10:00:00+00:00", "detail": "transaction 1"}
    ],
}


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
    ledger.issue_invoice("receivable", "sales", 1000, DUE)
    ledger.issue_invoice("receivable", "sales", 2000, DUE)
    ledger.issue_invoice("receivable", "sales", 3000, DUE)
    ledger.void_invoice(2)
    ledger.pay_invoice(3, "cash")
    clock.now = LATER
    ledger.assess_late_fees(500, "fees")
    ledger.post(LATER.date(), "extra", [Posting("cash", 5), Posting("sales", -5)])
    ledger.close_period(date(2039, 3, 15))
    return ledger, clock


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.mkdtemp(dir=".")
        self.addCleanup(shutil.rmtree, self.directory)
        self.path = os.path.join(self.directory, "book.json")

    def saved_doc(self) -> dict[str, Any]:
        ledger, _ = make_ledger()
        save_ledger(ledger, self.path)
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)

    def write_doc(self, doc: dict[str, Any]) -> None:
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump(doc, handle)

    def round_trip(self) -> tuple[Ledger, Ledger]:
        ledger, clock = make_ledger()
        save_ledger(ledger, self.path)
        return ledger, load_ledger(self.path, clock=clock)


class RoundTripTests(Base):
    def test_format_keys(self) -> None:
        doc = self.saved_doc()
        self.assertEqual(doc["version"], 2)
        self.assertEqual(doc["closed_through"], "2039-03-15")
        first = doc["invoices"][0]
        self.assertEqual(first["id"], 1)
        self.assertEqual(first["issued"], "2039-02-01")
        self.assertEqual(first["late_fee"], 50)

    def test_open_period_is_null(self) -> None:
        ledger = Ledger()
        save_ledger(ledger, self.path)
        with open(self.path, encoding="utf-8") as handle:
            self.assertIsNone(json.load(handle)["closed_through"])
        self.assertIsNone(load_ledger(self.path).closed_through)

    def test_invoices_survive(self) -> None:
        ledger, loaded = self.round_trip()
        self.assertEqual(loaded.invoices, ledger.invoices)
        self.assertEqual(list(loaded.invoices), [1, 2, 3])

    def test_transactions_and_reversals_survive(self) -> None:
        ledger, loaded = self.round_trip()
        self.assertEqual(loaded.transactions, ledger.transactions)
        txn_id = loaded.invoices[2].txn_id
        self.assertTrue(loaded.is_reversed(txn_id))

    def test_audit_survives(self) -> None:
        ledger, loaded = self.round_trip()
        self.assertEqual(loaded.audit, ledger.audit)

    def test_closed_period_still_enforced(self) -> None:
        _, loaded = self.round_trip()
        self.assertEqual(loaded.closed_through, date(2039, 3, 15))
        lines = [Posting("cash", 5), Posting("sales", -5)]
        rejected(self, loaded.post, date(2039, 3, 15), "x", lines)

    def test_ids_continue_after_load(self) -> None:
        ledger, loaded = self.round_trip()
        invoice = loaded.issue_invoice("receivable", "sales", 10, date(2039, 5, 1))
        self.assertEqual(invoice.id, 4)
        self.assertEqual(invoice.txn_id, len(ledger.transactions) + 1)

    def test_loaded_invoices_are_usable(self) -> None:
        _, loaded = self.round_trip()
        self.assertEqual(loaded.balance("receivable"), 1050)
        paid = loaded.pay_invoice(1, "cash")
        self.assertEqual(paid.paid_on, LATER.date())
        self.assertEqual(loaded.balance("receivable"), 0)
        rejected(self, loaded.void_invoice, 2)

    def test_loaded_ledger_uses_given_clock(self) -> None:
        ledger, _ = make_ledger()
        save_ledger(ledger, self.path)
        moved = datetime(2045, 1, 1, 9, 0, tzinfo=timezone.utc)
        loaded = load_ledger(self.path, clock=lambda: moved)
        self.assertEqual(loaded.issue_invoice("receivable", "sales", 1, moved.date()).issued, moved.date())
        self.assertEqual(loaded.audit[-1].at, moved)


class OldFormatTests(Base):
    def test_version_one_loads_with_empty_new_state(self) -> None:
        self.write_doc(V1_DOC)
        loaded = load_ledger(self.path)
        self.assertEqual(loaded.balance("cash"), 700)
        self.assertEqual(loaded.invoices, {})
        self.assertIsNone(loaded.closed_through)
        self.assertIsNone(loaded.transaction(1).reverses)
        self.assertEqual(loaded.audit[0].action, "post")

    def test_version_one_becomes_two_when_saved_again(self) -> None:
        self.write_doc(V1_DOC)
        save_ledger(load_ledger(self.path), self.path)
        with open(self.path, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["version"], 2)


class BadFileTests(Base):
    def test_rejects_unknown_versions(self) -> None:
        for version in (0, 3, 99, "2"):
            doc = dict(V1_DOC, version=version)
            self.write_doc(doc)
            with self.assertRaises(StorageError):
                load_ledger(self.path)

    def test_rejects_bad_closed_through(self) -> None:
        doc = self.saved_doc()
        doc["closed_through"] = "not-a-date"
        self.write_doc(doc)
        rejected(self, load_ledger, self.path)

    def test_rejects_bad_invoice_date(self) -> None:
        doc = self.saved_doc()
        doc["invoices"][0]["due"] = "soon"
        self.write_doc(doc)
        rejected(self, load_ledger, self.path)

    def test_rejects_incomplete_invoice(self) -> None:
        doc = self.saved_doc()
        del doc["invoices"][0]["customer"]
        self.write_doc(doc)
        rejected(self, load_ledger, self.path)

    def test_rejects_non_cents_invoice_amount(self) -> None:
        doc = self.saved_doc()
        doc["invoices"][0]["amount"] = 12.5
        self.write_doc(doc)
        rejected(self, load_ledger, self.path)

    def test_rejects_non_cents_late_fee(self) -> None:
        doc = self.saved_doc()
        doc["invoices"][0]["late_fee"] = 0.5
        self.write_doc(doc)
        rejected(self, load_ledger, self.path)
