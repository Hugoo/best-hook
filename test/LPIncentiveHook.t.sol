// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {LPIncentiveHook} from "../src/LPIncentiveHook.sol";

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
    address owner = address(0x4);

    uint256 constant rewardRate = 10e6;

    mapping(address => PoolModifyLiquidityTest) modifyLiquidityRouters;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
        rewardToken = deployMintAndApproveCurrency();

        // Calculate hook address based on permissions
        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // Deploy the hook at the correct address
        deployCodeTo("LPIncentiveHook.sol", abi.encode(manager, rewardToken, owner), hookAddress);
        hook = LPIncentiveHook(hookAddress);

        // Init Pool
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.setRewardRate(key.toId(), rewardRate);
        // Fund hook with reward tokens
        deal(Currency.unwrap(rewardToken), address(hook), 1000000 ether);

        // we deploy one modifyLiquidityRouter for each user
        modifyLiquidityRouters[alice] = new PoolModifyLiquidityTest(manager);
        modifyLiquidityRouters[bob] = new PoolModifyLiquidityTest(manager);
        modifyLiquidityRouters[charlie] = new PoolModifyLiquidityTest(manager);
    }

    function test_ProportionalRewardsToTime() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        // Create identical liquidity positions

        uint256 liquidity = 1000e18;
        int24 tickLower = -120;
        int24 tickUpper = 120;

        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Alice keeps position for 1000 seconds
        uint256 timeDiff = 1000;
        advanceTime(timeDiff);

        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // Bob adds liquidity
        addLiquidity(bob, liquidity, tickLower, tickUpper);

        // keeping it 2x in the contract
        advanceTime(timeDiff * 2);

        // Bob removes liquidity
        removeLiquidity(bob, liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Bob should have approximately twice the rewards as Alice since he stayed twice as long
        assertEq(bobRewards, aliceRewards * 2, "Bob should have twice the rewards of Alice");

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
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions with ticks that are multiples of 60
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        addLiquidity(alice, liquidity, tickLower, tickUpper);
        addLiquidity(bob, liquidity * 2, tickLower, tickUpper);

        advanceTime(1000);

        removeLiquidity(alice, liquidity, tickLower, tickUpper);
        removeLiquidity(bob, liquidity * 2, tickLower, tickUpper);

        // Get secondsperliquidityOutisde for both ticks
        uint256 aliceSecondsPerLiquidityOutsideLower = hook.secondsPerLiquidityOutside(key.toId(), tickLower, 1);
        uint256 aliceSecondsPerLiquidityOutsideUpper = hook.secondsPerLiquidityOutside(key.toId(), tickUpper, 1);
        // assert that they are greater than zero
        assertEq(
            aliceSecondsPerLiquidityOutsideLower, 0, "Alice's secondsPerLiquidityOutsideLower should be greater than 0"
        );
        assertEq(
            aliceSecondsPerLiquidityOutsideUpper,
            hook.secondsPerLiquidity(key.toId(), 1),
            "Alice's secondsPerLiquidityOutsideUpper should be greater than 0"
        );
        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        assertEq(bobRewards, aliceRewards * 2, "Bob should have twice the rewards of Alice");
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
            hook.lastUpdateTimeOfSecondsPerLiquidity(poolId, 1),
            block.timestamp,
            "Last update time should be set to current timestamp"
        );

        assertEq(hook.secondsPerLiquidity(poolId, 1), 0, "secondsPerLiquidity should be initialized");

        // Verify position-specific state
        assertEq(
            hook.secondsPerLiquidityInsideDeposit(poolId, positionKey, 1),
            hook.calculateSecondsPerLiquidityInside(poolId, params.tickLower, params.tickUpper, 1),
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
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        // Create liquidity position far above current price
        // Note: Pool is initialized at SQRT_PRICE_1_1 which corresponds to tick 0
        int24 tickLower = 3600; // Position way above current price
        int24 tickUpper = 3720;
        uint256 liquidity = 1000e18;

        addLiquidity(alice, liquidity, tickLower, tickUpper);

        advanceTime(1000);

        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // Check rewards - should be zero since position was never in range
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        assertEq(aliceRewards, 0, "Out of range position should not earn rewards");
    }

    function test_CloseLiquidityTickHalveTimeInAliceRange() public {
        //  Liquidity Distribution
        //          price
        //  -120 ---- 0 ---- 60 ---------- 240
        //
        //     ---------------                   <- Alice (1x liquidity)
        //                    ===============    <- Bob   (2x liquidity)

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions with ticks that are multiples of 60
        int24 tickLowerAlice = -120;
        int24 tickUpperAlice = 60;
        int24 tickLowerBob = tickUpperAlice;
        int24 tickUpperBob = 240;

        uint256 liquidity = 1000e18;

        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob);

        (, int24 startingTick,,) = manager.getSlot0(key.toId());
        assertGt(startingTick, tickLowerAlice, "Initial tick should be in Alice's range. Above her lower tick");
        assertLt(startingTick, tickUpperAlice, "Initial tick should be in Alice's range. Below her upper tick");

        uint256 timeDiff = 1000;

        advanceTime(timeDiff); // Spend timeDiff in Alice's range
        // Total time spent:
        // Alice:   1 x timeDiff
        // Bob:     0

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
        assertGt(endingTick, tickLowerBob, "Tick should be in Bob's range");

        advanceTime(timeDiff); // Spend timeDiff in Bob's range
        // Total time spent:
        // Alice:   1 x timeDiff
        // Bob:     1 x timeDiff

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Bob should have approximately twice the rewards as Alice.
        // Tick was:
        // - in Alice's range for timeDiff
        // - in Bob's range for timeDiff
        // Bob has twice the liquidity of Alice, so he should have twice the rewards.
        assertEq(bobRewards, aliceRewards, "Bob should have gotten the same rewards of Alice");

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_CloseLiquidityTickThreeQuartersTimeInAliceRange() public {
        //  Liquidity Distribution
        //          price
        //  -120 ---- 0 ---- 60 --------- 240
        //
        //     ---------------                   <- Alice (1x liquidity)
        //                    ===============    <- Bob   (2x liquidity)

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        int24 tickLowerAlice = -120;
        int24 tickUpperAlice = 60;
        int24 tickLowerBob = tickUpperAlice;
        int24 tickUpperBob = 240;

        uint256 liquidity = 1000e18;

        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob); // Bob adds twice the liquidity of Alice

        (, int24 startingTick,,) = manager.getSlot0(key.toId());
        assertGt(startingTick, tickLowerAlice, "Initial tick should be in Alice's range. Above her lower tick");
        assertLt(startingTick, tickUpperAlice, "Initial tick should be in Alice's range. Below her upper tick");

        uint256 timeDiff = 1000;

        advanceTime(timeDiff * 3 / 4); // Spend 75% of time in Alice's range
        // Total time spent:
        // Alice:   3/4 x timeDiff
        // Bob:     0

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
        assertGt(endingTick, tickLowerBob, "Tick should be in Bob's range");

        advanceTime(timeDiff * 1 / 4); // Spend remaining 25% of time in Bob's range
        // Total time spent:
        // Alice:   3/4 x timeDiff
        // Bob:     1/4 x timeDiff

        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Bob should have approximately 1/3 of the rewards of Alice
        assertEq(
            bobRewards * 3,
            aliceRewards,
            "Bob should have approximately twice the rewards of Alice for the same time period"
        );

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_ThreeRangeMovement() public {
        //  Liquidity Distribution
        //          price
        //  -120 ----- 0 ----- 60 ---------- 240 ---------- 420 ---------- 600
        //
        //                                    ------------------------------   <- Charlie (1x liquidity)
        //      ---------------                                                <- Alice (1x liquidity)
        //                     ---------------                                 <- Bob   (1x liquidity)

        // Create three adjacent liquidity ranges

        // Charlie adds liquidity for a whole range
        // 2 x 180 = 360 ticks wide
        int24 tickLowerCharlie = 240;
        int24 tickUpperCharlie = 600;

        // 180 ticks wide
        int24 tickLowerAlice = -120;
        int24 tickUpperAlice = 60;

        // 180 ticks wide
        int24 tickLowerBob = tickUpperAlice;
        int24 tickUpperBob = 240;

        require(tickUpperAlice <= tickUpperBob, "tickUpperAlice should be <= tickUpperBob");
        require(tickUpperBob <= tickUpperCharlie, "tickUpperBob should be <= tickUpperCharlie");

        uint256 liquidity = 1000e18;

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);
        deal(Currency.unwrap(token0), charlie, 100000 ether);
        deal(Currency.unwrap(token1), charlie, 100000 ether);

        // Approve tokens for routers and swap router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[charlie]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[charlie]), type(uint256).max);
        vm.stopPrank();

        addLiquidity(charlie, liquidity, tickLowerCharlie, tickUpperCharlie);
        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Get initial tick
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickLowerAlice, "Initial tick should be in Alice's range. Above her lower tick");
        assertLt(currentTick, tickUpperAlice, "Initial tick should be in Alice's range. Below her upper tick");

        uint256 timePerRange = 1000;

        advanceTime(timePerRange); // Wait in Alice's range
        // Total time spent:
        // Alice:   1 x timePerRange
        // Bob:     0
        // Charlie: 0

        // Move up, to Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 10 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're in Bob's range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickLowerBob, "Tick should be in Bob's range. Above his lower tick");
        assertLt(currentTick, tickUpperBob, "Tick should be in Bob's range. Below his upper tick");

        advanceTime(timePerRange); // Wait in Bob's range
        // Total time spent:
        // Alice:   1 x timePerRange
        // Bob:     1 x timePerRange
        // Charlie: 0

        // Move up, out of Bob's range
        vm.prank(bob);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 2 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're outside both Alice's and Bob's ranges
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickUpperBob, "Tick should be above Alice's and Bob's ranges. Above Bob's upper tick");

        advanceTime(timePerRange); // Wait outside of both ranges [in Charlie's range]
        // Total time spent:
        // Alice:   1 x timePerRange
        // Bob:     1 x timePerRange
        // Charlie: 1 x timePerRange

        // Move down, back to Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're back in Bob's range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickLowerBob, "Tick should be back in Bob's range. Above his lower tick");
        assertLt(currentTick, tickUpperBob, "Tick should be back in Bob's range. Below his upper tick");

        advanceTime(timePerRange); // Wait again in Bob's range
        // Total time spent:
        // Alice:   1 x timePerRange
        // Bob:     2 x timePerRange
        // Charlie: 1 x timePerRange

        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Get accumulated rewards for each user
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));
        uint256 charlieRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[charlie]));

        assertEq(bobRewards, aliceRewards * 2, "Bob should have twice the rewards of Alice");

        // Verify non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");

        assertEq(charlieRewards, 0, "Charlie should not have rewards because he didn't remove liquidity");
    }

    function test_MultiplePositionsFromSameUser() public {
        // Deal tokens to users (further reduced amounts)
        deal(Currency.unwrap(token0), alice, 1000 ether);
        deal(Currency.unwrap(token1), alice, 1000 ether);
        deal(Currency.unwrap(token0), bob, 1000 ether);
        deal(Currency.unwrap(token1), bob, 1000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 10e16;

        // Initial positions for Alice and Bob
        addLiquidity(bob, liquidity, tickLower, tickUpper);

        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait some time for rewards to accumulate
        uint256 timeDiff = 10000;
        advanceTime(timeDiff);

        // Alice adds second position with same amount
        addLiquidity(alice, 2 * liquidity, tickLower, tickUpper);

        // Wait more time
        advanceTime(timeDiff);

        // Remove all positions
        removeLiquidity(bob, liquidity, tickLower, tickUpper);
        removeLiquidity(alice, 3 * liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        assertEq(aliceRewards * 3, bobRewards * 5, "Alice should have 5/3 Bob's rewards");

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_MultipleDecreasingPositionsFromSameUser() public {
        // Deal tokens to users (further reduced amounts)
        deal(Currency.unwrap(token0), alice, 1000 ether);
        deal(Currency.unwrap(token1), alice, 1000 ether);
        deal(Currency.unwrap(token0), bob, 1000 ether);
        deal(Currency.unwrap(token1), bob, 1000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 4 * 9 * 10e2;

        // Initial positions for Alice and Bob
        addLiquidity(bob, liquidity, tickLower, tickUpper);

        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait some time for rewards to accumulate
        uint256 timeDiff = 10000;
        advanceTime(timeDiff);

        // Alice adds second position with same amount
        removeLiquidity(alice, liquidity * 2 / 3, tickLower, tickUpper);

        // Wait more time
        advanceTime(timeDiff);

        // Remove all positions
        removeLiquidity(bob, liquidity, tickLower, tickUpper);
        removeLiquidity(alice, liquidity / 3, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // we need to use approx, since there are some rounding errors
        assertApproxEqRel(
            bobRewards * 3, aliceRewards * 5, 0.01e12, "Bob should have approximately 5/3 the rewards of Alice"
        );

        // Both should have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");
    }

    function test_MultiplePoolsFromSameUser() public {
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        // Create a second pool with different fee tier
        (PoolKey memory key2,) = initPool(token0, token1, hook, 500, SQRT_PRICE_1_1);
        vm.prank(owner);
        uint256 secondTokenRewardRate = 2 * rewardRate;
        hook.setRewardRate(key2.toId(), secondTokenRewardRate);

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity1 = 1000e18;
        uint256 liquidity2 = 2000e18;

        // Add liquidity to both pools
        addLiquidity(alice, liquidity1, tickLower, tickUpper); // First pool (key)

        vm.prank(alice);
        modifyLiquidityRouters[alice].modifyLiquidity(
            key2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity2),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Wait some time for rewards to accumulate
        uint256 timeDiff = 1000;
        advanceTime(timeDiff);

        // Remove liquidity from both pools
        removeLiquidity(alice, liquidity1, tickLower, tickUpper); // First pool

        vm.prank(alice);
        modifyLiquidityRouters[alice].modifyLiquidity(
            key2,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity2),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));

        // Verify rewards are non-zero
        assertGt(aliceRewards, 0, "Alice should have rewards");

        // Verify secondsPerLiquidity is tracked separately for each pool
        assertEq(
            hook.secondsPerLiquidity(key.toId(), 1),
            (timeDiff * 1e36) / liquidity1,
            "Incorrect secondsPerLiquidity for pool 1"
        );
        assertEq(
            hook.secondsPerLiquidity(key2.toId(), 1),
            (timeDiff * 1e36) / liquidity2,
            "Incorrect secondsPerLiquidity for pool 2"
        );
        // Verify rewards are proportional to total liquidity provided across both pools
        assertApproxEqRel(
            aliceRewards,
            (liquidity1 * hook.secondsPerLiquidity(key.toId(), 1) * secondTokenRewardRate)
                + (liquidity2 * hook.secondsPerLiquidity(key2.toId(), 1) * rewardRate),
            0.01e18,
            "Total rewards should be proportional to total liquidity"
        );
    }

    function test_RewardRateChange() public {
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;
        uint256 initialRewardRate = rewardRate;
        uint256 newRewardRate = rewardRate * 2;
        uint256 timeDiff = 1000;

        // Add liquidity
        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait some time for rewards to accumulate at initial rate
        advanceTime(timeDiff);

        // Change reward rate
        vm.prank(owner);
        hook.setRewardRate(key.toId(), newRewardRate);

        // Wait some more time for rewards to accumulate at new rate
        advanceTime(timeDiff);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));

        // Calculate expected rewards
        // First period: liquidity * time * initialRewardRate
        // Second period: liquidity * time * newRewardRate
        // Each period's reward calculation needs to be adjusted for the secondsPerLiquidity calculation
        uint256 expectedRewardsFirstPeriod = timeDiff * 1e36 * initialRewardRate;
        uint256 expectedRewardsSecondPeriod = timeDiff * 1e36 * newRewardRate;
        uint256 expectedTotalRewards = expectedRewardsFirstPeriod + expectedRewardsSecondPeriod;

        // Verify rewards
        assertApproxEqRel(
            aliceRewards, expectedTotalRewards, 0.01e18, "Rewards should reflect both rate periods correctly"
        );

        // Verify the reward periods were tracked correctly
        assertEq(hook.currentRewardPeriod(key.toId()), 2, "Current reward period should be 2");
        assertEq(hook.rewardRate(key.toId(), 1), initialRewardRate, "Initial reward rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 2), newRewardRate, "New reward rate should be stored correctly");
    }

    function test_RewardRateChangeWithRangeMovement() public {
        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for router and swap router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        // Alice's position will have a narrower range
        int24 tickLowerAlice = -120;
        int24 tickUpperAlice = 120;

        // Bob's position will have a wider range to provide liquidity for price movement
        int24 tickLowerBob = -240;
        int24 tickUpperBob = 240;

        uint256 liquidity = 1000e18;
        uint256 initialRewardRate = rewardRate;
        uint256 newRewardRate = rewardRate * 2;
        uint256 timeDiff = 1000;

        // Add liquidity for both users
        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Wait some time for rewards to accumulate at initial rate
        advanceTime(timeDiff);

        // Change reward rate
        vm.prank(owner);
        hook.setRewardRate(key.toId(), newRewardRate);

        // Perform a large swap to move price outside of Alice's range but still within Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 13 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're outside Alice's range but still in Bob's range
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickUpperAlice, "Tick should be outside Alice's range");
        assertLt(currentTick, tickUpperBob, "Tick should be within Bob's range");

        // Wait while position is out of range for Alice - should not accumulate rewards for her
        advanceTime(timeDiff);

        // Move price back into Alice's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 13 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're back in Alice's range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickLowerAlice, "Tick should be back in Alice's range");
        assertLt(currentTick, tickUpperAlice, "Tick should be back in Alice's range");

        // Wait some more time for rewards to accumulate at new rate while in range
        advanceTime(timeDiff);

        // Remove liquidity for both users
        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Calculate expected rewards for Alice - only for periods when position was in range
        // First period: liquidity * time * initialRewardRate
        // Second period: 0 (out of range)
        // Third period: liquidity * time * newRewardRate
        uint256 expectedRewardsFirstPeriod = timeDiff * 1e36 / 2 * initialRewardRate;
        uint256 expectedRewardsThirdPeriod = timeDiff * 1e36 / 2 * newRewardRate;
        uint256 expectedTotalRewardsAlice = expectedRewardsFirstPeriod + expectedRewardsThirdPeriod;

        // Verify Alice's rewards - should only be for in-range periods
        assertApproxEqRel(
            aliceRewards,
            expectedTotalRewardsAlice,
            0.01e18,
            "Alice's rewards should reflect only in-range periods with correct rates"
        );

        // Bob should have rewards for all periods since he was always in range
        uint256 expectedTotalRewardsBob =
            expectedRewardsFirstPeriod + (timeDiff * 1e36 * newRewardRate) + expectedRewardsThirdPeriod;
        assertApproxEqRel(
            bobRewards, expectedTotalRewardsBob, 0.01e18, "Bob's rewards should reflect all periods with correct rates"
        );

        // Verify rewards are greater than zero
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");

        // Bob should have more rewards than Alice since he was in range for all periods
        assertGt(bobRewards, aliceRewards, "Bob should have more rewards than Alice");

        // Verify the reward rates were tracked correctly
        assertEq(hook.currentRewardPeriod(key.toId()), 2, "Current reward period should be 2");
        assertEq(hook.rewardRate(key.toId(), 1), initialRewardRate, "Initial reward rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 2), newRewardRate, "New reward rate should be stored correctly");
    }

    function test_DecreasingRewardRateAdjustments() public {
        // Setup initial high reward rate
        uint256 initialHighRate = rewardRate * 10; // 10x the default rate
        vm.prank(owner);
        hook.setRewardRate(key.toId(), initialHighRate);

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        // Alice and Bob add liquidity
        addLiquidity(alice, liquidity, tickLower, tickUpper);
        addLiquidity(bob, liquidity, tickLower, tickUpper);

        // Trading period with high reward rate
        uint256 timeDiff = 1000;
        advanceTime(timeDiff / 2);

        // Do a swap to simulate trading
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 1 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        advanceTime(timeDiff / 2);

        // First reward rate decrease (to 50% of initial)
        uint256 midRate = initialHighRate / 2;
        vm.prank(owner);
        hook.setRewardRate(key.toId(), midRate);

        // Store rewards accumulated so far
        uint256 aliceRewardsAfterFirstPeriod = (timeDiff / 2 * 1e36 * initialHighRate) / 2;
        uint256 bobRewardsAfterFirstPeriod = (timeDiff / 2 * 1e36 * initialHighRate) / 2;

        // More time passes with mid rate
        advanceTime(timeDiff);

        // Alice withdraws half her liquidity
        removeLiquidity(alice, liquidity / 2, tickLower, tickUpper);
        uint256 aliceRewardsAfterPartialWithdrawal = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));

        // Second reward rate decrease (to 25% of initial)
        uint256 finalRate = midRate / 2;
        vm.prank(owner);
        hook.setRewardRate(key.toId(), finalRate);

        // More time passes with final rate
        advanceTime(timeDiff);

        // Bob withdraws his full liquidity
        removeLiquidity(bob, liquidity, tickLower, tickUpper);
        uint256 bobFinalRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Alice withdraws her remaining liquidity
        removeLiquidity(alice, liquidity / 2, tickLower, tickUpper);
        uint256 aliceFinalRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));

        // Verify reward tracking
        assertEq(hook.currentRewardPeriod(key.toId()), 4, "Current reward period should be 3");
        assertEq(hook.rewardRate(key.toId(), 2), initialHighRate, "Initial high rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 3), midRate, "Middle rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 4), finalRate, "Final rate should be stored correctly");

        // Verify rewards increase at each step
        assertGt(aliceRewardsAfterFirstPeriod, 0, "Alice should have rewards after first period");
        assertGt(
            aliceRewardsAfterPartialWithdrawal,
            aliceRewardsAfterFirstPeriod,
            "Alice's rewards should increase after second period"
        );
        assertGt(
            aliceFinalRewards,
            aliceRewardsAfterPartialWithdrawal,
            "Alice's final rewards should be greater than after partial withdrawal"
        );

        // Verify reward rate impact
        uint256 aliceSecondPeriodRewards = aliceRewardsAfterPartialWithdrawal - aliceRewardsAfterFirstPeriod;
        uint256 aliceThirdPeriodRewards = aliceFinalRewards - aliceRewardsAfterPartialWithdrawal;

        // Second period had mid rate with full liquidity, third period had final rate with half liquidity
        // So if we normalize (divide third period by 1/3 for liquidity and multiply by 2 for rate difference),
        // they should be roughly equal
        // uint256 normalizedThirdPeriodRewards = aliceThirdPeriodRewards * 6; // Adjust for both 1/3 liquidity and quarter rate
        assertApproxEqRel(
            aliceSecondPeriodRewards,
            aliceThirdPeriodRewards * 6,
            0.05e18,
            "Normalized rewards should be approximately equal across periods"
        );

        // Bob maintained full liquidity throughout, so his rewards should follow rate ratios
        // uint256 expectedBobFinalPeriodRewards =
        // bobRewardsAfterFirstPeriod + (timeDiff * midRate) * 1e36 * 2 / 3 + (timeDiff * finalRate) * 1e36;
        assertApproxEqRel(
            bobFinalRewards,
            bobRewardsAfterFirstPeriod + (timeDiff * midRate) * 1e36 * 2 / 3 + (timeDiff * finalRate) * 1e36,
            0.1e18,
            "Bob's rewards should follow rate changes proportionally"
        );

        // Bob should have more total rewards than Alice since he maintained full liquidity
        assertGt(bobFinalRewards, aliceFinalRewards, "Bob should have more rewards than Alice");
    }

    function test_ZeroRewardRate() public {
        //  Liquidity Distribution
        //          price
        //  -120 ---- 0 ---- 60 ---------- 240
        //
        //     ---------------                   <- Alice (1x liquidity)
        //                    ===============    <- Bob   (2x liquidity)

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 200000 ether);
        deal(Currency.unwrap(token1), bob, 200000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Create test params for liquidity positions with ticks that are multiples of 60
        int24 tickLowerAlice = -120;
        int24 tickUpperAlice = 60;
        int24 tickLowerBob = tickUpperAlice;
        int24 tickUpperBob = 240;

        uint256 liquidity = 1000e18;

        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob);

        (, int24 startingTick,,) = manager.getSlot0(key.toId());
        assertGt(startingTick, tickLowerAlice, "Initial tick should be in Alice's range. Above her lower tick");
        assertLt(startingTick, tickUpperAlice, "Initial tick should be in Alice's range. Below her upper tick");

        uint256 timeDiff = 1000;

        advanceTime(timeDiff); // Spend timeDiff in Alice's range

        // Perform a large swap to cross ticks into Bob's range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 3.2 ether,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT // Swap as far as possible
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Get ending tick
        (, int24 endingTick,,) = manager.getSlot0(key.toId());

        // Verify tick was crossed
        assertNotEq(startingTick, endingTick, "Tick should have changed");
        assertGt(endingTick, tickLowerBob, "Tick should be in Bob's range");

        advanceTime(timeDiff); // Spend timeDiff in Bob's range

        // Set reward rate to zero
        vm.prank(owner);
        hook.setRewardRate(key.toId(), 0);

        // Wait some more time - this should not generate rewards
        advanceTime(timeDiff);

        // Perform swap back to Alice's range
        vm.prank(bob);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1.1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify we're back in Alice's range
        (, int24 finalTick,,) = manager.getSlot0(key.toId());
        assertGt(finalTick, tickLowerAlice, "Tick should be back in Alice's range");
        assertLt(finalTick, tickUpperAlice, "Tick should be back in Alice's range");

        // Wait more time with zero reward rate
        advanceTime(timeDiff);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity * 2, tickLowerBob, tickUpperBob);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Both should have non-zero rewards from before rate was set to zero
        assertGt(aliceRewards, 0, "Alice should have rewards from before rate was zero");
        assertGt(bobRewards, 0, "Bob should have rewards from before rate was zero");

        // Verify the reward periods
        assertEq(hook.currentRewardPeriod(key.toId()), 2, "Current reward period should be 2");
        assertEq(hook.rewardRate(key.toId(), 1), rewardRate, "Initial reward rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 2), 0, "Zero reward rate should be stored correctly");

        // Check that rewards are consistent with expected values
        // They only earned during first two periods, and not during the zero-rate periods

        // Time spent before rate went to zero:
        // Alice: timeDiff (in her range) + 0 (in Bob's range) = timeDiff
        // Bob: 0 (in Alice's range) + timeDiff (in his range) = timeDiff

        // Calculate expected rewards
        uint256 expectedAliceRewards = (timeDiff * 1e36) * rewardRate; // Alice should get rewards for first period
        uint256 expectedBobRewards = (timeDiff * 1e36) * rewardRate; // Bob should get rewards for second period

        assertApproxEqRel(aliceRewards, expectedAliceRewards, 0.01e18, "Alice's rewards should match expected amount");
        assertApproxEqRel(bobRewards, expectedBobRewards, 0.01e18, "Bob's rewards should match expected amount");
    }

    function test_OverlappingRangesWithPriceMovementAndRateChange() public {
        //  Liquidity Distribution
        //          price
        //  -240 --- -60 --- 0 --- 60 --- 240
        //
        //  =====================               <- Alice (-240 to 60)
        //              ===================     <- Bob   (-60 to 240)
        //              ===                     <- Overlap (-60 to 60)

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        // Setup position ranges
        int24 tickLowerAlice = -240;
        int24 tickUpperAlice = 60;
        int24 tickLowerBob = -60;
        int24 tickUpperBob = 240;

        uint256 liquidity = 1000e18;

        // Add liquidity
        addLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        addLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Verify initial price is at tick 0 (in both ranges)
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0, "Initial tick should be at 0");

        uint256 initialRewardRate = rewardRate;
        uint256 timeDiff = 1000;

        // Wait with price in both ranges
        advanceTime(timeDiff);

        // Perform swap to move price below -60 (in Alice's range only, out of Bob's range)
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, // Move price down
                amountSpecified: 10 ether,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify price is below -60 (in Alice's range only)
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertLt(currentTick, tickLowerBob, "Tick should be below Bob's lower tick");
        assertGt(currentTick, tickLowerAlice, "Tick should be above Alice's lower tick");

        // Wait with price only in Alice's range
        advanceTime(timeDiff);

        // Change reward rate
        uint256 newRewardRate = initialRewardRate * 2;
        vm.prank(owner);
        hook.setRewardRate(key.toId(), newRewardRate);

        // Wait a bit more with the new rate
        advanceTime(timeDiff / 2);

        // Move price back to the overlapping range
        vm.prank(alice);
        swapRouter.swap{gas: 10000000}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, // Move price up
                amountSpecified: 5 ether,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Verify price is in the overlapping range
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertGt(currentTick, tickLowerBob, "Tick should be above Bob's lower tick");
        assertLt(currentTick, tickUpperAlice, "Tick should be below Alice's upper tick");

        // Wait with price in both ranges at new rate
        advanceTime(timeDiff);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLowerAlice, tickUpperAlice);
        removeLiquidity(bob, liquidity, tickLowerBob, tickUpperBob);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        // Calculate expected rewards
        // Alice was in range for entire test duration:
        // - timeDiff with initialRewardRate
        // - timeDiff with only her in range
        // - timeDiff/2 with new rate but only her in range
        // - timeDiff with new rate and both in range

        // Bob was only in range for:
        // - timeDiff with initialRewardRate at the beginning
        // - timeDiff with newRewardRate at the end

        // Alice should have significantly more rewards than Bob
        assertGt(aliceRewards, bobRewards, "Alice should have more rewards than Bob");

        // Verify both have non-zero rewards
        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");

        // Verify reward periods were tracked correctly
        assertEq(hook.currentRewardPeriod(key.toId()), 2, "Current reward period should be 2");
        assertEq(hook.rewardRate(key.toId(), 1), initialRewardRate, "Initial reward rate should be stored correctly");
        assertEq(hook.rewardRate(key.toId(), 2), newRewardRate, "New reward rate should be stored correctly");

        // Calculate roughly what the reward ratio should be
        // In the first period, Alice and Bob were in range for the same amount of time -> Token split (1/2, 1/2) * 1
        // In the second period, Alice was in range for 1 timeDiff with the old rate -> Token split (1, 0) * 1
        // IN the 3rd period, Alice was in range for 1/2 timeDiff with the new rate -> Token split (1/2, 0) * 2
        // In the last period, Alice was in range for 1 timeDiff with the new rate, Bob was in range for 1 timeDiff with the new rate -. Token split (1, 1) * 2
        // Total token split (7/2, 3/2)
        assertApproxEqRel(
            aliceRewards * 3, bobRewards * 7, 0.1e18, "Alice should have approximately twice the rewards of Bob"
        );
    }

    function test_RedeemRewards() public {
        deal(Currency.unwrap(rewardToken), address(hook), 1e52);
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        // Create test params
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        // Add liquidity
        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait some time for rewards to accumulate
        advanceTime(1000);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        assertGt(aliceRewards, 0, "Alice should have rewards");

        // Record contract balance before redemption
        uint256 contractBalanceBefore = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(hook));
        uint256 aliceBalanceBefore =
            IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[alice]));

        // Claim rewards
        vm.prank(address(modifyLiquidityRouters[alice]));
        hook.redeemRewards();

        // Verify rewards were sent
        uint256 contractBalanceAfter = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(hook));
        uint256 aliceBalanceAfter =
            IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[alice]));

        assertEq(
            contractBalanceAfter,
            contractBalanceBefore - aliceRewards,
            "Contract balance should decrease by reward amount"
        );
        assertEq(aliceBalanceAfter, aliceBalanceBefore + aliceRewards, "Alice balance should increase by reward amount");

        // Verify rewards were reset to zero
        assertEq(
            hook.accumulatedRewards(address(modifyLiquidityRouters[alice])),
            0,
            "Accumulated rewards should be reset to zero"
        );
    }

    function test_RedeemRewardsFailsWhenNoRewards() public {
        // Attempt to claim when no rewards are available
        vm.prank(charlie);
        vm.expectRevert(LPIncentiveHook.NoRewardsAvailable.selector);
        hook.redeemRewards();
    }

    function test_RedeemRewardsFailsWithInsufficientBalance() public {
        deal(Currency.unwrap(rewardToken), address(hook), 1e39);

        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        // Create test params
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        // Add liquidity
        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait some time for rewards to accumulate
        advanceTime(1000);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        assertGt(aliceRewards, 0, "Alice should have rewards");

        // Drain contract of rewards
        deal(Currency.unwrap(rewardToken), address(hook), 0);

        // Attempt to claim rewards with insufficient contract balance
        vm.prank(address(modifyLiquidityRouters[alice]));
        vm.expectRevert(LPIncentiveHook.InsufficientRewardBalance.selector);
        hook.redeemRewards();
    }

    function test_MultipleUsersRedeemRewards() public {
        deal(Currency.unwrap(rewardToken), address(hook), 1e52);

        // Deal tokens to users
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);
        deal(Currency.unwrap(token0), bob, 100000 ether);
        deal(Currency.unwrap(token1), bob, 100000 ether);

        // Approve tokens for routers
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[bob]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        // Add liquidity for both users
        addLiquidity(alice, liquidity, tickLower, tickUpper);
        addLiquidity(bob, liquidity, tickLower, tickUpper);

        // Wait for rewards to accumulate
        advanceTime(1000);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLower, tickUpper);
        removeLiquidity(bob, liquidity, tickLower, tickUpper);

        // Get accumulated rewards
        uint256 aliceRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[alice]));
        uint256 bobRewards = hook.accumulatedRewards(address(modifyLiquidityRouters[bob]));

        assertGt(aliceRewards, 0, "Alice should have rewards");
        assertGt(bobRewards, 0, "Bob should have rewards");

        // Record balances before redemption
        uint256 contractBalanceBefore = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(hook));
        uint256 aliceBalanceBefore =
            IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[alice]));
        uint256 bobBalanceBefore = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[bob]));

        // Claim rewards
        vm.prank(address(modifyLiquidityRouters[alice]));
        hook.redeemRewards();

        vm.prank(address(modifyLiquidityRouters[bob]));
        hook.redeemRewards();

        // Verify rewards were sent
        uint256 contractBalanceAfter = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(hook));
        uint256 aliceBalanceAfter =
            IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[alice]));
        uint256 bobBalanceAfter = IERC20(Currency.unwrap(rewardToken)).balanceOf(address(modifyLiquidityRouters[bob]));

        assertEq(
            contractBalanceAfter,
            contractBalanceBefore - aliceRewards - bobRewards,
            "Contract balance should decrease by total rewards"
        );
        assertEq(aliceBalanceAfter, aliceBalanceBefore + aliceRewards, "Alice balance should increase by reward amount");
        assertEq(bobBalanceAfter, bobBalanceBefore + bobRewards, "Bob balance should increase by reward amount");

        // Verify rewards were reset to zero
        assertEq(
            hook.accumulatedRewards(address(modifyLiquidityRouters[alice])),
            0,
            "Alice accumulated rewards should be reset"
        );
        assertEq(
            hook.accumulatedRewards(address(modifyLiquidityRouters[bob])), 0, "Bob accumulated rewards should be reset"
        );
    }

    function test_RedeemRewardsTwice() public {
        deal(Currency.unwrap(rewardToken), address(hook), 1e50);
        // Deal tokens to alice
        deal(Currency.unwrap(token0), alice, 100000 ether);
        deal(Currency.unwrap(token1), alice, 100000 ether);

        // Approve tokens for router
        vm.startPrank(alice);
        IERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        IERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouters[alice]), type(uint256).max);
        vm.stopPrank();

        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 liquidity = 1000e18;

        // Add liquidity
        addLiquidity(alice, liquidity, tickLower, tickUpper);

        // Wait for rewards to accumulate
        advanceTime(1000);

        // Remove liquidity
        removeLiquidity(alice, liquidity, tickLower, tickUpper);

        // First redemption should succeed
        vm.prank(address(modifyLiquidityRouters[alice]));
        hook.redeemRewards();

        // Second redemption should fail with NoRewardsAvailable
        vm.prank(address(modifyLiquidityRouters[alice]));
        vm.expectRevert(LPIncentiveHook.NoRewardsAvailable.selector);
        hook.redeemRewards();
    }

    // -----------------------------
    //   internal helper functions
    // -----------------------------

    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    function addLiquidity(address user, uint256 liquidityToAdd, int24 tickLower, int24 tickUpper) internal {
        adjustLiquidity(user, int256(liquidityToAdd), tickLower, tickUpper);
    }

    function removeLiquidity(address user, uint256 liquidityToRemove, int24 tickLower, int24 tickUpper) internal {
        adjustLiquidity(user, -int256(liquidityToRemove), tickLower, tickUpper);
    }

    function adjustLiquidity(address user, int256 liquidityDelta, int24 tickLower, int24 tickUpper) internal {
        vm.prank(user);
        modifyLiquidityRouters[user].modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }
}
