"""Saving and loading a Ledger as a JSON file."""

import json
import os
import tempfile
from dataclasses import asdict
from datetime import date, datetime
from typing import Any

from ledger.accounts import Account, AccountKind
from ledger.book import AuditEvent, Ledger
from ledger.clock import Clock, system_clock
from ledger.errors import StorageError
from ledger.invoices import Invoice
from ledger.money import require_cents
from ledger.transactions import Posting, Transaction, validate_postings

FORMAT_VERSION = 2
_READABLE_VERSIONS: tuple[int, ...] = (1, 2)


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


def _iso(value: date | None) -> str | None:
    return None if value is None else value.isoformat()


def _dump_invoice(invoice: Invoice) -> dict[str, Any]:
    fields = asdict(invoice)
    for key in ("issued", "due", "paid_on"):
        fields[key] = _iso(fields[key])
    return fields


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
                "reverses": t.reverses,
            }
            for t in ledger.transactions
        ],
        "audit": [
            {"action": e.action, "at": e.at.isoformat(), "detail": e.detail}
            for e in ledger.audit
        ],
        "closed_through": _iso(ledger.closed_through),
        "invoices": [_dump_invoice(i) for i in ledger.invoices.values()],
    }


def save_ledger(ledger: Ledger, path: str) -> None:
    atomic_write(path, json.dumps(_dump(ledger), indent=2, sort_keys=True) + "\n")


def _optional_date(value: str | None) -> date | None:
    return None if value is None else date.fromisoformat(value)


def _restore_invoice(item: dict[str, Any]) -> Invoice:
    fields = dict(item)
    fields["amount"] = require_cents(item["amount"])
    fields["late_fee"] = require_cents(item["late_fee"])
    fields["issued"] = date.fromisoformat(item["issued"])
    fields["due"] = date.fromisoformat(item["due"])
    fields["paid_on"] = _optional_date(item["paid_on"])
    return Invoice(**fields)


def _restore_transaction(item: dict[str, Any]) -> Transaction:
    lines = validate_postings(
        Posting(p["account"], p["amount"]) for p in item["postings"]
    )
    on = date.fromisoformat(item["on"])
    return Transaction(item["id"], on, item["memo"], lines, item.get("reverses"))


def _restore(doc: dict[str, Any], clock: Clock) -> Ledger:
    ledger = Ledger(clock)
    for item in doc["accounts"]:
        ledger.accounts[item["name"]] = Account(item["name"], AccountKind(item["kind"]))
    ledger.transactions = [_restore_transaction(item) for item in doc["transactions"]]
    for item in doc["audit"]:
        at = datetime.fromisoformat(item["at"])
        ledger.audit.append(AuditEvent(item["action"], at, item["detail"]))
    ledger.closed_through = _optional_date(doc.get("closed_through"))
    for item in doc.get("invoices", []):
        invoice = _restore_invoice(item)
        ledger.invoices[invoice.id] = invoice
    return ledger


def load_ledger(path: str, clock: Clock = system_clock) -> Ledger:
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        raise StorageError(f"cannot read {path}: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("version") not in _READABLE_VERSIONS:
        raise StorageError(f"unsupported file: {path}")
    try:
        return _restore(doc, clock)
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise StorageError(f"malformed file {path}: {exc}") from exc
