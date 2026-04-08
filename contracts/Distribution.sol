// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Token.sol";
import "./common/IFeeSettings.sol";

struct Reassignment {
    address from;
    address to;
    uint256 amount;
}

struct DistributionInitializerArguments {
    /// @notice Owner of the contract
    address owner;
    /// @notice Token whose snapshot determines distribution shares
    Token token;
    /// @notice Snapshot id that determines distribution shares
    uint256 snapshotId;
    /// @notice ERC20 token used for distribution payouts; must have TRUSTED_CURRENCY bit set on the token's allowList
    IERC20 currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 pricePerToken;
    /// @notice Earliest timestamp at which the owner can reassign unclaimed funds or drain the contract
    uint64 reassignOrDrainAfter;
    /// @notice Reassignments to apply immediately at initialization, bypassing the time restriction
    Reassignment[] initialReassignments;
}

/**
 * @title tokenize.it Distribution
 * @author malteish, cjentzsch
 * @notice This contract implements the distribution of any proceeds (e.g. Dividends)
 *      based on a snapshot of Token.sol.
 *      Initial funding ideally covers all eligible payouts plus fees (tokenSupplyAtSnapshot * pricePerToken + fees),
 *      but that is not enforced. More funds can be added later.
 */
contract Distribution is ERC2771ContextUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    Token public token;
    uint256 public snapshotId;
    IERC20 public currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 public pricePerToken;
    mapping(address => uint256) public paidOut;
    /// @notice Extra currency credit assigned to an address via reassign(), analogous to token reissuance after key loss
    mapping(address => uint256) public extraCredit;
    uint64 public reassignOrDrainAfter;

    event Reassigned(address indexed from, address indexed to, uint256 amount);

    /**
     * This constructor creates a logic contract that is used to clone new distribution contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the distribution contract. Can only be called once.
     * @param _arguments Struct containing all configuration parameters
     * @param _currencyProvider Address that provides the initial currency funding; must have approved this contract
     * @param _initialFundingAmount Amount of currency to transfer from _currencyProvider at initialization
     */
    function initialize(
        DistributionInitializerArguments memory _arguments,
        address _currencyProvider,
        uint256 _initialFundingAmount
    ) external initializer {
        require(_arguments.pricePerToken > 0, "price must be positive");
        __ReentrancyGuard_init();
        __Ownable2Step_init();
        _transferOwnership(_arguments.owner);
        token = _arguments.token;
        snapshotId = _arguments.snapshotId;
        // background: totalSupply 0 would make every claim revert, thus locking up funds forever
        require(token.totalSupplyAt(snapshotId) > 0, "snapshot has no tokens");
        currency = _arguments.currency;
        require(address(_arguments.currency) != address(_arguments.token), "currency and token must be different");
        require(
            token.allowList().map(address(_arguments.currency)) & TRUSTED_CURRENCY == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        pricePerToken = _arguments.pricePerToken;
        reassignOrDrainAfter = _arguments.reassignOrDrainAfter;
        if (_initialFundingAmount > 0) {
            _arguments.currency.safeTransferFrom(_currencyProvider, address(this), _initialFundingAmount);
        }
        for (uint256 i = 0; i < _arguments.initialReassignments.length; i++) {
            Reassignment memory reassignment = _arguments.initialReassignments[i];
            _reassign(reassignment.from, reassignment.to, reassignment.amount);
        }
    }


    /**
     * @notice Returns the amount of currency a holder can claim.
     *  Equals the holder's token balance at the snapshot multiplied by pricePerToken,
     *  plus any extra credit from reassignments, minus already paid out amounts.
     * @param _holder Address of the token holder
     * @return Amount of currency claimable by _holder
     */
    function eligible(address _holder) public view returns (uint256) {
        return
            (token.balanceOfAt(_holder, snapshotId) * pricePerToken) /
            (10 ** token.decimals()) +
            extraCredit[_holder] -
            paidOut[_holder];
    }

    /**
     * @notice Reassigns (unclaimed) distribution funds from one address to another. This is used to fix
     *  holders in the snapshot not being able to claim their funds. It can be audited because the
     *  reassignment is emitted on-chain. Some cases that could lead to this being needed:
     *      - holder losing their key and only noticing after the snapshot
     *      - a smart contract holder that cannot execute the claim for any reason
     *      - a Vesting contract holding tokens for multiple beneficiaries: the owner can reassign
     *        each beneficiary's proportional share individually
     * @dev onlyOwner, matching the requirements of calling Token.burn+mint to fix an issue with
     *  current token holders.
     * @param _amount amount of currency to reassign; must not exceed eligible(_from)
     */
    function reassign(address _from, address _to, uint256 _amount) external onlyOwner {
        require(block.timestamp >= reassignOrDrainAfter, "reassignment not yet available");
        _reassign(_from, _to, _amount);
    }

    /**
     * @notice Internal reassignment logic shared by reassign() and initialize().
     * @param _from Address whose eligible amount is reduced
     * @param _to Address that receives the extra credit
     * @param _amount Amount of currency to reassign; must not exceed eligible(_from)
     */
    function _reassign(address _from, address _to, uint256 _amount) internal {
        require(_to != address(0), "to can not be zero address");
        require(_amount > 0, "amount must be positive");
        require(_amount <= eligible(_from), "amount exceeds eligible");
        paidOut[_from] += _amount;
        extraCredit[_to] += _amount;
        emit Reassigned(_from, _to, _amount);
    }

    /**
     * @notice Claims the full eligible amount for the caller and sends it to _recipient.
     *  Supports both direct calls and meta-transactions via ERC2771.
     *  Transfers the fee to the fee collector from the contract's balance if IFeeSettingsV3 is supported.
     * @param _recipient Address that receives the currency payout
     * @param _minPayout Minimum acceptable payout; reverts if eligible amount is below this
     */
    function claim(address _recipient, uint256 _minPayout) external nonReentrant {
        address holder = _msgSender();
        uint256 eligibleAmount = eligible(holder);
        require(eligibleAmount > 0, "nothing to claim");
        paidOut[holder] += eligibleAmount;
        require(eligibleAmount >= _minPayout, "payout below minimum");
        IFeeSettingsV3 feeSettings = IFeeSettingsV3(address(token.feeSettings()));
        if (feeSettings.supportsInterface(type(IFeeSettingsV3).interfaceId)) {
            uint256 fee = feeSettings.fee(FeeTypes.DISTRIBUTION, eligibleAmount, address(token));
            address feeCollector = feeSettings.feeCollector(FeeTypes.DISTRIBUTION, address(token));
            if (fee != 0) {
                currency.safeTransfer(feeCollector, fee);
            }
        }
        currency.safeTransfer(_recipient, eligibleAmount);
    }

    /**
     * @notice Transfers the entire currency balance of this contract to _recipient.
     *  Can only be called by the owner after reassignOrDrainAfter has passed.
     *  Intended to recover unclaimed funds once the distribution period is over.
     * @param _recipient Address that receives the remaining currency balance
     */
    function drain(address _recipient) external onlyOwner nonReentrant {
        require(block.timestamp >= reassignOrDrainAfter, "drain not yet available");
        currency.safeTransfer(_recipient, currency.balanceOf(address(this)));
    }

    /// @inheritdoc ERC2771ContextUpgradeable
    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /// @inheritdoc ERC2771ContextUpgradeable
    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    /// @inheritdoc ERC2771ContextUpgradeable
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
