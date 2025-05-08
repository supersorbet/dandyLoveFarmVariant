# DandyLoveFarm V2

MasterChef V2 style staking/farming contract and a yield token with some semi-superpower functions.

### DandyV2 Token

- Gas-optimized ERC20 token implementation using Solady
- Anti-bot protection via transaction limits and blacklisting
- Configurable fee system (marketing/treasury/burn)
- Transfer cooldown to prevent flash loan attacks
- Whale protection via wallet caps

### DandyFarmV2 

- MasterChef V2 style farming contract
- Multiple pools with allocation point weighting
- Harvest interval protection
- Configurable deposit fees
- Emergency withdrawal functionality
- Block-based reward distribution

## Implementation

All UPDATED contracts in the `contracts/V2` directory:
- Main token: `DandyV2.sol`
- Farming contract: `DandyFarmV2.sol`

## 💡

1. Get DandyV2
2. Provide liquidity on uni v2-like contracts to get LP tokens
3. Stake those LP tokens in the farm
4. colleccc

