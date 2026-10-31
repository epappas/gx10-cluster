"""Chart of accounts types."""

from dataclasses import dataclass
from enum import Enum


class AccountKind(str, Enum):
    ASSET = "asset"
    LIABILITY = "liability"
    EQUITY = "equity"
    INCOME = "income"
    EXPENSE = "expense"


@dataclass(frozen=True)
class Account:
    name: str
    kind: AccountKind
