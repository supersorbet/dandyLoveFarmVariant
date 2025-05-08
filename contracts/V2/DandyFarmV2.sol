// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "../../lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "../../lib/solady/src/utils/ReentrancyGuard.sol";
import {DandyV2} from "./DandyV2.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title DandyFarmV2
/// @notice Staking contract for LP tokens to earn Dandy tokens with gas optimizations
contract DandyFarmV2 is Ownable, ReentrancyGuard {
    
    error InvalidPool();
    error InvalidAmount();
    error InsufficientBalance();
    error ExcessiveDepositFee();
    error ZeroAddress();
    error AlreadyInitialized();
    error HarvestTooEarly();

    using SafeTransferLib for address;
    using SafeTransferLib for DandyV2;
    using FixedPointMathLib for uint256;

    struct UserInfo {
        uint256 amount;             // How many LP tokens the user has provided
        uint256 rewardDebt;         // Reward debt (technical accounting value for rewards)
        uint64 lastHarvestTimestamp; // Last time user harvested rewards
    }

    struct PoolInfo {
        address lpToken;            // Address of LP token contract
        uint256 allocPoint;         // How many allocation points assigned to this pool
        uint256 lastRewardBlock;    // Last block number that reward distribution occurs
        uint256 accDandyPerShare;   // Accumulated Dandy per share, times 1e12
        uint16 depositFeeBP;        // Deposit fee in basis points (100 = 1%)
        uint32 harvestInterval;     // Minimum time between harvests (anti-flash loan)
    }

    DandyV2 public immutable dandy;
    uint256 public dandyPerBlock;
    uint256 public constant BONUS_MULTIPLIER = 1;
    uint256 public constant PRECISION_FACTOR = 1e12;
    address public feeAddress;
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    uint256 public totalAllocPoint;
    uint256 public immutable startBlock;

    /// @notice Constructor
    /// @param _dandy The DandyV2 token address
    /// @param _feeAddress Address where deposit fees go
    /// @param _dandyPerBlock DANDY tokens created per block
    /// @param _startBlock The block number when mining starts
    constructor(
        DandyV2 _dandy,
        address _feeAddress,
        uint256 _dandyPerBlock,
        uint256 _startBlock
    ) {
        if (address(_dandy) == address(0)) revert ZeroAddress();
        if (_feeAddress == address(0)) revert ZeroAddress();
        
        dandy = _dandy;
        feeAddress = _feeAddress;
        dandyPerBlock = _dandyPerBlock;
        startBlock = _startBlock;
        
        _initializeOwner(msg.sender);
    }

    /// @notice View function to see poolLength
    /// @return Number of pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice Return reward multiplier over the given _from to _to block
    /// @param _from Starting block
    /// @param _to Ending block
    /// @return Multiplier
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return (_to > _from) ? (_to - _from) * BONUS_MULTIPLIER : 0;
    }

    /// @notice View function to see pending DANDY tokens
    /// @param _pid Pool ID
    /// @param _user User address
    /// @return Pending DANDY tokens
    function pendingDandy(uint256 _pid, address _user) external view returns (uint256) {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        
        uint256 accDandyPerShare = pool.accDandyPerShare;
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 dandyReward = multiplier.mulDiv(
                dandyPerBlock * pool.allocPoint,
                totalAllocPoint
            );
            accDandyPerShare = accDandyPerShare + dandyReward.mulDiv(PRECISION_FACTOR, lpSupply);
        }
        
        return user.amount.mulDiv(accDandyPerShare, PRECISION_FACTOR) - user.rewardDebt;
    }

    /// @notice Add a new LP token to the pool
    /// @param _allocPoint Allocation points
    /// @param _lpToken LP Token address
    /// @param _depositFeeBP Deposit fee in basis points
    /// @param _harvestInterval Minimum time between harvests
    /// @param _withUpdate Whether to update all pools
    function add(
        uint256 _allocPoint,
        address _lpToken,
        uint16 _depositFeeBP,
        uint32 _harvestInterval,
        bool _withUpdate
    ) external onlyOwner {
        if (_depositFeeBP > 1100) revert ExcessiveDepositFee();
        if (_lpToken == address(0)) revert ZeroAddress();
        
        if (_withUpdate) {
            massUpdatePools();
        }
        
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accDandyPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval
        }));
        
        emit PoolAdded(poolInfo.length - 1, _lpToken, _depositFeeBP, _harvestInterval, _allocPoint);
    }

    /// @notice Update the given pool's allocation point and settings
    /// @param _pid Pool ID
    /// @param _allocPoint Allocation points
    /// @param _depositFeeBP Deposit fee in basis points
    /// @param _harvestInterval Minimum time between harvests
    /// @param _withUpdate Whether to update all pools
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint32 _harvestInterval,
        bool _withUpdate
    ) external onlyOwner {
        if (_pid >= poolInfo.length) revert InvalidPool();
        if (_depositFeeBP > 1100) revert ExcessiveDepositFee();
        
        if (_withUpdate) {
            massUpdatePools();
        }
        
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        
        emit PoolUpdated(_pid, _allocPoint, _depositFeeBP, _harvestInterval);
    }

    /// @notice Update reward variables for all pools
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Update reward variables of the given pool
    /// @param _pid Pool ID
    function updatePool(uint256 _pid) public {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        
        unchecked {
            uint256 dandyReward = multiplier.mulDiv(
                dandyPerBlock * pool.allocPoint,
                totalAllocPoint
            );
            
            dandy.mint(address(this), dandyReward);
            
            pool.accDandyPerShare = pool.accDandyPerShare + 
                dandyReward.mulDiv(PRECISION_FACTOR, lpSupply);
            pool.lastRewardBlock = block.number;
        }
    }

    /// @notice Deposit LP tokens to DandyFarm for DANDY rewards
    /// @param _pid Pool ID
    /// @param _amount Amount to deposit
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
    
        if (user.amount > 0) {
            _harvestRewards(_pid, msg.sender);
        }
        if (_amount > 0) {
            SafeTransferLib.safeTransferFrom(
                pool.lpToken,
                msg.sender,
                address(this),
                _amount
            );
            
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (_amount * pool.depositFeeBP) / 10000;
                SafeTransferLib.safeTransfer(
                    pool.lpToken,
                    feeAddress,
                    depositFee
                );
                user.amount += _amount - depositFee;
            } else {
                user.amount += _amount;
            }
        }
        
        user.rewardDebt = user.amount.mulDiv(pool.accDandyPerShare, PRECISION_FACTOR);
        
        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from DandyFarm
    /// @param _pid Pool ID
    /// @param _amount Amount to withdraw
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        if (user.amount < _amount) revert InsufficientBalance();
        updatePool(_pid);
        
        _harvestRewards(_pid, msg.sender);
        
        if (_amount > 0) {
            user.amount -= _amount;
            SafeTransferLib.safeTransfer(
                pool.lpToken,
                msg.sender,
                _amount
            );
        }
        
        user.rewardDebt = user.amount.mulDiv(pool.accDandyPerShare, PRECISION_FACTOR);
        
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Harvest rewards without withdrawing
    /// @param _pid Pool ID
    function harvest(uint256 _pid) external nonReentrant {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        updatePool(_pid);
        _harvestRewards(_pid, msg.sender);
        
        UserInfo storage user = userInfo[_pid][msg.sender];
        PoolInfo storage pool = poolInfo[_pid];
        
        user.rewardDebt = user.amount.mulDiv(pool.accDandyPerShare, PRECISION_FACTOR);
    }
    
    /// @notice Internal function to harvest rewards with anti-flash loan protection
    /// @param _pid Pool ID
    /// @param _user User address
    function _harvestRewards(uint256 _pid, address _user) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        
        if (pool.harvestInterval > 0) {
            uint64 currentTimestamp = uint64(block.timestamp);
            if (currentTimestamp - user.lastHarvestTimestamp < pool.harvestInterval) {
                revert HarvestTooEarly();
            }
            user.lastHarvestTimestamp = currentTimestamp;
        }
        
        uint256 pending = user.amount.mulDiv(pool.accDandyPerShare, PRECISION_FACTOR) - user.rewardDebt;
        
        if (pending > 0) {
            _safeDandyTransfer(_user, pending);
            emit Harvested(_user, _pid, pending);
        }
    }

    /// @notice Withdraw without caring about rewards
    /// @param _pid Pool ID
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        if (_pid >= poolInfo.length) revert InvalidPool();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.lastHarvestTimestamp = 0;
        
        SafeTransferLib.safeTransfer(
            pool.lpToken,
            msg.sender,
            amount
        );
        
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /// @notice Update fee address
    /// @param _feeAddress New fee address
    function setFeeAddress(address _feeAddress) external onlyOwner {
        if (_feeAddress == address(0)) revert ZeroAddress();
        
        address oldFeeAddress = feeAddress;
        feeAddress = _feeAddress;
        
        emit FeeAddressUpdated(oldFeeAddress, _feeAddress);
    }

    /// @notice Update emission rate
    /// @param _dandyPerBlock New DANDY tokens per block
    function updateEmissionRate(uint256 _dandyPerBlock) external onlyOwner {
        massUpdatePools();
        
        uint256 oldRate = dandyPerBlock;
        dandyPerBlock = _dandyPerBlock;
        
        emit EmissionRateUpdated(oldRate, _dandyPerBlock);
    }

    /// @notice Safe dandy transfer function
    /// @param _to Recipient address
    /// @param _amount Amount to transfer
    function _safeDandyTransfer(address _to, uint256 _amount) internal {
        uint256 dandyBal = dandy.balanceOf(address(this));
        
        if (_amount > dandyBal) {
            SafeTransferLib.safeTransfer(address(dandy), _to, dandyBal);
        } else {
            SafeTransferLib.safeTransfer(address(dandy), _to, _amount);
        }
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event FeeAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);
    event PoolAdded(uint256 indexed pid, address indexed lpToken, uint16 depositFeeBP, uint32 harvestInterval, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint, uint16 depositFeeBP, uint32 harvestInterval);
    event Harvested(address indexed user, uint256 indexed pid, uint256 amount);

} 