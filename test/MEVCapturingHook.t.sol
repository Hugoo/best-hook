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

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
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
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags);

        deployCodeTo("MEVCapturingHook.sol", abi.encode(manager, address(this)), hookAddress);
        hook = MEVCapturingHook(hookAddress);

        // Init Pool
        (key,) = initPool(token0, token1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

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

    function test_lowPrioritySwap() public {
        deal(Currency.unwrap(token0), alice.addr, 1 ether);

        assertEq(token0.balanceOf(alice.addr), 1 ether);
        assertEq(token1.balanceOf(alice.addr), 0);

        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 1 ether);

        vm.txGasPrice(hook.DEFAULT_PRIORITY_THRESHOLD() - 1);
        vm.fee(0);

        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice.addr), 0 ether);
        assertApproxEqAbs(token1.balanceOf(alice.addr), 1 ether, 0.1 ether);
    }

    function test_highPrioritySwap() public {
        deal(Currency.unwrap(token0), alice.addr, 1 ether);

        assertEq(token0.balanceOf(alice.addr), 1 ether);
        assertEq(token1.balanceOf(alice.addr), 0);

        vm.prank(alice.addr);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 1 ether);

        // with the default settings this should equal 100% fee
        vm.txGasPrice(1 ether);
        vm.fee(0);

        vm.prank(alice.addr);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(token0.balanceOf(alice.addr), 0 ether);
        assertEq(token1.balanceOf(alice.addr), 0 ether);
    }
}
