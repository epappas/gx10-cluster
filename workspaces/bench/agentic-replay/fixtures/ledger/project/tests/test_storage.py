import json
import os
import shutil
import tempfile
import unittest
from datetime import date

from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.errors import StorageError
from ledger.storage import atomic_write, load_ledger, save_ledger
from ledger.transactions import Posting


class StorageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.mkdtemp(dir=".")
        self.addCleanup(shutil.rmtree, self.directory)
        self.path = os.path.join(self.directory, "book.json")

    def test_atomic_write_replaces(self) -> None:
        atomic_write(self.path, "one")
        atomic_write(self.path, "two")
        with open(self.path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "two")
        self.assertEqual(os.listdir(self.directory), ["book.json"])

    def test_atomic_write_missing_directory(self) -> None:
        with self.assertRaises(StorageError):
            atomic_write(os.path.join(self.directory, "no", "x.txt"), "one")

    def test_round_trip(self) -> None:
        ledger = Ledger()
        ledger.open_account("cash", AccountKind.ASSET)
        ledger.open_account("sales", AccountKind.INCOME)
        ledger.post(date(2031, 1, 5), "sale", [Posting("cash", 5), Posting("sales", -5)])
        save_ledger(ledger, self.path)
        loaded = load_ledger(self.path)
        self.assertEqual(loaded.accounts, ledger.accounts)
        self.assertEqual(loaded.transactions, ledger.transactions)
        self.assertEqual(loaded.audit, ledger.audit)

    def test_load_rejects_bad_files(self) -> None:
        with self.assertRaises(StorageError):
            load_ledger(self.path)
        for text in ("not json", json.dumps({"version": 0}), json.dumps({"accounts": []})):
            with open(self.path, "w", encoding="utf-8") as handle:
                handle.write(text)
            with self.assertRaises(StorageError):
                load_ledger(self.path)
