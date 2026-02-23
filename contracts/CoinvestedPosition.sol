// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./TokenSwapBase.sol";
import "./IDistribution.sol";

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
    /// base price per token in currency bits (amount coinvestor is entitled to per token before carry)
    uint256 basePrice;
    /// currency used for payment. Must be ERC20.
    IERC20 currency;
    /// token being held
    Token token;
}

/**
 * @title CoinvestedPosition
 * @author malteish, cjentzsch
 * @notice This contract holds tokens and sells them at a preset price, distributing proceeds
 *      between a coinvestor (receiver) and lead investors.
 *      The coinvestor (receiver) receives basePrice per token sold.
 *      Any remaining proceeds after fees and coinvestor payout are split among lead investors
 *      according to their carry percentages, with dust going to the coinvestor.
 *      If the sale price minus fees is less than the base price, all proceeds go to the coinvestor.
 * @dev Uses clone/proxy pattern. Constructor disables initializers, separate initialize().
 */
contract CoinvestedPosition is TokenSwapBase {
    using SafeERC20 for IERC20;

    /// lead investors and their carry fractions
    LeadInvestor[] public leadInvestors;
    /// base price per token in currency bits
    uint256 public basePrice;

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

        require(_arguments.leadInvestors.length > 0, "There must be at least one lead investor");
        uint256 carryFractionsSum = 0;
        for (uint256 i = 0; i < _arguments.leadInvestors.length; i++) {
            require(_arguments.leadInvestors[i].account != address(0), "lead investor can not be zero address");
            carryFractionsSum += _arguments.leadInvestors[i].carryFraction;
            leadInvestors.push(_arguments.leadInvestors[i]);
        }
        require(carryFractionsSum < type(uint64).max, "carry fractions must leave a share for the receiver");
        basePrice = _arguments.basePrice;

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
            _distributeCarry(remaining - payoutCoinvestor);
        }

        // transfer tokens from this contract to the buyer's receiver
        token.transfer(_tokenReceiver, _tokenAmount);

        emit TokensBought(_msgSender(), _tokenAmount, currencyAmount);
    }

    /**
     * @notice Splits `carry` among lead investors by carryFraction; rounding dust goes to receiver.
     * @dev Assumes `carry` is already held by this contract.
     * @param carry amount of currency to distribute as carry
     */
    function _distributeCarry(uint256 carry) internal {
        uint256 distributed = 0;
        for (uint256 i = 0; i < leadInvestors.length; i++) {
            uint256 share = (uint256(leadInvestors[i].carryFraction) * carry) / type(uint64).max;
            if (share != 0) {
                currency.safeTransfer(leadInvestors[i].account, share);
                distributed += share;
            }
        }
        uint256 receiverShare = carry - distributed;
        if (receiverShare > 0) {
            currency.safeTransfer(receiver, receiverShare);
        }
    }

    /**
     * @notice Claim this contract's eligible share from `_dist` and split it among the receiver and lead investors.
     * @dev Calls Distribution.claim() as msg.sender (this contract is the holder), then distributes received currency.
     *      On exit: receiver gets base first; if proceeds < base, receiver gets everything; remainder is carry.
     *      On non-exit: full amount is treated as carry.
     *      Carry is split among lead investors by carryFraction; rounding dust goes to receiver.
     * @param _dist the Distribution contract to claim from
     */
    function distribute(IDistribution _dist) external onlyOwner nonReentrant {
        uint256 before = currency.balanceOf(address(this));
        // this transfers the currency to the contract
        _dist.claim(address(this));
        uint256 received = currency.balanceOf(address(this)) - before;

        uint256 carry = received;

        if (_dist.exit()) {
            uint256 basePayout = (basePrice * token.balanceOfAt(address(this), _dist.snapshotId())) /
                10 ** token.decimals();
            if (basePayout >= received) {
                // proceeds don't cover base: all goes to receiver
                currency.safeTransfer(receiver, received);
                return;
            }
            currency.safeTransfer(receiver, basePayout);
            carry = received - basePayout;
        }

        _distributeCarry(carry);
    }

    /**
     * @notice Returns the number of lead investors.
     * @return the length of the leadInvestors array
     */
    function getLeadInvestorsCount() external view returns (uint256) {
        return leadInvestors.length;
    }
}
