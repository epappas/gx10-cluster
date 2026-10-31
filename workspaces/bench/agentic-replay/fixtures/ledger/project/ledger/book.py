"""The Ledger: accounts, transactions and the audit trail."""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date, datetime

from ledger.accounts import Account, AccountKind
from ledger.clock import Clock, system_clock
from ledger.errors import (
    DuplicateAccountError,
    InvalidAccountError,
    InvalidTransactionError,
    UnknownAccountError,
    UnknownTransactionError,
)
from ledger.transactions import Posting, Transaction, validate_postings


@dataclass(frozen=True)
class AuditEvent:
    action: str
    at: datetime
    detail: str


class Ledger:
    def __init__(self, clock: Clock = system_clock) -> None:
        self.clock = clock
        self.accounts: dict[str, Account] = {}
        self.transactions: list[Transaction] = []
        self.audit: list[AuditEvent] = []

    def open_account(self, name: str, kind: AccountKind) -> Account:
        if not isinstance(name, str) or not name:
            raise InvalidAccountError(f"bad account name: {name!r}")
        if name in self.accounts:
            raise DuplicateAccountError(name)
        account = Account(name, AccountKind(kind))
        self.accounts[name] = account
        self._record("open_account", name)
        return account

    def account(self, name: str) -> Account:
        if name not in self.accounts:
            raise UnknownAccountError(name)
        return self.accounts[name]

    def post(self, on: date, memo: str, postings: Iterable[Posting]) -> Transaction:
        if not isinstance(on, date):
            raise InvalidTransactionError(f"bad date: {on!r}")
        lines = validate_postings(postings)
        for line in lines:
            self.account(line.account)
        txn = Transaction(len(self.transactions) + 1, on, memo, lines)
        self.transactions.append(txn)
        self._record("post", f"transaction {txn.id}")
        return txn

    def transaction(self, txn_id: int) -> Transaction:
        for txn in self.transactions:
            if txn.id == txn_id:
                return txn
        raise UnknownTransactionError(str(txn_id))

    def balance(self, name: str) -> int:
        self.account(name)
        return sum(
            line.amount
            for txn in self.transactions
            for line in txn.postings
            if line.account == name
        )

    def transactions_for(self, name: str) -> list[Transaction]:
        self.account(name)
        found = [
            txn
            for txn in self.transactions
            if any(line.account == name for line in txn.postings)
        ]
        return sorted(found, key=lambda txn: (txn.on, txn.id))

    def _record(self, action: str, detail: str) -> None:
        self.audit.append(AuditEvent(action, self.clock(), detail))
