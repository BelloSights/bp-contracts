# ERC1155 Factory and Creator NFT Contracts

This directory contains upgradeable contracts for deploying and managing ERC1155 NFT collections with drop functionality.

## Overview

- **BlueprintERC1155Factory.sol**: Upgradeable factory contract that deploys and manages BlueprintERC1155 collections
- **BlueprintERC1155.sol**: Upgradeable implementation of ERC1155 with drop functionality, fee distribution, and metadata management

## Architecture

- Both contracts use the UUPS (Universal Upgradeable Proxy Standard) pattern
- The Factory has full control over all collections
- Creators have limited permissions (can only update start/end times)
- Collections are deployed as minimal clones for gas efficiency
- Token IDs automatically increment for new drops (starting at 0)
- Custom errors instead of string messages for better debugging and gas efficiency

## Key Features

### Factory Management

- Deploy new collections with minimal gas cost
- Control all aspects of collections through the factory
- Role-based access control for admin operations
- Upgradeable implementation for future enhancements

### Collection Management

- Create collections with custom metadata
- Configure split percentages and recipients
- Update collection metadata
- Assign limited control to creators

### Drop Management

- Create drops with auto-incrementing token IDs
- Set pricing, start/end times, and active status
- Update metadata per drop
- Creators can modify time windows only

### Minting & Fee Distribution

- Public minting with payment processing
- Admin-only minting without payment
- Automatic fee distribution to:
  - Blueprint recipient (platform fees)
  - Creator recipient (creator earnings)
  - Reward pool recipient (community incentives)
  - Treasury (remaining funds)

## Example Usage

### Deploying the Factory

```solidity
// Deploy implementation contract first
BlueprintERC1155 implementation = new BlueprintERC1155();

// Deploy factory proxy
ERC1155FactoryProxy factory = new ERC1155FactoryProxy(
    address(logic),
    abi.encodeWithSelector(
        BlueprintERC1155Factory.initialize.selector,
        implementation,
        0xBlueprintWallet,
        500, // 5% platform fee
        777000000000000, // 0.000777 ETH default mint fee
        0xTreasuryWallet,
        0xRewardPoolWallet,
        300, // 3% reward pool fee
        0xAdminWallet
    )
);
```

### Creating a Collection

```solidity
// Create a collection via the factory
BlueprintERC1155Factory factory = BlueprintERC1155Factory(factoryProxyAddress);
address collectionAddress = factory.createCollection(
    "ipfs://baseuri/",
    0xCreatorAddress, // gets creator role
    1000 // 10% creator split
);
```

### Creating and Managing Drops

```solidity
// Create a drop with auto-incrementing token ID
uint256 dropId = factory.createNewDrop(
    collectionAddress,
    111000000000000, // 0.000111 ETH in wei
    block.timestamp + 1 days, // start in 1 day
    block.timestamp + 30 days, // end in 30 days
    true // active
);
// dropId will be 0 for the first drop

// Create another drop, which will have token ID 1
uint256 secondDropId = factory.createNewDrop(
    collectionAddress,
    222000000000000,
    block.timestamp + 7 days,
    block.timestamp + 60 days,
    true
);
// secondDropId will be 1

// Update drop price
factory.updateDropPrice(
    collectionAddress,
    dropId, // token ID
    333000000000000 // 0.000333 ETH
);

// Creator can update times (limited permission)
BlueprintERC1155 collection = BlueprintERC1155(collectionAddress);
collection.updateDropTimes(
    dropId, // token ID
    block.timestamp + 2 days, // new start time
    block.timestamp + 60 days // new end time
);
```

### Minting Tokens

```solidity
// Public minting with payment (users call this directly on the collection)
collection.mint{value: 333000000000000}(
    msg.sender, // recipient
    dropId, // token ID
    5, // quantity
);

// Admin minting through factory (no payment required)
factory.adminMint(
    collectionAddress,
    0xRecipientAddress,
    dropId, // token ID
    10 // quantity
);
```

### Updating Collection Config

```solidity
// Update fee configuration via factory
factory.updateFeeConfig(
    collectionAddress,
    0xNewBlueprintRecipient,
    300, // 3% platform fee
    0xNewCreatorRecipient,
    1500, // 15% creator split
    0xNewRewardPoolRecipient,
    200, // 2% reward pool fee
    0xNewTreasuryAddress
);

// Update just the creator recipient
factory.updateCreatorRecipient(
    collectionAddress,
    0xNewCreatorRecipient
);

// Update just the reward pool recipient
factory.updateRewardPoolRecipient(
    collectionAddress,
    0xNewRewardPoolRecipient
);
```

### Configuring Token-Specific Fees

```solidity
// Set custom fees for a specific token
factory.updateTokenFeeConfig(
    collectionAddress,
    dropId,
    0xTokenBlueprintRecipient,
    250, // 2.5% platform fee for this token
    0xTokenCreatorRecipient,
    750, // 7.5% creator fee for this token
    0xTokenRewardPoolRecipient,
    150, // 1.5% reward pool fee for this token
    0xTokenTreasuryAddress
);

// Remove token-specific fee config (revert to collection default)
factory.removeTokenFeeConfig(
    collectionAddress,
    dropId
);
```

## Implementation Details

- Uses OpenZeppelin's upgradeable contracts and Clones library
- Role-based access control for different permission levels
- Fee distribution system with configurable percentages and recipients:
  - Platform fees (Blueprint)
  - Creator earnings
  - Reward pool for community incentives (NEW)
  - Treasury for remaining funds
- Time-based minting restrictions with both start and end times
- Auto-incrementing token IDs for sequential drops
- Custom errors for better gas efficiency and ABI clarity:
  - BlueprintERC1155 errors include invalid times, insufficient payment, and transfer failures
  - BlueprintERC1155Factory errors include validation for deployed collections
- Event emission for all state changes
- Factory maintains control of all collections it deploys
