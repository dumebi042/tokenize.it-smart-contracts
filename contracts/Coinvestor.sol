// SPDX-License-Identifier: MIT

pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "./Token.sol";

/**
 * @title Coinvestor
 * @author malteish, cjentzsch
 * @notice This contract is used to invest into a company, following a lead investor's recommendation.
 *      In return for this recommendation, the lead investor will receive a carry on the proceeds of the investment.
 *      The contract holds the tokens until the investment is sold, at which point the proceeds are distributed between
 *      the coinvestor and the lead investors.
 *      Lead investor = beneficiary = carry receiver
 */

contract Coinvestor is Ownable2StepUpgradeable {
    address[] public beneficiaries; // [0] is the coinvestor, the others are the carry receivers (=lead investors)
    uint64[] public percentage; // divided by uint64max
    uint public baseprice; // currency: EUR

    constructor(
        address[] memory _beneficiaries,
        uint64[] memory _percentage,
        uint _baseprice,
        address _owner
    ) Ownable2StepUpgradeable(_owner) {
        beneficiaries = _beneficiaries;
        percentage = _percentage;
        baseprice = _baseprice;
    }

    function withdraw(Token _token, TokenSwapCarry _tokenSwapCarry, uint amount) public onlyOwner {
        // ensure that _tokenSwapCarry is actually a TokenSwapCarry contract

        bytes32 accountHash = 0x0; // TODO: replace with actual TokenSwapCarry contract code hash
        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(address(_token))
        }
        require(codeHash == accountHash && codeHash != 0x0);

        _token.approve(_tokenSwapCarry, amount);
    }

    function withdrawToTokenAdmin(Token _token, address _admin) public onlyOwner {
        // only used in case of an exit, or executing the put-option
        require(_token.hasRole(DEFAULT_ADMIN_ROLE, _admin));
        _token.transfer(_admin, _token.balanceOf(address(this)));
    }
}
