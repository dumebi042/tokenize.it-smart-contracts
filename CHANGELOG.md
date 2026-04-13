# New contracts

## `CoinvestedPosition`

Holds tokens on behalf of a co-investor and sells them, splitting proceeds between the co-investor (_receiver_) and lead investors via _carry_.

- **Base price:** Reference price per token recorded at initialization, denominated in `baseCurrency` (any trusted currency). After fees, the receiver is entitled to `basePrice` per token; any surplus is carry split among lead investors by `carryFraction`. If net proceeds don't cover `basePrice`, all proceeds go to the receiver.
- **Currency flexibility:** All three distribution paths (`buy`, dividends, exit) accept any trusted currency (`TRUSTED_CURRENCY` bit set). The currency used by `buy()` is a state variable the owner can update via `setCurrency()`.
- **Balance sweep:** Lead investor shares are paid first, then the contract's entire remaining currency balance is swept to `receiver`, including any accidentally sent funds.
- includes a timelock feature
- doesn't try to enforce correct base price. The focus instead is to a) document which currency and base price are used and b) guarantee correct execution of the payout logic.

---

## `TokenSwapBase`

Abstract base extracted from duplicated logic in `TokenSwap` and `CoinvestedPosition`, covering shared state, fee handling, price/receiver management and ERC-2771 support. Both contracts now extend it.

## `Distribution`

Distributes a fixed currency amount among token holders proportional to their balance at a given snapshot. An owner-only `reassign` function (available at deployment and after a configurable delay post-deployment) handles recovery cases. Deployed via an atomic clone-and-fund factory.

## `Exit`

Allows token holders to redeem tokens for a fixed currency payout within a configurable duration after the exit date. Deployed via an atomic clone-and-fund factory.

## `GlobalTokenExitRegistry`

A single shared registry that maps any token to its authorized `Exit` contract, replacing per-deployment `TokenExitRegistry` instances.

- **One-time registration:** `setExit()` can be called exactly once per token. The exit contract address cannot be changed after it is set.
- **Dual access-control support:** The caller must be either a `DEFAULT_ADMIN_ROLE` holder or the `owner()` of the token. Both checks use try/catch so the registry works with tokens that implement only one of the two access-control models.
- **Shared deployment:** One registry instance serves all tokens, reducing deployment overhead.
- **Signal semantics:** A non-zero `exit` value signals to connected `TimeLock` and `CoinvestedPosition` contracts that the time-lock bypass for exit claims is active — they call `claimExit()` without checking `lockedUntil`.

## `TimeLock`

Holds ERC20 tokens on behalf of an owner and blocks withdrawals until a configurable timestamp.

- **`drain(token, recipient)`:** Transfers the full token balance to `recipient`. Reverts until `lockedUntil` has passed.
- **`claimDistribution(dist, dividendCurrency, recipient, minPayout)`:** Claims this contract's share from a `Distribution` contract and forwards the proceeds to `recipient`. Not subject to the time lock — dividends can be claimed at any time.
- **`claimExit(exitCurrency, recipient, minPayout)`:** Claims exit proceeds for this contract's full token balance via the exit contract registered in `TokenExitRegistry`, and forwards them to `recipient`. Bypasses the `lockedUntil` constraint when an exit is set.

# Updates

## `PrivateOfferFactory`

The lockup mechanism has been replaced: `deployPrivateOfferWithTimeLock` previously deployed a `Vesting` contract; it now deploys a `TimeLock` contract.

- **Breaking change:** The function signature changed. The vesting parameters (`vestingStart`, `vestingCliff`, `vestingDuration`, `vestingContractOwner`) are replaced by `_lockedUntil`, `_timeLockOwner`, `_tokenExitRegistry`, and `_trustedForwarder`.
- **Breaking change:** The `NewPrivateOfferWithLockup` event is replaced by `NewPrivateOfferWithTimeLock`.
- **Breaking change:** `predictPrivateOfferAndTimeLockAddress` replaces the old `predictPrivateOfferAndVestingAddress`-equivalent overload.
- The factory constructor now takes a `TimeLockCloneFactory` instead of a `VestingCloneFactory`.

## `TokenSwap`

`TokenSwap` now extends `TokenSwapBase`, eliminating duplicated state and logic shared with `CoinvestedPosition`. The external interface is unchanged except:

- **`unpause()`** now requires `tokenPrice != 0` before unpausing (consistent with `CoinvestedPosition`).

## `FeeSettings` (now V3)

`FeeSettings` now implements `IFeeSettingsV3` alongside `IFeeSettingsV1` and `IFeeSettingsV2`, adding a fully dynamic fee type registry while staying backwards compatible with existing callers.

- **Dynamic fee types:** New fee types can be registered post-deployment via `registerFeeType(bytes32, uint32, uint32, address)` without a contract upgrade. Each type carries its own `maxNumerator`, `defaultNumerator`, and default collector. Querying an unregistered fee type returns a zero fee (no revert), so new contracts can safely use a fee type that an older `FeeSettings` deployment does not yet know about.
- **Generic accessors (`IFeeSettingsV3`):** `fee(bytes32 feeType, uint256 amount, address token)` and `feeCollector(bytes32 feeType, address token)` work for any registered type.
- **Backwards compatible:** All `IFeeSettingsV1` and `IFeeSettingsV2` named accessors (`tokenFee`, `crowdinvestingFee`, `privateOfferFee`, etc.) are preserved as thin wrappers over the V3 generics.
- **Consumer-side backwards compatibility:** `TokenSwap`, and `CoinvestedPosition` each detect V3 support via `supportsInterface` at runtime. If V3 is not available they fall back to `privateOfferFee` / `privateOfferFeeCollector` from `IFeeSettingsV2`. The V3 fee type is `FeeTypes.SECONDARY_MARKET`.

# Todo

Stuff that still needs to be done (after this PR is merged):

- natspec where it is missing
- update specifications in docs
- update docs
- ERC1400 mentions some kind of controllers, which I have to look into (to decide if and how to support this in GlobalTokenExitRegistry)
