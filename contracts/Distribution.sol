// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./Vesting.sol";
import "./Token.sol";

/**
 * @title tokenize.it Distribution
 * @author malteish, cjentzsch
 * @notice This contract implements the distribution of any proceeds (Exit, Liquidation, Dividends) based on a snapshot of Token.sol
 *
 */
contract Distribution is ERC2771ContextUpgradeable, Ownable2StepUpgradeable {
    Token public token;
    uint public snapshotId;
    uint public totalTokenAmount;
    IERC20 public currency;
    uint public totalCurrencyAmount;
    mapping(address => uint256) public paidOut;
    bool public exit;

    constructor(
        Token _token,
        address _owner,
        address _trustedForwarder,
        bool _exit
    ) ERC2771ContextUpgradeable(_trustedForwarder) {
        token = _token;
        exit = _exit;
        _transferOwnership(_owner);
    }

    function confirm(uint _snapshotId, IERC20 _currency, uint _totalCurrencyAmount) external onlyOwner {
        // one could also rename it to initalized, both work
        snapshotId = _snapshotId;
        totalTokenAmount = token.totalSupplyAt(snapshotId);
        currency = _currency;
        require(_currency.balanceOf(address(this)) >= _totalCurrencyAmount);
        totalCurrencyAmount = _totalCurrencyAmount;
    }

    function eligible(address _holder) public view returns (uint) {
        return (totalCurrencyAmount * token.balanceOfAt(_holder, snapshotId)) / totalTokenAmount - paidOut[_holder];
    }

    function claim(address _recipient) external {
        _claim(_msgSender(), _recipient); //should work for directly calling it (msg.sender), as well as with a meta transaction with a signed message
    }

    function claim(IERC1271 _holder, bytes32 _hash, bytes memory _signature, address _recipient) external {
        require(_holder.isValidSignature(_hash, _signature) == 0x1626ba7e);
        _claim(address(_holder), _recipient);
    }

    function claim(Vesting _holder, address _recipient) external {
        //only works for lockups, where there is only one vesting plan per deployment. For EP it will not and should not work, since there are not tokens in EP contracts
        require(_msgSender() == _holder.beneficiary(0));
        _claim(address(_holder), _recipient);
    }

    function _claim(address _holder, address _recipient) internal {
        uint amount = eligible(_holder);
        paidOut[_holder] += amount;
        currency.transfer(_recipient, amount);
    }

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
