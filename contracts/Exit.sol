// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Token.sol";
import "./common/IFeeSettings.sol";

struct ExitInitializerArguments {
    /// @notice Owner of the contract
    address owner;
    /// @notice Token holders will return in exchange for exit proceeds
    Token token;
    /// @notice ERC20 token used for exit payouts; must have TRUSTED_CURRENCY bit set on the token's allowList
    IERC20 currency;
    /// @notice Currency amount (in smallest currency units) per 10**token.decimals() token units
    uint256 pricePerToken;
    /// @notice Timestamp from which claims are valid
    uint64 claimStart;
    /// @notice Timestamp after which claims expire
    uint64 drainStart;
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
    uint64 public drainStart;

    /**
     * This constructor creates a logic contract that is used to clone new exit contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the exit contract. Can only be called once.
     * @param _arguments Struct containing all configuration parameters
     * @param _currencyProvider Address that provides the currency funding; must have approved this contract
     * @param _totalCurrencyAmount Amount of currency to transfer from _currencyProvider at initialization;
     *  should cover all eligible payouts plus fees (totalTokenSupply * pricePerToken + fees)
     */
    function initialize(
        ExitInitializerArguments memory _arguments,
        address _currencyProvider,
        uint256 _totalCurrencyAmount
    ) external initializer {
        require(_arguments.pricePerToken > 0, "price must be positive");
        require(_arguments.claimStart > 0, "claimStart must be set");
        require(_arguments.drainStart > _arguments.claimStart, "drainStart must be after claimStart");
        require(address(_arguments.currency) != address(_arguments.token), "currency and token must be different");
        __Ownable2Step_init();
        _transferOwnership(_arguments.owner);
        token = _arguments.token;
        require(
            token.allowList().map(address(_arguments.currency)) == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        currency = _arguments.currency;
        pricePerToken = _arguments.pricePerToken;
        claimStart = _arguments.claimStart;
        drainStart = _arguments.drainStart;
        _arguments.currency.safeTransferFrom(_currencyProvider, address(this), _totalCurrencyAmount);
    }


    /**
     * @notice Returns the currency amount a holder would receive for their entire current token balance.
     * @param _holder Address of the token holder
     * @return Currency amount the holder would receive for all their tokens at the current price
     */
    function eligible(address _holder) public view returns (uint256) {
        return (token.balanceOf(_holder) * pricePerToken) / 10 ** token.decimals();
    }

    /**
     * @notice Transfers _tokenAmount tokens from the caller to this contract and sends the
     *  corresponding currency payout to _recipient. Supports ERC2771 meta-transactions.
     * @param _tokenAmount Amount of tokens to exchange; caller must have approved this contract
     * @param _recipient Address that receives the currency payout
     * @param _minPayout Minimum acceptable payout; reverts if the resulting currency amount is below this
     */
    function claim(uint256 _tokenAmount, address _recipient, uint256 _minPayout) external {
        _claim(_msgSender(), _tokenAmount, _recipient, _minPayout);
    }

    /**
     * @notice Transfers the entire currency balance of this contract to _recipient.
     *  Can only be called by the owner after drainStart has passed.
     *  Intended to recover unclaimed funds once the exit window is closed.
     * @param _recipient Address that receives the remaining currency balance
     */
    function drain(address _recipient) external onlyOwner {
        require(block.timestamp > drainStart, "exit window not yet closed");
        currency.safeTransfer(_recipient, currency.balanceOf(address(this)));
    }

    /**
     * @notice Internal claim logic. Pulls tokens from _holder, sends currency to _recipient and, if IFeeSettingsV3
     *  is supported, additionally transfers the fee to the fee collector from the contract's balance.
     * @param _holder Address whose tokens are transferred
     * @param _tokenAmount Amount of tokens to exchange
     * @param _recipient Address that receives the currency payout
     * @param _minPayout Minimum acceptable payout; reverts if the resulting currency amount is below this
     */
    function _claim(address _holder, uint256 _tokenAmount, address _recipient, uint256 _minPayout) internal {
        require(block.timestamp >= claimStart, "exit not yet started");
        IERC20(address(token)).safeTransferFrom(_holder, address(this), _tokenAmount);
        uint256 currencyAmount = (_tokenAmount * pricePerToken) / 10 ** token.decimals();
        require(currencyAmount >= _minPayout, "payout below minimum");
        IFeeSettingsV3 feeSettings = IFeeSettingsV3(address(token.feeSettings()));
        if (feeSettings.supportsInterface(type(IFeeSettingsV3).interfaceId)) {
            uint256 fee = feeSettings.fee(FeeTypes.EXIT, currencyAmount, address(token));
            address feeCollector = feeSettings.feeCollector(FeeTypes.EXIT, address(token));
            if (fee != 0) {
                currency.safeTransfer(feeCollector, fee);
            }
        }
        currency.safeTransfer(_recipient, currencyAmount);
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
