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
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
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

    // function test_RewardAccumulation() public {
    //     // Simulate adding liquidity
    //     IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
    //         tickLower: 0,
    //         tickUpper: 100,
    //         liquidityDelta: 1000e18,
    //         salt: bytes32(0)
    //     });

    //     hook.afterAddLiquidity(alice, key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

    //     // Simulate time passing and price movement
    //     vm.warp(1000); // 1000 seconds passed
    //     poolManager.setSlot0Data(key, 0, 50, 0, 0); // Price moves

    //     // Remove liquidity and check rewards
    //     vm.warp(3000); // Another 1000 seconds
    //     hook.afterRemoveLiquidity(alice, poolKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

    //     bytes32 positionKey = keccak256(abi.encode(alice, int24(0), int24(100), bytes32(0)));
    //     uint256 rewards = hook.accumulatedRewards(positionKey);
    //     assertGt(rewards, 0, "Should have accumulated rewards");
    // }
}
