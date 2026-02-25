// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Vesting.sol";
import "./Token.sol";

/**
 * @title tokenize.it Exit
 * @author malteish, cjentzsch
 * @notice This contract implements the automated exit: token holders transfer their tokens here
 *  and receive exit proceeds in return. The price is fixed at deployment.
 *  Claims are only valid within 3 years of the exit date.
 *  Received tokens are held in this contract (not burned).
 */
contract Exit is ERC2771ContextUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    uint64 public constant EXIT_WINDOW = 3 * 365 days;

    Token public token;
    IERC20 public currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 public pricePerToken;
    uint64 public exitDate;

    /**
     * This constructor creates a logic contract that is used to clone new exit contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
        _disableInitializers();
    }

    function initialize(
        Token _token,
        address _owner,
        IERC20 _currency,
        uint256 _pricePerToken,
        uint64 _exitDate,
        uint256 _totalCurrencyAmount
    ) external initializer {
        require(_pricePerToken > 0, "price must be positive");
        require(_exitDate > 0, "exitDate must be set");
        __Ownable2Step_init();
        _transferOwnership(_owner);
        token = _token;
        require(
            token.allowList().map(address(_currency)) & TRUSTED_CURRENCY == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        currency = _currency;
        pricePerToken = _pricePerToken;
        exitDate = _exitDate;
        require(_currency.balanceOf(address(this)) == _totalCurrencyAmount);
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
        require(block.timestamp > uint256(exitDate) + EXIT_WINDOW, "exit window not yet closed");
        currency.safeTransfer(_recipient, currency.balanceOf(address(this)));
    }

    function _claim(address _holder, uint256 _tokenAmount, address _recipient) internal {
        require(block.timestamp >= exitDate, "exit not yet started");
        require(block.timestamp <= uint256(exitDate) + EXIT_WINDOW, "exit window closed");
        IERC20(address(token)).safeTransferFrom(_holder, address(this), _tokenAmount);
        uint256 currencyAmount = (_tokenAmount * pricePerToken) / 10 ** token.decimals();
        currency.safeTransfer(_recipient, currencyAmount);
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
