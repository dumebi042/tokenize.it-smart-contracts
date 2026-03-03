// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Vesting.sol";
import "./Token.sol";
import "./interfaces/IFeeSettings.sol";

struct ExitInitializerArguments {
    /// @notice Owner of the contract
    address owner;
    /// @notice Token holders will return in exchange for exit proceeds
    Token token;
    /// @notice ERC20 token used for exit payouts; must have TRUSTED_CURRENCY | EURO_CURRENCY bits set on the token's allowList
    IERC20 currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 pricePerToken;
    /// @notice Timestamp from which claims are valid
    uint64 claimStart;
    /// @notice Timestamp after which claims expire
    uint64 claimEnd;
    /// @notice Total amount of currency to fund the exit contract with
    uint256 totalCurrencyAmount;
}

/**
 * @title tokenize.it Exit
 * @author malteish, cjentzsch
 * @notice This contract implements the automated exit: token holders transfer their tokens here
 *  and receive exit proceeds in return. The price is fixed at deployment.
 *  Claims are only valid within the exit window set at initialization.
 *  Received tokens are held in this contract (not burned).
 */
contract Exit is ERC2771ContextUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    Token public token;
    IERC20 public currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 public pricePerToken;
    uint64 public claimStart;
    uint64 public claimEnd;

    /**
     * This constructor creates a logic contract that is used to clone new exit contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
        _disableInitializers();
    }

    function initialize(ExitInitializerArguments memory _arguments, address _currencyProvider) external initializer {
        require(_arguments.pricePerToken > 0, "price must be positive");
        require(_arguments.claimStart > 0, "claimStart must be set");
        require(_arguments.claimEnd > _arguments.claimStart, "claimEnd must be after claimStart");
        require(address(_arguments.currency) != address(_arguments.token), "currency and token must be different");
        __Ownable2Step_init();
        _transferOwnership(_arguments.owner);
        token = _arguments.token;
        require(
            token.allowList().map(address(_arguments.currency)) & (TRUSTED_CURRENCY | EURO_CURRENCY) ==
                (TRUSTED_CURRENCY | EURO_CURRENCY),
            "currency needs to be a trusted EURO currency"
        );
        currency = _arguments.currency;
        pricePerToken = _arguments.pricePerToken;
        claimStart = _arguments.claimStart;
        claimEnd = _arguments.claimEnd;
        _arguments.currency.safeTransferFrom(_currencyProvider, address(this), _arguments.totalCurrencyAmount);
    }

    function claim(uint256 _tokenAmount, address _recipient) external {
        _claim(_msgSender(), _tokenAmount, _recipient);
    }

    function claim(
        IERC1271 _holder,
        bytes32 _hash,
        bytes memory _signature,
        uint256 _tokenAmount,
        address _recipient
    ) external {
        require(_holder.isValidSignature(_hash, _signature) == 0x1626ba7e);
        _claim(address(_holder), _tokenAmount, _recipient);
    }

    function claim(Vesting _holder, uint256 _tokenAmount, address _recipient) external {
        // only works for lockups, where there is only one vesting plan per deployment
        require(_msgSender() == _holder.beneficiary(0));
        _claim(address(_holder), _tokenAmount, _recipient);
    }

    function drain(address _recipient) external onlyOwner {
        require(block.timestamp > claimEnd, "exit window not yet closed");
        currency.safeTransfer(_recipient, currency.balanceOf(address(this)));
    }

    function _claim(address _holder, uint256 _tokenAmount, address _recipient) internal {
        require(block.timestamp >= claimStart, "exit not yet started");
        require(block.timestamp <= claimEnd, "exit window closed");
        IERC20(address(token)).safeTransferFrom(_holder, address(this), _tokenAmount);
        uint256 currencyAmount = (_tokenAmount * pricePerToken) / 10 ** token.decimals();
        IFeeSettingsV2 feeSettings = token.feeSettings();
        uint256 fee = feeSettings.privateOfferFee(currencyAmount, address(token));
        if (fee != 0) {
            currency.safeTransfer(feeSettings.privateOfferFeeCollector(address(token)), fee);
        }
        currency.safeTransfer(_recipient, currencyAmount - fee);
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
