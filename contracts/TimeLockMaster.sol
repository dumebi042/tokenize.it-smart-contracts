// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TimeLockMaster
 * @author malteish
 * @notice Provides a centralized unlock signal for TimeLock and CoinvestedPosition contracts.
 *         Once unlock() is called by the owner, all connected lockup contracts treat
 *         their lockedUntil time constraint as expired, regardless of the current timestamp.
 *         Intended for exit scenarios where beneficiaries must be able to claim immediately.
 */
contract TimeLockMaster is Ownable {
    bool public isUnlocked;

    event Unlocked();

    constructor(address _owner) {
        require(_owner != address(0), "owner can not be zero address");
        _transferOwnership(_owner);
    }

    /**
     * @notice Signal that all connected lockups should be unlocked immediately.
     *         Irreversible: once unlocked, the flag cannot be reset.
     */
    function unlock() external onlyOwner {
        isUnlocked = true;
        emit Unlocked();
    }
}
