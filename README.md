<p align="center">
  <br>
  <a href="https://bp.fun" target="_blank">
    <img width="300" height="100" src="./assets/blueprint.png" alt="Blueprint Logo">
  </a>
  <br><br>
</p>

[![Twitter](https://img.shields.io/twitter/follow/bpdotfun?color=blue&style=flat-square)](https://twitter.com/bpdotfun)
[![LICENSE](https://img.shields.io/badge/license-Apache--2.0-blue?logo=apache)](./LICENSE)

# BP.FUN Contracts

This repository contains upgradeable smart contracts that power the Blueprint NFT ecosystem. The contracts include:

- **BlueprintERC1155Factory** – A factory contract for deploying and managing ERC1155 NFT collections, enabling NFT drops with configurable fees and royalties.
- **RewardPoolFactory** – A factory contract for deploying and managing XP-based reward pools with batch operations for efficient user management.

---

## Table of Contents

- [Overview](#overview)
- [Smart Contract Details](#smart-contract-details)
  - [BlueprintERC1155Factory](#blueprinterc1155factory)
  - [RewardPoolFactory](#rewardpoolfactory)
- [Setup and Installation](#setup-and-installation)
- [Deployment](#deployment)
- [Testing](#testing)
- [SDK](#sdk)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

Blueprint's smart contract suite enables NFT collection management and drop functionality. The contracts are built with upgradeability (UUPS pattern) and leverage OpenZeppelin's upgradeable libraries for security and reliability.

---

## Smart Contract Details

### BlueprintERC1155Factory

- **Purpose:**  
  Factory contract for deploying and managing BlueprintERC1155 collection clones with NFT drop functionality.
- **Key Features:**
  - Uses OpenZeppelin's Clones library for gas-efficient deployment.
  - Configurable fee structure for platform fees and creator royalties.
  - Admin controls for collection and drop management.
  - Supports creating and managing drops with start/end times.
  - Access control for admin and creator roles.
- **File:** [BlueprintERC1155Factory.sol](./src/nft/BlueprintERC1155Factory.sol)

### RewardPoolFactory

- **Purpose:**  
  Factory contract for deploying and managing XP-based reward pools with efficient batch operations for large-scale user management.
- **Key Features:**
  - Upgradeable factory pattern using UUPS proxy.
  - Batch operations for adding, updating, and penalizing users (optimized for 10k+ users).
  - XP-based reward system with pool activation controls.
  - Role-based access control for admins and signers.
  - Gas-optimized operations with ~72-77k gas per user in batch operations.
  - Comprehensive validation and atomic operation guarantees.
- **Files:**
  - [RewardPoolFactory.sol](./src/reward-pool/RewardPoolFactory.sol)
  - [RewardPool.sol](./src/reward-pool/RewardPool.sol)

---

## Setup and Installation

Ensure you have [Foundry](https://book.getfoundry.sh) installed and updated:

```bash
foundryup
```

## Install

```bash
make install
```

Build the contracts:

```bash
make build
```

---

## Deployment

The contracts are designed for upgradeability and can be deployed using Forge scripts.

### Deploy NFT Factory

```bash
make deploy_nft_factory ARGS="--network base_sepolia"
```

### Deploy RewardPool Factory

```bash
make deploy_reward_pool ARGS="--network base_sepolia"
```

### Deploy on Zero Network

For Zero Network deployments, you'll need the foundry-zksync fork:

```bash
make install-foundry-zksync
make deploy_nft_factory_zero ARGS="--network zero"
```

### Upgrade Contracts

```bash
# Upgrade NFT Factory
make upgrade_nft_factory ARGS="--network base_sepolia"

# Upgrade RewardPool Factory
make upgrade_reward_pool ARGS="--network base_sepolia"
```

### Verification

#### NFT Contracts

For ERC1155 implementation contracts:

```bash
make verify_erc1155_implementation_base_sepolia
```

For factory implementation contracts:

```bash
make verify_blueprint_factory_implementation_base_sepolia
```

#### RewardPool Contracts

Verify all RewardPool contracts (recommended):

```bash
# For Base Sepolia
make verify_reward_pool NETWORK=base_sepolia

# For Base Mainnet
make verify_reward_pool NETWORK=base
```

Verify individual RewardPool contracts:

```bash
# RewardPool implementation
make verify_reward_pool_impl NETWORK=base_sepolia

# RewardPoolFactory implementation
make verify_reward_pool_factory_impl NETWORK=base_sepolia

# RewardPoolFactory proxy (main contract)
make verify_reward_pool_proxy NETWORK=base_sepolia
```

#### Custom Contract Verification

For custom contract verification:

```bash
make verify_base_sepolia ADDRESS=0x... CONTRACT=src/nft/BlueprintERC1155.sol:BlueprintERC1155
make verify_base ADDRESS=0x... CONTRACT=src/reward-pool/RewardPool.sol:RewardPool
```

For local development with Anvil:

```bash
anvil
```

In a new terminal, run:

```bash
forge script script/Anvil.s.sol --rpc-url http://localhost:8545 --private-key <ANVIL_PRIVATE_KEY> --broadcast --via-ir
```

---

## Testing

Run the complete test suite with:

```bash
make test
```

Run RewardPool tests specifically:

```bash
make test-reward-pool
```

Or directly with Forge:

```bash
forge install
forge test

# Test specific contract
forge test --match-contract RewardPoolTest
```

---

## SDK

To generate the SDK ABIs, run the following commands:

```bash
jq '.abi' out/BlueprintERC1155Factory.sol/BlueprintERC1155Factory.json > sdk/abis/blueprintERC1155FactoryAbi.json
jq '.abi' out/BlueprintERC1155.sol/BlueprintERC1155.json > sdk/abis/blueprintERC1155Abi.json
```

## Troubleshooting

- **Foundry Installation Issues:**  
  If you encounter "Permission Denied" errors during `forge install`, ensure your GitHub SSH keys are correctly added. Refer to [GitHub SSH documentation](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).

- **Zero Network Deployments:**  
  For Zero Network deployments, ensure you have foundry-zksync installed via `make install-foundry-zksync`. This overrides the standard forge binary with ZKsync support.

- **Deployment Failures:**  
  Ensure that the correct flags and salt values are used (especially for CREATE2 deployments) and verify that your deployer address matches the expected CREATE2 proxy address if applicable.

---

## License

This repository is released under the [Apache 2.0 License](./LICENSE). Some files (such as tests and scripts) may be licensed under MIT.
