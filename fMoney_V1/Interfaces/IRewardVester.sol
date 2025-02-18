// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IRewardVester {
    function vestFor(address account, uint amount) external;
    function isPaused() external view returns (bool);
}
