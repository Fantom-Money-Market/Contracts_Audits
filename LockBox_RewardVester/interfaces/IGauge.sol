// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IGauge {

    function deposit(uint amount) external;

    function withdraw(uint amount) external;

    function claim_rewards() external;

    function balanceOf(address user) external view returns (uint);

}
