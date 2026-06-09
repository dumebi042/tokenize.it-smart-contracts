# **Tokenize.it Token SC DualDefense Audit**

Company:[Tokenize.it](https://hackenproof.com/companies/tokenize-dot-it)

## Program info

The [tokenize.it](https://hackenproof.com/redirect?url=http%3A%2F%2Ftokenize.it) protocol is a modular smart contract system for tokenizing real-world company equity on the EVM. It provides a complete lifecycle — from token issuance with compliance enforcement, through primary and secondary market sales, vesting, dividend distribution, and exit — with platform-level fee collection and an AllowList-based KYC/attribute registry governing who may transact.

## In scope

| Target | Type | Severity | Reward |
| :---- | :---- | :---- | :---- |
| [https://github.com/corpus-io/tokenize.it-smart-contracts/tree/52b0322fb566c7143d09c23b7bd30f2e092e0691](https://github.com/corpus-io/tokenize.it-smart-contracts/tree/52b0322fb566c7143d09c23b7bd30f2e092e0691) Final Commit: 52b0322fb566c7143d09c23b7bd30f2e092e0691 [Requirements](https://github.com/corpus-io/tokenize.it-smart-contracts/tree/52b0322fb566c7143d09c23b7bd30f2e092e0691/docs) [Technical Requirements](https://github.com/corpus-io/tokenize.it-smart-contracts/blob/52b0322fb566c7143d09c23b7bd30f2e092e0691/README.md) | Smart Contract | Critical |  |

## Focus Area

### **IN-SCOPE: SMART CONTRACT VULNERABILITIES**

We are looking for evidence and reasons for incorrect behavior of the smart contract, which could cause unintended functionality:

* Stealing or loss of end-user funds  
* Permanent lock of end-user funds

### **OUT OF SCOPE: SMART CONTRACT VULNERABILITIES**

* Theoretical vulnerabilities without any proof or demonstration  
* Old compiler version  
* The compiler version is not locked  
* Vulnerabilities in imported contracts  
* Code style guide violations  
* Redundant code  
* Gas optimizations  
* Best practice issues  
* Known issues on GitHub issue tracker  
* Known issues in [README.md](https://github.com/corpus-io/tokenize.it-smart-contracts/blob/52b0322fb566c7143d09c23b7bd30f2e092e0691/README.md)  
* Front-run attacks  
* All other issues not mentioned “IN SCOPE” area

## Program Rules

**Only critical vulnerabilities that could lead to the loss of user funds or the permanent lock of funds are eligible for rewards.**

* The company is not obliged to pay for "Low"-"High" severity issues. Only "Critical" issues are under the scope. However, the team may, at its discretion, accept the report and pay the bonus, the reward will not be a part of the bounty pool.  
* Perform testing only within the scope  
* Any details of found vulnerabilities must not be communicated to anyone who is not a HackenProof Team or an authorized employee of this Company without appropriate permission  
* All communication regarding the program must take place exclusively through the HackenProof platform. Contacting the project team directly through support channels, social media, or any other external communication channels is strictly prohibited. Researchers who violate this rule may be disqualified from the program and may face account suspension.  
* Each vulnerability must have a fully working Proof of Concept (PoC) attached to the report at the time of submission. Submissions missing a valid POC will be closed and may result in a reputation point penalty.  
* Each vulnerability must have a significant, implicit high likelihood of exploitation.  
* Each vulnerability must include a suggested fix or mitigation strategy at the time of submission of the report  
* Human-based errors and rogue privileged users are considered to be not valid vulnerabilities or risks.

**Fail to comply with these rules may result in the closure of your report, loss of reputation points, and ban from future participation in the contest**  
**A critical vulnerability is defined as a vulnerability with both high likelihood and high impact.**

### **High likelihood:**

* The attack can be executed without requiring privileged roles, although it may involve a mechanism that allows the attacker to gain control over a privileged entity and exploit that power if the vulnerability permits privilege escalation.  
* It does not require a significant token balance or substantial funding.  
* It does not demand considerable computational resources or extended time.  
* It has limited number of conditions that must occur.

### **High impact:**

* Direct theft of end-user funds.  
* Direct theft of protocol’s owner funds.  
* Permanent lockout of end-user funds.  
* Permanent lockout of protocol’s owner funds.  
* The amount of stolen or locked funds must exceed 2% of protocol’s TVL.  
* The amount of stolen or locked funds must exceed 1% of user’s deposit.

## Reward Distribution:

* The reward will be distributed in HAI tokens. For that you will need to provide in your account your hAI wallet address so we can arrange the transaction.

**Clear wording:**

* Bounty pool — total amount of reward in the DualDefence Audit.  
* Allocated bounty — amount of reward for each unique vulnerability reported.  
* The total bounty pool for the DualDefence Audit will be equally split among all unique issues reported.  
* Example: If three researchers identify the same vulnerability and also there are two other vulnerabilities submitted only once (total 3 unique issues reported) each vulnerability will get 1/3 of the bounty pool.  
  Allocated bounty reward will be split between all researchers who submitted the same issue (where uniq issues receive 1/3 of the pool and researchers will get 1/9 each of the initial reward pool).

Allocated bounty reward will be split between all researchers who submitted the same issue (where uniq issues receive 1/3 of the pool and researchers will get 1/9 each of the initial reward pool).  
HackenProof is entitled to 10% of rewards as the fee for the triage and other services\!

### **Single Valid Submission**

Full Reward: If a critical vulnerability is found by only one participant, that reporter receives 100% of the bounty pool.

### **Duplicate Submissions**

If multiple participants find the same vulnerability, the allocated bounty for that issue (bounty pool always equally split among all unique issues reported) is divided equally among all reporters.  
Example: If two researchers report the same vulnerability, each receives 50% of the allocated bounty. It can be 50% of the bounty pool if only one eligible issue was reported.

### **Multiple Unique Submissions**

Split Based on Uniqueness of issues reported:

* Unique Issue 1: Found by one reporter.  
* Unique Issue 2: Found by another reporter.

Each will receive 50% of the bounty pool.  
For any questions regarding the program, feel free to reach out in our [DualDefense Support Request](https://hackenproof.com/redirect?url=https%3A%2F%2Fdiscord.com%2Fchannels%2F918595597769015397%2F1358942125609455727).  
HackenProof is entitled to 10% of rewards as the fee for the triage and other services‼️

## Disclosure Guidelines

Do not discuss this program or any vulnerabilities (even resolved ones) outside of the program without express consent from the organization

* No vulnerability disclosure, including partial is allowed till the end of FlashBounty Audit contest.  
* Please do NOT publish/discuss bugs  
* Researchers must not contact the project team directly regarding any findings, questions, or bounty-related matters. All communication must be conducted through the HackenProof platform only.

## Eligibility and Coordinated Disclosure

We are happy to thank everyone who submits valid reports which help us improve our security. However, only those that meet the following eligibility requirements may receive a monetary reward:

* The vulnerability must be a qualifying vulnerability.  
* Any vulnerability found must be reported exclusively through [hackenproof.com](https://hackenproof.com/redirect?url=http%3A%2F%2Fhackenproof.com).  
* You must provide a clear textual description of the issue along with detailed reproduction steps, including screenshots or proof-of-concept code as necessary.  
* You must not be a current or former employee, or contractor, of our organization.  
* Reports must be concise, relevant, and easy to reproduce.  
* Findings must be applicable to the protocol as currently deployed. Hypothetical issues based on alternative or future deployments (e.g., on different chains or configurations) are out of scope.  
* AI-generated reports without runable PoC are not accepted under this program.

#### **Last audit**

[Hacken](https://hacken.io/audits/tokenize-it/sca-tokenize-it-token-apr2026/) \- May 2026

## Assets in Scope

./Crowdinvesting.sol  
./FeeSettings.sol  
./Vesting.sol  
./Token.sol  
./CoinvestedPosition.sol  
./Distribution.sol  
./Exit.sol  
./PriceLinear.sol  
./common/TokenSwapBase.sol  
./TimeLock.sol  
./PrivateOffer.sol  
./AllowList.sol  
./TokenSwap.sol  
./GlobalTokenExitRegistry.sol  
common/PayoutBase.sol

