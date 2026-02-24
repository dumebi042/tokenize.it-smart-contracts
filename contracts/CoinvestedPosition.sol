// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./TokenSwapBase.sol";
import "./IDistribution.sol";
import "./IExit.sol";

struct LeadInvestor {
    /// lead investor address that receives carry
    address account;
    /// carry percentage, divided by uint64.max
    uint64 carryFraction;
}

struct CoinvestedPositionInitializerArguments {
    /// Owner of the contract
    address owner;
    /// coinvestor address: receives base price payout and carry dust
    address receiver;
    /// lead investors and their carry fractions
    LeadInvestor[] leadInvestors;
    /// base price per token in EURO bits (smallest subunit of any EURO currency; amount coinvestor is entitled to per token before carry)
    uint256 basePrice;
    /// currency used for buy() payments. Must be a EURO ERC20 (TRUSTED_CURRENCY | EURO_CURRENCY bits set on the token's allowList).
    IERC20 currency;
    /// token being held
    Token token;
}

/**
 * @title CoinvestedPosition
 * @author malteish, cjentzsch
 * @notice This contract holds tokens and sells them at a preset price, distributing proceeds
 *      between a coinvestor (receiver) and lead investors.
 *      The coinvestor (receiver) receives basePrice (a EURO reference price) per token sold.
 *      Any remaining proceeds after fees and coinvestor payout are split among lead investors
 *      according to their carry percentages, with dust going to the coinvestor.
 *      If the sale price minus fees is less than the base price, all proceeds go to the coinvestor.
 *      For exits and dividends, any EURO token (with TRUSTED_CURRENCY | EURO_CURRENCY bits set on the
 *      token's allowList) may be used, not just the currency stored for buy().
 * @dev Uses clone/proxy pattern. Constructor disables initializers, separate initialize().
 */
contract CoinvestedPosition is TokenSwapBase {
    using SafeERC20 for IERC20;

    /// lead investors and their carry fractions
    LeadInvestor[] public leadInvestors;
    /// base price per token in EURO bits (smallest subunit of any EURO currency)
    uint256 public basePrice;
    /// decimals of the currency used when basePrice was set; used to scale payouts when a different EURO token is used at exit/dividend time
    uint8 public basePriceDecimals;

    /**
     * This constructor creates a logic contract that is used to clone new contracts.
     * It has no owner, and can not be used directly.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) TokenSwapBase(_trustedForwarder) {
        _disableInitializers();
    }

    /**
     * @notice Sets up the CoinvestedPosition. The contract is usable immediately after being initialized.
     * @param _arguments Struct containing all arguments for the initializer
     */
    function initialize(CoinvestedPositionInitializerArguments memory _arguments) external initializer {
        _initializeBase(_arguments.owner, 0, _arguments.currency, _arguments.token, _arguments.receiver);

        require(
            _arguments.token.allowList().map(address(_arguments.currency)) & (TRUSTED_CURRENCY | EURO_CURRENCY) == (TRUSTED_CURRENCY | EURO_CURRENCY),
            "currency must be a trusted EURO currency"
        );
        require(_arguments.leadInvestors.length > 0, "There must be at least one lead investor");
        uint256 carryFractionsSum = 0;
        for (uint256 i = 0; i < _arguments.leadInvestors.length; i++) {
            require(_arguments.leadInvestors[i].account != address(0), "lead investor can not be zero address");
            carryFractionsSum += _arguments.leadInvestors[i].carryFraction;
            leadInvestors.push(_arguments.leadInvestors[i]);
        }
        require(carryFractionsSum < type(uint64).max, "carry fractions must leave a share for the receiver");
        basePrice = _arguments.basePrice;
        basePriceDecimals = IERC20Metadata(address(_arguments.currency)).decimals();

        // Pausing the contract prevents an immediate sell of the tokens. Once they should be sold, update price and unpause.
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

        // pull full amount to this contract first, then distribute from here
        currency.safeTransferFrom(_msgSender(), address(this), currencyAmount);

        // collect fee
        (uint256 fee, address feeCollector) = _getFeeAndFeeReceiver(currencyAmount);
        if (fee != 0) {
            currency.safeTransfer(feeCollector, fee);
        }

        uint256 remaining = currencyAmount - fee;

        // calculate coinvestor's base payout
        uint256 payoutCoinvestor = (basePrice * _tokenAmount) / (10 ** token.decimals());

        if (payoutCoinvestor >= remaining) {
            // sale price minus fees doesn't cover base price: all goes to coinvestor
            currency.safeTransfer(receiver, remaining);
        } else {
            // pay base price to coinvestor, split remainder as carry
            currency.safeTransfer(receiver, payoutCoinvestor);
            _distributeCarry(remaining - payoutCoinvestor, currency);
        }

        // transfer tokens from this contract to the buyer's receiver
        token.transfer(_tokenReceiver, _tokenAmount);

        emit TokensBought(_msgSender(), _tokenAmount, currencyAmount);
    }

    /**
     * @notice Scales `_amount` from `basePriceDecimals` to `_targetDecimals`.
     * @param _amount amount expressed in basePriceDecimals units
     * @param _targetDecimals decimals of the target currency
     * @return scaled amount in target currency units
     */
    function _scaleToDecimals(uint256 _amount, uint8 _targetDecimals) internal view returns (uint256) {
        if (_targetDecimals > basePriceDecimals) {
            return _amount * 10 ** (_targetDecimals - basePriceDecimals);
        } else if (_targetDecimals < basePriceDecimals) {
            return _amount / 10 ** (basePriceDecimals - _targetDecimals);
        }
        return _amount;
    }

    /**
     * @notice Splits `carry` among lead investors by carryFraction; rounding dust goes to receiver.
     * @dev Assumes `carry` of `_currency` is already held by this contract.
     * @param carry amount of currency to distribute as carry
     * @param _currency the EURO token to distribute
     */
    function _distributeCarry(uint256 carry, IERC20 _currency) internal {
        uint256 distributed = 0;
        for (uint256 i = 0; i < leadInvestors.length; i++) {
            uint256 share = (uint256(leadInvestors[i].carryFraction) * carry) / type(uint64).max;
            if (share != 0) {
                _currency.safeTransfer(leadInvestors[i].account, share);
                distributed += share;
            }
        }
        uint256 receiverShare = carry - distributed;
        if (receiverShare > 0) {
            _currency.safeTransfer(receiver, receiverShare);
        }
    }

    /**
     * @notice Claim this contract's eligible dividend share from `_dist` and split it among lead investors.
     * @dev The full received amount is treated as carry and split among lead investors by carryFraction;
     *      remainder goes to receiver. Any EURO token (TRUSTED_CURRENCY | EURO_CURRENCY) may be used.
     * @param _dist the Distribution (dividend) contract to claim from
     * @param _dividendCurrency the EURO token paid out by the distribution
     */
    function distributeDividends(IDistribution _dist, IERC20 _dividendCurrency) external onlyOwner nonReentrant {
        require(
            token.allowList().map(address(_dividendCurrency)) & (TRUSTED_CURRENCY | EURO_CURRENCY) == (TRUSTED_CURRENCY | EURO_CURRENCY),
            "dividend currency must be a trusted EURO currency"
        );
        uint256 before = _dividendCurrency.balanceOf(address(this));
        _dist.claim(address(this));
        uint256 received = _dividendCurrency.balanceOf(address(this)) - before;
        require(received > 0, "didn't receive expected currency from distribution");
        _distributeCarry(received, _dividendCurrency);
    }

    /**
     * @notice Claim exit proceeds for this contract's full token balance and split them among the receiver and lead investors.
     * @dev Transfers all held tokens to the Exit contract in exchange for currency. Named separately from distribute()
     *      to avoid ABI-level clash (both IDistribution and IExit encode as address in external signatures).
     *      Receiver gets basePrice per token first; if proceeds < base, receiver gets everything; remainder is carry.
     *      Carry is split among lead investors by carryFraction; remainder goes to receiver.
     *      Any EURO token (TRUSTED_CURRENCY | EURO_CURRENCY) may be used, independent of the currency used for buy().
     * @param _exit the Exit contract to claim from
     * @param _exitCurrency the EURO token paid out by the exit
     */
    function distributeExit(IExit _exit, IERC20 _exitCurrency) external onlyOwner nonReentrant {
        require(
            token.allowList().map(address(_exitCurrency)) & (TRUSTED_CURRENCY | EURO_CURRENCY) == (TRUSTED_CURRENCY | EURO_CURRENCY),
            "exit currency must be a trusted EURO currency"
        );
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "no tokens to claim");
        IERC20(address(token)).approve(address(_exit), tokenBalance);
        uint256 before = _exitCurrency.balanceOf(address(this));
        _exit.claim(tokenBalance, address(this));
        uint256 received = _exitCurrency.balanceOf(address(this)) - before;
        require(received > 0, "didn't receive expected currency from exit");
        uint256 basePayout = _scaleToDecimals((basePrice * tokenBalance) / 10 ** token.decimals(), IERC20Metadata(address(_exitCurrency)).decimals());
        if (basePayout >= received) {
            _exitCurrency.safeTransfer(receiver, received);
            return;
        }
        _exitCurrency.safeTransfer(receiver, basePayout);
        _distributeCarry(received - basePayout, _exitCurrency);
    }

    /**
     * @notice Returns the number of lead investors.
     * @return the length of the leadInvestors array
     */
    function getLeadInvestorsCount() external view returns (uint256) {
        return leadInvestors.length;
    }
}
