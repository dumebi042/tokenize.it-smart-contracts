// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Token.sol";
import "./interfaces/IFeeSettings.sol";

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
    /// @notice Total amount of currency to distribute
    uint256 totalCurrencyAmount;
    /// @notice Earliest timestamp at which the owner can reassign unclaimed funds
    uint64 reassignAfter;
    /// @notice Reassignments to apply immediately at initialization, bypassing the reassignAfter time restriction
    Reassignment[] initialReassignments;
}

/**
 * @title tokenize.it Distribution
 * @author malteish, cjentzsch
 * @notice This contract implements the distribution of any proceeds (Liquidation, Dividends)
 *      based on a snapshot of Token.sol
 */
contract Distribution is ERC2771ContextUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    Token public token;
    uint256 public snapshotId;
    IERC20 public currency;
    uint256 public totalCurrencyAmount;
    mapping(address => uint256) public paidOut;
    /// @notice Extra currency credit assigned to an address via reassign(), analogous to token reissuance after key loss
    mapping(address => uint256) public extraCredit;
    uint64 public reassignAfter;

    event Reassigned(address indexed from, address indexed to, uint256 amount);

    /**
     * This constructor creates a logic contract that is used to clone new distribution contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
        _disableInitializers();
    }

    function initialize(
        DistributionInitializerArguments memory _arguments,
        address _currencyProvider
    ) external initializer {
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
        IFeeSettingsV2 feeSettingsV2 = _arguments.token.feeSettings();
        uint256 fee;
        address feeCollector;
        if (feeSettingsV2.supportsInterface(type(IFeeSettingsV3).interfaceId)) {
            IFeeSettingsV3 feeSettings = IFeeSettingsV3(address(feeSettingsV2));
            fee = feeSettings.fee(FeeTypes.DISTRIBUTION, _arguments.totalCurrencyAmount, address(_arguments.token));
            feeCollector = feeSettings.feeCollector(FeeTypes.DISTRIBUTION, address(_arguments.token));
        } else {
            fee = feeSettingsV2.privateOfferFee(_arguments.totalCurrencyAmount, address(_arguments.token));
            feeCollector = feeSettingsV2.privateOfferFeeCollector(address(_arguments.token));
        }
        if (fee != 0) {
            _arguments.currency.safeTransferFrom(_currencyProvider, feeCollector, fee);
        }
        totalCurrencyAmount = _arguments.totalCurrencyAmount - fee;
        reassignAfter = _arguments.reassignAfter;
        _arguments.currency.safeTransferFrom(_currencyProvider, address(this), totalCurrencyAmount);
        for (uint256 i = 0; i < _arguments.initialReassignments.length; i++) {
            Reassignment memory reassignment = _arguments.initialReassignments[i];
            _reassign(reassignment.from, reassignment.to, reassignment.amount);
        }
    }

    function eligible(address _holder) public view returns (uint256) {
        return
            (totalCurrencyAmount * token.balanceOfAt(_holder, snapshotId)) /
            token.totalSupplyAt(snapshotId) +
            extraCredit[_holder] -
            paidOut[_holder];
    }

    /**
     * @notice Reassigns unclaimed distribution funds from one address to another. This is used to fix
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
        require(block.timestamp >= reassignAfter, "reassignment not yet available");
        _reassign(_from, _to, _amount);
    }

    function _reassign(address _from, address _to, uint256 _amount) internal {
        require(_amount > 0, "amount must be positive");
        require(_amount <= eligible(_from), "amount exceeds eligible");
        paidOut[_from] += _amount;
        extraCredit[_to] += _amount;
        emit Reassigned(_from, _to, _amount);
    }

    function claim(address _recipient) external {
        _claim(_msgSender(), _recipient); //should work for directly calling it (msg.sender), as well as with a meta transaction with a signed message
    }

    function _claim(address _holder, address _recipient) internal {
        uint256 amount = eligible(_holder);
        paidOut[_holder] += amount;
        currency.safeTransfer(_recipient, amount);
    }

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
