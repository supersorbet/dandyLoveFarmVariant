# DandyFarm Foundry Project

A modern, gas-optimized implementation of the DandyFarm staking system using Solady libraries.

## Overview

This project contains the optimized DandyV2 token and DandyFarmV2 contracts, built with Foundry and utilizing Solady's gas-efficient libraries.

## Getting Started

1. Clone the repository:
```sh
git clone https://github.com/yourusername/dandy-farm-foundry.git
cd dandy-farm-foundry
```

2. Install dependencies:
```sh
forge install
```

3. Build the project:
```sh
forge build
```

4. Run tests:
```sh
forge test
```

## Contract Architecture

- **DandyV2.sol**: The main token contract with anti-bot protection, fee distribution, and Uniswap integration.
- **DandyFarmV2.sol**: The staking contract that allows users to stake LP tokens and earn DandyV2 rewards.
- **Interfaces**: Contains IERC20 and IUniswapV2Router interfaces.

## Key Improvements

### DandyV2 Token

- **Gas Optimization**: Uses Solady's optimized ERC20 implementation, FixedPointMathLib, and unchecked math.
- **Enhanced Security**: Implements transfer cooldown, comprehensive blacklist system, and improved swap error handling.
- **New Features**: Added configurable cooldown periods and enhanced fee distributions.

### DandyFarmV2 Staking

- **Gas Optimization**: Uses Solady's ReentrancyGuard, SafeTransferLib, and optimized data structures.
- **Enhanced Security**: Adds anti-flash loan protection and comprehensive input validation.
- **New Features**: Dedicated harvest function and better reward calculations.

## Deployment

To deploy the contracts, use the following command:

```sh
forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
```

## License

This project is licensed under the MIT license.
