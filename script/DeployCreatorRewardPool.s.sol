// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CreatorRewardPoolFactory} from "../src/reward-pool/CreatorRewardPoolFactory.sol";
import {CreatorRewardPool} from "../src/reward-pool/CreatorRewardPool.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployCreatorRewardPool
/// @notice Script to deploy the creator-specific reward pool factory to production
/// @dev Deploys factory for creator reward pools with custom allocations and protocol fees
contract DeployCreatorRewardPool is Script {
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    
    CreatorRewardPoolFactory public factory;
    uint256 public deployerKey;
    address public deployer;
    address public protocolFeeRecipient;

    function setUp() public {
        if (block.chainid == 31337) {
            deployerKey = DEFAULT_ANVIL_PRIVATE_KEY;
            deployer = vm.addr(deployerKey);
            // For anvil/local testing, use deployer as fee recipient
            protocolFeeRecipient = deployer;
        } else {
            string memory pkString = vm.envString("PRIVATE_KEY");
            deployerKey = vm.parseUint(pkString);
            deployer = vm.addr(deployerKey);
            
            // Try to get protocol fee recipient from environment, fallback to deployer
            try vm.envAddress("PROTOCOL_FEE_RECIPIENT") returns (address feeRecipient) {
                protocolFeeRecipient = feeRecipient;
            } catch {
                console.log("PROTOCOL_FEE_RECIPIENT not set, using deployer as fee recipient");
                protocolFeeRecipient = deployer;
            }
        }
    }

    function run() public {
        vm.startBroadcast(deployerKey);

        console.log("=== DEPLOYING CREATOR REWARD POOL FACTORY ===");
        console.log("Deployer/Admin:", deployer);
        console.log("Protocol Fee Recipient:", protocolFeeRecipient);
        console.log("Chain ID:", block.chainid);

        // Deploy CreatorRewardPool implementation first
        CreatorRewardPool creatorRewardPoolImpl = new CreatorRewardPool();
        console.log(
            "CreatorRewardPool implementation deployed at:",
            address(creatorRewardPoolImpl)
        );

        // Deploy factory implementation
        CreatorRewardPoolFactory implementation = new CreatorRewardPoolFactory();
        console.log(
            "CreatorRewardPoolFactory implementation deployed at:",
            address(implementation)
        );

        // Deploy ERC1967Proxy for upgradeable pattern
        bytes memory initData = abi.encodeWithSelector(
            CreatorRewardPoolFactory.initialize.selector,
            deployer,
            address(creatorRewardPoolImpl),
            protocolFeeRecipient
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        factory = CreatorRewardPoolFactory(address(proxy));
        console.log("CreatorRewardPoolFactory proxy deployed at:", address(factory));
        console.log("Factory initialized with admin:", deployer);
        console.log("Default protocol fee rate:", factory.defaultProtocolFeeRate(), "basis points (1% = 100)");

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Chain ID:", block.chainid);
        console.log("CreatorRewardPoolFactory (Proxy):", address(factory));
        console.log(
            "CreatorRewardPoolFactory (Implementation):",
            address(implementation)
        );
        console.log("CreatorRewardPool (Implementation):", address(creatorRewardPoolImpl));
        console.log(
            "CreatorRewardPool implementation in factory:",
            factory.implementation()
        );
        console.log("Factory Admin:", deployer);
        console.log("Protocol Fee Recipient:", factory.protocolFeeRecipient());
        console.log("Default Protocol Fee Rate:", factory.defaultProtocolFeeRate(), "basis points");
        
        console.log("\n=== USAGE INSTRUCTIONS ===");
        console.log("1. Create creator pools via factory.createCreatorRewardPool(creator, name, description)");
        console.log("2. Add users with custom allocations via factory.addUser(creator, user, allocation)");
        console.log("3. Fund pools with creator coins (ERC20 or ETH)");
        console.log("4. Take snapshot via factory.takeSnapshot(creator, tokenAddresses)");
        console.log("5. Activate pool via factory.activateCreatorPool(creator)");
        console.log("6. Users can then claim rewards with 1% protocol fee automatically deducted");
        
        console.log("\n=== PROTOCOL FEE INFO ===");
        console.log("- Default fee rate: 1% (100 basis points)");
        console.log("- Fee is deducted from each claim automatically");
        console.log("- Users receive 99% of their allocation, protocol receives 1%");
        console.log("- Fee recipient can be updated by admin");
    }

    /// @notice Helper function to verify deployment
    /// @dev Can be called after deployment to verify everything is set up correctly
    function verify() public view {
        require(address(factory) != address(0), "Factory not deployed");
        require(factory.implementation() != address(0), "Implementation not set");
        require(factory.protocolFeeRecipient() != address(0), "Fee recipient not set");
        require(factory.defaultProtocolFeeRate() > 0, "Fee rate not set");
        
        console.log("Deployment verification passed");
        console.log("Factory address:", address(factory));
        console.log("Implementation address:", factory.implementation());
        console.log("Protocol fee recipient:", factory.protocolFeeRecipient());
        console.log("Default protocol fee rate:", factory.defaultProtocolFeeRate());
    }
} 