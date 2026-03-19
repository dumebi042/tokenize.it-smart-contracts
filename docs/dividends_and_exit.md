# Dividends, Distributions and Exit

## Dividend Distribution

Token holders can receive dividend payouts proportional to their token balance at a specific point in time. This is implemented using the [Token.sol](../contracts/Token.sol) snapshot mechanism and the [Distribution.sol](../contracts/Distribution.sol) contract.

### Workflow

1. **Snapshot**: The token admin calls `snapshot()` on the Token contract. This freezes every holder's balance under a `snapshotId`. The timing is critical: it must happen before any tokens change hands in anticipation of the dividend.

2. **Deploy Distribution**: The company (or platform) clones a Distribution contract via `DistributionCloneFactory`, providing:

   - `token` and `snapshotId`
   - `currency`: the ERC-20 token used for payouts (must have `TRUSTED_CURRENCY` on the AllowList)
   - `totalCurrencyAmount`: gross amount to distribute
   - `reassignAfter`: timestamp from which unclaimed funds can be redirected

   At initialization, the platform fee (`privateOfferFee`) is deducted from `totalCurrencyAmount` and sent to the fee collector. Only the net remainder is available for claims.

3. **Holders claim**: Any holder at snapshot time calls `Distribution.claim(recipient)`. Their share is `netAmount * balanceAtSnapshot / totalSupplyAtSnapshot`. Smart contract holders (e.g. Gnosis Safe, CoinvestedPosition) can use the ERC-1271 variant.

4. **Reassignment** (recovery): If a holder cannot claim (lost key, broken smart contract), the owner can call `reassign(from, to, amount)` after `reassignAfter` to redirect that share. Every reassignment is recorded on-chain via the `Reassigned` event.

### CoinvestedPosition integration

A `CoinvestedPosition` contract holding tokens at snapshot time can claim its share via `distributeDividends(dist, currency)`. The received dividend is then split: lead investors receive carry shares, the co-investor (receiver) receives the remainder.

---

## Exit

When a company is acquired or wound down, it can set up an automated exit contract that lets holders redeem their tokens for a fixed cash payout. This is implemented in [Exit.sol](../contracts/Exit.sol).

### Workflow

1. **Deploy Exit**: The company clones an Exit contract via `ExitCloneFactory`, providing:

   - `token`: the token to be redeemed
   - `currency`: the payout currency (must have both `TRUSTED_CURRENCY` and `EURO_CURRENCY` on the AllowList — typically USDC, EURe, EUROC)
   - `pricePerToken`: currency payout in smallest currency units per full token unit (same unit convention as `tokenPrice` in TokenSwap)
   - `claimStart` / `drainStart`: the exit window
   - `totalCurrencyAmount`: amount to pre-fund the contract with

   The full `totalCurrencyAmount` is transferred from the funder to the Exit contract at initialization (no fee is taken here).

2. **Holders claim**: From `claimStart` onwards, any holder calls `claim(tokenAmount, recipient)`. The contract:

   - Transfers `tokenAmount` tokens from the caller to itself (tokens are held, not burned)
   - Calculates gross payout: `tokenAmount * pricePerToken / 10**token.decimals()`
   - Deducts `privateOfferFee` and sends it to the fee collector
   - Sends net payout to `recipient`

   Claims are rejected before `claimStart` or at/after `drainStart`.

3. **Drain**: After `drainStart`, the company can call `drain(recipient)` to recover any unclaimed currency.

### CoinvestedPosition integration

A `CoinvestedPosition` can participate in an exit via `distributeExit(exit, currency, minAmount)`. It redeems its full token balance, then splits proceeds: carry (proceeds above base price) goes to lead investors, everything else to the co-investor (receiver).

---

## Summary

| Feature              | Distribution                      | Exit                                 |
| -------------------- | --------------------------------- | ------------------------------------ |
| Price determination  | Proportional to snapshot balance  | Fixed price per token                |
| Snapshot required    | Yes                               | No                                   |
| Token fate           | Held by token holder throughout   | Transferred to Exit contract         |
| Fee timing           | Once at initialization            | Per claim                            |
| Recovery mechanism   | `reassign()` by owner after delay | `drain()` by owner after window      |
| Currency requirement | `TRUSTED_CURRENCY`                | `TRUSTED_CURRENCY` + `EURO_CURRENCY` |
