// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "../TokenExitRegistry.sol";
import "../Token.sol";
import "./CloneFactory.sol";

/**
 * @title TokenExitRegistryCloneFactory
 * @author malteish
 * @notice Use this contract to create deterministic clones of TokenExitRegistry contracts
 */
contract TokenExitRegistryCloneFactory is CloneFactory {
    constructor(address _implementation) CloneFactory(_implementation) {}

    /**
     * @notice Create a new TokenExitRegistry clone and initialize it.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _token the token whose DEFAULT_ADMIN_ROLE controls the new TokenExitRegistry
     */
    function createTokenExitRegistryClone(bytes32 _rawSalt, Token _token) external returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _token);
        TokenExitRegistry clone = TokenExitRegistry(Clones.cloneDeterministic(implementation, salt));
        clone.initialize(_token);
        emit NewClone(address(clone));
        return address(clone);
    }

    /**
     * @notice Return the address a clone would have if created with these parameters.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _token the token whose DEFAULT_ADMIN_ROLE controls the new TokenExitRegistry
     */
    function predictCloneAddress(bytes32 _rawSalt, Token _token) external view returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _token);
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /**
     * @notice generates a salt from all input parameters
     */
    function _getSalt(bytes32 _rawSalt, Token _token) internal pure returns (bytes32) {
        return keccak256(abi.encode(_rawSalt, _token));
    }
}
