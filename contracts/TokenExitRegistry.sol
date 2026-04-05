// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "./IExit.sol";
import "./Token.sol";

/**
 * @title TokenExitRegistry
 * @author malteish
 * @notice Provides a centralized exit and unlock signal for all TimeLock and CoinvestedPosition
 *         contracts of a specific token. Once setExit() is called by a token DEFAULT_ADMIN_ROLE,
 *         all connected lockup contracts treat their lockedUntil time constraint as expired and
 *         use the stored exit contract for claiming exit proceeds.
 */
contract TokenExitRegistry is Initializable {
    /// @notice The token this registry is associated with. Used for access control.
    Token public token;

    /// @notice The authorized exit contract. Non-zero value signals that the timelock is bypassed.
    IExit public exit;

    /// @param exit The exit contract that has been set.
    event ExitSet(IExit indexed exit);

    /**
     * This contract will be used through clones, so the constructor only initializes
     * the logic contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Sets up the TokenExitRegistry.
     * @param _token the token whose DEFAULT_ADMIN_ROLE controls this contract
     */
    function initialize(Token _token) public initializer {
        require(address(_token) != address(0), "token can not be zero address");
        token = _token;
    }

    /**
     * @notice Set the authorized exit contract. This simultaneously unlocks all connected
     *         lockup contracts and restricts exit claims to this specific contract.
     *         Callable only by a token DEFAULT_ADMIN_ROLE address.
     * @param _exit the exit contract to authorize; must not be zero address
     */
    function setExit(IExit _exit) external {
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), msg.sender), "caller is not token admin");
        require(address(_exit) != address(0), "exit can not be zero address");
        require(address(exit) == address(0), "exit has already been set");
        exit = _exit;
        emit ExitSet(_exit);
    }
}
