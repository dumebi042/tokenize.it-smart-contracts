# Changelog

## Unreleased

### New contract: `CoinvestedPosition`

`CoinvestedPosition` is a new contract that holds tokens on behalf of a co-investor and sells them at a
configurable price, distributing the proceeds between the co-investor (the *receiver*) and one or more
lead investors according to their *carry fractions*.

**Key mechanics:**

- **Base price:** A EURO-denominated reference price (expressed in the smallest subunit of any EURO
  currency, i.e. `TRUSTED_CURRENCY | EURO_CURRENCY` bits set) recorded at initialization and locked
  to the decimals of the initialization currency. After fees, the receiver is entitled to `basePrice`
  per token; any excess is distributed as carry.
- **Carry:** The surplus above `basePrice` (after fees) is split among lead investors proportionally by
  their `carryFraction` (encoded as a fraction of `uint64.max`). Rounding dust goes to the receiver.
  If the sale price net of fees does not cover `basePrice`, all proceeds go to the receiver.
- **Balance sweep pattern:** Rather than computing and transferring dust explicitly, all three
  distribution paths (`buy`, `distributeDividends`, `distributeExit`) call `_distributeCarry` for lead
  investor shares only, then sweep the contract's full remaining balance of the relevant currency to
  `receiver`. This means any balance of that currency already sitting in the contract (e.g. from an
  accidental direct transfer) is swept to `receiver` at the same time. The `before`/`received` delta in
  `distributeDividends` and `distributeExit` ensures lead investors are always paid carry on the
  legitimately received amount only — a pre-existing balance does not inflate their share.
- **Dividends:** `distributeDividends(IDistribution, IERC20)` — owner claims from a `Distribution`
  contract and distributes the received amount fully as carry among lead investors (receiver gets
  rounding dust). Any EURO token may be used.
- **Exit:** `distributeExit(IExit, IERC20)` — owner sends the contract's full token balance to an
  `Exit` contract and splits the proceeds: receiver gets `basePrice` per token (scaled to the exit
  currency's decimals), remainder is carry. Any EURO token may be used.
- **Currency flexibility:** `buy()` uses the currency fixed at initialization; `distributeDividends`
  and `distributeExit` accept any EURO token (verified via the `TRUSTED_CURRENCY | EURO_CURRENCY`
  bitmask), enabling payouts in a different stablecoin than the one used for secondary-market sales.
- **Clone/proxy pattern:** Constructor disables initializers; `initialize()` sets all state. Starts
  paused — owner must set a price and unpause before `buy()` is available.
- **Clone factory:** `CoinvestedPositionCloneFactory` deploys deterministic clones from a single
  implementation using `CREATE2` (salt derived from all initialization parameters).

**New interfaces added:** `IDistribution` (`claim(address)`) and `IExit` (`claim(uint256, address)`)
allow `CoinvestedPosition` to interact with `Distribution` and `Exit` contracts without circular
imports.

---

### New contract: `TokenSwapBase`

Shared logic previously duplicated across `TokenSwap` and `CoinvestedPosition` has been extracted into
`TokenSwapBase`, an abstract upgradeable base contract.

**Extracted shared state and logic:**
- Storage variables: `tokenPrice`, `currency`, `token`, `receiver`
- Initialization: `_initializeBase(owner, tokenPrice, currency, token, receiver)` — validates inputs
  and calls `TRUSTED_CURRENCY` bitmask check
- Fee handling: `_getFeeAndFeeReceiver(currencyAmount)` — queries `token.feeSettings()`
- Price management: `setTokenPrice()`, `setReceiver()`
- Pause controls: `pause()`, `unpause()` (unpause requires non-zero `tokenPrice`)
- ERC-2771 meta-transaction overrides: `_msgSender()`, `_msgData()`, `_contextSuffixLength()`

`TokenSwap` has been refactored to extend `TokenSwapBase`, removing the previously duplicated code.
`CoinvestedPosition` also extends `TokenSwapBase`.

---

### New contract: `Distribution`

`Distribution` distributes a fixed pool of currency among token holders proportional to their balance
at a specified snapshot, using `Token.balanceOfAt` / `Token.totalSupplyAt`.

**Key features:**
- Initialized with: `token`, `owner`, `snapshotId`, `currency`, `totalCurrencyAmount`,
  `reassignAfter`. The factory transfers currency into the clone before calling `initialize()`, which
  verifies the balance.
- `eligible(address)` returns the claimable amount for a holder (snapshot share + extra credit - paid
  out).
- `claim(address recipient)` — direct claim by the holder.
- `claim(IERC1271, bytes32, bytes, address)` — claim on behalf of a smart-contract holder (ERC-1271
  signature).
- `claim(Vesting, address)` — claim on behalf of a lockup/vesting contract (caller must be the
  beneficiary).
- `reassign(address from, address to)` — `onlyOwner`, available only after `reassignAfter` timestamp
  (minimum 30 days after deployment). Moves unclaimed balance from one address to another, emitting
  `Reassigned`. Intended for recovery cases (lost key, `CoinvestedPosition` currency mismatch, etc.).
- Clone factory: `DistributionCloneFactory` — deploys a clone, transfers currency from
  `_currencyProvider` in a single atomic transaction, then initializes. Address is deterministic from
  all parameters except `_currencyProvider`.

---

### New contract: `Exit`

`Exit` allows token holders to redeem their tokens for a fixed currency payout within a 3-year window
after the exit date.

**Key features:**
- Initialized with: `token`, `owner`, `currency`, `pricePerToken`, `exitDate`,
  `totalCurrencyAmount`. Factory verifies pre-funded balance.
- `claim(uint256 tokenAmount, address recipient)` — pulls tokens from caller (requires ERC-20
  approval), sends `tokenAmount * pricePerToken / 10**token.decimals()` currency to `recipient`.
  Accepted only between `exitDate` and `exitDate + EXIT_WINDOW` (3 years).
- ERC-1271 and Vesting overloads (same pattern as `Distribution`).
- Received tokens are held in the contract (not burned).
- Clone factory: `ExitCloneFactory` — same atomic clone + fund + initialize pattern as
  `DistributionCloneFactory`.

---

### New constant: `EURO_CURRENCY` in `AllowList`

`uint256 constant EURO_CURRENCY = 2 ** 254` (bit 254) has been added alongside the existing
`TRUSTED_CURRENCY` (bit 255). It marks a currency address as Euro-denominated and is required by
`CoinvestedPosition` for its buy currency and for all dividend / exit currencies.

The `AllowList` NatSpec has been updated to document the two-bit scheme and to clarify that bitmask
checks (not equality) should be used.

---

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
