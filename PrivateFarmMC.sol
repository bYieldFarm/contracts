    // SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./BYieldToken.sol";
import "./Presale.sol";

// MasterChef is the master of bYield. He can make BYield and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once BYield is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.

contract PrivateFarmMC is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of BYield
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accbYieldPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accbYieldPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. BYIELD to distribute per block.
        uint256 lastRewardBlock;  // Last block number that BYIELD distribution occurs.
        uint256 accByieldPerShare;   // Accumulated BYIELD per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The BYIELD TOKEN!
    BYieldToken public byield;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // BYIELD tokens created per block.
    uint256 public byieldPerBlock;
    // Bonus muliplier for early bYield makers.
    uint256 public constant BONUS_MULTIPLIER = 1;

    // Presale Contract for measuring allowance and whitelisting status
    Presale public presale;

    // Total of 6,400 bYield Allocated for Private Farms 
    // Based on Period of 4 days (115200 blocks), equalivant to 0.055 bYield Per Block
    // Emission Rate will stay constant throughout
    // 55 Finney is the same as 0.055 BYIELD PER BLOCK
    uint256 public constant INITIAL_EMISSION_RATE = 55 finney;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The block number when BYIELD mining starts.
    uint256 public startBlock;
    // Block number when private farming ends
    uint256 public endBlock;
    // Block number when harvest of rewards becomes available 
    uint256 public harvestUnlockBlock;
    // Lockup Period for all Withdrawal: 4 days = 115200 Blocks
    uint256 public constant PRIVATE_FARM_LOCKUP_PERIOD = 115200;
    // Lockup Period for all Harvest: 6 days = 172800 Blocks
    // Withdrawal Locked for 4 days, Harvest Lock for 6 days, 2 days after Private Farming has ended
    uint256 public constant HARVEST_LOCKUP_PERIOD = 172800;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        BYieldToken _byield,
        Presale _presale,
        uint256 _startBlock
    ) public {
        byield = _byield;
        presale = _presale;
        startBlock = _startBlock;
        endBlock =_startBlock.add(PRIVATE_FARM_LOCKUP_PERIOD);
        harvestUnlockBlock = _startBlock.add(HARVEST_LOCKUP_PERIOD);
        devAddress = msg.sender;
        feeAddress = msg.sender;
        byieldPerBlock = INITIAL_EMISSION_RATE;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 0, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accByieldPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's BYIELD allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 0, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 balance = byield.balanceOf(address(this));
        if(balance == 0){
            return 0;
        }
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending BYIELD on frontend.
    function pendingByield(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accByieldPerShare = pool.accByieldPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 byieldReward = multiplier.mul(byieldPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accByieldPerShare = accByieldPerShare.add(byieldReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accByieldPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    // Dev does not take rewards from Emission.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 byieldReward = multiplier.mul(byieldPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        // Removed Mint Function as PrivateMC will have preminted allocation
        pool.accByieldPerShare = pool.accByieldPerShare.add(byieldReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;

    }

    // Deposit LP tokens to MasterChef for BYIELD allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        // Test for WhiteListing Allowance for Private Farms
        uint256 userAllowance = presale.getUserWhitelistingAllowance(msg.sender);
        if(_amount > 0){
            require(presale.getUserWhitelistingStatus(msg.sender) == true, "You're not whitelisted for private farming");
            if (_pid != 0 && _pid != 1 && _pid != 2) {
                require(_amount <= userAllowance, "User have exceeded whitelisting allowance! Please see how much allowance you have left");
        }
        }

        // Ensure that end block has been reached before harvest can be allowed 
        // Depositing more does not harvest any rewards if end block has not been reached
        if (user.amount > 0 && block.number >= harvestUnlockBlock) {
            uint256 pending = user.amount.mul(pool.accByieldPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeByieldTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }

        // If everything succeed, change whitelisting allowance
        // Pid 0, 1 and 2 will be Native LP that will have no allowance limitations
        if (_pid != 0 && _pid != 1 && _pid != 2) {
            presale.changeWhitelistingAllowance(msg.sender, _amount);
        }

        user.rewardDebt = user.amount.mul(pool.accByieldPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Withdrawal only allowed after End Block
        require(block.number >= endBlock, "Withdrawal locked until end block");

        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accByieldPerShare).div(1e12).sub(user.rewardDebt);

        if (pending > 0 && block.number >= harvestUnlockBlock) {
            safeByieldTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accByieldPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    // Despite withdrawal being locked, Emergency withdrawal will still be enabled, but no rewards will be given
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe Byield transfer function, just in case if rounding error causes pool to not have enough BYIELD.
    function safeByieldTransfer(address _to, uint256 _amount) internal {
        uint256 byieldBal = byield.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > byieldBal) {
            transferSuccess = byield.transfer(_to, byieldBal);
        } else {
            transferSuccess = byield.transfer(_to, _amount);
        }
        require(transferSuccess, "safeByieldTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
    }

    // updateEmissionRate
    function updateEmissionRate(uint256 _byieldPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, byieldPerBlock, _byieldPerBlock);
        byieldPerBlock = _byieldPerBlock;
    }

}