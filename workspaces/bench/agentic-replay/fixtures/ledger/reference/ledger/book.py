"""The Ledger: accounts, transactions, invoices and the audit trail."""

from collections.abc import Iterable
from dataclasses import dataclass, replace
from datetime import date, datetime

from ledger.accounts import Account, AccountKind
from ledger.bank import BankRow, read_bank_csv
from ledger.clock import Clock, system_clock
from ledger.errors import (
    AccountKindError,
    ClosedPeriodError,
    DuplicateAccountError,
    InvalidAccountError,
    InvalidAmountError,
    InvalidInvoiceError,
    InvalidPeriodError,
    InvalidReversalError,
    InvalidTransactionError,
    UnknownAccountError,
    UnknownInvoiceError,
    UnknownTransactionError,
)
from ledger.invoices import Invoice
from ledger.money import percent_of, require_cents
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
        self.closed_through: date | None = None
        self.invoices: dict[int, Invoice] = {}

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
        txn = self._commit(on, memo, postings)
        self._record("post", f"transaction {txn.id}")
        return txn

    def reverse(self, txn_id: int, on: date, memo: str | None = None) -> Transaction:
        txn = self._reverse(txn_id, on, memo)
        self._record("reverse", f"transaction {txn_id}")
        return txn

    def is_reversed(self, txn_id: int) -> bool:
        self.transaction(txn_id)
        return any(txn.reverses == txn_id for txn in self.transactions)

    def close_period(self, through: date) -> None:
        if not isinstance(through, date) or through >= self._today():
            raise InvalidPeriodError(f"period has not ended: {through!r}")
        if self.closed_through is not None and through <= self.closed_through:
            raise InvalidPeriodError(f"already closed through {self.closed_through}")
        self.closed_through = through
        self._record("close_period", through.isoformat())

    def issue_invoice(self, customer: str, income: str, amount: int, due: date) -> Invoice:
        self._require_kind(customer, AccountKind.ASSET)
        self._require_kind(income, AccountKind.INCOME)
        if require_cents(amount) <= 0:
            raise InvalidAmountError(f"invoice amount must be positive: {amount}")
        today = self._today()
        if not isinstance(due, date) or due < today:
            raise InvalidInvoiceError(f"bad due date: {due!r}")
        invoice_id = len(self.invoices) + 1
        lines = [Posting(customer, amount), Posting(income, -amount)]
        txn = self._commit(today, f"invoice {invoice_id}", lines)
        invoice = Invoice(invoice_id, customer, income, amount, today, due, txn.id)
        self.invoices[invoice_id] = invoice
        self._record("issue_invoice", f"invoice {invoice_id}")
        return invoice

    def pay_invoice(self, invoice_id: int, cash: str) -> Invoice:
        invoice = self._open_invoice(invoice_id)
        self._require_kind(cash, AccountKind.ASSET)
        today = self._today()
        lines = [Posting(cash, invoice.owed), Posting(invoice.customer, -invoice.owed)]
        self._commit(today, f"payment of invoice {invoice_id}", lines)
        paid = replace(invoice, paid_on=today)
        self.invoices[invoice_id] = paid
        self._record("pay_invoice", f"invoice {invoice_id}")
        return paid

    def void_invoice(self, invoice_id: int) -> Invoice:
        invoice = self._open_invoice(invoice_id)
        today = self._today()
        self._reverse(invoice.txn_id, today, None)
        if invoice.fee_txn_id is not None:
            self._reverse(invoice.fee_txn_id, today, None)
        voided = replace(invoice, voided=True)
        self.invoices[invoice_id] = voided
        self._record("void_invoice", f"invoice {invoice_id}")
        return voided

    def assess_late_fees(self, rate_bp: int, income: str) -> list[Invoice]:
        self._require_kind(income, AccountKind.INCOME)
        percent_of(0, rate_bp)
        today = self._today()
        self._check_open(today)
        charged: list[Invoice] = []
        for invoice in sorted(self.invoices.values(), key=lambda i: (i.due, i.id)):
            fee = percent_of(invoice.amount, rate_bp)
            if invoice.is_open and invoice.due < today and invoice.late_fee == 0 and fee:
                charged.append(self._charge_fee(invoice, income, fee, today))
        if charged:
            self._record("assess_late_fees", f"{len(charged)} invoices")
        return charged

    def import_bank_csv(self, path: str, cash: str, suspense: str) -> list[Transaction]:
        self.account(cash)
        self.account(suspense)
        rows = read_bank_csv(path)
        for row in rows:
            self._check_open(row.on)
        created = [self._commit_bank_row(row, cash, suspense) for row in rows]
        if created:
            self._record("import_bank_csv", f"{len(created)} rows")
        return sorted(created, key=lambda txn: (txn.on, txn.id))

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

    def _today(self) -> date:
        return self.clock().date()

    def _record(self, action: str, detail: str) -> None:
        self.audit.append(AuditEvent(action, self.clock(), detail))

    def _check_open(self, on: date) -> None:
        if self.closed_through is not None and on <= self.closed_through:
            raise ClosedPeriodError(f"{on} is closed")

    def _require_kind(self, name: str, kind: AccountKind) -> None:
        if self.account(name).kind is not kind:
            raise AccountKindError(f"{name} is not {kind.value}")

    def _open_invoice(self, invoice_id: int) -> Invoice:
        if invoice_id not in self.invoices:
            raise UnknownInvoiceError(str(invoice_id))
        invoice = self.invoices[invoice_id]
        if not invoice.is_open:
            raise InvalidInvoiceError(f"invoice {invoice_id} is not open")
        return invoice

    def _commit(
        self,
        on: date,
        memo: str,
        postings: Iterable[Posting],
        reverses: int | None = None,
    ) -> Transaction:
        """Validate and append a transaction without an audit event."""
        if not isinstance(on, date):
            raise InvalidTransactionError(f"bad date: {on!r}")
        self._check_open(on)
        lines = validate_postings(postings)
        for line in lines:
            self.account(line.account)
        txn = Transaction(len(self.transactions) + 1, on, memo, lines, reverses)
        self.transactions.append(txn)
        return txn

    def _reverse(self, txn_id: int, on: date, memo: str | None) -> Transaction:
        original = self.transaction(txn_id)
        if original.reverses is not None or self.is_reversed(txn_id):
            raise InvalidReversalError(f"transaction {txn_id} cannot be reversed")
        if not isinstance(on, date) or on < original.on:
            raise InvalidReversalError(f"bad reversal date: {on!r}")
        lines = [Posting(p.account, -p.amount) for p in original.postings]
        text = f"reversal of {txn_id}" if memo is None else memo
        return self._commit(on, text, lines, txn_id)

    def _charge_fee(self, invoice: Invoice, income: str, fee: int, on: date) -> Invoice:
        lines = [Posting(invoice.customer, fee), Posting(income, -fee)]
        txn = self._commit(on, f"late fee invoice {invoice.id}", lines)
        updated = replace(invoice, late_fee=fee, fee_txn_id=txn.id)
        self.invoices[invoice.id] = updated
        return updated

    def _commit_bank_row(self, row: BankRow, cash: str, suspense: str) -> Transaction:
        lines = [Posting(cash, row.amount), Posting(suspense, -row.amount)]
        return self._commit(row.on, row.description, lines)
