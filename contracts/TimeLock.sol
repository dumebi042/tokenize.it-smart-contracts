// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IDistribution.sol";

/**
 * @title TimeLock
 * @author malteish
 * @notice Blocks ERC20 token withdrawals until a given timestamp. The owner can drain any
 *      token to any recipient after lockedUntil has passed.
 * @dev Uses clone/proxy pattern. Constructor disables initializers, separate initialize().
 */
contract TimeLock is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /// unix timestamp before which drain() is blocked; 0 means no lock
    uint64 public lockedUntil;

    event Drained(IERC20 indexed token, address indexed recipient, uint256 amount);
    event DividendsDistributed(IDistribution indexed distribution, IERC20 indexed currency, address indexed recipient, uint256 amount);


    /**
     * This contract will be used through clones, so the constructor only initializes
     * the logic contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Sets up the TimeLock.
     * @param _owner owner of the contract
     * @param _lockedUntil unix timestamp before which drain() is blocked; 0 means no lock
     */
    function initialize(address _owner, uint64 _lockedUntil) public initializer {
        require(_owner != address(0), "owner can not be zero address");
        require(_lockedUntil > block.timestamp, "lockedUntil must be in the future");
        __Ownable_init();
        _transferOwnership(_owner);
        lockedUntil = _lockedUntil;
    }

    /**
     * @notice Claim this contract's eligible share from _dist and forward the received currency to _recipient.
     * @param _dist the Distribution contract to claim from
     * @param _recipient address to forward the received currency to
     */
    function distributeDividends(IDistribution _dist, address _recipient) external onlyOwner {
        require(_recipient != address(0), "recipient can not be zero address");
        IERC20 dividendCurrency = _dist.currency();
        uint256 before = dividendCurrency.balanceOf(address(this));
        _dist.claim(address(this));
        uint256 received = dividendCurrency.balanceOf(address(this)) - before;
        require(received > 0, "no currency received from distribution");
        dividendCurrency.safeTransfer(_recipient, received);
        emit DividendsDistributed(_dist, dividendCurrency, _recipient, received);
    }

    /**
     * @notice Transfer the full balance of _token to _recipient. Blocked until lockedUntil has passed.
     * @param _token ERC20 token to drain
     * @param _recipient address to send the tokens to
     */
    function drain(IERC20 _token, address _recipient) external onlyOwner {
        require(block.timestamp >= lockedUntil, "timelock has not expired");
        require(_recipient != address(0), "recipient can not be zero address");
        uint256 balance = _token.balanceOf(address(this));
        require(balance > 0, "no tokens to drain");
        _token.safeTransfer(_recipient, balance);
        emit Drained(_token, _recipient, balance);
    }
}
