// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDistribution {
    function claim(address _recipient, uint256 _minPayout) external;
    function currency() external view returns (IERC20);
}
