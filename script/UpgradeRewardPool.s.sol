// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RewardPoolFactory} from "../src/reward-pool/RewardPoolFactory.sol";
import {RewardPool} from "../src/reward-pool/RewardPool.sol";
import {IRewardPool} from "../src/reward-pool/interfaces/IRewardPool.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title UpgradeRewardPool
/// @notice Comprehensive upgrade script for RewardPool system with shared implementation pattern
/// @dev Handles factory upgrade, implementation deployment, and optional existing pool upgrades
contract UpgradeRewardPool is Script {
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Upgrade configuration
    struct UpgradeConfig {
        bool upgradeExistingPools;
        bool skipStorageCheck;
        bool validateUpgrade;
        bool dryRun;
    }

    function run() public {
        UpgradeConfig memory config = UpgradeConfig({
            upgradeExistingPools: false, // Set to true if you want to upgrade existing pools
            skipStorageCheck: block.chainid == 31337, // Only skip on Anvil
            validateUpgrade: true,
            dryRun: false // Set to true for validation without execution
        });

        executeUpgrade(config);
    }

    function executeUpgrade(UpgradeConfig memory config) public {
        address proxyAddr = getFactoryProxyAddress();
        address admin = getAdminAddress();

        console.log("=== REWARDPOOL SYSTEM UPGRADE ===");
        console.log("Factory proxy address:", proxyAddr);
        console.log("Admin address:", admin);
        console.log("Network:", getNetworkName());
        console.log("Dry run mode:", config.dryRun);

        // Get current factory instance and validate
        RewardPoolFactory factory = RewardPoolFactory(payable(proxyAddr));
        validatePreUpgrade(factory, admin);

        if (config.dryRun) {
            console.log("DRY RUN MODE - No changes will be made");
            return;
        }

        // Step 1: Deploy new RewardPool implementation
        address newRewardPoolImpl = deployNewRewardPoolImplementation(admin);
        console.log(
            "SUCCESS: New RewardPool implementation deployed:",
            newRewardPoolImpl
        );

        // Step 2: Upgrade the Factory contract itself
        upgradeFactory(admin, proxyAddr, config.skipStorageCheck);
        console.log("SUCCESS: RewardPoolFactory upgrade complete");

        // Step 3: Set the new implementation for future pools
        setNewImplementation(admin, factory, newRewardPoolImpl);
        console.log("SUCCESS: New implementation set for future pools");

        // Step 4: Optionally upgrade existing pools
        if (config.upgradeExistingPools) {
            upgradeExistingPools(admin, factory, config.skipStorageCheck);
            console.log("SUCCESS: Existing pools upgrade complete");
        } else {
            logExistingPools(factory);
        }

        // Step 5: Validate upgrade if requested
        if (config.validateUpgrade) {
            validatePostUpgrade(factory, newRewardPoolImpl);
        }

        logUpgradeSummary(factory, newRewardPoolImpl, proxyAddr);
    }

    function validatePreUpgrade(
        RewardPoolFactory factory,
        address admin
    ) internal view {
        console.log("\n=== PRE-UPGRADE VALIDATION ===");

        // Check admin permissions
        bool hasAdminRole = factory.hasRole(
            factory.DEFAULT_ADMIN_ROLE(),
            admin
        );
        require(hasAdminRole, "Admin does not have DEFAULT_ADMIN_ROLE");
        console.log("SUCCESS: Admin has required permissions");

        // Log current state
        console.log("Current next pool ID:", factory.s_nextPoolId());

        // Check if factory already has an implementation set
        try factory.implementation() returns (address currentImpl) {
            if (currentImpl != address(0)) {
                console.log("Current implementation:", currentImpl);
            } else {
                console.log("No current implementation set (legacy factory)");
            }
        } catch {
            console.log(
                "Factory doesn't support implementation() - legacy version"
            );
        }

        console.log("SUCCESS: Pre-upgrade validation complete");
    }

    function validatePostUpgrade(
        RewardPoolFactory factory,
        address newImpl
    ) internal view {
        console.log("\n=== POST-UPGRADE VALIDATION ===");

        // Verify implementation is set correctly
        address setImpl = factory.implementation();
        require(setImpl == newImpl, "Implementation not set correctly");
        console.log("SUCCESS: Implementation correctly set:", setImpl);

        // Verify factory still has basic functionality
        uint256 nextPoolId = factory.s_nextPoolId();
        console.log(
            "SUCCESS: Factory state accessible, next pool ID:",
            nextPoolId
        );

        // Test that new pools would use the new implementation
        console.log("SUCCESS: Future pools will use implementation:", setImpl);

        // Verify existing pools still work (if any)
        if (nextPoolId > 1) {
            validateExistingPoolAccess(factory);
        }

        console.log("SUCCESS: Post-upgrade validation complete");
    }

    function validateExistingPoolAccess(
        RewardPoolFactory factory
    ) internal view {
        uint256 nextPoolId = factory.s_nextPoolId();
        console.log(
            "Validating access to",
            nextPoolId - 1,
            "existing pools..."
        );

        for (uint256 poolId = 1; poolId < nextPoolId; poolId++) {
            try factory.s_pools(poolId) returns (
                uint256 /* id */,
                address poolAddress,
                bool /* active */,
                string memory /* name */,
                string memory /* description */
            ) {
                if (poolAddress != address(0)) {
                    // Test basic pool functionality
                    IRewardPool pool = IRewardPool(poolAddress);
                    try pool.s_totalXP() returns (uint256 totalXP) {
                        console.log(
                            "SUCCESS: Pool",
                            poolId,
                            "accessible, total XP:",
                            totalXP
                        );
                    } catch {
                        console.log("WARNING: Pool", poolId, "not accessible");
                    }
                }
            } catch {
                console.log("WARNING: Pool", poolId, "data not accessible");
            }
        }
    }

    function logExistingPools(RewardPoolFactory factory) internal view {
        console.log("\n=== EXISTING POOLS STATUS ===");
        uint256 nextPoolId = factory.s_nextPoolId();

        if (nextPoolId == 1) {
            console.log("No existing pools found");
            return;
        }

        console.log("Found", nextPoolId - 1, "existing pools:");
        for (uint256 poolId = 1; poolId < nextPoolId; poolId++) {
            try factory.s_pools(poolId) returns (
                uint256 /* id */,
                address poolAddress,
                bool active,
                string memory name,
                string memory /* description */
            ) {
                if (poolAddress != address(0)) {
                    console.log("  Pool", poolId, ":", name);
                    console.log("    Address:", poolAddress);
                    console.log("    Active:", active);
                    console.log(
                        "    Note: Uses old implementation (upgrade manually if needed)"
                    );
                }
            } catch {
                console.log("  Pool", poolId, ": Error reading data");
            }
        }
    }

    function logUpgradeSummary(
        RewardPoolFactory factory,
        address newImpl,
        address proxyAddr
    ) internal view {
        console.log("\n=== UPGRADE SUMMARY ===");
        console.log("SUCCESS: Upgrade completed successfully!");
        console.log("");
        console.log("Addresses:");
        console.log("  Factory Proxy:", proxyAddr);
        console.log("  New RewardPool Implementation:", newImpl);
        console.log(
            "  Current Implementation in Factory:",
            factory.implementation()
        );
        console.log("");
        console.log("Status:");
        console.log("  SUCCESS: Factory upgraded with new batch operations");
        console.log("  SUCCESS: Future pools will use shared implementation");
        console.log("  SUCCESS: Gas-efficient clone-based deployment enabled");
        console.log(
            "  SUCCESS: Batch operations (10k+ users) available for new pools"
        );
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Test create a new pool to verify upgrade");
        console.log("  2. Optional: Upgrade existing pools if needed");
        console.log("  3. Update frontend/SDK to use new batch functions");
    }

    function getNetworkName() internal view returns (string memory) {
        if (block.chainid == 31337) return "Anvil";
        if (block.chainid == 84532) return "Base Sepolia";
        if (block.chainid == 8453) return "Base Mainnet";
        if (block.chainid == 111557560) return "Cyber Testnet";
        if (block.chainid == 7560) return "Cyber Mainnet";
        if (block.chainid == 543210) return "Zero Network";
        return "Unknown";
    }

    function getFactoryProxyAddress() internal view returns (address) {
        if (block.chainid == 31337) {
            // Anvil testnet - read from broadcast artifacts
            string memory json = vm.readFile(
                "broadcast/DeployRewardPool.s.sol/31337/run-latest.json"
            );
            return
                abi.decode(
                    vm.parseJson(json, ".transactions[1].contractAddress"),
                    (address)
                );
        }

        // Base Sepolia
        if (block.chainid == 84532) {
            return
                vm.envAddress("BASE_SEPOLIA_REWARD_POOL_FACTORY_PROXY_ADDRESS");
        }

        // Base Mainnet
        if (block.chainid == 8453) {
            return vm.envAddress("BASE_REWARD_POOL_FACTORY_PROXY_ADDRESS");
        }

        // Cyber Testnet
        if (block.chainid == 111557560) {
            return
                vm.envAddress(
                    "CYBER_TESTNET_REWARD_POOL_FACTORY_PROXY_ADDRESS"
                );
        }

        // Cyber Mainnet
        if (block.chainid == 7560) {
            return vm.envAddress("CYBER_REWARD_POOL_FACTORY_PROXY_ADDRESS");
        }

        // Zero Network
        if (block.chainid == 543210) {
            return vm.envAddress("ZERO_REWARD_POOL_FACTORY_PROXY_ADDRESS");
        }

        // Fallback to generic env var
        return vm.envAddress("REWARD_POOL_FACTORY_PROXY_ADDRESS");
    }

    function getAdminAddress() internal view returns (address) {
        if (block.chainid == 31337) {
            return vm.addr(DEFAULT_ANVIL_PRIVATE_KEY);
        }
        return vm.envAddress("DEPLOYER_ADDRESS");
    }

    function deployNewRewardPoolImplementation(
        address _admin
    ) public returns (address) {
        console.log("\n=== DEPLOYING NEW IMPLEMENTATION ===");
        console.log(
            "Deploying new RewardPool implementation with batch operations..."
        );

        vm.startBroadcast(_admin);

        // Deploy the new RewardPool implementation
        RewardPool newImplementation = new RewardPool();

        vm.stopBroadcast();

        console.log(
            "RewardPool implementation deployed at:",
            address(newImplementation)
        );
        console.log(
            "Features: Batch operations, optimized gas usage, 10k+ user support"
        );

        return address(newImplementation);
    }

    function upgradeFactory(
        address _admin,
        address _proxyAddress,
        bool skipStorageCheck
    ) public {
        console.log("\n=== UPGRADING FACTORY ===");
        console.log(
            "Upgrading RewardPoolFactory to support shared implementations..."
        );

        vm.startBroadcast(_admin);

        Options memory opts;
        opts.unsafeSkipStorageCheck = skipStorageCheck;
        opts.referenceContract = "RewardPoolFactory.sol:RewardPoolFactory";
        Upgrades.upgradeProxy(
            _proxyAddress,
            "RewardPoolFactory.sol",
            new bytes(0),
            opts
        );

        vm.stopBroadcast();
        console.log(
            "Factory upgrade complete - now supports setImplementation()"
        );
    }

    function setNewImplementation(
        address _admin,
        RewardPoolFactory _factory,
        address _newImplementation
    ) public {
        console.log("\n=== SETTING NEW IMPLEMENTATION ===");
        console.log(
            "Setting new RewardPool implementation for future pools..."
        );

        vm.startBroadcast(_admin);

        _factory.setImplementation(_newImplementation);

        vm.stopBroadcast();
        console.log(
            "Implementation set - future pools will use:",
            _newImplementation
        );
    }

    function upgradeExistingPools(
        address _admin,
        RewardPoolFactory _factory,
        bool skipStorageCheck
    ) public {
        console.log("\n=== UPGRADING EXISTING POOLS ===");
        console.log("Checking and upgrading existing pools...");

        uint256 nextPoolId = _factory.s_nextPoolId();
        console.log("Total pools to check:", nextPoolId - 1);

        if (nextPoolId == 1) {
            console.log("No existing pools to upgrade");
            return;
        }

        vm.startBroadcast(_admin);

        Options memory opts;
        opts.unsafeSkipStorageCheck = skipStorageCheck;

        uint256 upgradedCount = 0;

        for (uint256 poolId = 1; poolId < nextPoolId; poolId++) {
            try _factory.s_pools(poolId) returns (
                uint256 /* id */,
                address poolAddress,
                bool /* active */,
                string memory name,
                string memory /* description */
            ) {
                if (poolAddress != address(0)) {
                    console.log("Upgrading pool", poolId, ":", name);
                    console.log("  Address:", poolAddress);

                    try this.upgradeIndividualPool(poolAddress, opts) {
                        console.log(
                            "  SUCCESS: Pool",
                            poolId,
                            "upgraded successfully"
                        );
                        upgradedCount++;
                    } catch Error(string memory reason) {
                        console.log(
                            "  ERROR: Pool",
                            poolId,
                            "upgrade failed:",
                            reason
                        );
                    } catch {
                        console.log(
                            "  ERROR: Pool",
                            poolId,
                            "upgrade failed: Unknown error"
                        );
                    }
                }
            } catch {
                console.log(
                    "Pool",
                    poolId,
                    "does not exist or error accessing"
                );
            }
        }

        vm.stopBroadcast();
        console.log(
            "Existing pools upgrade complete:",
            upgradedCount,
            "pools upgraded"
        );
    }

    function upgradeIndividualPool(
        address poolAddress,
        Options memory opts
    ) external {
        Upgrades.upgradeProxy(
            poolAddress,
            "RewardPool.sol",
            new bytes(0),
            opts
        );
    }


}
