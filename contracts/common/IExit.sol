// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IExit {
    function claim(uint256 _tokenAmount, address _recipient, uint256 _minPayout) external;
}
