# Foundation

## Dividend distribution

- token admin takes snapshot
- token admin creates and funds distribution contract
- account that held tokens at snapshot can claim their share of dividend
- it is not relevant who holds the tokens after the snapshot

## Exit

Legal requirement: token holder must send token to a company address in order to get their proceeds.

Company announces exit date. From that date on for 3 years, holders can execute their rights. Snapshots are not relevant. When a holder returns the tokens, the company must issue the reward, manually or automatically.

### automated approach

- company sets up exit contract
- after exit date, holders can claim
- during claim:
  - the token is transferred to the contract
  - the reward is calculated and transferred to the former holder

### manual approach

- after exit, holder simply transfers their tokens to the announced company address (which can be a smart contract)
- then, the company issues the reward (possibly through smart contract)
