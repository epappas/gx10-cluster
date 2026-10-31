# ledger

A small double-entry bookkeeping library in pure Python 3 (standard library only).

- `ledger/book.py`: the `Ledger` class: accounts, transactions, balances.
- `ledger/transactions.py`: postings and transactions. A debit is a positive amount.
- `ledger/money.py`: parsing and formatting of amounts.
- `ledger/reports.py`: account statement and trial balance.
- `ledger/storage.py`: saving to and loading from a JSON file.

```python
from datetime import date
from ledger.accounts import AccountKind
from ledger.book import Ledger
from ledger.transactions import Posting

book = Ledger()
book.open_account("cash", AccountKind.ASSET)
book.open_account("sales", AccountKind.INCOME)
book.post(date(2031, 1, 5), "first sale", [Posting("cash", 1250), Posting("sales", -1250)])
print(book.balance("cash"))
```

Run the tests with `python3 -m unittest discover -s tests`.
