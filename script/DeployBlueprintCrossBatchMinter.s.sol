// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/nft/BlueprintCrossBatchMinter.sol";
import "../src/nft/BlueprintERC1155Factory.sol";

contract DeployBlueprintCrossBatchMinter is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get the factory address from environment or use a default
        address factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));
        require(factoryAddress != address(0), "Factory address must be provided");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the implementation
        BlueprintCrossBatchMinter implementation = new BlueprintCrossBatchMinter();
        
        // Deploy the proxy
        bytes memory initData = abi.encodeWithSelector(
            BlueprintCrossBatchMinter.initialize.selector,
            factoryAddress,  // factory
            deployer        // admin
        );

        // For this example, we'll deploy a simple proxy
        // In production, you might want to use OpenZeppelin's TransparentUpgradeableProxy
        
        console.log("Cross Batch Minter Implementation deployed at:", address(implementation));
        console.log("Factory address used:", factoryAddress);
        console.log("Admin address:", deployer);

        vm.stopBroadcast();
    }
} 