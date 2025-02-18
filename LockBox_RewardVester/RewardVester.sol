// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IVault} from "./interfaces/IVault.sol";
import {ILockBox} from "./interfaces/ILockBox.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract RewardVester is ReentrancyGuard, AccessControlEnumerable {

    // ERRORS //
    error NotAllowed();
    error Paused();
    error NotVested();
    error NotUnitroller();
    error ZeroAmount();
    error UnderTimeLock();
    error OverParams();
    error VestExpired();

    // ADDRESSES /
    address public immutable fBux;
    address public immutable sTs;
    address public immutable lp;
    address public immutable unitroller;
    address public immutable vault;
    address public immutable multisig;
    address public lockBox;

    address[] internal lpTokens;

    bytes32 internal immutable poolId;

    uint internal constant DURATION = 91 days;

    bool public isPaused;

    // VEST ACCOUNTING // 

    struct UserInfo{
        uint vestedAmount;
        uint vestEnd;
        bool isVested;
    }

    mapping(address user => UserInfo) public userInfo;
  
    // EVENTS //

    event Vested(address indexed user, uint amount, uint vestEnd);

    event VestClaimed(address indexed user, uint amount);

    event ClaimedEarly(address indexed user, uint fBuxAmount, uint sTsAmount, uint lpAmount);

    event TokenRescued(address indexed token, address indexed to, uint amount);

    event WasPaused(bool state);

    event Unpaused(bool state);

    event LockBoxSet(address indexed lockBox);

    constructor(
        address _admin,
        address _fBux,
        address _sTs,
        address _lp,
        address _unitroller,
        address _vault,
        bytes32 _poolId
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        multisig = _admin;
        sTs = _sTs;
        fBux = _fBux;
        unitroller = _unitroller;
        vault = _vault;
        poolId = _poolId;
        lp = _lp;
        lpTokens = [fBux, sTs];

        renewApprovals();
    }

    /// @notice Vests fBux for an account when claiming rewards on fMoney Lender
    //  If vest has expired, it will first claim the vest, reset it and resume accounting in a new 3M cycle.
    function vestFor(address user, uint amount) external nonReentrant {
        if(msg.sender != unitroller){revert NotUnitroller();}
        UserInfo storage account = userInfo[user];

        if(account.isVested){
            if(block.timestamp >= account.vestEnd){_forceClaim(user);}
        }
        
        if(!account.isVested){
            account.vestedAmount += amount;
            account.vestEnd = block.timestamp + DURATION;
            account.isVested = true; 
        } else {
            account.vestedAmount += amount;
        }
        emit Vested(user, amount, account.vestEnd);
    }

    /// @notice Withdraw vested rewards once vesting is complete and reset vest for account
    function claimVest() external nonReentrant{
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isVested){revert NotVested();}
        if(block.timestamp < account.vestEnd){revert UnderTimeLock();}

        uint toClaim = account.vestedAmount;

        account.vestedAmount = 0;
        account.vestEnd = 0;
        account.isVested= false;

        _safeTransfer(fBux, user, toClaim);

        emit VestClaimed(user, toClaim);
    }

    /// @notice Allows partial or full exit from 3 month fBux vest into a 1.5M locked Staked fMoney with Attitude position.
    //  If vest expired, _forceClaim rewards for user and reset stored info. Requires user sTs approval for this contract.
    function earlyClaim(uint sTsAmount, uint minLpReceived) external nonReentrant {
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isVested) {revert NotVested();}
        if(isPaused){revert Paused();}
        if(sTsAmount == 0){revert ZeroAmount();}

        if(block.timestamp >= account.vestEnd){_forceClaim(user);}
        else{
            uint availableToClaim = account.vestedAmount;
            if(availableToClaim == 0){revert ZeroAmount();}

            uint fBuxAmount = getFbuxPairAmount(sTsAmount);
            if(fBuxAmount > availableToClaim){revert OverParams();}
            account.vestedAmount -= fBuxAmount;
            _safeTransferFrom(sTs, user, address(this), sTsAmount);

            // Create LP on BeethovenX & vest on Lockbox.
            _joinPool(fBuxAmount, sTsAmount);
            uint lpAmount = IERC20(lp).balanceOf(address(this));
            if(lpAmount < minLpReceived) {revert OverParams();}
            ILockBox(lockBox).createVest(user, lpAmount);

            emit ClaimedEarly(user, fBuxAmount, sTsAmount, lpAmount);
        }
    }

    // INTERNAL //

    /// @notice Prevents bypassing 3M vest cycle if a user's vest has expired.
    //  Further unitroller deposits or earlyUnvests will forcefully claim rewards and reset vest.
    function _forceClaim(address user) internal {
        UserInfo storage account = userInfo[user];

        uint amountClaimed = account.vestedAmount;
        account.vestedAmount = 0;
        account.vestEnd = 0;
        account.isVested = false;

        _safeTransfer(fBux, user, amountClaimed);

        emit VestClaimed(user, amountClaimed);
    }

    /// @notice Adds liquidity to fMoney's 80/20 pool on BeethovenX.
    function _joinPool(uint fBuxAmt, uint sTsAmt) internal {
        uint256[] memory amounts = new uint256[](lpTokens.length);
    
        amounts[0] = fBuxAmt;
        amounts[1] = sTsAmt;
        bytes memory userData = abi.encode(1, amounts, 1);

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest(lpTokens, amounts, userData, false);
        IVault(vault).joinPool(poolId, address(this), address(this), request);
    }

    /// @notice Returns remaining vest time for a user
    function timeLeft(address user) external view returns (uint) {
        UserInfo memory account = userInfo[user];

        if(account.vestedAmount == 0){ return 0;}
        if(block.timestamp >= account.vestEnd){return 0;}
        return account.vestEnd - block.timestamp;
    }

    // Returns total vested fBux in contract
    function vestedfBux() external view returns (uint fBuxBal){
        fBuxBal = IERC20(fBux).balanceOf(address(this));
    }
    
    /// @notice Returns user required sTs to earlyUnvest an fBux amount;
    function getFbuxPairAmount(uint sTsAmount) public view returns (uint fBuxRequired){
        // balances[0] - total fBUX in BPT. balances[1] - total sTs in BPT.
        (, uint256[] memory balances, ) = IVault(vault).getPoolTokens(poolId);
        fBuxRequired = sTsAmount * balances[0] / balances[1];
    }


    // ADMIN //


    // Recovers token mistakenly sent to the contract
    function recoverTokens(address token, address to, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if(token == fBux){revert NotAllowed();}
        _safeTransfer(token, to, amount);
        emit TokenRescued(token, to, amount);
    }

    // Approval refresh for contract longevity
    function renewApprovals() public onlyRole(DEFAULT_ADMIN_ROLE){
        _safeApprove(fBux, vault, 0);
        _safeApprove(fBux, vault, type(uint).max);

        _safeApprove(sTs, vault, 0);
        _safeApprove(sTs, vault, type(uint).max);

        if(lockBox != address(0)){
            _safeApprove(lp, lockBox, 0);
            _safeApprove(lp, lockBox, type(uint).max);
        }
    }

    /// @notice Sets LockBox address. Can only be set once.
    function setLockBox(address _lockBox) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(lockBox != address(0)){revert NotAllowed();}
        lockBox = _lockBox;

        _safeApprove(lp, lockBox, 0);
        _safeApprove(lp, lockBox, type(uint).max);
        emit LockBoxSet(_lockBox);
    }

    /// @notice For Sonic migration this contract must be paused to not receive lender rewards. 
    //  Checked on Unitroller. Only pauses earlyUnvest in this contract.
    function setPaused(bool state) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(isPaused == state){revert NotAllowed();}
        isPaused = state;

        if(state){emit WasPaused(state);} 
        else{emit Unpaused(state);}
    }

    // ERC20 handling
    function _safeTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transfer, (to, value))
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.transferFrom, (from, to, value))
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeApprove(address token, address spender, uint value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeCall(IERC20.approve, (spender, value))
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _balanceOf(address token, address account) internal view returns (uint) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeCall(IERC20.balanceOf, (account))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint));
    }
}