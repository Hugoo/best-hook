// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {LPIncentiveHook} from "../src/LPIncentiveHook.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract LPIncentiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    LPIncentiveHook hook;

    Currency token0;
    Currency token1;

    Currency rewardToken;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

    PoolModifyLiquidityTest modifyLiquidityRouterAlice;
    PoolModifyLiquidityTest modifyLiquidityRouterBob;
    PoolModifyLiquidityTest modifyLiquidityRouterCharlie;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
        rewardToken = deployMintAndApproveCurrency();

        // Calculate hook address based on permissions
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);

        // Deploy the hook at the correct address
        deployCodeTo("LPIncentiveHook.sol", abi.encode(manager, rewardToken), hookAddress);
        hook = LPIncentiveHook(hookAddress);

        // Init Pool
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Fund hook with reward tokens
        deal(Currency.unwrap(rewardToken), address(hook), 1000000 ether);

        // we deploy two modifyLiquidityRouters, one for each user
        modifyLiquidityRouterAlice = new PoolModifyLiquidityTest(manager);
        modifyLiquidityRouterBob = new PoolModifyLiquidityTest(manager);
        modifyLiquidityRouterCharlie = new PoolModifyLiquidityTest(manager);
    }

    function test_ProportionalRewardsToTime() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        vm.stopPrank();

        // Create identical liquidity positions
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        // Alice adds liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, params, ZERO_BYTES);

        // Alice keeps position for 1000 seconds
        uint256 timeDiff = 1000;
        advanceTime(timeDiff);

        // Alice removes liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: -params.liquidityDelta,
                salt: params.salt
            }),
            ZERO_BYTES
        );

        // Bob adds liquidity
        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(key, params, ZERO_BYTES);

        // keeping it 2x in the contract
        advanceTime(timeDiff * 2);

        // Bob removes liquidity
        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: -params.liquidityDelta,
                salt: params.salt
            }),
            ZERO_BYTES
        );

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouterBob));

        // Bob should have approximately twice the rewards as Alice since he stayed twice as long
        assertEq(bobRewards, aliceRewards * 2); // 1% tolerance

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_ProportionalRewardsToAmounts() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
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
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, aliceParams, ZERO_BYTES);

        // Bob adds liquidity
        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(key, bobParams, ZERO_BYTES);

        advanceTime(1000);

        // Remove liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceParams.tickLower,
                tickUpper: aliceParams.tickUpper,
                liquidityDelta: -aliceParams.liquidityDelta,
                salt: aliceParams.salt
            }),
            ZERO_BYTES
        );

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobParams.tickLower,
                tickUpper: bobParams.tickUpper,
                liquidityDelta: -bobParams.liquidityDelta,
                salt: bobParams.salt
            }),
            ZERO_BYTES
        );

        // Get secondsperliquidityOutisde for both ticks
        uint256 aliceSecondsPerLiquidityOutsideLower =
            hook.secondsPerLiquidityOutside(key.toId(), aliceParams.tickLower);
        uint256 aliceSecondsPerLiquidityOutsideUpper =
            hook.secondsPerLiquidityOutside(key.toId(), aliceParams.tickUpper);
        // assert that they are greater than zero
        assertEq(
            aliceSecondsPerLiquidityOutsideLower, 0, "Alice's secondsPerLiquidityOutsideLower should be greater than 0"
        );
        assertEq(
            aliceSecondsPerLiquidityOutsideUpper,
            hook.secondsPerLiquidity(key.toId()),
            "Alice's secondsPerLiquidityOutsideUpper should be greater than 0"
        );
        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouterBob));

        // Bob should have approximately twice the rewards as Alice
        assertEq(bobRewards, aliceRewards * 2);

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

        assertEq(hook.secondsPerLiquidity(poolId), 0, "secondsPerLiquidity should be initialized");

        // Verify position-specific state
        assertEq(
            hook.secondsPerLiquidityInsideDeposit(poolId, positionKey),
            hook.calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper),
            "Initial secondsPerLiquidityInside should be set correctly"
        );

        // Verify initial rewards are zero
        assertEq(hook.accumulatedRewards(alice), 0, "Initial rewards should be zero");
    }

    function test_NoRewardsForOutOfRangePosition() public {
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        vm.stopPrank();

        // Create liquidity position far above current price
        // Note: Pool is initialized at SQRT_PRICE_1_1 which corresponds to tick 0
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 3600, // Position way above current price
            tickUpper: 3720,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        // Add liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, params, ZERO_BYTES);

        advanceTime(1000);

        // Remove liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: -params.liquidityDelta,
                salt: params.salt
            }),
            ZERO_BYTES
        );

        // Check rewards - should be zero since position was never in range
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        assertEq(aliceRewards, 0, "Out of range position should not earn rewards");
    }

    function test_CloseLiquidityTickHalveTimeInAliceRange() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions with ticks that are multiples of 60
        IPoolManager.ModifyLiquidityParams memory aliceParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 60,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        IPoolManager.ModifyLiquidityParams memory bobParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 60,
            tickUpper: 240,
            liquidityDelta: 2000e18, // Bob adds twice the liquidity
            salt: bytes32(0)
        });

        // Alice adds liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, aliceParams, ZERO_BYTES);

        // Bob adds liquidity
        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(key, bobParams, ZERO_BYTES);

        (, int24 startingTick,,) = manager.getSlot0(key.toId());

        uint256 timeDiff = 1000;
        advanceTime(timeDiff);

        // Perform a large swap to cross ticks into Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 4 ether,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // Swap as far as possible
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Get ending tick
        (, int24 endingTick,,) = manager.getSlot0(key.toId());

        // Verify tick was crossed
        assertNotEq(startingTick, endingTick, "Tick should have changed");
        assertGt(endingTick, 60, "Tick not in bobs range");

        advanceTime(timeDiff);

        // Remove liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceParams.tickLower,
                tickUpper: aliceParams.tickUpper,
                liquidityDelta: -aliceParams.liquidityDelta,
                salt: aliceParams.salt
            }),
            ZERO_BYTES
        );

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobParams.tickLower,
                tickUpper: bobParams.tickUpper,
                liquidityDelta: -bobParams.liquidityDelta,
                salt: bobParams.salt
            }),
            ZERO_BYTES
        );

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouterBob));

        // Bob should have approximately twice the rewards as Alice
        assertEq(bobRewards, aliceRewards * 2);

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_CloseLiquidityTickThreeQuartersTimeInAliceRange() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions
        IPoolManager.ModifyLiquidityParams memory aliceParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 60,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        IPoolManager.ModifyLiquidityParams memory bobParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 60,
            tickUpper: 240,
            liquidityDelta: 2000e18, // Bob adds twice the liquidity
            salt: bytes32(0)
        });

        // Add liquidity for both users
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, aliceParams, ZERO_BYTES);

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(key, bobParams, ZERO_BYTES);

        (, int24 startingTick,,) = manager.getSlot0(key.toId());
        uint256 timeDiff = 1000;

        // Spend 75% of time in Alice's range
        advanceTime(timeDiff * 3 / 4);

        // Perform swap to cross into Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 4 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Get ending tick
        (, int24 endingTick,,) = manager.getSlot0(key.toId());

        // Verify tick was crossed
        assertNotEq(startingTick, endingTick, "Tick should have changed");
        assertGt(endingTick, 60, "Tick not in bobs range");

        // Spend remaining 25% of time in Bob's range
        advanceTime(timeDiff * 1 / 4);

        // Remove liquidity for both users
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceParams.tickLower,
                tickUpper: aliceParams.tickUpper,
                liquidityDelta: -aliceParams.liquidityDelta,
                salt: aliceParams.salt
            }),
            ZERO_BYTES
        );

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobParams.tickLower,
                tickUpper: bobParams.tickUpper,
                liquidityDelta: -bobParams.liquidityDelta,
                salt: bobParams.salt
            }),
            ZERO_BYTES
        );

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouterBob));

        // Bob should have approximately twice the rewards as Alice for the same time period
        // Since time is split 75/25, and Bob has 2x liquidity:
        // Alice's effective share: 0.75 * 1x = 0.75
        // Bob's effective share: 0.25 * 2x = 0.5
        // Bob's rewards should be about 2/3 of Alice's rewards
        assertApproxEqRel(bobRewards * 3, aliceRewards * 2, 0.01e18); // 1% tolerance

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_ThreeRangeMovement() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);
        deal(Currency.unwrap(token0), charlie, 100000 ether);
        deal(Currency.unwrap(token1), charlie, 100000 ether);

        // Approve tokens for routers and swap router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterAlice), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterBob), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouterCharlie), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouterCharlie), type(uint256).max);
        vm.stopPrank();

        // charlie adds liquidity for a whole range
        IPoolManager.ModifyLiquidityParams memory charlieParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 240,
            tickUpper: 600,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        vm.prank(charlie);
        modifyLiquidityRouterCharlie.modifyLiquidity(key, charlieParams, ZERO_BYTES);

        // Create three adjacent liquidity ranges
        IPoolManager.ModifyLiquidityParams memory aliceParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 60,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        IPoolManager.ModifyLiquidityParams memory bobParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 60,
            tickUpper: 240,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        // Add liquidity for each user in their respective ranges
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(key, aliceParams, ZERO_BYTES);

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(key, bobParams, ZERO_BYTES);

        // Get initial tick
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, aliceParams.tickLower, "Initial tick should be in Alice's range");
        assertLt(currentTick, aliceParams.tickUpper, "Initial tick should be in Alice's range");

        uint256 timePerRange = 1000;

        // Wait in Alice's range
        advanceTime(timePerRange);

        // Move to Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 10 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're in Bob's range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, bobParams.tickLower, "Tick should be in Bob's range");
        assertLt(currentTick, bobParams.tickUpper, "Tick should be in Bob's range");

        // Wait in Bob's range
        advanceTime(timePerRange);

        // Move out of Bob's range
        vm.prank(bob);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 2 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're outside both ranges
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, bobParams.tickUpper, "Tick should be above both ranges");

        // Wait outside of both ranges
        advanceTime(timePerRange);

        // Move back to Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're back in Bob's range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, bobParams.tickLower, "Tick should be back in Bob's range");
        assertLt(currentTick, bobParams.tickUpper, "Tick should be back in Bob's range");

        // Wait outside of both ranges
        advanceTime(timePerRange);

        // Remove all liquidity
        vm.prank(alice);
        modifyLiquidityRouterAlice.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: aliceParams.tickLower,
                tickUpper: aliceParams.tickUpper,
                liquidityDelta: -aliceParams.liquidityDelta,
                salt: aliceParams.salt
            }),
            ZERO_BYTES
        );

        vm.prank(bob);
        modifyLiquidityRouterBob.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bobParams.tickLower,
                tickUpper: bobParams.tickUpper,
                liquidityDelta: -bobParams.liquidityDelta,
                salt: bobParams.salt
            }),
            ZERO_BYTES
        );

        // Get accumulated rewards for each user
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouterAlice));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouterBob));

        // Verify non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");

        assertEq(aliceRewards * 2, bobRewards);
    }

    // internal helper functions

    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }
}
