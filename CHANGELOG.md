# Changelog

## Unreleased

### New contract: `CoinvestedPosition`

Holds tokens on behalf of a co-investor and sells them, splitting proceeds between the co-investor (_receiver_) and lead investors via _carry_.

- **Base price:** EURO-denominated reference price recorded at initialization. After fees, the receiver is entitled to `basePrice` per token; any surplus is carry split among lead investors by `carryFraction`. If net proceeds don't cover `basePrice`, all proceeds go to the receiver.
- **Currency flexibility:** All three distribution paths (`buy`, dividends, exit) accept any EURO token (`TRUSTED_CURRENCY | EURO_CURRENCY`). The currency used by `buy()` is a state variable the owner can update via `setCurrency()`.
- **Balance sweep:** Lead investor shares are paid first, then the contract's entire remaining currency balance is swept to `receiver`, including any accidentally sent funds.

---

### New contract: `TokenSwapBase`

Abstract base extracted from duplicated logic in `TokenSwap` and `CoinvestedPosition`, covering shared state, fee handling, price/receiver management, pause controls, and ERC-2771 support. Both contracts now extend it.

---

### New contract: `Distribution`

Distributes a fixed currency amount among token holders proportional to their balance at a given snapshot. Supports direct claims, ERC-1271 smart-contract holders, and vesting contracts. An owner-only `reassign` function (available after a configurable delay post-deployment) handles recovery cases. Deployed via an atomic clone-and-fund factory.

## Fee collection

Note that for Distributions, all fees are collected at smart contract creation instead of at claim time. Rationale: there is no way to extract the currency without a fee payment, so we might as well collect at the beginning and save gas because we do it only once instead of bite-by-bite.

### New contract: `Exit`

Allows token holders to redeem tokens for a fixed currency payout within a configurable duration after the exit date. Deployed via an atomic clone-and-fund factory.

---

### New constant: `EURO_CURRENCY` in `AllowList`

`uint256 constant EURO_CURRENCY = 2 ** 254` (bit 254) added alongside `TRUSTED_CURRENCY` (bit 255). Marks a currency as Euro-denominated; required by `CoinvestedPosition` for all currency inputs.

---

### Breaking change: `TRUSTED_CURRENCY` check relaxed to bitmask

**Affected:** `Crowdinvesting`, `PrivateOffer`, `TokenSwap`

The currency allowList check changed from exact equality to a bitmask, allowing currency addresses to carry additional bits (e.g. `EURO_CURRENCY`) without being rejected. Existing deployments are affected when the attributes on the AllowList or the AllowList itself are updated.
