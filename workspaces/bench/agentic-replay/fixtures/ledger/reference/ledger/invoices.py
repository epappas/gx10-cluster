"""Customer invoices."""

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class Invoice:
    id: int
    customer: str
    income: str
    amount: int
    issued: date
    due: date
    txn_id: int
    paid_on: date | None = None
    voided: bool = False
    late_fee: int = 0
    fee_txn_id: int | None = None

    @property
    def is_open(self) -> bool:
        return self.paid_on is None and not self.voided

    @property
    def owed(self) -> int:
        return self.amount + self.late_fee
