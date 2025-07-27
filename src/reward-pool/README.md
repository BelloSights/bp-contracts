# Creator Reward Pool System

The Creator Reward Pool system allows creators to set up custom reward pools for their supporters with their own tokens (creator coins). This system charges a 1% protocol fee on all claims and allows creators to set custom allocations for each user.

## Key Features

- **Custom Allocations**: Creators can set specific reward allocations for each user
- **Protocol Fees**: Automatic 1% fee deduction on all claims (user gets 99%, protocol gets 1%)
- **Multiple Token Support**: Supports both native ETH and ERC20 tokens
- **Batch Operations**: Gas-optimized batch operations for managing multiple users
- **EIP-712 Signatures**: Secure claiming with typed data signatures
- **Upgradeable**: Uses UUPS proxy pattern for future upgrades

## Architecture

```
CreatorRewardPoolFactory (UUPS Proxy)
├── Creates individual CreatorRewardPool instances for each creator
├── Manages protocol fee settings
└── Handles admin operations

CreatorRewardPool (Clone)
├── Stores custom user allocations (not XP-based)
├── Handles reward claiming with protocol fees
├── Supports snapshots for reward distribution
└── Validates signatures for secure claiming
```

## Usage Flow

### 1. Deploy the System
```bash
forge script script/DeployCreatorRewardPool.s.sol --broadcast
```

### 2. Create a Creator Pool
```solidity
// Admin creates a pool for a creator
address poolAddress = factory.createCreatorRewardPool(
    creatorAddress,
    "Creator's Reward Pool",
    "Pool for creator's supporters"
);
```

### 3. Add Users with Custom Allocations
```solidity
// Add individual user
factory.addUser(creatorAddress, userAddress, 1000); // 1000 allocation units

// Or batch add users
address[] memory users = [user1, user2, user3];
uint256[] memory allocations = [1000, 2000, 1500]; // Custom allocations
factory.batchAddUsers(creatorAddress, users, allocations);
```

### 4. Fund the Pool
```solidity
// For native ETH
payable(poolAddress).transfer(10 ether);

// For ERC20 tokens
IERC20(tokenAddress).transfer(poolAddress, amount);
```

### 5. Take Snapshot
```solidity
// For native ETH only
factory.takeNativeSnapshot(creatorAddress);

// For ERC20 tokens
address[] memory tokens = [tokenAddress1, tokenAddress2];
factory.takeSnapshot(creatorAddress, tokens);
```

### 6. Activate Pool
```solidity
factory.activateCreatorPool(creatorAddress);
```

### 7. Users Claim Rewards
```solidity
// User checks eligibility first
(bool canClaim, uint256 grossAmount, uint256 protocolFee) = 
    pool.checkClaimEligibility(user, tokenAddress, TokenType.ERC20);

// Generate signature (off-chain)
ClaimData memory claimData = ClaimData({
    user: userAddress,
    nonce: 1,
    tokenAddress: tokenAddress,
    tokenType: TokenType.ERC20
});

// User claims with signature
pool.claimReward(claimData, signature);
// User receives: grossAmount - protocolFee (99% of their allocation)
// Protocol receives: protocolFee (1% of their allocation)
```

## Protocol Fee Mechanics

- **Fee Rate**: Default 1% (100 basis points), configurable up to 10%
- **Fee Calculation**: `protocolFee = (userAllocation * feeRate) / 10000`
- **Fee Distribution**: 
  - User receives: `allocation - protocolFee`
  - Protocol receives: `protocolFee`
- **Fee Recipient**: Configurable address, typically the protocol treasury

## Key Differences from Regular RewardPool

| Feature | RewardPool | CreatorRewardPool |
|---------|------------|-------------------|
| Allocation Method | XP-based (percentage) | Custom fixed amounts |
| Fee Structure | No fees | 1% protocol fee |
| Creator Ownership | Admin-managed | Creator-specific pools |
| Use Case | General XP rewards | Creator coin rewards |

## Security Features

- **EIP-712 Signatures**: Prevents replay attacks and ensures user consent
- **Nonce Tracking**: Per-user nonce system prevents signature reuse
- **Access Control**: Role-based permissions with admin controls
- **Reentrancy Protection**: Guards against reentrancy attacks
- **Allocation Validation**: Ensures allocations don't exceed available rewards

## Gas Optimization

- **Batch Operations**: Process multiple users in single transaction
- **Minimal Storage**: Efficient state variable packing
- **Clone Pattern**: Reduces deployment costs for individual pools
- **Unchecked Math**: Safe arithmetic optimizations where overflow is impossible

## Example Integration

```solidity
// Creator brings their coin to the platform
IERC20 creatorCoin = IERC20(0x...);

// Admin creates pool for creator
address poolAddress = factory.createCreatorRewardPool(
    creator,
    "CreatorCoin Rewards",
    "Reward pool for CreatorCoin holders"
);

// Creator funds the pool
creatorCoin.transfer(poolAddress, 100000e18); // 100k tokens

// Admin sets custom allocations based on engagement
factory.addUser(creator, topSupporter, 10000e18);   // 10k tokens
factory.addUser(creator, regularUser, 1000e18);     // 1k tokens

// Take snapshot and activate
address[] memory tokens = [address(creatorCoin)];
factory.takeSnapshot(creator, tokens);
factory.activateCreatorPool(creator);

// Users can now claim their allocations (minus 1% protocol fee)
```

## Events

The system emits comprehensive events for tracking:

- `CreatorPoolCreated`: When a new creator pool is deployed
- `UserAdded`: When users are added with allocations
- `RewardClaimed`: When users claim rewards (includes fee breakdown)
- `ProtocolFeeCollected`: When protocol fees are collected
- `SnapshotTaken`: When reward snapshots are captured

## Deployment Addresses

After deployment, update this section with the deployed contract addresses:

- **CreatorRewardPoolFactory**: `TBD`
- **CreatorRewardPool Implementation**: `TBD`
- **Protocol Fee Recipient**: `TBD` 