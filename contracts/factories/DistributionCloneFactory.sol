// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../Distribution.sol";
import "./CloneFactory.sol";

/**
 * @title DistributionCloneFactory
 * @author malteish
 * @notice Use this contract to create deterministic clones of Distribution contracts.
 *  In a single transaction, it clones the contract, transfers the currency from the caller, and initializes the clone.
 */
contract DistributionCloneFactory is CloneFactory {
    using SafeERC20 for IERC20;

    constructor(address _implementation) CloneFactory(_implementation) {}

    /**
     * @notice Create a new Distribution clone, fund it with currency from `_currencyProvider`, and initialize it.
     *  `_currencyProvider` must have approved this factory to spend at least `_totalCurrencyAmount` of `_currency`.
     *  `_currencyProvider` does not affect the clone's address.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _currencyProvider address from which the currency is transferred; does not affect clone address
     * @param _token the token whose snapshot determines distribution shares
     * @param _owner owner of the new Distribution contract
     * @param _snapshotId the token snapshot id that determines distribution shares
     * @param _currency the ERC20 token used for distribution payouts
     * @param _totalCurrencyAmount total amount of currency to distribute
     * @param _reassignAfter earliest timestamp at which the owner can reassign unclaimed funds
     */
    function createDistributionClone(
        bytes32 _rawSalt,
        address _trustedForwarder,
        address _currencyProvider,
        Token _token,
        address _owner,
        uint256 _snapshotId,
        IERC20 _currency,
        uint256 _totalCurrencyAmount,
        uint64 _reassignAfter
    ) external returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _trustedForwarder, _token, _owner, _snapshotId, _currency, _totalCurrencyAmount, _reassignAfter);
        Distribution clone = Distribution(Clones.cloneDeterministic(implementation, salt));
        require(clone.isTrustedForwarder(_trustedForwarder), "DistributionCloneFactory: Unexpected trustedForwarder");
        _currency.safeTransferFrom(_currencyProvider, address(clone), _totalCurrencyAmount);
        clone.initialize(_token, _owner, _snapshotId, _currency, _totalCurrencyAmount, _reassignAfter);
        emit NewClone(address(clone));
        return address(clone);
    }

    /**
     * @notice Return the address a clone would have if created with these parameters.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _token the token whose snapshot determines distribution shares
     * @param _owner owner of the new Distribution contract
     * @param _snapshotId the token snapshot id that determines distribution shares
     * @param _currency the ERC20 token used for distribution payouts
     * @param _totalCurrencyAmount total amount of currency to distribute
     * @param _reassignAfter earliest timestamp at which the owner can reassign unclaimed funds
     */
    function predictCloneAddress(
        bytes32 _rawSalt,
        address _trustedForwarder,
        Token _token,
        address _owner,
        uint256 _snapshotId,
        IERC20 _currency,
        uint256 _totalCurrencyAmount,
        uint64 _reassignAfter
    ) external view returns (address) {
        bytes32 salt = _getSalt(_rawSalt, _trustedForwarder, _token, _owner, _snapshotId, _currency, _totalCurrencyAmount, _reassignAfter);
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /**
     * @notice generates a salt from all input parameters
     */
    function _getSalt(
        bytes32 _rawSalt,
        address _trustedForwarder,
        Token _token,
        address _owner,
        uint256 _snapshotId,
        IERC20 _currency,
        uint256 _totalCurrencyAmount,
        uint64 _reassignAfter
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_rawSalt, _trustedForwarder, _token, _owner, _snapshotId, _currency, _totalCurrencyAmount, _reassignAfter));
    }
}
