// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract LPIncentiveHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NoRewardsAvailable();
    error InsufficientRewardBalance();

    // State variables for tracking liquidity mining rewards
    IERC20 public immutable rewardToken;
    mapping(PoolId => uint256) public secondsPerLiquidity;
    mapping(PoolId => mapping(int24 => uint256)) public secondsPerLiquidityOutside;
    mapping(PoolId => mapping(bytes32 => uint256)) public secondsPerLiquidityInsideDeposit;
    // Storing the last liquidity per second updates
    // Storing the last time
    mapping(PoolId => mapping(int24 => uint256)) public secondsPerLiquidityOutsideLastUpdate;
    // Storing the last global liquidity per second
    mapping(PoolId => mapping(int24 => uint256)) public lastLiquidityPerSecondOfTick;

    // Track last tick for each pool before the swap
    mapping(PoolId => int24) public beforeSwapTick;
    // Track last timestamp for each pool
    mapping(PoolId => uint256) public lastUpdateTimeOfSecondsPerLiquidity;
    // Track accumulated rewards for each position
    mapping(address => uint256) public accumulatedRewards;

    // Reward rate per second per unit of liquidity
    uint256 public constant REWARD_RATE = 1e18; // Configurable

    constructor(IPoolManager _manager, IERC20 _rewardToken) BaseHook(_manager) {
        rewardToken = _rewardToken;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 oldTick = beforeSwapTick[poolId];

        // If we are crossing ticks, we need to update the secondsPerLiquidity
        if (currentTick != oldTick) {
            updateSecondsPerLiquidity(poolId);
            
            // Determine which direction we crossed ticks
            bool zeroForOne = params.zeroForOne;
            int24 tickLower = oldTick < currentTick ? oldTick : currentTick;
            int24 tickUpper = oldTick < currentTick ? currentTick : oldTick;

            // Update all crossed ticks
            for (int24 tick = tickLower; tick <= tickUpper; tick++) {
                updatesecondsPerLiquidityOutsideForTick(poolId, tick, zeroForOne);
            }
        }

        beforeSwapTick[poolId] = currentTick;
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // maybe put this into afterINitialized
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        beforeSwapTick[poolId] = currentTick;

        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        
        updateSecondsPerLiquidity(poolId);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickLower, params.tickLower > currentTick); 
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickUpper, params.tickUpper > currentTick); 
        updateUserRewards(sender, poolId, params, positionKey);

        
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        updateSecondsPerLiquidity(poolId);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickLower, params.tickLower > currentTick); 
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickUpper, params.tickUpper > currentTick); 
        updateUserRewards(sender, poolId, params, positionKey);

        return (BaseHook.beforeRemoveLiquidity.selector);
    }

    function updateSecondsPerLiquidity(PoolId poolId) internal {
        uint256 timeElapsed = block.timestamp - lastUpdateTimeOfSecondsPerLiquidity[poolId];
        if (timeElapsed > 0) {  // Only update if time has passed
            uint256 currentLiquidity = poolManager.getLiquidity(poolId);
            if (currentLiquidity > 0) {
                // Scale by 1e18 to maintain precision
                secondsPerLiquidity[poolId] += (timeElapsed * 1e36) / currentLiquidity;
            }
            lastUpdateTimeOfSecondsPerLiquidity[poolId] = block.timestamp;
        }
    }

    function updateSecondsPerLiquidityInTicks(
        PoolId poolId,
        int24 currentTick,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal {
        int24 tickLower = params.tickLower > currentTick ? params.tickLower : currentTick;
        int24 tickUpper = params.tickUpper < currentTick ? params.tickUpper : currentTick;
        for (int24 tick = tickLower; tick <= tickUpper; tick++) {
            updatesecondsPerLiquidityOutsideForTick(poolId, tick, params.tickLower > currentTick);
        }
    }

    function updatesecondsPerLiquidityOutsideForTick(PoolId poolId, int24 tick, bool tickWasOutside) internal {
        (uint128 tickLiquidityGross,,,) = poolManager.getTickInfo(poolId, tick);
        if (tickLiquidityGross > 0) {
            uint256 timeElapsed = block.timestamp - secondsPerLiquidityOutsideLastUpdate[poolId][tick];
            if (timeElapsed > 0) {  // Only update if time has passed
                if(!tickWasOutside){
                    uint256 secondsPerliquidityDelta = secondsPerLiquidity[poolId] - lastLiquidityPerSecondOfTick[poolId][tick];
                    if (secondsPerliquidityDelta > 0) {  // Only update if there's a change in liquidity
                        secondsPerLiquidityOutside[poolId][tick] += secondsPerliquidityDelta;
                    }
                }
                lastLiquidityPerSecondOfTick[poolId][tick] = secondsPerLiquidity[poolId];
                secondsPerLiquidityOutsideLastUpdate[poolId][tick] = block.timestamp;
            }
        }
    }

    function updateUserRewards(
        address sender,
        PoolId poolId,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes32 positionKey
    ) internal {
        // Get position liquidity BEFORE the modification
        (uint128 positionLiquidity) = poolManager.getPositionLiquidity(poolId, positionKey);

        // Calculate rewards
        uint256 secondsPerLiquidityInside = calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper);
        uint256 lastSecondsPerLiquidityInside = secondsPerLiquidityInsideDeposit[poolId][positionKey];

        // Only calculate rewards if this isn't the first deposit
        if (lastSecondsPerLiquidityInside > 0) {
            uint256 totalSecondsPerLiquidity = secondsPerLiquidityInside - lastSecondsPerLiquidityInside;
            
            // Calculate rewards based on the position's liquidity before the modification
            if (positionLiquidity > 0) {
                uint256 rewards = calculateRewards(totalSecondsPerLiquidity, uint256(positionLiquidity));
                accumulatedRewards[sender] += rewards;
            }
        }

        // Update the stored secondsPerLiquidityInside for future calculations
        secondsPerLiquidityInsideDeposit[poolId][positionKey] = secondsPerLiquidityInside;
    }

    function calculateSecondsPerLiquidityInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        uint256 secondsPerLiquidityBelow;
        uint256 secondsPerLiquidityAbove;

        if (currentTick < tickLower) {
            secondsPerLiquidityBelow = secondsPerLiquidity[poolId] - secondsPerLiquidityOutside[poolId][tickLower];
        } else {
            secondsPerLiquidityBelow = secondsPerLiquidityOutside[poolId][tickLower];
        }

        if (currentTick < tickUpper) {
            secondsPerLiquidityAbove = secondsPerLiquidity[poolId] - secondsPerLiquidityOutside[poolId][tickUpper];
        } else {
            secondsPerLiquidityAbove = secondsPerLiquidityOutside[poolId][tickUpper];
        }

        return secondsPerLiquidity[poolId] - secondsPerLiquidityBelow - secondsPerLiquidityAbove;
    }

    function calculateRewards(uint256 totalSecondsPerLiquidity, uint256 liquidity) internal pure returns (uint256) {
        // Adjust reward calculation to properly account for time and liquidity
        // REWARD_RATE is per second per unit of liquidity (1e18)
        // We divide by 1e36 because totalSecondsPerLiquidity is scaled by 1e18 and we want to normalize the result
        return (totalSecondsPerLiquidity * liquidity * REWARD_RATE) / 1e36;
    }

    function redeemRewards() external {
        uint256 rewards = accumulatedRewards[msg.sender];
        if (rewards == 0) revert NoRewardsAvailable();

        if (rewardToken.balanceOf(address(this)) < rewards) {
            revert InsufficientRewardBalance();
        }

        delete accumulatedRewards[msg.sender];
        rewardToken.transfer(msg.sender, rewards);
    }
}
