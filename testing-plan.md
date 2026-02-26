# Testing Plan

## Status
- [ ] = not yet written
- [x] = implemented

---

# Distribution.sol

## D1. Constructor / Logic Contract

- [ ] Logic contract's `initialize()` reverts (initializers disabled)
- [ ] Calling `initialize()` a second time reverts

---

## D2. `initialize()` — Validation & State

**Deployment flow note:** `_currencyProvider` must approve the clone address (via `predictCloneAddress()`)
before calling `createDistributionClone()`. Only `TRUSTED_CURRENCY` is required (not `EURO_CURRENCY`).

- [ ] `_reassignAfter < block.timestamp + 30 days` → reverts
- [ ] `_reassignAfter == block.timestamp + 30 days` → accepted (boundary)
- [ ] Non-trusted currency (missing `TRUSTED_CURRENCY` bit) → reverts
- [ ] `_currencyProvider` has insufficient allowance to clone address → reverts
- [ ] Correct allowance → succeeds; all state variables set correctly (token, snapshotId, totalTokenAmount, currency, totalCurrencyAmount, reassignAfter)
- [ ] `totalTokenAmount` equals `token.totalSupplyAt(snapshotId)` (set from the snapshot, not a parameter)
- [ ] After init, clone holds exactly `_totalCurrencyAmount` of currency

---

## D3. `eligible()` — Math

The formula is: `(totalCurrencyAmount * balanceOfAt(_holder, snapshotId)) / totalTokenAmount + extraCredit[_holder] - paidOut[_holder]`

### Concrete fixed-value example

```
totalCurrencyAmount = 1,000e6 (USDC, 6 dec)
totalTokenAmount    = 1000e18 (1000 Tokens)

Holder A: 600e18 tokens → eligible = (1,000e6 * 600e18) / 1000e18 = 600e6
Holder B: 300e18 tokens → eligible = 300e6
Holder C: 100e18 tokens → eligible = 100e6
Holder D:   0 tokens    → eligible = 0

Sum of eligible = 1,000e6 == totalCurrencyAmount (no rounding dust in this example)
```

- [ ] Each holder's eligible matches the formula above
- [ ] Holder with 0 snapshot balance → eligible = 0
- [ ] Holder not in snapshot at all → eligible = 0

### Rounding / dust

```
totalCurrencyAmount = 10 (10 bits of currency)
totalTokenAmount    = 3e18

Holder A: 1e18 tokens → eligible = floor(10 * 1e18 / 3e18) = floor(3.33) = 3
Holder B: 1e18 tokens → eligible = 3
Holder C: 1e18 tokens → eligible = 3
Sum = 9, but totalCurrencyAmount = 10 → 1 bit of dust permanently locked in contract
```

- [ ] Sum of all eligible amounts ≤ `totalCurrencyAmount` (integer division truncates)
- [ ] Rounding dust stays locked in the contract (no drain function exists)
- [ ] Fuzz: random totalCurrencyAmount and balances → sum of all eligible never exceeds totalCurrencyAmount

---

## D4. `claim(address)` — Direct Claim

- [ ] Correct currency amount transferred to `_recipient`
- [ ] `paidOut[holder]` updated; `eligible(holder)` becomes 0 after claim
- [ ] **Second claim immediately after first: transfers 0, does not revert** (eligible = 0, safeTransfer(0) succeeds)
- [ ] `_recipient` differs from `_msgSender` → currency goes to `_recipient`, not caller
- [ ] Multiple holders claim in sequence; each receives their correct share independently
- [ ] ERC2771: claim via trusted forwarder correctly identifies holder as `_msgSender`

---

## D5. `claim(IERC1271, ...)` — ERC1271 Signature Claim

- [ ] Valid signature → tokens credited to `_holder` (the ERC1271 contract), currency sent to `_recipient`
- [ ] Invalid signature (wrong magic value) → reverts
- [ ] `_recipient` differs from `_holder` → currency goes to `_recipient`
- [ ] After claim, `eligible(_holder)` = 0; second claim transfers 0

---

## D6. `claim(Vesting, ...)` — Vesting / Lockup Claim

- [ ] `_msgSender` is `_holder.beneficiary(0)` → succeeds; `eligible(_holder)` debited, currency sent to `_recipient`
- [ ] `_msgSender` is not the beneficiary → reverts
- [ ] Currency sent to `_recipient`, not to the Vesting contract

---

## D7. `reassign()`

### Access and timing
- [ ] Non-owner → reverts
- [ ] Before `reassignAfter` → reverts ("reassignment not yet available")
- [ ] At exactly `reassignAfter` (boundary) → succeeds
- [ ] `eligible(_from) == 0` → reverts ("nothing to reassign")

### Effect on state — concrete example

```
Holder A: 600e6 eligible (from snapshot balance), has not claimed
Owner calls reassign(A, B) after reassignAfter

After:
  paidOut[A]     += 600e6  → eligible(A) = 0
  extraCredit[B] += 600e6  → eligible(B) = own_share + 600e6
  Reassigned event emitted with (A, B, 600e6)
```

- [ ] `eligible(_from)` = 0 after reassign
- [ ] `eligible(_to)` = previous eligible + reassigned amount
- [ ] `Reassigned(from, to, amount)` event emitted with correct values

### Stacking: reassign to an address with its own snapshot balance

```
Holder B has 300e6 own eligible. A's 600e6 is reassigned to B.
eligible(B) = 300e6 + 600e6 = 900e6
B claims → receives 900e6
```

- [ ] B receives own share + reassigned amount in a single claim

### Multiple reassigns to the same recipient

`extraCredit` is additive — each reassign to the same address appends to it.

```
A has own_share_A. B has own_share_B. C has own_share_C.

reassign(B, A): extraCredit[A] += own_share_B → eligible(A) = own_share_A + own_share_B
reassign(C, A): extraCredit[A] += own_share_C → eligible(A) = own_share_A + own_share_B + own_share_C

A claims → receives own_share_A + own_share_B + own_share_C
```

- [ ] eligible(A) after both reassigns equals sum of all three shares
- [ ] A's single claim pays out the full stacked amount
- [ ] B and C each have eligible = 0 and payout = 0

### Chained reassignment: A → B → C

`extraCredit` is a plain accumulator, so a reassigned amount can itself be reassigned onward.

**Case 1: B has no snapshot balance (clean chain)**
```
eligible(A) = 5 EURe, eligible(B) = 0

reassign(A, B): extraCredit[B] = 5 → eligible(B) = 5
reassign(B, C): extraCredit[C] += 5 → eligible(B) = 0, eligible(C) = own_share_C + 5
C claims → receives own_share_C + 5
```
- [ ] eligible(B) = 0 after second reassign
- [ ] eligible(C) = own_share_C + 5 before C's claim
- [ ] C's claim pays out own_share_C + 5; A and B both have eligible = 0

**Case 2: B has their own snapshot balance — must claim own share first**
```
eligible(A) = 5 EURe, eligible(B) = 3 EURe (own snapshot share)

reassign(A, B): eligible(B) = 3 + 5 = 8 EURe
B claims own share first: paidOut[B] += 8 → eligible(B) = 0
  (B receives all 8 EURe — own 3 + reassigned 5)

... this is not the desired chain. To pass only the 5 EURe on to C,
B must NOT have a snapshot balance (Case 1), or the owner must accept
that reassign(B, C) moves B's full eligible including their own share.
```
- [ ] If B claims before second reassign, eligible(B) = 0 → reassign(B, C) reverts
- [ ] If B does NOT claim, reassign(B, C) moves B's full eligible (own + reassigned) to C

### Other edge cases
- [ ] Reassign to `_from` itself (self-reassign): `eligible(_from)` unchanged (paidOut and extraCredit both increase by same amount)
- [ ] Second `reassign(_from, ...)` after first: eligible(_from) = 0 → reverts ("nothing to reassign")
- [ ] Reassign after `_from` has already claimed: eligible(_from) = 0 → reverts

---

## D8. Interaction: claim then reassign

```
A claims their full amount → eligible(A) = 0
Owner tries reassign(A, B) → reverts ("nothing to reassign")
```

- [ ] Confirmed: claiming before reassignAfter deadline does not prevent owner from knowing the amount was claimed (it's auditable via `paidOut[A]`), but reassign correctly rejects since nothing remains

---

## D9. Interaction: reassign then claim by recipient

```
Owner reassigns A → B (after deadline)
B claims → receives own_share + A's reassigned amount
A claims → receives 0 (paidOut[A] covers their share)
```

- [ ] B's claim pays out the full stacked amount
- [ ] A's claim pays 0 (no double-payment)
- [ ] Sum of all payouts ≤ totalCurrencyAmount

---

## D10. Fuzz / Property-Based Tests

- [ ] Fuzz: random `totalCurrencyAmount`, random holder balances at snapshot → verify:
  - `sum(eligible(all holders)) ≤ totalCurrencyAmount` (always, due to truncation)
  - Each `eligible(holder) == floor(totalCurrencyAmount * balance / totalTokenAmount)`
  - After each holder claims, their eligible = 0; no double-payment
- [ ] Fuzz: random reassign sequence (including chains A→B→C and multiple reassigns to same address) → verify:
  - `sum(eligible(all addresses))` is invariant across every reassign (each reassign adds equal amounts to paidOut and extraCredit, net zero)
  - `sum(paidOut)` may grow well beyond `totalCurrencyAmount` but this causes no issue — it is an audit trail, not a liability
  - `eligible(x)` never underflows (paidOut[x] can only reach base_x + extraCredit_x)
  - sum of all actual currency transfers ≤ totalCurrencyAmount

---

## What's missing from your list

1. **`initialize()` validation** — `reassignAfter` deadline, non-trusted currency, insufficient allowance, second init
2. **`eligible()` for holder with 0 or no snapshot balance** → 0
3. **Rounding dust is permanently locked** — no drain function; sum of eligible ≤ totalCurrencyAmount
4. **Second claim transfers 0, does not revert** — the "work once" behaviour is a 0-transfer, not a revert
5. **`_recipient != _msgSender`** for all claim variants
6. **`reassign` self-reassign** edge case
7. **`reassign` when `_from` already claimed** → reverts
8. **Stacking: reassign to address with own snapshot balance**
9. **ERC2771** for `claim(address)`

---

# Exit.sol

## E1. Constructor / Logic Contract

- [ ] Logic contract's `initialize()` reverts (initializers disabled)
- [ ] Calling `initialize()` a second time reverts (initializers disabled after first call)

---

## E2. `initialize()` — Validation & State

**Deployment flow note:** `_currencyProvider` must approve the clone address (obtained via
`predictCloneAddress()`) before calling `createExitClone()`. `initialize()` pulls the funds
via `safeTransferFrom(_currencyProvider, address(this), _totalCurrencyAmount)`.

- [ ] `_pricePerToken == 0` → reverts
- [ ] `_claimStart == 0` → reverts
- [ ] `_claimEnd <= _claimStart` → reverts (including `_claimEnd == _claimStart`)
- [ ] `_currency == _token` → reverts ("currency and token must be different")
- [ ] Non-trusted currency (missing TRUSTED_CURRENCY bit) → reverts
- [ ] Trusted but non-EURO currency (missing EURO_CURRENCY bit) → reverts
- [ ] `_currencyProvider` has insufficient allowance to clone address → reverts
- [ ] Correct allowance → succeeds; all state variables set correctly (token, currency, pricePerToken, claimStart, claimEnd)
- [ ] After init, clone holds exactly `_totalCurrencyAmount` of currency

---

## E3. `claim(uint256, address)` — Direct Claim

- [ ] Claim before `claimStart` → reverts
- [ ] Claim at exactly `claimStart` (boundary) → succeeds
- [ ] Claim at exactly `claimEnd` (boundary) → succeeds
- [ ] Claim after `claimEnd` → reverts
- [ ] Tokens transferred from caller to Exit contract (not burned)
- [ ] Currency transferred to `_recipient`, not to `_msgSender` (these can differ)
- [ ] Math: `currencyAmount = (_tokenAmount * pricePerToken) / 10 ** token.decimals()` rounds down
- [ ] Claim without token approval → reverts
- [ ] Claim with zero token balance → reverts (safeTransferFrom fails)
- [ ] Multiple sequential claims by different holders reduce currency balance correctly
- [ ] Claim for more currency than contract holds → reverts

---

## E4. `claim(IERC1271, ...)` — ERC1271 Signature Claim

- [ ] Valid signature: tokens pulled from `_holder`, currency sent to `_recipient`
- [ ] Invalid signature (isValidSignature returns wrong magic value) → reverts
- [ ] `_recipient` differs from `_holder` → currency goes to `_recipient`

---

## E5. `claim(Vesting, ...)` — Vesting / Lockup Claim

- [ ] `_msgSender` is `_holder.beneficiary(0)` → succeeds; tokens pulled from Vesting contract
- [ ] `_msgSender` is not the beneficiary → reverts
- [ ] Currency sent to `_recipient`, not to the Vesting contract

---

## E6. `drain()`

- [ ] Non-owner → reverts
- [ ] Before `claimEnd` → reverts
- [ ] At exactly `claimEnd` → reverts (`> claimEnd` required)
- [ ] After `claimEnd` → succeeds; full currency balance transferred to `_recipient`
- [ ] Drain when currency balance is 0 (all already claimed) → succeeds (transfers 0, no revert)

---

## E7. Math & Rounding

- [ ] Concrete fixed-value example: 1 Token (18 dec), pricePerToken = 1.5e6 (6 dec currency)
  - `currencyAmount = (1e18 * 1.5e6) / 1e18 = 1.5e6` → floors to 1e6 (holder receives less)
- [ ] Fuzz: random tokenAmount and pricePerToken → `currencyAmount` always ≤ `tokenAmount * pricePerToken / 1e18`; never reverts for valid inputs within funded balance

---

## E8. ERC2771 / Meta-transactions

- [ ] Direct `claim()` via trusted forwarder correctly identifies holder as `_msgSender`

---

# CoinvestedPosition.sol

## 1. Constructor / Logic Contract

- [ ] Logic contract's `initialize()` reverts (initializers disabled)

---

## 2. `initialize()` — Variable Initialization & Validation

- [ ] All state variables set correctly after init (owner, receiver, currency, token, basePrice, basePriceDecimals, leadInvestors)
- [ ] `basePriceDecimals` reflects the decimals of `baseCurrency` at init time
- [ ] Non-EURO currency rejected (missing EURO_CURRENCY bit)
- [ ] Non-trusted currency rejected (missing TRUSTED_CURRENCY bit)
- [ ] Currency with only one of the two bits → rejected
- [ ] Empty `leadInvestors` array → reverts ("There must be at least one lead investor")
- [ ] Lead investor with zero address → reverts
- [ ] `carryFractionsSum == 0` → reverts ("using this contract with 0 carry fraction doesn't make sense")
- [ ] `carryFractionsSum >= type(uint64).max` → reverts ("carry fractions must leave a share for the receiver")
- [ ] `carryFractionsSum == type(uint64).max - 1` → accepted (boundary)
- [ ] Contract starts paused
- [ ] `tokenPrice` initialized to 0 (so `unpause()` requires `setTokenPrice` first)
- [ ] `getLeadInvestorsCount()` returns correct count after init
- [ ] Zero address owner → reverts (from base)
- [ ] Zero address receiver → reverts (from base)

---

## 3. `setCurrency()`

- [ ] Only owner can call; non-owner reverts
- [ ] Non-EURO currency rejected
- [ ] Non-trusted currency rejected
- [ ] Currency with only one of the two bits → rejected
- [ ] Valid EURO+trusted currency accepted and stored
- [ ] `basePriceDecimals` is NOT updated by `setCurrency()` (stays fixed from init)

---

## 4. `setTokenPrice()` / `pause()` / `unpause()` (from base)

- [ ] Only owner can call each; non-owner reverts for all three
- [ ] `unpause()` reverts when `tokenPrice == 0` (as initialized)
- [ ] `setTokenPrice(0)` reverts
- [ ] After `setTokenPrice(nonZero)`, `unpause()` succeeds
- [ ] `pause()` re-pauses an active contract; subsequent `buy()` reverts

---

## 5. `setReceiver()` (from base)

- [ ] Only owner can call; non-owner reverts
- [ ] Zero address reverts
- [ ] Correct value stored, `ReceiverChanged` event emitted

---

## 6. `buy()` — Core Logic

### Revert Cases
- [ ] Buy when paused → reverts
- [ ] `_maxCurrencyAmount` too low → reverts
- [ ] Tokens transferred to `_tokenReceiver`, not `_msgSender`
- [ ] `TokensBought` event emitted with correct values

### Fee Handling
- [ ] Zero fee: full remaining currency available for carry/coinvestor split
- [ ] Non-zero fee: fee transferred to feeCollector before carry is computed

### Same-currency, same-decimals: sell at or below base price
- [ ] Sell at exactly basePrice: carry = 0, receiver gets everything minus fee; no transfers to lead investors
- [ ] Sell below basePrice (tokenPrice < basePrice): carry = 0, receiver gets full remaining

### Same-currency, same-decimals: sell above base price — concrete fixed-value example
- [ ] Setup: 0 fee, 2 Tokens (18 dec), basePrice = 300e6, tokenPrice = 400e6, currency 6 dec
  - Paid: 800e6. Fee: 0. Remaining: 800e6. BasePayout: 600e6. Carry: 200e6.
  - leadInvestors carry fractions: 5% ≈ 9.223e17 of uint64.max, 2% ≈ 3.689e17, 10% ≈ 1.844e18
  - Lead investor payouts: 10e6, 4e6, 20e6 (verify exact amounts)
  - Receiver gets: 800e6 - 10e6 - 4e6 - 20e6 = 766e6

### Rounding
- [ ] `currencyAmount` is ceiling-rounded (buyer pays up to 1 currency bit more for fractional amounts)

---

## 7. `buy()` — Cross-currency Decimal Scaling

**Scenario A — upscaling:** basePrice set in EURc (6 dec, 100 EURc/Token); later `setCurrency` to EURe (18 dec); tokenPrice = 200e18.

- [ ] `basePriceDecimals` = 6 (unchanged by `setCurrency`)
- [ ] `scaledBasePrice` correctly scales 100e6 → 100e18 when buying
- [ ] Carry = (200e18 - 100e18) × tokenAmount / 1e18 split among lead investors
- [ ] Receiver gets correct remainder

**Scenario B — downscaling:** basePrice set in EURe (18 dec); later `setCurrency` to EURc (6 dec).

- [ ] `scaledBasePrice` correctly truncates (divides) basePriceDecimals → 6 dec
- [ ] Carry and receiver amounts correct

**Scenario C — equal decimals:** no scaling, result identical to unscaled amount.

---

## 8. `buy()` — Sequential Partial Sells

The contract starts with a token balance and sells it in multiple tranches. Between tranches the
owner may change price and/or currency. Each `buy()` is independent: carry is computed on the
spot using the current `currency` decimals and the fixed `basePriceDecimals`.

### Fixed-value example: 100 Tokens total, sold in three tranches

Setup: Token 18 dec. basePrice = 100 EURc (6 dec), so basePriceDecimals = 6.
Lead investors: A=10% carry, B=5% carry. Zero fee throughout.

**Tranche 1** — 5 Tokens, currency = EURc (6 dec), tokenPrice = 150e6 (above base)
- Paid: 750e6. scaledBasePrice = 100e6. BasePayout: 500e6. Carry: 250e6.
- A gets 25e6, B gets 12e6 (floored). Receiver gets remainder.
- Verify: contract token balance = 95 Tokens after.

**Tranche 2** — 40 Tokens, `setCurrency` to EURe (18 dec), tokenPrice = 200e18 (above base)
- Paid: 8000e18. scaledBasePrice = 100e18 (upscaled from basePriceDecimals=6). BasePayout: 4000e18. Carry: 4000e18.
- A and B get their fractional shares of 4000e18. Receiver gets remainder.
- Verify: contract token balance = 55 Tokens after.
- Verify: EURc balances from tranche 1 are unchanged (different currency, no interference).

**Tranche 3** — 55 Tokens, tokenPrice = 80e18 (below base after scaling)
- scaledBasePrice = 100e18. BasePayout would be 5500e18. Paid: 4400e18 < BasePayout → carry = 0.
- Receiver gets full 4400e18. Lead investors get nothing.
- Verify: contract token balance = 0 after.

- [ ] All three tranches execute with correct balances
- [ ] Cumulative receiver payout = sum of each tranche's receiver share
- [ ] Lead investor balances accumulate correctly across tranches in different currencies
- [ ] No cross-tranche interference (tranche 1 EURc balance unaffected by tranche 2/3 EURe operations)
- [ ] Contract token balance decreases correctly after each tranche

### Fuzz: sequential partial sells
- [ ] Fuzz: random split of total token supply into N tranches (1–5), random price and currency per tranche → invariant: sum of all currency paid across tranches equals sum of all payouts (fee + lead investors + receiver) per tranche; no tokens lost or double-counted

---

## 9. `_settle()` Sweep Behavior — Accidentally Sent Currency

`_settle` computes carry from `remaining` (the buyer's payment minus fee), not from the
contract's balance. Accidentally present currency does NOT inflate carry or lead investor
payouts — it is simply swept to the receiver at the end.

### Fixed-value example: extra currency present during buy()

Setup: 10 Tokens (18 dec), basePrice = 100e6 EURc (6 dec), tokenPrice = 200e6, 0 fee,
lead investor A = 10% carry. Someone sends 500e6 EURc directly to the contract before the buy.

- Buyer pays 2000e6 for 10 Tokens. Fee: 0. Remaining (from buyer): 2000e6.
- scaledBasePrice = 100e6. BasePayout: 1000e6. Carry: 1000e6.
- A gets 100e6 (10% of carry). Contract balance before final sweep: 2000e6 - 100e6 + 500e6 = 2400e6.
- Receiver gets 2400e6.

- [ ] Lead investor A receives exactly 100e6 — carry is not inflated by the 500e6 extra
- [ ] Receiver receives 2400e6 (correct share + accidental amount)
- [ ] Same scenario with carry = 0 (tokenPrice ≤ basePrice): lead investors get nothing, receiver gets entire balance including the accidentally sent amount

### Extra currency of a different denomination present during buy()

- [ ] EURe carry math is unchanged by a pre-existing EURc balance on the contract
- [ ] EURc balance is NOT swept during an EURe `_settle` call (only the active currency is swept)
- [ ] EURc stays on the contract after the EURe buy() completes

### Fuzz: random extra balance present
- [ ] Fuzz: random accidental extra balance of active currency added before buy() → invariant: lead investor payouts unchanged; receiver payout == expected share + extra balance

---

## 10. Fuzz / Property-Based Tests

- [ ] `buy()` fuzz: random tokenAmount, tokenPrice, basePrice, fee bps, 1–N lead investors with random carryFractions → verify:
  - invariant: sum of all payouts (fee + lead investors + receiver) == currencyAmount
  - invariant: each lead investor payout == floor(carryFraction × carry / uint64.max)
  - invariant: receiver payout == contract balance after lead investor distributions
  - no overflow/unexpected revert for valid inputs
- [ ] Fuzz `_scaleToDecimals`: random amount, random targetDecimals vs basePriceDecimals → no overflow, correct direction

---

## 11. Access Control — consolidated

- [ ] `setCurrency()`: non-owner reverts
- [ ] `setTokenPrice()`: non-owner reverts
- [ ] `setReceiver()`: non-owner reverts
- [ ] `pause()`: non-owner reverts
- [ ] `unpause()`: non-owner reverts

---

## 12. Reentrancy

- [ ] `buy()` with malicious ERC20 that re-enters `buy()` → reverts (ReentrancyGuard)

---

## 13. ERC2771 / Meta-transactions

- [ ] `buy()` via trusted forwarder correctly identifies buyer as `_msgSender`
- [ ] Untrusted forwarder cannot spoof sender

---

# CoinvestedPosition × Exit Integration

Tests the full flow of `CoinvestedPosition.distributeExit()` against a real `Exit` contract.
Lives in a dedicated test file (e.g. `CoinvestedPositionExit.t.sol`).

**Currency policy:**
- `Exit.initialize()` requires `TRUSTED_CURRENCY | EURO_CURRENCY`
- `distributeExit()` requires `TRUSTED_CURRENCY | EURO_CURRENCY`
- `distributeDividends()` requires `TRUSTED_CURRENCY` only (not EURO_CURRENCY)

### Setup shared across integration tests

```
Token:               18 decimals, total supply 1000 Tokens
AllowList:           EURc flagged TRUSTED_CURRENCY | EURO_CURRENCY
                     EURe flagged TRUSTED_CURRENCY | EURO_CURRENCY
baseCurrency:        EURc (6 dec) — used at CoinvestedPosition init time → basePriceDecimals = 6
basePrice:           100e6  (= 100 EURc per Token, in 6-dec units)
CoinvestedPosition:  holds 200 Tokens (minted/transferred directly, no buy() needed)
Lead investors:      A = 10% carry, B = 5% carry
Exit claimWindow:    claimStart = now + 1 day, claimEnd = now + 30 days
                     → tests warp into the window unless testing window violations
```

---

## I. Basic Sanity

- [ ] `distributeExit()` reverts when called before `claimStart` (Exit.claim reverts internally)
- [ ] `distributeExit()` reverts when called after `claimEnd` (Exit.claim reverts internally)
- [ ] `distributeExit()` reverts when CoinvestedPosition holds 0 tokens
- [ ] Non-EURO exit currency (TRUSTED_CURRENCY set but EURO_CURRENCY missing) → reverts at the `distributeExit` guard
- [ ] Only owner can call `distributeExit()`

---

## II. Same Currency, Same Decimals — Concrete Fixed-Value Examples

### II-A: Exit price above base (carry > 0)

```
Exit currency:      EURc (6 dec), pricePerToken = 200e6

Exit.claim pays:    (200e18 * 200e6) / 1e18 = 40,000e6 EURc
received:           40,000e6
basePayout:         _scaleToDecimals((100e6 * 200e18) / 1e18, 6) = 20,000e6
carry:              20,000e6

A gets:    2,000e6   (10%)
B gets:    1,000e6   (5%)
receiver: 37,000e6
```

- [ ] A, B, receiver balances match exact values above
- [ ] CoinvestedPosition token balance = 0 after
- [ ] Exit contract holds 200 Tokens after
- [ ] Sum check: 2,000 + 1,000 + 37,000 = 40,000 (no currency lost or created)

### II-B: Exit price exactly equals base (carry = 0)

```
pricePerToken = 100e6 → received = basePayout = 20,000e6 → carry = 0
```

- [ ] A and B receive 0
- [ ] Receiver gets full 20,000e6

### II-C: Exit price below base (carry = 0, shortfall)

```
pricePerToken = 60e6 → Exit pays 12,000e6. basePayout would be 20,000e6 → carry = 0
```

- [ ] A and B receive 0
- [ ] Receiver gets full 12,000e6 (no top-up, no revert)

---

## III. Cross-Currency Decimal Scaling

### III-A: Upscaling — basePrice in EURc (6 dec), exit in EURe (18 dec)

```
Exit currency:      EURe (18 dec), pricePerToken = 200e18

Exit.claim pays:    (200e18 * 200e18) / 1e18 = 40,000e18 EURe
received:           40,000e18
basePayout:         _scaleToDecimals(20,000e6, 18) = 20,000e18 EURe
carry:              20,000e18 EURe

A gets:    2,000e18 EURe
B gets:    1,000e18 EURe
receiver: 37,000e18 EURe
```

- [ ] Exact amounts as above
- [ ] EURc balance on CoinvestedPosition untouched (no sweep of the other currency)

### III-B: Downscaling — basePrice in EURe (18 dec), exit in EURc (6 dec)

Re-deploy CoinvestedPosition with baseCurrency = EURe (18 dec), basePrice = 100e18.

```
Exit currency:      EURc (6 dec), pricePerToken = 200e6

Exit.claim pays:    40,000e6 EURc
basePayout:         _scaleToDecimals(20,000e18, 6) = 20,000e6 EURc
carry:              20,000e6 EURc
```

- [ ] Exact amounts correct despite downscaling
- [ ] No precision loss causes revert or wrong distribution

### III-C: Equal decimals

- [ ] `_scaleToDecimals` returns unchanged amount when `targetDecimals == basePriceDecimals`

---

## IV. Multiple Lead Investors and Carry Fraction Precision

### IV-A: Three lead investors with non-round fractions

```
Lead investors: A = 17%, B = 11%, C = 3% (as uint64 fractions of uint64.max)
carry = 100,000e6 EURc

A gets: floor(17% * 100,000e6) = 17,000e6
B gets: floor(11% * 100,000e6) = 11,000e6
C gets: floor(3%  * 100,000e6) =  3,000e6
receiver gets: basePayout + all rounding dust (full sweep)
```

- [ ] Each lead investor receives exactly the floored amount
- [ ] Receiver receives full remaining balance (including all rounding dust)
- [ ] Sum invariant: A + B + C + receiver == received

### IV-B: Single lead investor with 99.9% carry

- [ ] Lead investor gets 99.9% of carry (floored), receiver gets base + 0.1% + dust
- [ ] No revert due to large carryFraction close to uint64.max

### IV-C: Maximum number of lead investors (e.g., 10)

- [ ] All 10 receive their correct share; sum invariant holds

---

## V. Fee Scenarios

`distributeExit()` does not pay fees — it distributes the full amount received from Exit.

- [ ] With non-zero FeeSettings, `distributeExit()` still distributes the full received amount (no phantom fee deduction)

---

## VI. Pre-existing Currency Balance ("accidentally sent" isolation)

### VI-A: CoinvestedPosition already holds exitCurrency before distributeExit()

```
500e6 EURc sent directly to CoinvestedPosition before the call.
Exit pays 40,000e6 EURc → received = 40,000e6 (before snapshot excludes the 500e6).
Carry computed on received only.
```

- [ ] A and B get their share of 40,000e6 carry (not inflated by the 500e6)
- [ ] Receiver gets 37,000e6 + 500e6 = 37,500e6 (correct share + accidentally sent, via sweep)

### VI-B: CoinvestedPosition holds a different currency than exitCurrency

```
1,000e18 EURe already on the contract; exit is in EURc.
```

- [ ] EURe balance untouched after `distributeExit()` in EURc

---

## VII. Exit Contract Funding Edge Cases

### VII-A: Exit underfunded (third party already claimed most of the pool)

```
Exit funded for 200 Tokens total. Third party claims 150 Tokens worth first.
CoinvestedPosition tries to claim 200 Tokens → Exit has insufficient currency.
```

- [ ] `distributeExit()` reverts (propagated from Exit's safeTransfer failure)
- [ ] CoinvestedPosition retains its tokens (atomic transaction: both token transfer and currency payment revert together)

### VII-B: Exit funded for exactly the right amount

- [ ] Full claim succeeds, Exit currency balance = 0 after

---

## VIII. Token Approval

- [ ] `distributeExit()` sets token approval to `address(_exit)` for exactly `tokenBalance` before calling claim
- [ ] CoinvestedPosition holds 0 tokens after successful exit

---

## IX. Fuzz Tests

- [ ] Fuzz: random `tokenBalance`, `pricePerToken`, `basePrice`, decimal combinations, 1–5 lead investors with random carryFractions → verify:
  - `received` matches `(tokenBalance * pricePerToken) / 10**token.decimals()`
  - `basePayout` matches `_scaleToDecimals((basePrice * tokenBalance) / 10**token.decimals(), exitDecimals)`
  - `carry = max(0, received - basePayout)`
  - sum of all payouts (lead investors + receiver) == received
  - no unexpected reverts for valid inputs
- [ ] Fuzz: random pre-existing exitCurrency balance → carry unaffected; receiver receives expected share + extra via sweep

---

## X. Interaction Ordering: buy() then distributeExit()

```
Start: CoinvestedPosition holds 200 Tokens
buy() sells 50 Tokens → 150 Tokens remain
distributeExit() called for the remaining 150 Tokens
```

- [ ] `tokenBalance` in `distributeExit()` = 150e18
- [ ] basePayout scaled to 150 Tokens correctly
- [ ] Carry and distribution correct for 150-Token exit

---

## Key Invariants (assert in every integration test)

1. `sum(lead investor payouts) + receiver_payout == received` — no currency created or destroyed
2. Each lead investor payout == `floor(carryFraction * carry / uint64.max)`
3. Receiver payout == full contract balance at the moment of the final sweep
4. `token.balanceOf(coinvestedPosition) == 0` after successful exit
5. Balances of other currencies on CoinvestedPosition are unchanged

---

# CoinvestedPosition × Distribution Integration

Tests the full flow of `CoinvestedPosition.distributeDividends()` against a real `Distribution`
contract. Lives in a dedicated test file (e.g. `CoinvestedPositionDistribution.t.sol`).

**Key difference from the Exit integration:**
- The **full received amount is carry** — there is no base price comparison. Lead investors always
  split everything proportionally; receiver always gets the remainder via sweep.
- No `basePriceDecimals` scaling — `_settle(received, _dividendCurrency)` operates on raw bits.
- `distributeDividends()` only requires `TRUSTED_CURRENCY` (not `EURO_CURRENCY`), so non-EURO
  tokens such as USDC are valid dividend currencies.
- Distribution has no claim window — claims are valid at any time after initialization.

### Setup shared across integration tests

```
Token:               18 decimals, total supply 1000 Tokens
CoinvestedPosition:  holds 200 Tokens at snapshot time → 20% of supply
Other holders:       hold remaining 800 Tokens
AllowList:           USDC flagged TRUSTED_CURRENCY
                     EURe flagged TRUSTED_CURRENCY | EURO_CURRENCY
baseCurrency:        EURc (6 dec) at CoinvestedPosition init (basePriceDecimals = 6)
Lead investors:      A = 10% carry, B = 5% carry (unless stated otherwise)
Distribution:        totalCurrencyAmount = 1000e6 USDC → CoinvestedPosition eligible = 200e6
```

---

## DI-I. Basic Proportional Claim

```
Distribution: 1000e6 USDC total. CoinvestedPosition: 200/1000 tokens → eligible = 200e6 USDC.
Full received treated as carry.

A gets:  floor(10% * 200e6) = 20e6
B gets:  floor(5%  * 200e6) = 10e6
receiver: 200e6 - 20e6 - 10e6 = 170e6
```

- [ ] A, B, receiver balances match exact values above
- [ ] Sum check: 20 + 10 + 170 = 200 (no currency lost)
- [ ] `Distribution.paidOut[coinvestedPosition]` = 200e6 after claim
- [ ] `Distribution.eligible(coinvestedPosition)` = 0 after claim

---

## DI-II. CoinvestedPosition as Minority Holder Among Active Claimers

Other token holders claim their shares from the same Distribution first.
CoinvestedPosition claims last.

- [ ] Other holders claiming first does not reduce CoinvestedPosition's eligible (each holder's
  share is independently calculated from the snapshot)
- [ ] CoinvestedPosition receives exactly its proportional 200e6, regardless of claim order
- [ ] Distribution currency balance after all claims ≤ totalCurrencyAmount (rounding dust may remain)

---

## DI-III. Various Carry Fractions × Various Currencies

### III-A: Non-round carry fractions, USDC (6 dec)

```
Lead investors: A = 7%, B = 13%, C = 3%   (as uint64 fractions of uint64.max)
received = 200e6 USDC

A gets: floor(7%  * 200e6) = 14e6
B gets: floor(13% * 200e6) = 26e6
C gets: floor(3%  * 200e6) =  6e6
receiver: 200e6 - 14e6 - 26e6 - 6e6 = 154e6  (+ any rounding dust via sweep)
```

- [ ] Exact amounts match; receiver collects all dust via full-balance sweep

### III-B: Same carry fractions, EURe (18 dec)

Re-deploy Distribution with EURe as currency (1000e18 total → CoinvestedPosition eligible = 200e18).

```
A gets: floor(7%  * 200e18) = 14e18
B gets: floor(13% * 200e18) = 26e18
C gets: floor(3%  * 200e18) =  6e18
receiver: 154e18
```

- [ ] No `basePriceDecimals` scaling applied — split operates on raw 18-dec bits
- [ ] Amounts proportionally identical to III-A despite different decimals

---

## DI-IV. Non-EURO Trusted Currency (USDC)

- [ ] `distributeDividends` accepts USDC (TRUSTED_CURRENCY, no EURO_CURRENCY bit) — contrasts
  with `distributeExit` which would reject it
- [ ] Carry split math correct for 6-dec USDC

---

## DI-V. Currency Different from baseCurrency

CoinvestedPosition initialised with EURc, Distribution pays USDC.
No `basePriceDecimals` scaling in the dividend path.

- [ ] USDC received correctly split by raw carryFractions with no decimal conversion
- [ ] EURc balance on CoinvestedPosition (if any) untouched

---

## DI-VI. CoinvestedPosition Has 0 Tokens in Snapshot

CoinvestedPosition's token balance at snapshot time = 0.

- [ ] `Distribution.eligible(coinvestedPosition)` = 0
- [ ] `Distribution._claim` transfers 0 to CoinvestedPosition
- [ ] `received = 0` → `distributeDividends` reverts ("didn't receive expected currency from distribution")

---

## DI-VII. CoinvestedPosition Receiving Extra Credit via Reassignment

In practice `reassign` always targets an EOA — a lost-key holder's funds are moved to a
new EOA and any split among parties is handled manually off-chain. Reassigning to a
CoinvestedPosition is not a real-world use case. This test simply verifies that
`extraCredit` stacks correctly with a CoinvestedPosition's own eligible, ensuring the
math holds even in this contrived scenario.

```
Setup:
  Holder X has 100e6 USDC eligible (from their 100 Token snapshot balance).
  Owner calls Distribution.reassign(X, coinvestedPosition) after reassignAfter.

  CoinvestedPosition eligible before:  200e6 (own share)
  CoinvestedPosition eligible after:   200e6 + 100e6 = 300e6

CoinvestedPosition.distributeDividends() →
  received = 300e6
  A gets: floor(10% * 300e6) = 30e6
  B gets: floor(5%  * 300e6) = 15e6
  receiver: 255e6
```

- [ ] `eligible(coinvestedPosition)` = 300e6 before claim
- [ ] A, B, receiver receive exact amounts above
- [ ] `eligible(X)` = 0 (reassign consumed it)
- [ ] X cannot claim anything further (paidOut[X] covers their share)

---

## DI-VIII. Multiple Distribution Contracts, Sequential Claims

CoinvestedPosition calls `distributeDividends` twice: once for a USDC distribution,
once for a EURe distribution (separate Distribution deployments, same snapshot).

- [ ] First call correctly claims and settles USDC; `_settle` sweeps only USDC
- [ ] Second call correctly claims and settles EURe; `_settle` sweeps only EURe
- [ ] USDC balance after first call is 0 on CoinvestedPosition (swept to receiver)
- [ ] EURe balance after second call is 0 on CoinvestedPosition
- [ ] No cross-contamination: EURe `before` snapshot during second call = 0 (all EURe claimed
  in that call, USDC not involved)

---

## DI-IX. Pre-existing Dividend Currency Balance Isolation

Same currency as the Distribution is already sitting on CoinvestedPosition (e.g. leftover
from a prior `buy()` in that currency).

```
300e6 USDC already on CoinvestedPosition before distributeDividends().
Distribution pays 200e6 USDC → received = 200e6 (before snapshot excludes the 300e6).
```

- [ ] Carry computed on 200e6 only — lead investor payouts not inflated by the 300e6
- [ ] Receiver gets correct dividend share + 300e6 pre-existing via the full-balance sweep
- [ ] Sum of lead investor payouts + receiver payout = 200e6 + 300e6 = 500e6 (all accounted for)

---

## DI-X. buy() Between Snapshot and Dividend Claim

CoinvestedPosition sells tokens via `buy()` after the snapshot is taken.
Distribution eligible is snapshot-based and unaffected by post-snapshot token movements.

```
Snapshot: CoinvestedPosition holds 200 Tokens → eligible = 200e6
After snapshot: 50 Tokens sold via buy()
Token balance at claim time: 150 Tokens
```

- [ ] `distributeDividends` claims the full snapshot-eligible 200e6 (not 150e6)
- [ ] Current token balance (150) does not affect the Distribution claim
- [ ] Post-buy() carry and post-dividend carry are independent; no state interference

---

## DI-XI. Fuzz Tests

- [ ] Fuzz: random CoinvestedPosition snapshot balance (as fraction of total supply),
  `totalCurrencyAmount`, 1–5 lead investors with random carryFractions, random currency
  decimals → verify:
  - `received == Distribution.eligible(coinvestedPosition)` at claim time
  - `sum(lead investor payouts) + receiver_payout == received`
  - each lead investor payout == `floor(carryFraction * received / uint64.max)`
  - receiver payout == full contract balance at sweep moment
  - no currency created or destroyed

---

## Key Invariants (assert in every Distribution integration test)

1. `sum(lead investor payouts) + receiver_payout == received`
2. Each lead investor payout == `floor(carryFraction * received / uint64.max)`
   (note: `received` is the full carry — no base price subtraction)
3. Receiver payout == full `_dividendCurrency` balance on CoinvestedPosition at sweep time
4. `Distribution.eligible(coinvestedPosition)` = 0 after claim
5. Balances of other currencies on CoinvestedPosition are unchanged

---

# CoinvestedPositionCloneFactory

Standard pattern: matches existing factory tests (TokenSwapCloneFactory, CrowdinvestingCloneFactory).
No currency funding required — clone+init only.

## F1-CP. Address Prediction

- [ ] `predictCloneAddress(rawSalt, trustedForwarder, arguments)` and `predictCloneAddress(precomputedSalt)` return the same address
- [ ] Actual deployed address matches predicted address
- [ ] `NewClone` event emitted with the correct clone address

## F2-CP. Each Salt Parameter Changes the Address

Mutate one field at a time; assert predicted address differs each time:
- [ ] `rawSalt`
- [ ] `trustedForwarder`
- [ ] `arguments.owner`
- [ ] `arguments.receiver`
- [ ] `arguments.basePrice`
- [ ] `arguments.baseCurrency`
- [ ] `arguments.token`
- [ ] `arguments.leadInvestors` (change a carryFraction or array length) — explicit test since it is a dynamic array in the struct

## F3-CP. Wrong Trusted Forwarder Reverts

- [ ] `predictCloneAddress` with mismatched `_trustedForwarder` → reverts
- [ ] `createCoinvestedPositionClone` with mismatched `_trustedForwarder` → reverts

## F4-CP. Second Deployment Fails

- [ ] Deploying with identical salt+params twice → reverts `"ERC1167: create2 failed"`

## F5-CP. Initialization

- [ ] All state variables correct: `owner`, `receiver`, `currency`, `token`, `basePrice`, `basePriceDecimals`, `leadInvestors` array, `paused == true`
- [ ] `isTrustedForwarder(_trustedForwarder)` returns true
- [ ] Re-initializing the clone reverts `"Initializable: contract is already initialized"`

## F6-CP. Invalid Currency Reverts

- [ ] Currency missing `TRUSTED_CURRENCY` bit → reverts
- [ ] Currency missing `EURO_CURRENCY` bit → reverts
- [ ] Currency with both bits set → succeeds

---

# ExitCloneFactory

Standard pattern plus funding-via-approval. `_currencyProvider` is excluded from the salt.

## F1-E. Address Prediction

- [ ] Both `predictCloneAddress` overloads return the same address
- [ ] Actual deployed address matches predicted address
- [ ] `NewClone` event emitted with the correct clone address

## F2-E. Each Salt Parameter Changes the Address

- [ ] `rawSalt`, `trustedForwarder`, `token`, `owner`, `currency`, `pricePerToken`, `claimStart`, `claimEnd`, `totalCurrencyAmount` each independently change the address

## F3-E. `_currencyProvider` Is Not in the Salt

- [ ] Different `_currencyProvider` values with identical other params → same predicted address
- [ ] Deployment succeeds regardless of which address provides the currency (as long as approval is in place)

## F4-E. Wrong Trusted Forwarder Reverts

- [ ] Both `predictCloneAddress` and `createExitClone` revert with mismatched forwarder

## F5-E. Second Deployment Fails

- [ ] Identical salt+params twice → reverts `"ERC1167: create2 failed"`

## F6-E. Initialization

- [ ] All state variables correct: `token`, `currency`, `pricePerToken`, `claimStart`, `claimEnd`, `owner`
- [ ] Clone holds exactly `_totalCurrencyAmount` of currency after deployment
- [ ] `isTrustedForwarder` returns true
- [ ] Re-initializing reverts

## F7-E. Funding via Clone Address Approval

- [ ] `_currencyProvider` approves factory address instead of clone → reverts (approval on wrong address)
- [ ] `_currencyProvider` approves clone address for less than `_totalCurrencyAmount` → reverts
- [ ] `_currencyProvider` approves clone address for exactly `_totalCurrencyAmount` → succeeds

## F8-E. Invalid Currency Reverts

- [ ] Currency missing `TRUSTED_CURRENCY` bit → reverts
- [ ] Currency missing `EURO_CURRENCY` bit → reverts
- [ ] Both bits set → succeeds

---

# DistributionCloneFactory

Standard pattern plus funding-via-approval. `_currencyProvider` is excluded from the salt.

## F1-D. Address Prediction

- [ ] Both `predictCloneAddress` overloads return the same address
- [ ] Actual deployed address matches predicted address
- [ ] `NewClone` event emitted with the correct clone address

## F2-D. Each Salt Parameter Changes the Address

- [ ] `rawSalt`, `trustedForwarder`, `token`, `owner`, `snapshotId`, `currency`, `totalCurrencyAmount`, `reassignAfter` each independently change the address

## F3-D. `_currencyProvider` Is Not in the Salt

- [ ] Different `_currencyProvider` values with identical other params → same predicted address

## F4-D. Wrong Trusted Forwarder Reverts

- [ ] Both `predictCloneAddress` and `createDistributionClone` revert with mismatched forwarder

## F5-D. Second Deployment Fails

- [ ] Identical salt+params twice → reverts `"ERC1167: create2 failed"`

## F6-D. Initialization

- [ ] All state variables correct: `token`, `snapshotId`, `totalTokenAmount`, `currency`, `totalCurrencyAmount`, `reassignAfter`, `owner`
- [ ] `totalTokenAmount` == `token.totalSupplyAt(snapshotId)` (derived, not passed)
- [ ] Clone holds exactly `_totalCurrencyAmount` of currency after deployment
- [ ] `isTrustedForwarder` returns true
- [ ] Re-initializing reverts

## F7-D. Funding via Clone Address Approval

- [ ] `_currencyProvider` approves factory address instead of clone → reverts
- [ ] `_currencyProvider` approves clone address for less than `_totalCurrencyAmount` → reverts
- [ ] `_currencyProvider` approves clone address for exactly `_totalCurrencyAmount` → succeeds

## F8-D. Invalid Currency and Timing Reverts

- [ ] Currency missing `TRUSTED_CURRENCY` bit → reverts
- [ ] Trusted non-EURO currency → succeeds (Distribution only requires `TRUSTED_CURRENCY`)
- [ ] `_reassignAfter < block.timestamp + 30 days` → reverts
- [ ] `_reassignAfter == block.timestamp + 30 days` → succeeds (boundary)

---

# Implementation Guidelines

## Shared Infrastructure First

Before writing any contract-specific tests, build the shared helpers that every file will need:

- `Token`, `AllowList`, `FeeSettings` deployment helpers (already exist in `CloneCreators.sol` — extend as needed)
- Fake ERC20 currencies with configurable decimals and `TRUSTED_CURRENCY` / `EURO_CURRENCY` allowlist bits
- A `warp(timestamp)` helper for time-dependent tests (claimStart/claimEnd, reassignAfter)
- Reusable `LeadInvestor[]` builders for CoinvestedPosition tests

Keep this in a shared base contract (e.g. `TestBase.sol`) or a fixture file imported by all test files.

## Recommended Implementation Order

Work through the sections roughly in this order. The first three can be written in parallel since
they have no dependencies on each other; everything after depends on them being solid.

1. **`Exit.t.sol`** — smallest surface area, no carry math, straightforward claim window and funding
2. **`Distribution.t.sol`** — snapshot math and reassignment accounting, no carry
3. **`ExitCloneFactory.t.sol`** — write immediately after Exit unit tests while the setup is fresh
4. **`DistributionCloneFactory.t.sol`** — write immediately after Distribution unit tests
5. **`CoinvestedPosition.t.sol`** — depends on allowlist/currency setup established above; carry math and decimal scaling are the most complex part
6. **`CoinvestedPositionCloneFactory.t.sol`** — write immediately after CoinvestedPosition unit tests
7. **`CoinvestedPositionExit.t.sol`** — integration; requires both Exit and CoinvestedPosition to be well-understood
8. **`CoinvestedPositionDistribution.t.sol`** — integration; requires both Distribution and CoinvestedPosition to be well-understood

## Fuzz Variants After Concrete Tests Pass

For every section that has a fuzz test (`D10`, `E7`, sections `10`/`IX`/`DI-XI`, etc.):
- Write and get the **concrete fixed-value tests green first**.
- Only then add the fuzz variant. Fuzzing a broken concrete case produces misleading counterexamples.
- The fixed-value examples in this plan are chosen to serve as the seed corpus for fuzz inputs.

## Cross-Decimal Scaling Is the Highest-Risk Area

`_scaleToDecimals` and the `basePriceDecimals` path in `buy()` / `distributeExit()` are the most
subtle parts of the codebase. Prioritise:

- Concrete upscale (6→18) and downscale (18→6) examples early, before fuzz
- Equal-decimals case as a sanity check
- Fuzz with the full decimal range (0–18) to catch overflow and off-by-one errors

## Factory Tests Are Structural, Not Math

Factory tests (F1–F8 in each section) are mostly structural — address prediction, salt sensitivity,
re-init guard, funding approval. They do not exercise carry math. Keep them short and focused.
The one non-obvious item across all three factories is the **approval-to-clone, not factory** pattern
(F7-E / F7-D): test both the correct and incorrect approval target explicitly.

## Integration Tests Are the Final Confidence Check

The integration test files (`CoinvestedPositionExit.t.sol`, `CoinvestedPositionDistribution.t.sol`)
should assert the **Key Invariants** listed at the bottom of each section in every test case, not
just the fuzz tests. Assert them as inline `assertEq` / `assertLe` statements so failures are
immediately locatable.
