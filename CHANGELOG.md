# Changelog

## Unreleased

### Breaking change: `TRUSTED_CURRENCY` allowList check relaxed from equality to bitmask

**Affected contracts:** `Crowdinvesting`, `Distribution`, `Exit`, `PrivateOffer`, `TokenSwapBase`

Previously, every contract that validated a currency address checked for *exact equality*:

```solidity
token.allowList().map(address(_currency)) == TRUSTED_CURRENCY
```

This meant a currency address could only have the single `TRUSTED_CURRENCY` bit (bit 255) set —
any other bit being set caused the check to fail.

The check has been changed to a bitmask:

```solidity
token.allowList().map(address(_currency)) & TRUSTED_CURRENCY == TRUSTED_CURRENCY
```

This allows currency addresses to carry additional classification bits (e.g. `EURO_CURRENCY`,
bit 254) alongside `TRUSTED_CURRENCY` without being rejected.

**Why:** The new `CoinvestedPosition` contract stores its base price as a EURO reference value
and requires currencies to be identified as Euro-denominated via `TRUSTED_CURRENCY | EURO_CURRENCY`.
The old equality check made it impossible to register a currency with both bits set, blocking
the entire EURO currency classification scheme.

**Impact on existing deployments:** Currencies already registered with exactly `TRUSTED_CURRENCY`
continue to work unchanged. The change only *widens* the accepted set — it does not invalidate
any previously valid currency. However, operators of the AllowList should be aware that assigning
additional bits to a currency address (e.g. adding `EURO_CURRENCY`) no longer disqualifies it
from being used as a payment currency.

**Test update:** `testInvalidCurrency` in `PrivateOffer.t.sol` had its fuzz assumption tightened
from `_attributes != TRUSTED_CURRENCY` to `_attributes & TRUSTED_CURRENCY != TRUSTED_CURRENCY`,
so that fuzzed values with `TRUSTED_CURRENCY` set (including `TRUSTED_CURRENCY | EURO_CURRENCY`)
are no longer treated as invalid inputs.
