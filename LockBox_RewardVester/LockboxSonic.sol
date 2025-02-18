// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IGauge} from "./interfaces/IGauge.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "./ERC20/IERC20.sol";
import {ERC20} from "./ERC20/ERC20NonTransferable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

contract LockboxSonic is ERC20, ReentrancyGuard, AccessControlEnumerable {

    error ZeroAmount();
    error InvalidTokenOrAddress();
    error Paused();
    error NotPaused();
    error UnderTimeLock();
    error InvalidLockDuration();
    error NoLock();
    error NoVest();
    error NotAllowed();
    error Expired();

    struct Reward {
        uint rewardRate;
        uint periodFinish;
        uint lastUpdateTime;
        uint rewardPerTokenStored;
    }

    struct UserInfo {
        bool isLocked;
        bool isVested;
        uint lockedFor;
        uint vestedFor;
        uint lockedAmount;
        uint vestedAmount;
    }

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public immutable stakingToken;
    address public immutable gauge;
    address public immutable beets;
    address public immutable multisig;
    address public immutable treasury;
    address public rewardVester;

    uint internal constant MINLOCK = 4 * 7 * 86400;
    uint internal constant MAXLOCK = 26 * 7 * 86400;
    uint internal constant MAXVEST = 6 * 7 * 86400;

    uint internal constant DURATION = 7 days;
    uint internal constant PRECISION = 10 ** 18;
    uint internal constant PENALTYDIV = 1000;

    // 60% penalty, 40% to lockers, 10% to treasury
    uint internal constant EARLYPENALTY = 600; 
    // Used to calculate lockerRetained based on pre-calculated penalty amount. 40% of Total amount = 83.33% of the 60% penalty amount
    // As it does not return a whole number, we have allowed it to be marginally over the 40% by rounding up to 83.4%
    uint internal constant LOCKRETAINED = 834;

    uint internal unsyncedBeets;
    uint public lastBeetsHarvest;

    bool public paused;
    bool public sonicMigration;

    address[] internal rewards;

    mapping(address token => Reward) internal _rewardData;
    mapping(address token => bool) public isReward;
    mapping(address user => mapping(address token => uint rewardPerToken)) public userRewardPerTokenStored;
    mapping(address user => mapping(address token => uint reward)) public storedRewardsPerUser;
    mapping(address user => UserInfo) public userInfo;

    event LockCreated(address indexed from, uint amount, uint lockEnd);

    event LockAmountIncreased(address indexed from, uint amount);

    event LockExtended(address indexed user, uint amount);

    event LockTransfered(address indexed from, address indexed to, uint amount);

    event UnlockedEarly(address indexed user, uint received, uint retained);

    event LockWithdrawn(address indexed user, uint amount);

    event LockBroken(address indexed user, uint lockAmount);

    event VestCreated(address indexed user, uint amount, uint vestEnd);

    event AddedToVest(address indexed user, uint amount);
    
    event EarlyUnvest(address indexed user, uint amountReceived, uint amountRetained);

    event VestWithdrawn(address indexed user, uint amount);

    event VestBroken(address indexed user, uint vestAmount);

    event NotifyReward(address indexed from, address indexed reward, uint amount);

    event ClaimRewards(address indexed from, address indexed reward, uint amount);

    event EmergencyWithdraw(uint amount);

    event RewardVesterSet(address indexed newVester);

    event WasPaused(uint amount);

    event UnPaused(uint amount);

    event ShutDown(bool state);

    constructor(
        address[3] memory _operators,
        address _admin,
        address _treasury,
        address _stakingtoken,
        address _gauge,
        address _rewardVester,
        address _beets,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) ReentrancyGuard() {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operators[0]);
        _grantRole(OPERATOR_ROLE, _operators[1]);
        _grantRole(OPERATOR_ROLE, _operators[2]);

        multisig = _admin;
        treasury = _treasury;
        stakingToken = _stakingtoken;  
        gauge = _gauge;
        rewardVester = _rewardVester;
        beets = _beets;

        rewards.push(_beets);
        isReward[_beets] = true;
      
        IERC20(stakingToken).approve(_gauge, type(uint).max);
    }

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    /// @dev compiled with via-ir, caching is less efficient
    function _updateReward(address account) internal {
        for (uint i; i < rewards.length; i++) {
            _rewardData[rewards[i]].rewardPerTokenStored = rewardPerToken(
                rewards[i]
            );
            _rewardData[rewards[i]].lastUpdateTime = lastTimeRewardApplicable(
                rewards[i]
            );
            if (account != address(0)) {
                storedRewardsPerUser[account][rewards[i]] = earned(
                    rewards[i],
                    account
                );
                userRewardPerTokenStored[account][rewards[i]] = _rewardData[
                    rewards[i]
                ].rewardPerTokenStored;
            }
        }
    }

    // Returns current reward list
    function rewardsList() external view returns (address[] memory _rewards) {
        _rewards = rewards;
    }

    function rewardsListLength() external view returns (uint _length) {
        _length = rewards.length;
    }

    /// @notice returns the last time the reward was modified or periodFinish if the reward has ended
    function lastTimeRewardApplicable(address token) public view returns (uint) {
        return Math.min(_getTimestamp(), _rewardData[token].periodFinish);
    }

    // Returns struct with all stored info regarding a reward token. 
    function rewardData(address token) external view returns (Reward memory data) {
        data = _rewardData[token];
    }

    // Returns depositor's accrued rewards
    function earned(address token,address account) public view returns (uint _reward) {
        uint userRewardRate = _getUserRewardRate();
        _reward =
        (((balanceOf(account) *
            (rewardPerToken(token) -
                userRewardPerTokenStored[account][token])) / PRECISION) * 
                userRewardRate) / 100 +
                storedRewardsPerUser[account][token];
    }

    /// @notice claims all pending locked and non locked rewards for depositor
    function getReward() public nonReentrant updateReward(msg.sender) {
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        for (uint i; i < rewards.length; i++) {
            uint reward = storedRewardsPerUser[user][rewards[i]];
            if (reward > 0) {
                storedRewardsPerUser[user][rewards[i]] = 0;
                if(rewards[i] == address(this)){
                    if(!account.isLocked && !account.isVested){_unlockReward(reward);
                    } else {
                        
                        // If reward is locked LP receipt, sort if amt is assinged to vest or lock.
                        if (!account.isLocked && account.isVested) {  // Only Vested
                            account.vestedAmount += reward;
                            } else if (account.isLocked && !account.isVested) { // Only locked
                                account.lockedAmount += reward;
                                } else if (account.isLocked && account.isVested) {
                                    if (account.lockedFor >= account.vestedFor) {
                                        account.lockedAmount += reward;
                                        } else {
                                            account.vestedAmount += reward;
                                        }
                                }
                                _mint(user, reward);
                    }
                } else {
                _safeTransfer(rewards[i], user, reward);
                }
                emit ClaimRewards(user, rewards[i], reward);
            } 
        }
    }

    // Returns rewardToken amount 
    function rewardPerToken(address token) public view returns (uint) {
        if (totalSupply() == 0) {
            return _rewardData[token].rewardPerTokenStored;
        }
        return
            _rewardData[token].rewardPerTokenStored +
            ((lastTimeRewardApplicable(token) -
                _rewardData[token].lastUpdateTime) *
                _rewardData[token].rewardRate *
                PRECISION) /
            totalSupply();
    }

    function _getUserRewardRate() internal view returns (uint) {
        address user = msg.sender;
        UserInfo memory account = userInfo[user];

        uint baseRate = 70;
        uint additionalRate;
        uint timeLeft;

        if(account.vestedAmount < account.lockedAmount){
            timeLeft = lockLeft(user);
        } else {timeLeft = vestLeft(user);}
        
        if (timeLeft > 5 * MINLOCK) {
            additionalRate = 30; // 5 to 6 months: 100%
            } else if (timeLeft > 4 * MINLOCK) {
                additionalRate = 24; // 4 to 5 months: 94%
                } else if (timeLeft > 3 * MINLOCK) {
                    additionalRate = 18; // 3 to 4 months: 88%
                    } else if (timeLeft > 2 * MINLOCK) {
                        additionalRate = 12; // 2 to 3 months: 82%
                        } else if (timeLeft > MINLOCK) {
                            additionalRate = 6; // 1 to 2 months: 76%
                        }        
        return baseRate + additionalRate;
    }

    /// @notice User created Lock. 1-6M duration range.
    function createLock(uint amount, uint duration) external nonReentrant updateReward(msg.sender){
        if(paused){revert Paused();}
        if(amount == 0) {revert ZeroAmount();}

        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(account.isLocked){revert UnderTimeLock();} // Check if already locked.

        uint timestamp = _getTimestamp();
        uint unlockTime = timestamp + duration;

        if(unlockTime <= timestamp + MINLOCK){unlockTime = timestamp + MINLOCK;}
        if(unlockTime >= timestamp + MAXLOCK){unlockTime = timestamp + MAXLOCK;}

        account.isLocked = true;
        account.lockedFor = unlockTime;

        _safeTransferFrom(stakingToken, user, address(this), amount);
        IGauge(gauge).deposit(amount);
        _mint(user, amount);

        account.lockedAmount += amount;

        emit LockCreated(user, amount, unlockTime);
    }

    // Adds an amount to an active lock.
    function increaseLockAmount(uint amount) external nonReentrant updateReward(msg.sender) {
        if(paused){revert Paused();}
        if(amount == 0) {revert ZeroAmount();}

        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isLocked){revert NoLock();}
        if(_getTimestamp() >= account.lockedFor){revert Expired();}

        _safeTransferFrom(stakingToken, user, address(this), amount);
        IGauge(gauge).deposit(amount);
        _mint(user, amount);

        account.lockedAmount += amount;

        emit LockAmountIncreased(user, amount);
    }

    // Extends duration of an ongoing lock
    function extendLock(uint duration) external nonReentrant {
        if(paused){revert Paused();}
        address user = msg.sender;
        UserInfo storage account = userInfo[user];
        if(!account.isLocked){revert NoLock();}

        uint timestamp = _getTimestamp();
        uint unlockTime = timestamp + duration;

        if(unlockTime <= account.lockedFor){revert InvalidLockDuration();} // Can only increase lock duration
        if(unlockTime < timestamp + MINLOCK){revert InvalidLockDuration();} // Below 1M min
        if(unlockTime >= timestamp + MAXLOCK){unlockTime = timestamp + MAXLOCK;} // 26 weeks max lock

        account.lockedFor = unlockTime;

        emit LockExtended(user, unlockTime);
    }

    function withdrawLock() public nonReentrant updateReward(msg.sender){
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isLocked){revert NoLock();}
        if(_getTimestamp() < account.lockedFor){revert UnderTimeLock();}

        account.isLocked = false;
        uint userLockBal = account.lockedAmount;
        account.lockedFor = 0;
        account.lockedAmount = 0;

        _burn(user, userLockBal);

        uint gaugeBal = _gaugeBalance();

        if(gaugeBal >= userLockBal){
            IGauge(gauge).withdraw(userLockBal);
        }

        _safeTransfer(stakingToken, user, userLockBal);   

        emit LockWithdrawn(user, userLockBal);
    }

    // Allows locker to exit full or partial position with a 40% penalty.
    function earlyUnlock(uint amount) external nonReentrant updateReward(msg.sender) updateReward(treasury){
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isLocked){revert NoLock();}
        if(_getTimestamp() >= account.lockedFor){revert Expired();}
        if(amount == 0) {revert ZeroAmount();}
        if(amount > account.lockedAmount){amount = account.lockedAmount;}

        account.lockedAmount -= amount;

        if(account.lockedAmount == 0){account.isLocked = false; account.lockedFor = 0;}

        UserInfo storage protocol = userInfo[treasury];

        uint earlyPenalty = amount * EARLYPENALTY / PENALTYDIV;
        uint userReceived = amount - earlyPenalty;
        uint lockerRetained = earlyPenalty * LOCKRETAINED / PENALTYDIV;
        uint treasuryRetained = earlyPenalty - lockerRetained;

        _burn(user, amount);
        _mint(treasury, treasuryRetained);

        if(!protocol.isLocked){
            protocol.isLocked = true;
            protocol.lockedFor = block.timestamp + MAXLOCK;
            protocol.lockedAmount += treasuryRetained;

        } else {
            protocol.lockedAmount += treasuryRetained;
        }

        _distroEarlyPenalty(lockerRetained);

        uint gaugeBal = _gaugeBalance();

        if(gaugeBal >= userReceived){
            IGauge(gauge).withdraw(userReceived);
        }

        _safeTransfer(stakingToken, user, userReceived);

        emit UnlockedEarly(user, userReceived, lockerRetained + treasuryRetained);
    }

    // Partial or complete transfer of a lock to new or existing lock. If receiver is locked, lockedFor must >= msg.sender's
    // If receiver isn't locked, creates one with the same lockedFor as msg.sender
    function transferLock(address receiver, uint amount) external nonReentrant updateReward(msg.sender) updateReward(receiver){
        address user = msg.sender;
        if(receiver == user){revert InvalidTokenOrAddress();}
        UserInfo storage senderAccount = userInfo[user];

        if(!senderAccount.isLocked){revert NoLock();}
        if(_getTimestamp() >= senderAccount.lockedFor){revert Expired();}
        if(amount == 0){revert NotAllowed();}
        if(amount > senderAccount.lockedAmount){amount = senderAccount.lockedAmount;}

        UserInfo storage receiverAccount = userInfo[receiver];
        if(receiverAccount.isLocked){
            if(receiverAccount.lockedFor < senderAccount.lockedFor){revert NotAllowed();} // Can't transfer to shorter lock.
        } 

        if(!receiverAccount.isLocked){
            receiverAccount.isLocked = true;
            receiverAccount.lockedFor = senderAccount.lockedFor;
            emit LockCreated(receiver, amount, receiverAccount.lockedFor);
        }

        senderAccount.lockedAmount -= amount;

        if(senderAccount.lockedAmount == 0){
            senderAccount.isLocked = false;
            senderAccount.lockedFor = 0;
        }

        _burn(user, amount);
        _mint(receiver, amount);
        receiverAccount.lockedAmount += amount;

        emit LockTransfered(user, receiver, amount);
    }

    // Creates vestLock when calling earlyClaim in RewardVester contract.
    function createVest(address user, uint amount) external nonReentrant updateReward(user){
        if(msg.sender != rewardVester){revert NotAllowed();}
        uint timestamp = _getTimestamp();
        UserInfo storage account = userInfo[user];

        if(account.isVested){
            if(timestamp >= account.vestedFor){revert Expired();}
        }

        if(!account.isVested){
            uint unlockTime = timestamp + MAXVEST;
            account.isVested = true;
            account.vestedFor = unlockTime;
            emit VestCreated(user, amount, unlockTime);
        } else {
            emit AddedToVest(user, amount);
        }

        _safeTransferFrom(stakingToken, rewardVester, address(this), amount);
        account.vestedAmount += amount;

        IGauge(gauge).deposit(amount);
        _mint(user, amount);

    }

    function withdrawVest() public nonReentrant updateReward(msg.sender) {
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isVested){revert NoVest();}
        if(_getTimestamp() < account.vestedFor){revert UnderTimeLock();}

        uint amount = account.vestedAmount;

        account.vestedAmount = 0;
        account.vestedFor = 0;
        account.isVested = false;
        _burn(user, amount);

        uint gaugeBal = _gaugeBalance();

        if(gaugeBal >= amount){
            IGauge(gauge).withdraw(amount);
        }

        _safeTransfer(stakingToken, user, amount);   

        emit VestWithdrawn(user, amount);
    }

    function earlyUnvest(uint amount) external nonReentrant updateReward(msg.sender) updateReward(treasury){
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isVested){revert NoVest();}
        if(_getTimestamp() >= account.vestedFor){revert Expired();}
        if(amount == 0) {revert ZeroAmount();}
        if(amount > account.vestedAmount){amount = account.vestedAmount;}

        account.vestedAmount -= amount;
        if(account.vestedAmount == 0){account.isVested = false;}

        uint earlyPenalty = amount * EARLYPENALTY / PENALTYDIV;
        uint userReceived = amount - earlyPenalty;
        uint lockerRetained = earlyPenalty * LOCKRETAINED / PENALTYDIV;
        uint treasuryRetained = earlyPenalty - lockerRetained;

        UserInfo storage protocol = userInfo[treasury];
        _burn(user, amount);
        _mint(treasury, treasuryRetained);

        if(!protocol.isLocked){
            protocol.isLocked = true;
            protocol.lockedFor = block.timestamp + MAXLOCK;
            protocol.lockedAmount += treasuryRetained;

        } else {
            protocol.lockedAmount += treasuryRetained;
        }

        _distroEarlyPenalty(lockerRetained);

        uint gaugeBal = _gaugeBalance();

        if(gaugeBal >= userReceived){
            IGauge(gauge).withdraw(userReceived);
        }

        _safeTransfer(stakingToken, user, userReceived);

        emit UnlockedEarly(user, userReceived, lockerRetained + treasuryRetained);
    }

    /// @notice Transfers vested amount into a new or existing non expired but longer lock
    function vestToLock(uint amount, uint duration) external nonReentrant{
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!account.isVested){revert NoVest();}
        if(amount == 0) {revert ZeroAmount();}
        if(amount > account.vestedAmount){amount = account.vestedAmount;}

        uint timestamp = _getTimestamp();
        if(timestamp >= account.vestedFor){revert Expired();}

        account.vestedAmount -= amount;

        if(!account.isLocked){
            uint unlockTime = timestamp + duration;
            if(unlockTime <= account.vestedFor){revert InvalidLockDuration();} // Lock shorter than vest
            if(unlockTime <= timestamp + MINLOCK){unlockTime = timestamp + MINLOCK;}
            if(unlockTime >= timestamp + MAXLOCK){unlockTime = timestamp + MAXLOCK;}
            
            account.isLocked = true;
            account.lockedFor = unlockTime;
            account.lockedAmount += amount;
            emit LockCreated(user, amount, unlockTime);
        } else {
            if(account.vestedFor >= account.lockedFor){revert InvalidLockDuration();} // Lock shorter than vest
            if(timestamp >= account.lockedFor){revert Expired();}
            account.lockedAmount += amount;
            emit LockAmountIncreased(user, amount);
        }

        if(account.vestedAmount == 0){account.isVested = false; account.vestedFor = 0;}
    }

    // Our protocol is slated to migrate from Fantom Opera to sonic. This function enables lockers to jailBreak if 
    // fMoney Staker is paused in order to bridge their fBUX and lock on Sonic.
    function breakerOfLocks() external {
        address user = msg.sender;
        UserInfo storage account = userInfo[user];

        if(!paused){revert NotPaused();}
        if(!sonicMigration){revert NotAllowed();}
        
        if(account.isLocked){
            account.lockedFor = 0;
            emit LockBroken(user, account.lockedAmount);
            withdrawLock();
        }

        if(account.isVested){
            account.vestedFor = 0; 
            emit VestBroken(user, account.vestedAmount);
            withdrawVest();
        }
    }

    // Returns, in seconds, how much time is left on a lock.
    function lockLeft(address user) public view returns(uint){
        UserInfo memory account = userInfo[user];
        uint timestamp = _getTimestamp();
        uint lockEnd = account.lockedFor;

        if(lockEnd == 0){return 0;}
        if(timestamp >= lockEnd){return 0;}

        return lockEnd - timestamp;
    }

    // Returns, in seconds, how much time is left on a vest.
    function vestLeft(address user) public view returns(uint){
        UserInfo memory account = userInfo[user];
        uint timestamp = _getTimestamp();
        uint vestEnd = account.vestedFor;

        if(vestEnd == 0){return 0;}
        if(timestamp >= vestEnd){return 0;}

        return vestEnd - timestamp;
    }

    // Returns reward duration
    function left(address token) public view returns (uint) {
        uint timestamp = _getTimestamp();
        if (timestamp >= _rewardData[token].periodFinish) return 0;
        uint _remaining = _rewardData[token].periodFinish - timestamp;
        return _remaining * _rewardData[token].rewardRate;
    }

    /// @notice Tops up reward pool for a token
    function notifyRewardAmount(address token, uint amount) external updateReward(address(0)) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) {revert ZeroAmount();}

        if (!isReward[token]) {
            rewards.push(token);
            isReward[token] = true;
        }

        uint timestamp = _getTimestamp();
        address thisContract = address(this);
        uint periodFinish = _rewardData[token].periodFinish;
        _rewardData[token].rewardPerTokenStored = rewardPerToken(token);

        // Check actual amount transferred for compatibility with fee on transfer tokens.
        uint balanceBefore = _balanceOf(token, thisContract);
        _safeTransferFrom(token, msg.sender, thisContract, amount);
        uint balanceAfter = _balanceOf(token, thisContract);
        amount = balanceAfter - balanceBefore;

        if (timestamp >= periodFinish) {
            _rewardData[token].rewardRate = amount / DURATION;
        } else {
            uint remaining = periodFinish - timestamp;
            uint _left = remaining * _rewardData[token].rewardRate;
            _rewardData[token].rewardRate = (amount + _left) / DURATION;
        }

        _rewardData[token].lastUpdateTime = timestamp;
        _rewardData[token].periodFinish = timestamp + DURATION;

        emit NotifyReward(msg.sender, token, amount);
    }

    // Harvests beets rewards & adds amount to reward pool
    function harvestBeets() external nonReentrant updateReward(address(0)) {
        uint timestamp = _getTimestamp();
        address thisContract = address(this);
        if(timestamp < lastBeetsHarvest + 5 days){revert UnderTimeLock();}
        lastBeetsHarvest = timestamp;

        uint beetsBalance = _balanceOf(beets, thisContract);
        IGauge(gauge).claim_rewards();
        uint beetsBalanceAfter = _balanceOf(beets, thisContract);

        uint _unsyncedBeets = beetsBalanceAfter - beetsBalance;
        _unsyncedBeets += unsyncedBeets;
        if(_unsyncedBeets == 0){revert ZeroAmount();}
        unsyncedBeets = 0;
        
        _rewardData[beets].rewardPerTokenStored = rewardPerToken(beets);

        if (timestamp >= _rewardData[beets].periodFinish) {
            _rewardData[beets].rewardRate = _unsyncedBeets / DURATION;
        } else {
            uint remaining = _rewardData[beets].periodFinish - timestamp;
            uint _left = remaining * _rewardData[beets].rewardRate;
            _rewardData[beets].rewardRate = (_unsyncedBeets + _left) / DURATION;
        }

        _rewardData[beets].lastUpdateTime = timestamp;
        _rewardData[beets].periodFinish = timestamp + DURATION;
                
        emit NotifyReward(msg.sender, beets, _unsyncedBeets);
    }

    /// @notice Distributes penalty from early unlocks as locked rewards to Lockers.
    function _distroEarlyPenalty(uint amount) internal updateReward(address(0)) {
        address lockReceipt = address(this);

        if (!isReward[lockReceipt]) {
            rewards.push(lockReceipt);
            isReward[lockReceipt] = true;
        }

        uint timestamp = _getTimestamp();
        _rewardData[lockReceipt].rewardPerTokenStored = rewardPerToken(lockReceipt);

        if (timestamp >= _rewardData[lockReceipt].periodFinish) {
            _rewardData[lockReceipt].rewardRate = amount / DURATION;
        } else {
            uint remaining = _rewardData[lockReceipt].periodFinish - timestamp;
            uint _left = remaining * _rewardData[lockReceipt].rewardRate;
            _rewardData[lockReceipt].rewardRate = (amount + _left) / DURATION;
        }

        _rewardData[lockReceipt].lastUpdateTime = timestamp;
        _rewardData[lockReceipt].periodFinish = timestamp + DURATION;

        emit NotifyReward(msg.sender, lockReceipt, amount);
    }

    //If user has exited lock or vest, getReward calls this func to unlock pending locked Reward and send to user.
    function _unlockReward(uint amount) internal{
        uint gaugeBal = _gaugeBalance();
        
        if(gaugeBal >= amount){
            IGauge(gauge).withdraw(amount);
        }
        _safeTransfer(stakingToken, msg.sender, amount);
    }

    /// @notice Emergency withdraw from chef to staking contract & pause deposits.
    function emergencyWithdrawFromGauge() external onlyRole(OPERATOR_ROLE){
        if(paused){revert Paused();}

        uint gaugeBal = IGauge(gauge).balanceOf(address(this));
        IGauge(gauge).withdraw(gaugeBal);

        paused = true;
        uint stakingBal = _balanceOf(stakingToken, address(this));
        
        emit EmergencyWithdraw(stakingBal);
    }

    // Unpauses deposits and stakes LP in chef if there's balance in the contract
    function unpause() external onlyRole(OPERATOR_ROLE){
        if(!paused){revert NotPaused();}
        paused = false;

        uint stakingBal = _balanceOf(stakingToken, address(this));
        if(stakingBal != 0){IGauge(gauge).deposit(stakingBal);}
        emit UnPaused(stakingBal);
    }

    // Recovers token mistakenly sent to the contract if not a protected token.
    function recoverTokens(address token, address to, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if(token == stakingToken || isReward[token] || token == gauge){revert InvalidTokenOrAddress();}
        _safeTransfer(token, to, amount);
    }

    //To cover a migration/shutdown, rewards can be sent to multisig.
    function recoverRewards(address token, uint amount) external onlyRole(OPERATOR_ROLE){
        if(!paused){revert NotPaused();}
        if(token == stakingToken){revert InvalidTokenOrAddress();}
        _safeTransfer(token, multisig, amount);
    }

    // To cover a pool migration/contract shutdown, this 
    // admin gated function enables users to dissolve locks if the staker has been emergency withdrawn and is paused.
    function setShutdown(bool state) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(!paused){revert NotPaused();}
        sonicMigration = state;
        emit ShutDown(state);
    }

    // In the event of a rewardVester change.
    function setRewardVester(address vester) external onlyRole(DEFAULT_ADMIN_ROLE){
        if(vester == address(0)){revert InvalidTokenOrAddress();}
        rewardVester = vester;
        emit RewardVesterSet(vester);
    }

    // Approval refresh for contract longevity
    function renewApprovals() external onlyRole(OPERATOR_ROLE){
        IERC20(stakingToken).approve(gauge, 0);
        IERC20(stakingToken).approve(gauge, type(uint).max);
    }

    // Returns contract's stakingToken amount deposited in chef & rewardDebt
    function _gaugeBalance() internal view returns(uint lpAmount){
        return IGauge(gauge).balanceOf(address(this));
    }

    function _getTimestamp() internal view returns (uint){
        return block.timestamp;
    }

    // Internal update function, adds or removes reward shares for a depositor.
    function _update(address from, address to, uint value) internal override {
        // if burn or mint
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
        } else {
            _updateReward(from);
            _updateReward(to);
            super._update(from, to, value);
        }
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

    function _balanceOf(address token, address account) internal view returns (uint) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeCall(IERC20.balanceOf, (account))
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint));
    }
}