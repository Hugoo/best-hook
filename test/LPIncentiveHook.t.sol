// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {LPIncentiveHook} from "../src/LPIncentiveHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
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

contract LPIncentiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    LPIncentiveHook hook;
    MockPoolManager poolManager;

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
}
