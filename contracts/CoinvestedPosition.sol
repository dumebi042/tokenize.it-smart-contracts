// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./TimeLockMaster.sol";
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
    /// base price per token in bits in currency below
    uint256 basePrice;
    /// currency used for buy() payments. Must have TRUSTED_CURRENCY bit set on the token's allowList.
    IERC20 baseCurrency;
    /// token being held
    Token token;
    /// unix timestamp before which unpause() is blocked; 0 means no lock
    uint64 lockedUntil;
    /// master unlock contract; if its isUnlocked() returns true, the lockedUntil constraint is bypassed
    TimeLockMaster timeLockMaster;
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
 *      For exits and dividends, any trusted token (TRUSTED_CURRENCY bit) may be used.
 *      Neither needs to match the currency stored for buy().
 * @dev Uses clone/proxy pattern. Constructor disables initializers, separate initialize().
 */
contract CoinvestedPosition is TokenSwapBase {
    using SafeERC20 for IERC20;

    /// lead investors and their carry fractions
    LeadInvestor[] public leadInvestors;
    /// base price per token in currency bits (smallest subunit of the base currency)
    uint256 public basePrice;
    /// decimals of the currency used when basePrice was set; used to scale payouts when a different EURO token is used at exit/dividend time
    uint8 public basePriceDecimals;
    /// unix timestamp before which unpause() is blocked; 0 means no lock
    uint64 public lockedUntil;
    /// master unlock contract; if its isUnlocked() returns true, the lockedUntil constraint is bypassed
    TimeLockMaster public timeLockMaster;

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
        _initializeBase(_arguments.owner, 0, _arguments.baseCurrency, _arguments.token, _arguments.receiver);

        require(
            _arguments.token.allowList().map(address(_arguments.baseCurrency)) == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        require(_arguments.leadInvestors.length > 0, "There must be at least one lead investor");
        uint64 carryFractionsSum = 0;
        for (uint256 i = 0; i < _arguments.leadInvestors.length; i++) {
            require(_arguments.leadInvestors[i].account != address(0), "lead investor can not be zero address");
            require(_arguments.leadInvestors[i].carryFraction > 0, "lead investor carry fraction can not be zero");
            carryFractionsSum += _arguments.leadInvestors[i].carryFraction; // reverts on overflow
            leadInvestors.push(_arguments.leadInvestors[i]);
        }
        require(address(_arguments.timeLockMaster) != address(0), "timeLockMaster can not be zero address");
        basePrice = _arguments.basePrice;
        basePriceDecimals = IERC20Metadata(address(_arguments.baseCurrency)).decimals();
        lockedUntil = _arguments.lockedUntil;
        timeLockMaster = _arguments.timeLockMaster;

        // Pausing the contract prevents an immediate sell of the tokens. Once they should be sold, update price and unpause.
        _pause();
    }

    /**
     * @notice Unpause the contract. Blocked until lockedUntil has passed.
     */
    function unpause() external override onlyOwner {
        require(tokenPrice != 0, "tokenPrice must be set before unpausing");
        require(block.timestamp >= lockedUntil || address(timeLockMaster.exit()) != address(0), "timelock has not expired");
        _unpause();
    }

    /**
     * @notice Change the payment currency to any trusted EURO currency.
     * @dev basePrice remains in its original canonical units (basePriceDecimals); buy() scales it
     *      dynamically, so no re-scaling of basePrice is needed here.
     * @param _currency new currency; must have TRUSTED_CURRENCY bit set on the token's allowList
     */
    function setCurrency(IERC20 _currency) external onlyOwner {
        require(
            token.allowList().map(address(_currency)) == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        currency = _currency;
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

        // calculate carry: surplus above base price. If remaining <= base price, carry is 0 and receiver gets everything.
        uint256 scaledBasePrice = _scaleToDecimals(basePrice, IERC20Metadata(address(currency)).decimals());
        uint256 payoutCoinvestor = (scaledBasePrice * _tokenAmount) / (10 ** token.decimals());
        uint256 carry = payoutCoinvestor < remaining ? remaining - payoutCoinvestor : 0;

        _settle(carry, currency);

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
     * @notice Distributes `carry` among lead investors by carryFraction, then sweeps the contract's
     *      full remaining balance of `_currency` to receiver. This even includes currency accidentally
     *      sent to the contract.
     * @dev The sweep covers the base price portion and any rounding dust. Pass carry=0 when there is
     *      no surplus above base price; the loop produces no transfers and the full balance goes to receiver.
     * @param carry surplus above base price to split among lead investors
     * @param _currency the EURO token to settle
     */
    function _settle(uint256 carry, IERC20 _currency) internal {
        require(address(_currency) != address(token), "currency cannot be the held token");
        for (uint256 i = 0; i < leadInvestors.length; i++) {
            uint256 share = (uint256(leadInvestors[i].carryFraction) * carry) / type(uint64).max;
            if (share != 0) {
                _currency.safeTransfer(leadInvestors[i].account, share);
            }
        }
        _currency.safeTransfer(receiver, _currency.balanceOf(address(this)));
    }

    /**
     * @notice Claim this contract's eligible dividend share from `_dist` and split it among lead investors.
     * @dev The full received amount is treated as carry and split among lead investors by carryFraction;
     *      remainder goes to receiver. Any trusted currency may be used (TRUSTED_CURRENCY bit required).
     * @param _dist the Distribution (dividend) contract to claim from
     */
    function distributeDividends(IDistribution _dist) external onlyOwner nonReentrant {
        IERC20 dividendCurrency = _dist.currency();
        require(
            token.allowList().map(address(dividendCurrency)) & TRUSTED_CURRENCY == TRUSTED_CURRENCY,
            "dividend currency must be a trusted currency"
        );
        uint256 before = dividendCurrency.balanceOf(address(this));
        _dist.claim(address(this));
        uint256 received = dividendCurrency.balanceOf(address(this)) - before;
        require(received > 0, "didn't receive expected currency from distribution");
        _settle(received, dividendCurrency);
    }

    /**
     * @notice Claim exit proceeds for this contract's full token balance and split them among the receiver and lead investors.
     * @dev Requires timeLockMaster.exit() to be set; that also acts as the unlock signal.
     *      If proceeds < base, receiver gets everything.
     *      Carry is split among lead investors by carryFraction; remainder goes to receiver.
     *      Any trusted token (TRUSTED_CURRENCY) may be used, independent of the currency stored for buy().
     * @param _exitCurrency the EURO token paid out by the exit
     * @param _minCurrencyAmount minimum currency the call must receive; reverts if proceeds fall short.
     *      This guards against faulty or malicious exit contracts.
     */
    function distributeExit(
        IERC20 _exitCurrency,
        uint256 _minCurrencyAmount
    ) external onlyOwner nonReentrant {
        IExit exit = timeLockMaster.exit();
        require(address(exit) != address(0), "no exit set in timeLockMaster");
        require(
            token.allowList().map(address(_exitCurrency)) == TRUSTED_CURRENCY,
            "currency needs to be on the allowlist with TRUSTED_CURRENCY attribute"
        );
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "no tokens to claim");
        IERC20(address(token)).approve(address(exit), tokenBalance);
        uint256 before = _exitCurrency.balanceOf(address(this));
        exit.claim(tokenBalance, address(this));
        uint256 received = _exitCurrency.balanceOf(address(this)) - before;
        require(received >= _minCurrencyAmount, "received less than _minCurrencyAmount");
        uint256 basePayout = _scaleToDecimals(
            (basePrice * tokenBalance) / 10 ** token.decimals(),
            IERC20Metadata(address(_exitCurrency)).decimals()
        );
        uint256 carry = basePayout < received ? received - basePayout : 0;
        _settle(carry, _exitCurrency);
    }

    /**
     * @notice Returns the number of lead investors.
     * @return length of the leadInvestors array
     */
    function getLeadInvestorsCount() external view returns (uint256) {
        return leadInvestors.length;
    }
}
