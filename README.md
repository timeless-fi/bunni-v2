# Bunni v2

Bunni v2 is a next-gen decentralized exchange with **shapeshifting liquidity**, the next breakthrough in AMM design after Uniswap v3's concentrated liquidity.

To learn more, see:
- [Bunni v2 whitepaper](https://github.com/Bunniapp/whitepaper/blob/main/bunni-v2.pdf)
- [Documentation](https://docs.bunni.xyz/)

## Installation

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install timeless-fi/bunni-v2
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

Note: This project only compiles using Solidity `0.8.25` (and not `0.8.26`), but Uniswap's v4-core repo only compiles using Solidity 0.8.26. To develop locally, change the Solidity version of `lib/v4-core/src/PoolManager.sol` to `0.8.25`.

### Dependencies

```
forge install
```

### Compilation

```
forge build
```

### Testing

```
forge test
```

### Contract deployment

Please create a `.env` file before deployment. An example can be found in `.env.example`.

#### Dryrun

```
forge script script/Deploy.s.sol -f [network]
```

### Live

```
forge script script/Deploy.s.sol -f [network] --verify --broadcast
```