"""Error types for the ledger package."""


class LedgerError(Exception):
    """Base class; `code` identifies the failure."""

    code: str = "ledger_error"


class InvalidAmountError(LedgerError):
    code = "invalid_amount"


class InvalidTransactionError(LedgerError):
    code = "invalid_transaction"


class InvalidAccountError(LedgerError):
    code = "invalid_account"


class UnknownAccountError(LedgerError):
    code = "unknown_account"


class UnknownTransactionError(LedgerError):
    code = "unknown_transaction"


class DuplicateAccountError(LedgerError):
    code = "duplicate_account"


class StorageError(LedgerError):
    code = "storage_failed"
