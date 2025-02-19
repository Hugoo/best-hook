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


contract LPIncentiveHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    LPIncentiveHook hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 rewardToken;
    PoolKey poolKey;
    PoolId poolId;

    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        deployFreshManagerAndRouters();

        // (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        rewardToken = new MockERC20("RewardToken", "RWD", 18);

        
        // Calculate hook address based on permissions
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);
        console.log(hookAddress);

        // Deploy the hook at the correct address
        deployCodeTo("LPIncentiveHook.sol", abi.encode(manager, rewardToken), hookAddress);
        hook = LPIncentiveHook(hookAddress);

        // Setup pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Fund hook with reward tokens
        rewardToken.mint(address(hook), 1000000e18);
    }

    function test_RewardAccumulation() public {
        // Setup initial conditions
        poolManager.setSlot0Data(poolId, 0, 100, 0, 0);
        vm.warp(1000); // Set initial timestamp

        // Simulate adding liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 100,
            liquidityDelta: 1000e18,
            salt: bytes32(0)
        });

        hook.afterAddLiquidity(alice, poolKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        // Simulate time passing and price movement
        vm.warp(2000); // 1000 seconds passed
        poolManager.setSlot0Data(poolId, 0, 50, 0, 0); // Price moves
        
        hook.beforeSwap(alice, poolKey, IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        }), "");

        hook.afterSwap(alice, poolKey, IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        }), BalanceDelta.wrap(0), "");

        // Remove liquidity and check rewards
        vm.warp(3000); // Another 1000 seconds
        hook.afterRemoveLiquidity(alice, poolKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        bytes32 positionKey = keccak256(abi.encode(alice, int24(0), int24(100), bytes32(0)));
        uint256 rewards = hook.accumulatedRewards(positionKey);
        assertGt(rewards, 0, "Should have accumulated rewards");
    }

    function test_RewardRedemption() public {
        // Setup a position with rewards
        bytes32 positionKey = keccak256(abi.encode(alice, int24(0), int24(100), bytes32(0)));
        uint256 rewardAmount = 100e18;
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(hook.accumulatedRewards.selector, positionKey),
            abi.encode(rewardAmount)
        );

        // Redeem rewards
        vm.prank(alice);
        uint256 balanceBefore = rewardToken.balanceOf(alice);
        hook.redeemRewards(positionKey);
        uint256 balanceAfter = rewardToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, rewardAmount, "Incorrect reward amount transferred");
    }

    function testFail_RedeemZeroRewards() public {
        bytes32 positionKey = keccak256(abi.encode(alice, int24(0), int24(100), bytes32(0)));
        vm.prank(alice);
        hook.redeemRewards(positionKey); // Should revert with NoRewardsAvailable
    }

    function testFail_RedeemInsufficientBalance() public {
        // Setup position with rewards larger than hook's balance
        bytes32 positionKey = keccak256(abi.encode(alice, int24(0), int24(100), bytes32(0)));
        uint256 largeRewardAmount = 1000000000e18;
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(hook.accumulatedRewards.selector, positionKey),
            abi.encode(largeRewardAmount)
        );

        vm.prank(alice);
        hook.redeemRewards(positionKey); // Should revert with InsufficientRewardBalance
    }
}
