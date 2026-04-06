# New contracts

## `CoinvestedPosition`

Holds tokens on behalf of a co-investor and sells them, splitting proceeds between the co-investor (_receiver_) and lead investors via _carry_.

- **Base price:** Reference price per token recorded at initialization, denominated in `baseCurrency` (any trusted currency). After fees, the receiver is entitled to `basePrice` per token; any surplus is carry split among lead investors by `carryFraction`. If net proceeds don't cover `basePrice`, all proceeds go to the receiver.
- **Currency flexibility:** All three distribution paths (`buy`, dividends, exit) accept any trusted currency (`TRUSTED_CURRENCY` bit set). The currency used by `buy()` is a state variable the owner can update via `setCurrency()`.
- **Balance sweep:** Lead investor shares are paid first, then the contract's entire remaining currency balance is swept to `receiver`, including any accidentally sent funds.
- includes a timelock feature

---

## `TokenSwapBase`

Abstract base extracted from duplicated logic in `TokenSwap` and `CoinvestedPosition`, covering shared state, fee handling, price/receiver management and ERC-2771 support. Both contracts now extend it.

## `Distribution`

Distributes a fixed currency amount among token holders proportional to their balance at a given snapshot. Supports direct claims and timelock contracts. An owner-only `reassign` function (available at deployment and after a configurable delay post-deployment) handles recovery cases. Deployed via an atomic clone-and-fund factory.

**Fee collection note:** All fees are collected at smart contract creation, not at claim time. There is no way to extract currency without fee payment, so collecting once upfront saves gas over bite-by-bite collection.

## `Exit`

Allows token holders to redeem tokens for a fixed currency payout within a configurable duration after the exit date. Deployed via an atomic clone-and-fund factory.

## `TimeLock`

Holds ERC20 tokens on behalf of an owner and blocks withdrawals until a configurable timestamp.

- **`drain(token, recipient)`:** Transfers the full token balance to `recipient`. Reverts until `lockedUntil` has passed.
- **`distributeDividends(distribution, recipient)`:** Claims this contract's share from a `Distribution` contract and forwards the proceeds to `recipient`. Not subject to the time lock — dividends can be claimed at any time.

# Updates

## `FeeSettings` (now V3)

`FeeSettings` now implements `IFeeSettingsV3` alongside `IFeeSettingsV1` and `IFeeSettingsV2`, adding a fully dynamic fee type registry while staying backwards compatible with existing callers.

- **Dynamic fee types:** New fee types can be registered post-deployment via `registerFeeType(bytes32, uint32, uint32, address)` without a contract upgrade. Each type carries its own `maxNumerator`, `defaultNumerator`, and default collector. Querying an unregistered fee type returns a zero fee (no revert), so new contracts can safely use a fee type that an older `FeeSettings` deployment does not yet know about.
- **Generic accessors (`IFeeSettingsV3`):** `fee(bytes32 feeType, uint256 amount, address token)` and `feeCollector(bytes32 feeType, address token)` work for any registered type.
- **Backwards compatible:** All `IFeeSettingsV1` and `IFeeSettingsV2` named accessors (`tokenFee`, `crowdinvestingFee`, `privateOfferFee`, etc.) are preserved as thin wrappers over the V3 generics.
- **Consumer-side backwards compatibility:** `Distribution`, `Exit`, `TokenSwap`, and `CoinvestedPosition` each detect V3 support via `supportsInterface` at runtime. If V3 is not available they fall back to `privateOfferFee` / `privateOfferFeeCollector` from `IFeeSettingsV2`. The V3 fee types used are `FeeTypes.DISTRIBUTION`, `FeeTypes.EXIT`, and `FeeTypes.SECONDARY_MARKET` (the last covering both swap contracts).

> **Reviewer question:** Is the V2 fallback worth the added complexity? Since `Distribution` and `Exit` are new contracts that will only be deployed alongside or after the V3 `FeeSettings` upgrade, a V2 fallback may never be exercised in practice. An alternative would be to **charge no fee** when the `FeeSettings` contract does not support V3 — simpler code, no silent mis-pricing risk, and old deployments simply waive the fee rather than approximating it with a V2 type that may not match the intended fee category.
