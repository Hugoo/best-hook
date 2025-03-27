# Uniswap V4 Hook - Priority is all you need[^1]

[Uniswap V4](https://docs.uniswap.org/contracts/v4/overview) hook that boosts LPs fees.

This project is part of the [Uniswap Hook Incubator Cohort 4](https://atrium.academy/uniswap).

## 🤖 MEV Protection Hook

### Problem

Arbitrageurs and other MEV actors often submit transactions with unusually high priority to capture profitable opportunities like arbitrage. However, the value they extract typically bypasses the protocol and its LPs.

### Solution

This hook dynamically detects high-priority transactions and adjusts fees in real-time to capture a portion of that value, redistributing it back to the liquidity providers.

## 📑 Usage

This is a [Foundry](https://book.getfoundry.sh/) project.

### Build

```shell
forge build
```

### Test

```shell
forge test
```

## 👨‍💻 Team

- [@siows](https://github.com/siosw)
- [@Hugoo](https://github.com/Hugoo)

## 📚 Resources & Related projects

- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- [Priority is all you need by Dan Robinson & Dave White](https://www.paradigm.xyz/2024/06/priority-is-all-you-need)
- [Arrakis](https://arrakis.finance)
- Angstrom by [Sorella Labs](https://sorellalabs.xyz)

[^1]: https://youtu.be/EmkwyVe04kY?t=2026
