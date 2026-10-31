"""Parsing, formatting, validation and arithmetic of amounts."""

import re

from ledger.errors import InvalidAllocationError, InvalidAmountError, InvalidRateError

_AMOUNT = re.compile(r"(-?)(\d+)(?:\.(\d{1,2}))?")
_BASIS: int = 10000


def require_cents(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidAmountError(f"bad amount: {value!r}")
    return value


def parse_amount(text: str) -> int:
    """Parse decimal text such as "12.30" or "-4"."""
    if not isinstance(text, str):
        raise InvalidAmountError(f"not text: {text!r}")
    match = _AMOUNT.fullmatch(text.strip())
    if match is None:
        raise InvalidAmountError(f"bad amount: {text!r}")
    sign, whole, fraction = match.groups()
    cents = int(whole) * 100 + int((fraction or "").ljust(2, "0"))
    return -cents if sign else cents


def format_cents(cents: int) -> str:
    """Render an amount as decimal text such as "-12.30"."""
    require_cents(cents)
    whole, fraction = divmod(abs(cents), 100)
    sign = "-" if cents < 0 else ""
    return f"{sign}{whole}.{fraction:02d}"


def _is_natural(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def percent_of(amount: int, basis_points: int) -> int:
    require_cents(amount)
    if not _is_natural(basis_points):
        raise InvalidRateError(f"bad rate: {basis_points!r}")
    magnitude = (abs(amount) * basis_points * 2 + _BASIS) // (2 * _BASIS)
    return -magnitude if amount < 0 else magnitude


def allocate(amount: int, weights: list[int]) -> list[int]:
    require_cents(amount)
    if not weights or not all(_is_natural(w) for w in weights) or sum(weights) == 0:
        raise InvalidAllocationError(f"bad weights: {weights!r}")
    total = sum(weights)
    magnitude = abs(amount)
    shares = [magnitude * weight // total for weight in weights]
    remainders = [magnitude * weight % total for weight in weights]
    ranked = sorted(range(len(weights)), key=lambda i: (-remainders[i], i))
    for index in ranked[: magnitude - sum(shares)]:
        shares[index] += 1
    return [-share if amount < 0 else share for share in shares]
