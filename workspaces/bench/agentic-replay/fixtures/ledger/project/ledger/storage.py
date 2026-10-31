"""Saving and loading a Ledger as a JSON file."""

import json
import os
import tempfile
from datetime import date, datetime
from typing import Any

from ledger.accounts import Account, AccountKind
from ledger.book import AuditEvent, Ledger
from ledger.clock import Clock, system_clock
from ledger.errors import StorageError
from ledger.transactions import Posting, Transaction, validate_postings

FORMAT_VERSION = 1


def atomic_write(path: str, text: str) -> None:
    """Replace `path` with `text`, leaving the old file intact on failure."""
    temp_path = ""
    try:
        directory = os.path.dirname(os.path.abspath(path))
        fd, temp_path = tempfile.mkstemp(dir=directory, prefix=".ledger-")
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    except OSError as exc:
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)
        raise StorageError(f"cannot write {path}: {exc}") from exc


def _dump(ledger: Ledger) -> dict[str, Any]:
    return {
        "version": FORMAT_VERSION,
        "accounts": [
            {"name": a.name, "kind": a.kind.value} for a in ledger.accounts.values()
        ],
        "transactions": [
            {
                "id": t.id,
                "on": t.on.isoformat(),
                "memo": t.memo,
                "postings": [
                    {"account": p.account, "amount": p.amount} for p in t.postings
                ],
            }
            for t in ledger.transactions
        ],
        "audit": [
            {"action": e.action, "at": e.at.isoformat(), "detail": e.detail}
            for e in ledger.audit
        ],
    }


def save_ledger(ledger: Ledger, path: str) -> None:
    atomic_write(path, json.dumps(_dump(ledger), indent=2, sort_keys=True) + "\n")


def _restore(doc: dict[str, Any], clock: Clock) -> Ledger:
    ledger = Ledger(clock)
    for item in doc["accounts"]:
        ledger.accounts[item["name"]] = Account(item["name"], AccountKind(item["kind"]))
    for item in doc["transactions"]:
        lines = validate_postings(
            Posting(p["account"], p["amount"]) for p in item["postings"]
        )
        on = date.fromisoformat(item["on"])
        ledger.transactions.append(Transaction(item["id"], on, item["memo"], lines))
    for item in doc["audit"]:
        at = datetime.fromisoformat(item["at"])
        ledger.audit.append(AuditEvent(item["action"], at, item["detail"]))
    return ledger


def load_ledger(path: str, clock: Clock = system_clock) -> Ledger:
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        raise StorageError(f"cannot read {path}: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("version") != FORMAT_VERSION:
        raise StorageError(f"unsupported file: {path}")
    try:
        return _restore(doc, clock)
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise StorageError(f"malformed file {path}: {exc}") from exc
