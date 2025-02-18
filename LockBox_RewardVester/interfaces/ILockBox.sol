// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface ILockBox {
    function createVest(address user, uint amount) external;
    function paused() external view returns(bool);
}
