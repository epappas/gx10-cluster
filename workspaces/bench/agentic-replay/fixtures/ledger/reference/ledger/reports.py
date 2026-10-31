"""Read-only views of a Ledger."""

from dataclasses import dataclass
from datetime import date

from ledger.book import Ledger
from ledger.errors import InvalidLimitError
from ledger.invoices import Invoice


@dataclass(frozen=True)
class StatementLine:
    on: date
    txn_id: int
    memo: str
    amount: int
    balance: int


@dataclass(frozen=True)
class AgingRow:
    customer: str
    current: int
    days_1_30: int
    days_31_60: int
    days_over_60: int
    total: int


def account_statement(ledger: Ledger, name: str) -> list[StatementLine]:
    lines: list[StatementLine] = []
    running = 0
    for txn in ledger.transactions_for(name):
        amount = sum(p.amount for p in txn.postings if p.account == name)
        running += amount
        lines.append(StatementLine(txn.on, txn.id, txn.memo, amount, running))
    return lines


def trial_balance(ledger: Ledger) -> list[tuple[str, int]]:
    return [(name, ledger.balance(name)) for name in sorted(ledger.accounts)]


def _bucket(days_overdue: int) -> int:
    if days_overdue <= 0:
        return 0
    if days_overdue <= 30:
        return 1
    return 2 if days_overdue <= 60 else 3


def _open_by_customer(ledger: Ledger) -> dict[str, list[Invoice]]:
    grouped: dict[str, list[Invoice]] = {}
    for invoice in ledger.invoices.values():
        if invoice.is_open:
            grouped.setdefault(invoice.customer, []).append(invoice)
    return grouped


def aging(ledger: Ledger) -> list[AgingRow]:
    today = ledger.clock().date()
    rows: list[AgingRow] = []
    for customer, invoices in sorted(_open_by_customer(ledger).items()):
        buckets = [0, 0, 0, 0]
        for invoice in invoices:
            buckets[_bucket((today - invoice.due).days)] += invoice.owed
        rows.append(AgingRow(customer, *buckets, sum(buckets)))
    return rows


def top_debtors(ledger: Ledger, limit: int) -> list[tuple[str, int]]:
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise InvalidLimitError(f"bad limit: {limit!r}")
    totals = [(row.customer, row.total) for row in aging(ledger)]
    return sorted(totals, key=lambda item: (-item[1], item[0]))[:limit]
