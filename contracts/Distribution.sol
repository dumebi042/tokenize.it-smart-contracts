// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

import "./Vesting.sol";
import "./Token.sol";
import "./Coinvestor.sol";

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

    constructor(Token _token, address _owner, bool _exit) Ownable2StepUpgradeable(_owner) {
        token = _token;
        exit = _exit;
    }

    function confirm(uint _snapshotId, IERC20 _currency, uint _totalCurrencyAmount) onlyOwner {
        // one could also rename it to initalized, both work
        snapshotId = _snapshotId;
        totalTokenAmount = token.totalSupplyAt(snapshotId);
        currency = _currency;
        require(_currency.balanceOf(address(this)) >= _totalCurrencyAmount);
        totalCurrencyAmount = _totalCurrencyAmount;
    }

    function eligible(address _holder) returns (uint) {
        return (totalCurrencyAmount * token.balanceOfAt(_holder, snapshotId)) / totalTokenAmount - paidOut[_holder];
    }

    function claim(address _recipient) {
        _claim(_msgSender(), _recipient); //should work for directly calling it (msg.sender), as well as with a meta transactions with a siged message
    }

    function claim(IERC1271 _holder, bytes32 _hash, bytes memory _signature, address _recipient) {
        require(_holder.isValidSignature(_hash, _signature) == 0x1626ba7e);
        _claim(_holder, _recipient);
    }

    function claim(Vesting _holder, address _recipient) {
        //only works for lockups, where there is only one vesting plan per deployment. For EP it will not and should not work, since there are not tokens in EP contracts
        require(_msgSender() == _holder.vestings[1].beneficiary());
        _claim(_holder, _recipient);
    }

    function claim(Coinvestor _coinvestor) {
        require(_msgSender() == _coinvestor.owner());
        address holder = address(_coinvestor);
        uint length = _coinvestor.beneficiaries().length();
        uint totalAmount = eligible(holder);
        if (exit) {
            uint payoutCoinvestor = _coinvestor.base() * token.balanceOfAt(holder, snapshotId);
            totalAmount -= payoutCoinvestor;
            paidOut[_coinvestor] += payoutCoinvestor;
            currency.transfer(_coinvestor.beneficiaries(0), payoutCoinvestor); // TODO handle case when the payout is lower than the base
        }

        for (uint i = 0; i < length; i++) {
            uint amount = (_coinvestor.percentage(i) * totalAmount) / type(uint64).max;
            paidOut[_coinvestor] += amount;
            currency.transfer(_coinvestor.beneficiaries(i), amount);
        }
    }

    function _claim(address _holder, address _recipient) internal {
        uint amount = eligible(_holder);
        paidOut[_holder] += amount;
        currency.transfer(_recipient, amount);
    }
}
