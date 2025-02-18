// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {MEVCapturingHook} from "../src/MEVCapturingHook.sol";

contract MEVCapturingHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    Vm.Wallet alice;
    Vm.Wallet bob;

    MEVCapturingHook public hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        alice = vm.createWallet("alice");
        bob = vm.createWallet("bob");

        // Deploy our hook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG
        );
        address hookAddress = address(flags);

        deployCodeTo("MEVCapturingHook.sol", abi.encode(manager), hookAddress);
        hook = MEVCapturingHook(hookAddress);

        // Init Pool
        (key, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

    }

    // TODO: tests
    function test_sample() public {
        assertEq(true, true);
    }

    function test_addLiquidityAndSwap() public {
        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14

        console.log(token0.balanceOfSelf());
        console.log(token1.balanceOfSelf());

        deal(Currency.unwrap(token0), alice.addr, 1 ether);

        console.log(token0.balanceOf(alice.addr));

        vm.prank(alice.addr);
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            "" 
        );

        console.log("after");
        console.log(token0.balanceOf(alice.addr));
    }
}
