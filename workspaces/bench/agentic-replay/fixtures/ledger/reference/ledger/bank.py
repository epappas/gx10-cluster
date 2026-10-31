"""Reading bank statement CSV files."""

import csv
from dataclasses import dataclass
from datetime import date

from ledger.errors import InvalidAmountError, InvalidBankRowError, StorageError
from ledger.money import parse_amount

HEADER: list[str] = ["date", "description", "amount"]


@dataclass(frozen=True)
class BankRow:
    on: date
    description: str
    amount: int


def _parse_row(number: int, row: list[str]) -> BankRow:
    if len(row) != len(HEADER):
        raise InvalidBankRowError(f"row {number}: expected three fields")
    try:
        on = date.fromisoformat(row[0])
    except ValueError as exc:
        raise InvalidBankRowError(f"row {number}: {exc}") from exc
    amount = parse_amount(row[2])
    if amount == 0:
        raise InvalidAmountError(f"row {number}: zero amount")
    return BankRow(on, row[1], amount)


def read_bank_csv(path: str) -> list[BankRow]:
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            rows = list(csv.reader(handle))
    except (OSError, UnicodeDecodeError, csv.Error) as exc:
        raise StorageError(f"cannot read {path}: {exc}") from exc
    if not rows or rows[0] != HEADER:
        raise StorageError(f"bad header in {path}")
    return [_parse_row(number, row) for number, row in enumerate(rows[1:], start=2)]
