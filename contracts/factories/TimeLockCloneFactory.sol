// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "../TimeLock.sol";
import "../TimeLockMaster.sol";
import "./CloneFactory.sol";

/**
 * @title TimeLockCloneFactory
 * @author malteish
 * @notice Use this contract to create deterministic clones of TimeLock contracts
 */
contract TimeLockCloneFactory is CloneFactory {
    constructor(address _implementation) CloneFactory(_implementation) {}

    /**
     * @notice Create a new TimeLock clone and initialize it.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _owner owner of the new TimeLock
     * @param _lockedUntil unix timestamp before which drain() is blocked
     * @param _timeLockMaster master unlock contract; setting exit on it bypasses lockedUntil
     */
    function createTimeLockClone(
        bytes32 _rawSalt,
        address _owner,
        uint64 _lockedUntil,
        TimeLockMaster _timeLockMaster
    ) external returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _owner, _lockedUntil, _timeLockMaster);
        TimeLock clone = TimeLock(Clones.cloneDeterministic(implementation, salt));
        clone.initialize(_owner, _lockedUntil, _timeLockMaster);
        emit NewClone(address(clone));
        return address(clone);
    }

    /**
     * @notice Return the address a clone would have if created with these parameters.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _owner owner of the new TimeLock
     * @param _lockedUntil unix timestamp before which drain() is blocked
     * @param _timeLockMaster master unlock contract; setting exit on it bypasses lockedUntil
     */
    function predictCloneAddress(
        bytes32 _rawSalt,
        address _owner,
        uint64 _lockedUntil,
        TimeLockMaster _timeLockMaster
    ) external view returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _owner, _lockedUntil, _timeLockMaster);
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /**
     * @notice generates a salt from all input parameters
     */
    function _getSalt(
        bytes32 _rawSalt,
        address _owner,
        uint64 _lockedUntil,
        TimeLockMaster _timeLockMaster
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_rawSalt, _owner, _lockedUntil, _timeLockMaster));
    }
}
