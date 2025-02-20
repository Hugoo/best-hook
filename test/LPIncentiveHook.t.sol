// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {LPIncentiveHook} from "../src/LPIncentiveHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract LPIncentiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
        using StateLibrary for IPoolManager;

    LPIncentiveHook hook;

    Currency token0;
    Currency token1;

    Currency rewardToken;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
        rewardToken = deployMintAndApproveCurrency();

        // Calculate hook address based on permissions
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG 
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // Deploy the hook at the correct address
        deployCodeTo("LPIncentiveHook.sol", abi.encode(manager, rewardToken), hookAddress);
        hook = LPIncentiveHook(hookAddress);

        // Init Pool
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Fund hook with reward tokens
        deal(Currency.unwrap(rewardToken), address(hook), 1000000 ether);
    }

    function test_ProportionalRewards() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions with ticks that are multiples of 60
        IPoolManager.ModifyLiquidityParams memory aliceParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        IPoolManager.ModifyLiquidityParams memory bobParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 2000e18, // Bob adds twice the liquidity
            salt: bytes32(0)
        });

        // Alice adds liquidity
        vm.startPrank(alice);
        modifyLiquidityRouter.modifyLiquidity(key, aliceParams, ZERO_BYTES);
        vm.stopPrank();

        // Bob adds liquidity
        vm.startPrank(bob);
        modifyLiquidityRouter.modifyLiquidity(key, bobParams, ZERO_BYTES);
        vm.stopPrank();

        // Simulate time passing (1000 seconds)
        vm.warp(block.timestamp + 1000);

        // Remove liquidity
        vm.startPrank(alice);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceParams.tickLower,
                tickUpper: aliceParams.tickUpper,
                liquidityDelta: -aliceParams.liquidityDelta,
                salt: aliceParams.salt
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(bob);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobParams.tickLower,
                tickUpper: bobParams.tickUpper,
                liquidityDelta: -bobParams.liquidityDelta,
                salt: bobParams.salt
            }),
            ZERO_BYTES
        );
        vm.stopPrank();


        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(alice);
        uint256 bobRewards = hook.accumulatedRewards(bob);

        // Bob should have approximately twice the rewards as Alice
        assertApproxEqRel(bobRewards, aliceRewards * 2, 0.01e18); // 1% tolerance
        
        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_LiquidityPositionSetup() public {
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Create test params
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        vm.stopPrank();

        // Get position key
        bytes32 positionKey = keccak256(abi.encodePacked(alice, params.tickLower, params.tickUpper, params.salt));
        PoolId poolId = key.toId();

        // Verify initial state
        assertEq(
            hook.lastUpdateTimeOfSecondsPerLiquidity(poolId),
            block.timestamp,
            "Last update time should be set to current timestamp"
        );

        assertEq(
            hook.secondsPerLiquidity(poolId),
            0,
            "secondsPerLiquidity should be initialized"
        );

        // Verify position-specific state
        assertEq(
            hook.secondsPerLiquidityInsideDeposit(poolId, positionKey),
            hook.calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper),
            "Initial secondsPerLiquidityInside should be set correctly"
        );

        // Verify tick-specific state for both lower and upper ticks
        assertTrue(
            hook.secondsPerLiquidityOutsideLastUpdate(poolId, params.tickLower) == 0 ||
            hook.secondsPerLiquidityOutsideLastUpdate(poolId, params.tickUpper) == 0,
            "At least one tick should have been updated"
        );

        // Verify initial rewards are zero
        assertEq(
            hook.accumulatedRewards(alice),
            0,
            "Initial rewards should be zero"
        );
    }

    function test_SecondsPerLiquidityUpdatesOnTickTrade() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Create liquidity position straddling current price
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        // Add liquidity
        vm.startPrank(alice);
        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        vm.stopPrank();

        PoolId poolId = key.toId();
        (, int24 startingTick,,) = manager.getSlot0(poolId);

        // Record initial seconds per liquidity
        uint256 initialSecondsPerLiquidity = hook.secondsPerLiquidity(poolId);
        uint256 initialOutsideLower = hook.secondsPerLiquidityOutside(poolId, params.tickLower);
        uint256 initialOutsideUpper = hook.secondsPerLiquidityOutside(poolId, params.tickUpper);

        // Warp time forward
        vm.warp(block.timestamp + 100);

        // Perform a large swap to cross ticks
        vm.startPrank(alice);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 0.01 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT // Swap as far as possible
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();

        // Get ending tick
        (, int24 endingTick,,) = manager.getSlot0(poolId);

        // Verify tick was crossed
        assertNotEq(startingTick, endingTick, "Tick should have changed");
        vm.warp(block.timestamp + 100);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0.5 ether,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // Swap as far as possible
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.stopPrank();

        // Verify seconds per liquidity was updated
        uint256 finalSecondsPerLiquidity = hook.secondsPerLiquidity(poolId);
        assertGt(
            finalSecondsPerLiquidity,
            initialSecondsPerLiquidity,
            "secondsPerLiquidity should have increased"
        );

        // Verify tick-specific updates
        uint256 finalOutsideLower = hook.secondsPerLiquidityOutside(poolId, params.tickLower);
        uint256 finalOutsideUpper = hook.secondsPerLiquidityOutside(poolId, params.tickUpper);

        assertTrue(
            finalOutsideLower != initialOutsideLower || finalOutsideUpper != initialOutsideUpper,
            "At least one tick's secondsPerLiquidityOutside should have updated"
        );
    }
}
