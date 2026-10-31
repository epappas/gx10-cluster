"""Transactions: balanced sets of signed postings (a debit is positive)."""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date

from ledger.errors import InvalidTransactionError
from ledger.money import require_cents


@dataclass(frozen=True)
class Posting:
    account: str
    amount: int


@dataclass(frozen=True)
class Transaction:
    id: int
    on: date
    memo: str
    postings: tuple[Posting, ...]


def validate_postings(postings: Iterable[Posting]) -> tuple[Posting, ...]:
    lines = tuple(postings)
    if len(lines) < 2:
        raise InvalidTransactionError("need at least two postings")
    if any(require_cents(line.amount) == 0 for line in lines):
        raise InvalidTransactionError("zero posting")
    if sum(line.amount for line in lines) != 0:
        raise InvalidTransactionError("postings do not balance")
    return lines
