// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/Console.sol";

contract LPIncentiveHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NoRewardsAvailable();
    error InsufficientRewardBalance();

    // State variables for tracking liquidity mining rewards
    IERC20 public immutable rewardToken;
    // For global secondsPerLIquidity calcualtion
    mapping(PoolId => mapping(uint256 rewardPeriod => uint256)) public secondsPerLiquidity;
    mapping(PoolId => mapping(uint256 rewardPeriod => uint256)) public lastUpdateTimeOfSecondsPerLiquidity;

    // For secondsPerLiquidity per tick calculation
    mapping(PoolId => mapping(int24 tick => mapping(uint256 rewardPeriod => uint256))) public secondsPerLiquidityOutside;
    mapping(PoolId => mapping(int24 tick => mapping(uint256 rewardPeriod => uint256))) public
        lastLiquidityPerSecondOfTick;
    mapping(PoolId => mapping(int24 tick => uint256)) public lastLiquidityPerSecondOfTickRewardPeriod;

    // For user rewards calculation
    mapping(PoolId => mapping(bytes32 positionKey => mapping(uint256 rewardPeriod => uint256))) public
        secondsPerLiquidityInsideDeposit;
    mapping(PoolId => mapping(bytes32 positionKey => uint256)) public lastUpdateUserRewardPeriod;

    // Track last tick for each pool before the swap
    mapping(PoolId => int24) public beforeSwapTick;
    // Track accumulated rewards for each user
    mapping(address => uint256) public accumulatedRewards;

    // Variables to keep track of the reward rate and the current reward period
    mapping(PoolId => mapping(uint256 rewardPeriod => uint256)) public rewardRate;
    mapping(PoolId => uint256) public currentRewardPeriod;

    // Tick spacing for rewards
    int24 public tickSpacing = 60; // Configurable Todo: check if this is correct

    constructor(IPoolManager _manager, IERC20 _rewardToken, address owner) BaseHook(_manager) Ownable(owner) {
        rewardToken = _rewardToken;
    }

    function setRewardRate(PoolId poolId, uint256 _rewardRate) external onlyOwner {
        updateSecondsPerLiquidity(poolId);
        // update reward period
        currentRewardPeriod[poolId] += 1;
        // set new starting parameters
        secondsPerLiquidity[poolId][currentRewardPeriod[poolId]] =
            secondsPerLiquidity[poolId][currentRewardPeriod[poolId] - 1];
        lastUpdateTimeOfSecondsPerLiquidity[poolId][currentRewardPeriod[poolId]] = block.timestamp;
        // set reward rate
        rewardRate[poolId][currentRewardPeriod[poolId]] = _rewardRate;
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

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        if (rewardRate[poolId][currentRewardPeriod[poolId]] == 0) {
            // todo: check if this is correct, since we might need to do some upodates, if the reward rate is recently set to 0
            return (BaseHook.afterSwap.selector, 0);
        }
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
            for (int24 tick = tickLower / tickSpacing; tick <= tickUpper / tickSpacing; tick++) {
                updatesecondsPerLiquidityOutsideForTick(poolId, tick * tickSpacing, zeroForOne);
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
        if (rewardRate[poolId][currentRewardPeriod[poolId]] == 0) {
            // todo: check whether this is correct
            return (BaseHook.beforeAddLiquidity.selector);
        }
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        beforeSwapTick[poolId] = currentTick;

        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        updateSecondsPerLiquidity(poolId);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickLower, params.tickLower < currentTick);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickUpper, params.tickUpper < currentTick);
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
        if (rewardRate[poolId][currentRewardPeriod[poolId]] == 0) {
            // todo: check whether no updates are really needed
            return (BaseHook.beforeRemoveLiquidity.selector);
        }
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        updateSecondsPerLiquidity(poolId);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickLower, params.tickLower < currentTick);
        updatesecondsPerLiquidityOutsideForTick(poolId, params.tickUpper, params.tickUpper < currentTick);
        updateUserRewards(sender, poolId, params, positionKey);

        return (BaseHook.beforeRemoveLiquidity.selector);
    }

    function updateSecondsPerLiquidity(PoolId poolId) internal {
        uint256 timeElapsed = block.timestamp - lastUpdateTimeOfSecondsPerLiquidity[poolId][currentRewardPeriod[poolId]];
        if (timeElapsed > 0) {
            // Only update if time has passed
            uint256 currentLiquidity = poolManager.getLiquidity(poolId);
            if (currentLiquidity > 0) {
                // Scale by 1e36 to maintain precision
                secondsPerLiquidity[poolId][currentRewardPeriod[poolId]] += (timeElapsed * 1e36) / currentLiquidity;
            }
            lastUpdateTimeOfSecondsPerLiquidity[poolId][currentRewardPeriod[poolId]] = block.timestamp;
        }
    }

    function updatesecondsPerLiquidityOutsideForTick(PoolId poolId, int24 tick, bool tickWasOutside) internal {
        for (
            uint256 currentUserRewardPeriod = lastLiquidityPerSecondOfTickRewardPeriod[poolId][tick];
            currentUserRewardPeriod <= currentRewardPeriod[poolId];
            currentUserRewardPeriod++
        ) {
            uint256 secondsPerliquidityDelta = secondsPerLiquidity[poolId][currentUserRewardPeriod]
                - lastLiquidityPerSecondOfTick[poolId][tick][currentUserRewardPeriod];
            if (secondsPerliquidityDelta > 0 && !tickWasOutside) {
                // Only update if there's a change in liquidity
                secondsPerLiquidityOutside[poolId][tick][currentUserRewardPeriod] += secondsPerliquidityDelta;
            }
            lastLiquidityPerSecondOfTick[poolId][tick][currentUserRewardPeriod] =
                secondsPerLiquidity[poolId][currentUserRewardPeriod];
            lastLiquidityPerSecondOfTickRewardPeriod[poolId][tick] = currentRewardPeriod[poolId];
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

        for (
            uint256 rewardPeriod = lastUpdateUserRewardPeriod[poolId][positionKey];
            rewardPeriod <= currentRewardPeriod[poolId];
            rewardPeriod++
        ) {
            uint256 secondsPerLiquidityInside =
                calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper, rewardPeriod);
            uint256 lastSecondsPerLiquidityInside = secondsPerLiquidityInsideDeposit[poolId][positionKey][rewardPeriod]
                == 0 && rewardPeriod > 0
                ? secondsPerLiquidityInsideDeposit[poolId][positionKey][rewardPeriod - 1]
                : secondsPerLiquidityInsideDeposit[poolId][positionKey][rewardPeriod];
            console.log("secondsPerLiquidityInside", secondsPerLiquidityInside);
            console.log("lastSecondsPerLiquidityInside", lastSecondsPerLiquidityInside);

            // Only calculate rewards if this isn't the first deposit
            if (secondsPerLiquidityInside > 0) {
                uint256 totalSecondsPerLiquidity = secondsPerLiquidityInside - lastSecondsPerLiquidityInside;

                // Calculate rewards based on the position's liquidity before the modification
                if (positionLiquidity > 0) {
                    uint256 rewards =
                        calculateRewards(totalSecondsPerLiquidity, uint256(positionLiquidity), poolId, rewardPeriod);
                    accumulatedRewards[sender] += rewards;
                }
            }
            //  Update the stored secondsPerLiquidityInside for future calculations
            secondsPerLiquidityInsideDeposit[poolId][positionKey][rewardPeriod] = secondsPerLiquidityInside;
        }
        lastUpdateUserRewardPeriod[poolId][positionKey] = currentRewardPeriod[poolId];
    }

    function calculateSecondsPerLiquidityInside(PoolId poolId, int24 tickLower, int24 tickUpper, uint256 rewardPeriod)
        public
        view
        returns (uint256)
    {
        uint256 secondsPerLiquidityBelow;
        uint256 secondsPerLiquidityAbove;

        secondsPerLiquidityBelow = secondsPerLiquidityOutside[poolId][tickLower][rewardPeriod];

        secondsPerLiquidityAbove =
            secondsPerLiquidity[poolId][rewardPeriod] - secondsPerLiquidityOutside[poolId][tickUpper][rewardPeriod];
        console.log("secondsPerLiquidity", secondsPerLiquidity[poolId][rewardPeriod]);
        console.log(
            "secondsPerLiquidityOutside lowerterick", secondsPerLiquidityOutside[poolId][tickLower][rewardPeriod]
        );
        console.log("secondsPerLiquidityOutside uppterick", secondsPerLiquidityOutside[poolId][tickUpper][rewardPeriod]);
        console.log("secondsPerLiquidityBelow", secondsPerLiquidityBelow);
        console.log("secondsPerLiquidityAbove", secondsPerLiquidityAbove);

        return secondsPerLiquidity[poolId][rewardPeriod] - secondsPerLiquidityBelow - secondsPerLiquidityAbove;
    }

    function calculateRewards(uint256 totalSecondsPerLiquidity, uint256 liquidity, PoolId poolId, uint256 rewardPeriod)
        internal
        view
        returns (uint256)
    {
        // Adjust reward calculation to properly account for time and liquidity
        return (totalSecondsPerLiquidity * liquidity * rewardRate[poolId][rewardPeriod]);
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
