// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDistribution {
    function claim(address _recipient) external;
    function exit() external view returns (bool);
    function snapshotId() external view returns (uint);
    function currency() external view returns (IERC20);
}
