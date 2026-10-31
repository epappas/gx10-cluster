"""Error types for the ledger package."""


class LedgerError(Exception):
    """Base class; `code` identifies the failure."""

    code: str = "ledger_error"


class InvalidAmountError(LedgerError):
    code = "invalid_amount"


class InvalidRateError(LedgerError):
    code = "invalid_rate"


class InvalidAllocationError(LedgerError):
    code = "invalid_allocation"


class InvalidTransactionError(LedgerError):
    code = "invalid_transaction"


class InvalidReversalError(LedgerError):
    code = "invalid_reversal"


class InvalidPeriodError(LedgerError):
    code = "invalid_period"


class ClosedPeriodError(LedgerError):
    code = "closed_period"


class InvalidAccountError(LedgerError):
    code = "invalid_account"


class AccountKindError(LedgerError):
    code = "wrong_account_kind"


class UnknownAccountError(LedgerError):
    code = "unknown_account"


class UnknownTransactionError(LedgerError):
    code = "unknown_transaction"


class DuplicateAccountError(LedgerError):
    code = "duplicate_account"


class InvalidInvoiceError(LedgerError):
    code = "invalid_invoice"


class UnknownInvoiceError(LedgerError):
    code = "unknown_invoice"


class InvalidLimitError(LedgerError):
    code = "invalid_limit"


class InvalidBankRowError(LedgerError):
    code = "invalid_bank_row"


class StorageError(LedgerError):
    code = "storage_failed"
