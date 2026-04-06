# Architecture Decisions

This document records the reasons why certain approaches have been taken or rejected. It serves as a reference for understanding the rationale behind design choices, so that future contributors can make informed decisions and avoid revisiting already-resolved trade-offs.

---

## Lockups: One Contract per Lockup

**Decision:** Each lockup is managed by its own dedicated contract, rather than having a single contract manage multiple lockups.

**Rationale:** A single contract managing multiple lockups must maintain internal accounting (e.g. tracking how many tokens belong to each beneficiary). This accounting can silently diverge from the contract's actual token balance if tokens are added externally, burned, never added despite a lockup being created, or otherwise transferred outside the expected flow. Such discrepancies are hard to detect and can lead to incorrect releases or locked funds.

By giving each lockup its own contract, the token balance of that contract _is_ the lockup balance — no internal bookkeeping is required, and any unexpected change in balance is immediately visible and attributable.

---

## MasterUnlock: Centralized Unlock Signal for Lockups

**Decision:** A dedicated `MasterUnlock` contract is deployed and referenced by all lockup contracts. Triggering it unlocks all connected lockups simultaneously.

**Rationale:** In an exit scenario, the company must be able to immediately unlock all tokens so that beneficiaries can claim their exit proceeds. The cleanest signal point would be the Token contract itself, since all lockups already reference it. However, that would require changes to the token contract — which is not possible for legacy v4 tokens, of which several are in active use.

A standalone `MasterUnlock` contract solves this without touching the token contract: it is connected to all lockups of a specific Token at deployment time, and a single call to it unlocks everything centrally.

---

## ERC2771Context: Duplicate Overrides in Every Contract

**Decision:** Each contract that uses `ERC2771ContextUpgradeable` alongside any other `ContextUpgradeable`-derived contract (e.g. `OwnableUpgradeable`, `AccessControlUpgradeable`) explicitly re-declares the three `_msgSender`, `_msgData`, and `_contextSuffixLength` overrides.

**Rationale:** Solidity's override resolution rule fires whenever multiple inheritance paths lead to the same function. An abstract base contract _can_ eliminate the per-contract boilerplate, but only if it inherits **all** the `ContextUpgradeable`-derived bases that the concrete contract uses — so that there is only one path to `ContextUpgradeable` and the base's non-virtual override is the unambiguous winner. The 10 affected contracts split across too many distinct combinations to make this viable:

| Combination                                                                                                | Contracts                                               |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `Ownable2StepUpgradeable`                                                                                  | PriceLinear, AllowList, Distribution, Exit, FeeSettings |
| `Ownable2StepUpgradeable` + `PausableUpgradeable`                                                          | Crowdinvesting                                          |
| `OwnableUpgradeable`                                                                                       | TimeLock, Vesting                                       |
| `OwnableUpgradeable` + `PausableUpgradeable`                                                               | TokenSwapBase                                           |
| `ERC20PermitUpgradeable` + `ERC20SnapshotUpgradeable` + `PausableUpgradeable` + `AccessControlUpgradeable` | Token                                                   |

Two base contracts would cover 7 of the 10 cases, but the saving is marginal and the indirection adds complexity. The overrides are therefore repeated in every affected contract by necessity, not by oversight.
