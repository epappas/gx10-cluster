import unittest

from ledger.errors import InvalidAmountError
from ledger.money import format_cents, parse_amount, require_cents


class MoneyTests(unittest.TestCase):
    def test_parse(self) -> None:
        self.assertEqual(parse_amount("12.30"), 1230)
        self.assertEqual(parse_amount("-4"), -400)
        self.assertEqual(parse_amount(" 0.5 "), 50)

    def test_parse_rejects_bad_text(self) -> None:
        for text in ("", "abc", "1.234", "1,000", "--1"):
            with self.assertRaises(InvalidAmountError):
                parse_amount(text)

    def test_format(self) -> None:
        self.assertEqual(format_cents(1230), "12.30")
        self.assertEqual(format_cents(-5), "-0.05")

    def test_require_cents(self) -> None:
        self.assertEqual(require_cents(7), 7)
        for value in (1.5, True, "7", None):
            with self.assertRaises(InvalidAmountError):
                require_cents(value)
