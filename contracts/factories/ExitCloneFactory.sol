// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../Exit.sol";
import "./CloneFactory.sol";

/**
 * @title ExitCloneFactory
 * @author malteish
 * @notice Use this contract to create deterministic clones of Exit contracts.
 *  In a single transaction, it clones the contract, transfers the currency from the caller, and initializes the clone.
 */
contract ExitCloneFactory is CloneFactory {
    using SafeERC20 for IERC20;

    constructor(address _implementation) CloneFactory(_implementation) {}

    /**
     * @notice Create a new Exit clone, fund it with currency from `_currencyProvider`, and initialize it.
     *  `_currencyProvider` must have approved this factory to spend at least `_totalCurrencyAmount` of `_currency`.
     *  `_currencyProvider` does not affect the clone's address.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _currencyProvider address from which the currency is transferred; does not affect clone address
     * @param _token the token holders will return in exchange for exit proceeds
     * @param _owner owner of the new Exit contract
     * @param _currency the ERC20 token used for exit payouts
     * @param _pricePerToken currency amount (in smallest units) per 10**token.decimals() token units
     * @param _exitDate timestamp from which claims are valid; claims expire after EXIT_WINDOW
     * @param _totalCurrencyAmount total amount of currency to fund the exit contract with
     */
    function createExitClone(
        bytes32 _rawSalt,
        address _trustedForwarder,
        address _currencyProvider,
        Token _token,
        address _owner,
        IERC20 _currency,
        uint256 _pricePerToken,
        uint64 _exitDate,
        uint256 _totalCurrencyAmount
    ) external returns (address) {
        bytes32 salt = _getSalt(
            _rawSalt,
            _trustedForwarder,
            _token,
            _owner,
            _currency,
            _pricePerToken,
            _exitDate,
            _totalCurrencyAmount
        );
        Exit clone = Exit(Clones.cloneDeterministic(implementation, salt));
        require(clone.isTrustedForwarder(_trustedForwarder), "ExitCloneFactory: Unexpected trustedForwarder");
        _currency.safeTransferFrom(_currencyProvider, address(clone), _totalCurrencyAmount);
        clone.initialize(_token, _owner, _currency, _pricePerToken, _exitDate, _totalCurrencyAmount);
        emit NewClone(address(clone));
        return address(clone);
    }

    /**
     * @notice Return the address a clone would have if created with these parameters.
     * @param _rawSalt influences the address of the clone, but not the initialization
     * @param _trustedForwarder can not be changed, but is checked for security
     * @param _token the token holders will return in exchange for exit proceeds
     * @param _owner owner of the new Exit contract
     * @param _currency the ERC20 token used for exit payouts
     * @param _pricePerToken currency amount (in smallest units) per 10**token.decimals() token units
     * @param _exitDate timestamp from which claims are valid; claims expire after EXIT_WINDOW
     * @param _totalCurrencyAmount total amount of currency to fund the exit contract with
     */
    function predictCloneAddress(
        bytes32 _rawSalt,
        address _trustedForwarder,
        Token _token,
        address _owner,
        IERC20 _currency,
        uint256 _pricePerToken,
        uint64 _exitDate,
        uint256 _totalCurrencyAmount
    ) external view returns (address) {
        bytes32 salt = _getSalt(
            _rawSalt,
            _trustedForwarder,
            _token,
            _owner,
            _currency,
            _pricePerToken,
            _exitDate,
            _totalCurrencyAmount
        );
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
        IERC20 _currency,
        uint256 _pricePerToken,
        uint64 _exitDate,
        uint256 _totalCurrencyAmount
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _rawSalt,
                    _trustedForwarder,
                    _token,
                    _owner,
                    _currency,
                    _pricePerToken,
                    _exitDate,
                    _totalCurrencyAmount
                )
            );
    }
}
