"""Read-only views of a Ledger."""

from dataclasses import dataclass
from datetime import date

from ledger.book import Ledger


@dataclass(frozen=True)
class StatementLine:
    on: date
    txn_id: int
    memo: str
    amount: int
    balance: int


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
