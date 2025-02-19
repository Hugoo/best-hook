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

    // Track last tick for each pool
    mapping(PoolId => int24) public lastTick;
    // Track last timestamp for each pool
    mapping(PoolId => uint256) public lastTimestamp;
    // Track accumulated rewards for each position
    mapping(bytes32 => uint256) public accumulatedRewards;

    // Reward rate per second per unit of liquidity
    uint256 public constant REWARD_RATE = 1e18; // Configurable

    constructor(IPoolManager _manager, IERC20 _rewardToken) BaseHook(_manager) {
        rewardToken = _rewardToken;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        lastTick[poolId] = tick;
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 oldTick = lastTick[poolId];

        if (currentTick != oldTick) {
            uint256 timeElapsed = block.timestamp - lastTimestamp[poolId];

            // Update secondsPerLiquidity
            // Get tick info for both old and new ticks
            (uint128 liquidityGross,,,) = poolManager.getTickInfo(poolId, currentTick);

            // Convert liquidityGross to uint256 for safe math
            uint256 currentLiquidity = uint256(liquidityGross);

            if (currentLiquidity > 0) {
                secondsPerLiquidity[poolId] += timeElapsed * currentLiquidity;
            }

            // Update secondsPerLiquidityOutside for crossed ticks
            int24 tickLower = oldTick < currentTick ? oldTick : currentTick;
            int24 tickUpper = oldTick < currentTick ? currentTick : oldTick;

            for (int24 tick = tickLower; tick <= tickUpper; tick++) {
                (uint128 tickLiquidityGross,,,) = poolManager.getTickInfo(poolId, tick);
                if (tickLiquidityGross > 0) {
                    secondsPerLiquidityOutside[poolId][tick] += timeElapsed * uint256(tickLiquidityGross);
                }
            }
        }

        lastTimestamp[poolId] = block.timestamp;
        lastTick[poolId] = currentTick;

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // Calculate and store secondsPerLiquidityInsideDeposit
        uint256 secondsPerLiquidityInside =
            calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper);

        secondsPerLiquidityInsideDeposit[poolId][positionKey] = secondsPerLiquidityInside;

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        // Calculate rewards
        uint256 secondsPerLiquidityInside =
            calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper);

        uint256 totalSecondsPerLiquidity =
            secondsPerLiquidityInside - secondsPerLiquidityInsideDeposit[poolId][positionKey];

        uint256 rewards = calculateRewards(totalSecondsPerLiquidity, uint256(params.liquidityDelta));
        accumulatedRewards[positionKey] += rewards;

        // Clean up storage
        delete secondsPerLiquidityInsideDeposit[poolId][positionKey];

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function calculateSecondsPerLiquidityInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
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
        return (totalSecondsPerLiquidity * liquidity * REWARD_RATE) / 1e18;
    }

    function redeemRewards( IPoolManager.ModifyLiquidityParams calldata params) external {
        bytes32 positionKey = Position.calculatePositionKey(msg.sender, params.tickLower, params.tickUpper, params.salt);
        uint256 rewards = accumulatedRewards[positionKey];
        if (rewards == 0) revert NoRewardsAvailable();

        if (rewardToken.balanceOf(address(this)) < rewards) {
            revert InsufficientRewardBalance();
        }

        delete accumulatedRewards[positionKey];
        rewardToken.transfer(msg.sender, rewards);
    }
}
