import unittest
from collections.abc import Callable
from typing import Any

from ledger.errors import InvalidAmountError, LedgerError
from ledger.money import allocate, percent_of


def rejected(case: unittest.TestCase, call: Callable[..., Any], *args: Any) -> LedgerError:
    with case.assertRaises(LedgerError) as ctx:
        call(*args)
    error = ctx.exception
    case.assertIsNot(type(error), LedgerError)
    case.assertRegex(error.code, r"^[a-z][a-z0-9_]*$")
    case.assertNotEqual(error.code, LedgerError.code)
    return error


class PercentOfTests(unittest.TestCase):
    def test_exact_values(self) -> None:
        self.assertEqual(percent_of(10000, 250), 250)
        self.assertEqual(percent_of(1999, 10000), 1999)
        self.assertEqual(percent_of(1999, 0), 0)

    def test_result_is_int(self) -> None:
        self.assertIs(type(percent_of(10000, 250)), int)

    def test_half_goes_up(self) -> None:
        self.assertEqual(percent_of(25, 5000), 13)
        self.assertEqual(percent_of(1, 5000), 1)
        self.assertEqual(percent_of(50, 500), 3)

    def test_half_goes_away_from_zero_when_negative(self) -> None:
        self.assertEqual(percent_of(-25, 5000), -13)
        self.assertEqual(percent_of(-1, 5000), -1)

    def test_below_half_goes_down(self) -> None:
        self.assertEqual(percent_of(49, 500), 2)
        self.assertEqual(percent_of(-49, 500), -2)

    def test_huge_amount_stays_exact(self) -> None:
        self.assertEqual(percent_of(10**18 + 1, 10000), 10**18 + 1)
        self.assertEqual(percent_of(10**18 + 3, 5000), 5 * 10**17 + 2)

    def test_rejects_non_cents_amount(self) -> None:
        for amount in (1.5, 100.0, True, "100", None):
            with self.assertRaises(InvalidAmountError):
                percent_of(amount, 100)

    def test_rejects_bad_rate(self) -> None:
        for rate in (12.5, -1, True, "100", None):
            rejected(self, percent_of, 100, rate)


class AllocateTests(unittest.TestCase):
    def test_even_split(self) -> None:
        self.assertEqual(allocate(90, [1, 1, 1]), [30, 30, 30])

    def test_leftover_goes_to_earlier_on_tie(self) -> None:
        self.assertEqual(allocate(100, [1, 1, 1]), [34, 33, 33])
        self.assertEqual(allocate(5, [1, 1, 1, 1, 1, 1]), [1, 1, 1, 1, 1, 0])

    def test_largest_remainder_wins(self) -> None:
        self.assertEqual(allocate(101, [1, 2]), [34, 67])
        self.assertEqual(allocate(100, [1, 2, 3]), [17, 33, 50])

    def test_zero_weight_gets_nothing(self) -> None:
        self.assertEqual(allocate(7, [0, 1, 0, 1]), [0, 4, 0, 3])

    def test_negative_amount_mirrors_positive(self) -> None:
        self.assertEqual(allocate(-100, [1, 1, 1]), [-34, -33, -33])

    def test_huge_amount_stays_exact(self) -> None:
        amount = 10**18 + 1
        self.assertEqual(allocate(amount, [1, 1]), [5 * 10**17 + 1, 5 * 10**17])

    def test_shares_are_ints_and_sum_exactly(self) -> None:
        shares = allocate(9999, [3, 7, 11, 13])
        self.assertEqual(sum(shares), 9999)
        self.assertTrue(all(type(share) is int for share in shares))

    def test_rejects_non_cents_amount(self) -> None:
        with self.assertRaises(InvalidAmountError):
            allocate(10.5, [1, 1])

    def test_rejects_bad_weights(self) -> None:
        for weights in ([], [0, 0], [1, -1], [1.5, 1], [True, 1]):
            rejected(self, allocate, 100, weights)
