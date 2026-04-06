// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "../Distribution.sol";
import "./CloneFactory.sol";

/**
 * @title DistributionCloneFactory
 * @author malteish
 * @notice Use this contract to create deterministic clones of Distribution contracts.
 *  In a single transaction, it clones the contract and initializes it.
 *  The clone address can be predicted with predictCloneAddress() before deployment,
 *  so _currencyProvider can approve the clone address directly rather than this factory.
 */
contract DistributionCloneFactory is CloneFactory {
    constructor(address _implementation) CloneFactory(_implementation) {}

    /**
     * @notice Create a new Distribution clone and initialize it. Optionally fund it with currency from `_currencyProvider`.
     *  If `_arguments.initialFundingAmount > 0`, `_currencyProvider` must have approved the clone address
     *  (use predictCloneAddress()) for that amount.
     *  `_currencyProvider` does not affect the clone's address.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _currencyProvider address from which the currency is pulled (if initialFundingAmount > 0); does not affect clone address
     * @param _arguments struct with all initialization parameters
     */
    function createDistributionClone(
        bytes32 _rawSalt,
        address _trustedForwarder,
        address _currencyProvider,
        DistributionInitializerArguments memory _arguments
    ) external returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _trustedForwarder, _arguments);
        Distribution clone = Distribution(Clones.cloneDeterministic(implementation, salt));
        require(clone.isTrustedForwarder(_trustedForwarder), "DistributionCloneFactory: Unexpected trustedForwarder");
        clone.initialize(_arguments, _currencyProvider);
        emit NewClone(address(clone));
        return address(clone);
    }

    /**
     * @notice Return the address a clone would have if created with these parameters.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _arguments struct with all initialization parameters
     */
    function predictCloneAddress(
        bytes32 _rawSalt,
        address _trustedForwarder,
        DistributionInitializerArguments memory _arguments
    ) external view returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _trustedForwarder, _arguments);
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /**
     * @notice generates a salt from all input parameters
     */
    function _getSalt(
        bytes32 _rawSalt,
        address _trustedForwarder,
        DistributionInitializerArguments memory _arguments
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_rawSalt, _trustedForwarder, _arguments));
    }
}
