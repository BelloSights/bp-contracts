// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BlueprintERC1155Factory} from "../src/nft/BlueprintERC1155Factory.sol";
import {BlueprintERC1155} from "../src/nft/BlueprintERC1155.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/**
 * @title DeployBlueprintNFT
 * @notice Deployment script for BlueprintERC1155Factory and implementation
 */
contract DeployBlueprintNFT is Script {
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

    constructor() {
        // Load configuration from environment variables
        BLUEPRINT_RECIPIENT = vm.envAddress("BLUEPRINT_ADDRESS");
        FEE_BASIS_POINTS = vm.envUint("BLUEPRINT_BPS");
        TREASURY = vm.envAddress("TREASURY_ADDRESS");
        REWARD_POOL_RECIPIENT = vm.envAddress("REWARD_POOL_ADDRESS");
        REWARD_POOL_BASIS_POINTS = vm.envUint("REWARD_POOL_BPS");
        ADMIN = vm.envAddress("DEPLOYER_ADDRESS");
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
        console.log("Deployed BlueprintERC1155Factory at:", factory);
        
        return factory;
    }

    function deployNFTFactory(address _admin) public returns (address) {
        console.log("Deploying BlueprintERC1155Factory with admin:", _admin);
        console.log("Blueprint recipient:", BLUEPRINT_RECIPIENT);
        console.log("Fee basis points:", FEE_BASIS_POINTS);
        console.log("Default mint fee:", DEFAULT_MINT_FEE, "(0.000777 ETH)");
        console.log("Treasury address:", TREASURY);
        console.log("Reward pool recipient:", REWARD_POOL_RECIPIENT);
        console.log("Reward pool basis points:", REWARD_POOL_BASIS_POINTS);
        
        vm.startBroadcast(_admin);
        
        // Deploy implementation contract first so it's available for the proxy
        BlueprintERC1155 implementation = new BlueprintERC1155();
        console.log("Deployed BlueprintERC1155 implementation at:", address(implementation));
        
        // Configure proxy options
        Options memory opts;
        opts.unsafeSkipStorageCheck = block.chainid == 31337; // Only skip on Anvil
        
        // Prepare initialization data for the factory
        bytes memory initData = abi.encodeCall(
            BlueprintERC1155Factory.initialize, 
            (
                address(implementation),
                BLUEPRINT_RECIPIENT,
                FEE_BASIS_POINTS,
                DEFAULT_MINT_FEE,
                TREASURY,
                REWARD_POOL_RECIPIENT,
                REWARD_POOL_BASIS_POINTS,
                _admin
            )
        );
        
        // Deploy the factory proxy using the contract name
        address proxy = Upgrades.deployUUPSProxy(
            "BlueprintERC1155Factory.sol",
            initData,
            opts
        );
        
        console.log("Deployed BlueprintERC1155Factory proxy at:", proxy);
        
        vm.stopBroadcast();
        
        return proxy;
    }
} 