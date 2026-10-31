"""CSV exports of reports."""

import csv
import io
from collections.abc import Iterable, Sequence

from ledger.book import Ledger
from ledger.money import format_cents
from ledger.reports import account_statement, aging
from ledger.storage import atomic_write


def _render(header: Sequence[str], rows: Iterable[Sequence[object]]) -> str:
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(header)
    writer.writerows(rows)
    return buffer.getvalue()


def export_statement_csv(ledger: Ledger, name: str, path: str) -> int:
    lines = account_statement(ledger, name)
    rows = [
        (x.on.isoformat(), x.txn_id, x.memo, format_cents(x.amount), format_cents(x.balance))
        for x in lines
    ]
    atomic_write(path, _render(("date", "txn_id", "memo", "amount", "balance"), rows))
    return len(rows)


def export_aging_csv(ledger: Ledger, path: str) -> int:
    header = ("customer", "current", "days_1_30", "days_31_60", "days_over_60", "total")
    rows = [
        (
            row.customer,
            format_cents(row.current),
            format_cents(row.days_1_30),
            format_cents(row.days_31_60),
            format_cents(row.days_over_60),
            format_cents(row.total),
        )
        for row in aging(ledger)
    ]
    atomic_write(path, _render(header, rows))
    return len(rows)
