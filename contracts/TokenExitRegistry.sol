// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

import "./common/IExit.sol";
import "./Token.sol";

/**
 * @title TokenExitRegistry
 * @author malteish
 * @notice Stores the authorized exit contract for a token. Once setExit() is called by a
 *         token DEFAULT_ADMIN_ROLE, TimeLock and CoinvestedPosition contracts connected to
 *         this registry can claim exit proceeds via the stored exit contract.
 */
contract TokenExitRegistry is ERC2771ContextUpgradeable {
    /// @notice The token this registry is associated with. Used for access control.
    Token public token;

    /// @notice The authorized exit contract. Non-zero value signals that the timelock is bypassed.
    IExit public exit;

    /// @param exit The exit contract that has been set.
    event ExitSet(IExit indexed exit);

    /**
     * This contract will be used through clones, so the constructor only initializes
     * the logic contract.
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {
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
     * @notice Set the authorized exit contract. Restricts exit claims to this specific contract.
     *         Callable only by a token DEFAULT_ADMIN_ROLE address.
     * @param _exit the exit contract to authorize; must not be zero address
     */
    function setExit(IExit _exit) external {
        require(token.hasRole(token.DEFAULT_ADMIN_ROLE(), _msgSender()), "caller is not token admin");
        require(address(_exit) != address(0), "exit can not be zero address");
        require(address(exit) == address(0), "exit has already been set");
        exit = _exit;
        emit ExitSet(_exit);
    }
}
