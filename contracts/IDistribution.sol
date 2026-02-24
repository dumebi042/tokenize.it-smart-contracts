// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDistribution {
    function claim(address _recipient) external;
    function exit() external view returns (bool);
    function snapshotId() external view returns (uint);
}
