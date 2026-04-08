// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

import "./common/IExit.sol";
import "./Token.sol";

/**
 * @title GlobalTokenExitRegistry
 * @author malteish
 * @notice Stores the authorized exit contract for each token in a single global registry.
 *         Only a token's DEFAULT_ADMIN_ROLE can register an exit for that token.
 *         Once set, an exit cannot be changed.
 */
contract GlobalTokenExitRegistry is ERC2771ContextUpgradeable {
    /// @notice The authorized exit contract per token.
    mapping(Token => IExit) public exits;

    /// @param token The token for which an exit was set.
    /// @param exit The exit contract that has been set.
    event ExitSet(Token indexed token, IExit indexed exit);

    /**
     * @param _trustedForwarder This address can execute transactions in the name of any other address
     */
    constructor(address _trustedForwarder) ERC2771ContextUpgradeable(_trustedForwarder) {}

    /**
     * @notice Set the authorized exit contract for `_token`. Once set, cannot be changed.
     *         Callable only by a token DEFAULT_ADMIN_ROLE address.
     * @param _token the token for which to set the exit
     * @param _exit the exit contract to authorize; must not be zero address
     */
    function setExit(Token _token, IExit _exit) external {
        require(address(_token) != address(0), "token can not be zero address");
        require(_token.hasRole(_token.DEFAULT_ADMIN_ROLE(), _msgSender()), "caller is not token admin");
        require(address(_exit) != address(0), "exit can not be zero address");
        require(address(exits[_token]) == address(0), "exit has already been set");
        exits[_token] = _exit;
        emit ExitSet(_token, _exit);
    }
}
