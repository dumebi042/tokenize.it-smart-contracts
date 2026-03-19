# Timelock & Distribution Plan

## Problem statement

We have been using `Vesting.sol` as a timelock (e.g. `PrivateOfferFactory.deployPrivateOfferWithTimeLock`).
This is an abuse: `Vesting` is designed for gradual token release, not simple date-gated holding.
The main pain point this surfaces is distributions: when a `Vesting` contract holds tokens at snapshot
time, it cannot call `Distribution.claim()` because `Vesting` has no such function. Currently the
only fix is the manual `Distribution.reassign()` path, which requires operator intervention.

## Decision

### Future timelocks: use `CoinvestedPosition` with `lockedUntil`

`CoinvestedPosition` already starts paused and requires an explicit `unpause()`. Adding a `lockedUntil`
timestamp makes `unpause()` impossible before that date — a natural, self-contained timelock.

Distribution is already solved: `CoinvestedPosition.distributeDividends()` calls
`_dist.claim(address(this))` and immediately settles proceeds. It is not gated by pause, so the owner
can claim distributions during the lock period with no additional code.

### Legacy Vesting timelocks: use `Distribution.reassign()`

Existing deployments that use `Vesting` as a timelock handle distributions via the already-present
`Distribution.reassign()` function. The distribution owner reassigns the Vesting contract's share to
the actual beneficiary. This is operationally manual but correct and auditable. No code changes needed.

## Implementation

### 1. `contracts/TokenSwapBase.sol`

Make `unpause()` virtual so `CoinvestedPosition` can override it:

```solidity
function unpause() external virtual onlyOwner {
    require(tokenPrice != 0, "tokenPrice must be set before unpausing");
    _unpause();
}
```

### 2. `contracts/CoinvestedPosition.sol`

Add `lockedUntil` to the initializer struct and contract state, override `unpause()`:

```solidity
struct CoinvestedPositionInitializerArguments {
    // ... existing fields ...
    uint64 lockedUntil; // 0 = no lock; unix timestamp after which unpause() is allowed
}

contract CoinvestedPosition is TokenSwapBase {
    uint64 public lockedUntil;

    function initialize(CoinvestedPositionInitializerArguments memory _arguments) external initializer {
        // ... existing init ...
        lockedUntil = _arguments.lockedUntil;
    }

    function unpause() external override onlyOwner {
        require(tokenPrice != 0, "tokenPrice must be set before unpausing");
        require(block.timestamp >= lockedUntil, "timelock has not expired");
        _unpause();
    }
}
```

`lockedUntil = 0` means no lock (0 <= any timestamp), so existing deployments passing 0 are unaffected.

### 3. `contracts/factories/CoinvestedPositionCloneFactory.sol`

No structural change needed — the factory already passes `CoinvestedPositionInitializerArguments`
through to `clone.initialize()`. Callers set `lockedUntil` in the struct.

Optionally add a dedicated `createCoinvestedPositionWithTimeLock` convenience function that
validates `lockedUntil > block.timestamp` to prevent accidental zero/past values.

### 4. Tests

- Update existing `CoinvestedPosition` tests to pass `lockedUntil: 0` in init args (no behaviour change).
- Add tests for:
  - `unpause()` reverts before `lockedUntil`
  - `unpause()` succeeds at and after `lockedUntil`
  - `distributeDividends()` succeeds during the locked period
  - `distributeExit()` succeeds during the locked period

## What does NOT change

- `Vesting.sol` — no changes; it remains the mechanism for `PrivateOffer` investor timelocks.
- `Distribution.sol` — no changes; `reassign()` covers legacy Vesting-held distributions.
- `PrivateOfferFactory.sol` — no changes; `deployPrivateOfferWithTimeLock` stays as-is.
- `IDistribution.sol` — no changes.
- `CoinvestedPosition.distributeDividends()` — already correct, no changes.
- `CoinvestedPosition.distributeExit()` — already correct, no changes.
