// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BlueprintERC1155FactoryZero} from "../src/nft/BlueprintERC1155FactoryZero.sol";
import {BlueprintERC1155Zero} from "../src/nft/BlueprintERC1155Zero.sol";

/**
 * @title DeployBlueprintNFTZero
 * @notice Deployment script for BlueprintERC1155FactoryZero and implementation on zkSync Era Zero
 * Uses direct deployment without upgradeable patterns for better compatibility
 */
contract DeployBlueprintNFTZero is Script {
    // Private key (for Anvil) used for deployments
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 public deployerKey;

    // Default configuration values
    address public BLUEPRINT_RECIPIENT;
    uint256 public FEE_BASIS_POINTS;
    uint256 public DEFAULT_MINT_FEE = 777000000000000; // 0.000777 ETH
    address public TREASURY;
    address public REWARD_POOL_RECIPIENT;
    uint256 public REWARD_POOL_BASIS_POINTS;
    address public ADMIN;
    address public CREATOR;
    uint256 public CREATOR_FEE_BPS;

    constructor() {
        // Load configuration from environment variables
        BLUEPRINT_RECIPIENT = vm.envAddress("BLUEPRINT_ADDRESS");
        FEE_BASIS_POINTS = vm.envUint("BLUEPRINT_BPS");
        TREASURY = vm.envAddress("TREASURY_ADDRESS");
        REWARD_POOL_RECIPIENT = vm.envAddress("REWARD_POOL_ADDRESS");
        REWARD_POOL_BASIS_POINTS = vm.envUint("REWARD_POOL_BPS");
        ADMIN = vm.envAddress("DEPLOYER_ADDRESS");
        CREATOR = vm.envAddress("CREATOR_ADDRESS");
        CREATOR_FEE_BPS = vm.envUint("CREATOR_BPS");
    }

    function run() external returns (address) {
        // Determine private key based on environment
        if (block.chainid == 31337) {
            deployerKey = DEFAULT_ANVIL_PRIVATE_KEY;
            console.log("Using Anvil private key for local deployment");
        } else {
            string memory pkString = vm.envString("PRIVATE_KEY");
            deployerKey = vm.parseUint(pkString);
            console.log("Using private key from environment for network deployment");
        }

        // Deploy the factory and implementation
        address factory = deployNFTFactory(vm.addr(deployerKey));
        console.log("Deployed BlueprintERC1155FactoryZero at:", factory);

        return factory;
    }

    function deployNFTFactory(address _admin) public returns (address) {
        console.log("Deploying BlueprintERC1155FactoryZero with admin:", _admin);
        console.log("Blueprint recipient:", BLUEPRINT_RECIPIENT);
        console.log("Fee basis points:", FEE_BASIS_POINTS);
        console.log("Default mint fee:", DEFAULT_MINT_FEE, "(0.000777 ETH)");
        console.log("Treasury address:", TREASURY);
        console.log("Reward pool recipient:", REWARD_POOL_RECIPIENT);
        console.log("Reward pool basis points:", REWARD_POOL_BASIS_POINTS);
        console.log("Creator address:", CREATOR);
        console.log("Creator fee basis points:", CREATOR_FEE_BPS);

        vm.startBroadcast(_admin);

        // Deploy implementation contract first
        BlueprintERC1155Zero implementation;
        {
            bytes32 implSalt = bytes32(block.timestamp);
            implementation = new BlueprintERC1155Zero{salt: implSalt}(
                "https://api.blueprint.xyz/v1/metadata/",
                "Blueprint",
                "BP",
                _admin,
                BLUEPRINT_RECIPIENT,
                FEE_BASIS_POINTS,
                CREATOR,
                CREATOR_FEE_BPS,
                REWARD_POOL_RECIPIENT,
                REWARD_POOL_BASIS_POINTS,
                TREASURY
            );
        }
        console.log("Deployed BlueprintERC1155Zero implementation at:", address(implementation));

        // Deploy factory with direct initialization
        BlueprintERC1155FactoryZero factory;
        {
            bytes32 factorySalt = bytes32(block.timestamp + 1); // Different salt for factory
            factory = new BlueprintERC1155FactoryZero{salt: factorySalt}(
                address(implementation),
                BLUEPRINT_RECIPIENT,
                FEE_BASIS_POINTS,
                DEFAULT_MINT_FEE,
                TREASURY,
                REWARD_POOL_RECIPIENT,
                REWARD_POOL_BASIS_POINTS,
                _admin
            );
        }

        console.log("Deployed BlueprintERC1155FactoryZero at:", address(factory));

        vm.stopBroadcast();

        return address(factory);
    }
}
