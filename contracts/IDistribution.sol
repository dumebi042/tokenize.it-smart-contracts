// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDistribution {
    function claim(address _recipient) external;
}
