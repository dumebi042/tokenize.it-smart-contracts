// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./TokenSwapBase.sol";

struct TokenSwapCoinvestorInitializerArguments {
    /// Owner of the contract
    address owner;
    /// beneficiaries[0] is the coinvestor, the rest are carry receivers (lead investors)
    address[] beneficiaries;
    /// carry percentages for each beneficiary, divided by uint64.max
    uint64[] percentage;
    /// base price per token in currency bits (amount coinvestor is entitled to per token before carry)
    uint256 basePrice;
    /// sell price per token in currency bits
    uint256 tokenPrice;
    /// currency used for payment. Must be ERC20.
    IERC20 currency;
    /// token being sold
    Token token;
}

/**
 * @title TokenSwapCoinvestor
 * @author malteish, cjentzsch
 * @notice This contract holds tokens and sells them at a preset price, distributing proceeds
 *      between a coinvestor and carry receivers (lead investors).
 *      The coinvestor (beneficiaries[0]) receives basePrice per token sold.
 *      Any remaining proceeds after fees and coinvestor payout are split among all beneficiaries
 *      according to their carry percentages.
 *      If the sale price minus fees is less than the base price, all proceeds go to the coinvestor.
 * @dev Uses clone/proxy pattern. Constructor disables initializers, separate initialize().
 */
contract TokenSwapCoinvestor is TokenSwapBase {
    using SafeERC20 for IERC20;

    /// beneficiaries[0] is the coinvestor, the rest are carry receivers
    address[] public beneficiaries;
    /// carry percentages for each beneficiary, divided by uint64.max
    uint64[] public percentage;
    /// base price per token in currency bits
    uint256 public basePrice;

    /**
     * This constructor creates a logic contract that is used to clone new contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) TokenSwapBase(_trustedForwarder) {}

    /**
     * @notice Sets up the TokenSwapCoinvestor. The contract is usable immediately after being initialized.
     * @param _arguments Struct containing all arguments for the initializer
     */
    function initialize(TokenSwapCoinvestorInitializerArguments memory _arguments) external initializer {
        _initializeBase(_arguments.owner, _arguments.tokenPrice, _arguments.currency, _arguments.token);

        require(
            _arguments.beneficiaries.length == _arguments.percentage.length,
            "beneficiaries and percentage arrays must have same length"
        );
        require(_arguments.beneficiaries.length > 0, "must have at least one beneficiary");
        for (uint256 i = 0; i < _arguments.beneficiaries.length; i++) {
            require(_arguments.beneficiaries[i] != address(0), "beneficiary can not be zero address");
        }

        beneficiaries = _arguments.beneficiaries;
        percentage = _arguments.percentage;
        basePrice = _arguments.basePrice;

        _pause();
    }

    /**
     * @notice Buy `_tokenAmount` tokens and transfer them to `_tokenReceiver`.
     * @param _tokenAmount amount of tokens to buy, in bits (smallest subunit of token)
     * @param _maxCurrencyAmount maximum amount of currency to spend, in bits (smallest subunit of currency)
     * @param _tokenReceiver address the tokens should be transferred to
     */
    function buy(
        uint256 _tokenAmount,
        uint256 _maxCurrencyAmount,
        address _tokenReceiver
    ) public whenNotPaused nonReentrant {
        // rounding up to the next whole number. Buyer is charged up to one currency bit more in case of a fractional currency bit.
        uint256 currencyAmount = Math.ceilDiv(_tokenAmount * tokenPrice, 10 ** token.decimals());

        require(currencyAmount <= _maxCurrencyAmount, "Purchase more expensive than _maxCurrencyAmount");

        // collect fee
        (uint256 fee, address feeCollector) = _getFeeAndFeeReceiver(currencyAmount);
        if (fee != 0) {
            currency.safeTransferFrom(_msgSender(), feeCollector, fee);
        }

        uint256 remaining = currencyAmount - fee;

        // calculate coinvestor's base payout
        uint256 payoutCoinvestor = (basePrice * _tokenAmount) / (10 ** token.decimals());

        if (payoutCoinvestor >= remaining) {
            // sale price minus fees doesn't cover base price: all goes to coinvestor
            currency.safeTransferFrom(_msgSender(), beneficiaries[0], remaining);
        } else {
            // pay base price to coinvestor
            currency.safeTransferFrom(_msgSender(), beneficiaries[0], payoutCoinvestor);

            // split carry among all beneficiaries
            uint256 carry = remaining - payoutCoinvestor;
            uint256 distributed = 0;
            for (uint256 i = 0; i < beneficiaries.length; i++) {
                uint256 share = (uint256(percentage[i]) * carry) / type(uint64).max;
                if (share != 0) {
                    currency.safeTransferFrom(_msgSender(), beneficiaries[i], share);
                    distributed += share;
                }
            }
            // send any rounding dust to the coinvestor
            if (distributed < carry) {
                currency.safeTransferFrom(_msgSender(), beneficiaries[0], carry - distributed);
            }
        }

        // transfer tokens from this contract to the buyer's receiver
        token.transfer(_tokenReceiver, _tokenAmount);

        emit TokensBought(_msgSender(), _tokenAmount, currencyAmount);
    }

    /**
     * @notice Emergency exit: transfer all tokens of `_token` to `_admin`, who must be a token admin.
     * @param _token the token to withdraw
     * @param _admin the token admin to send to
     */
    function withdrawToTokenAdmin(Token _token, address _admin) external onlyOwner {
        require(_token.hasRole(bytes32(0), _admin), "_admin must be token admin");
        _token.transfer(_admin, _token.balanceOf(address(this)));
    }
}
