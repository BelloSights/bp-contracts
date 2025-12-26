// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/nft/BlueprintCrossBatchMinter.sol";
import "../src/nft/BlueprintERC1155Factory.sol";
import {ERC1967Proxy} from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBlueprintCrossBatchMinter is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get the factory address from environment or use a default
        address factoryAddress = vm.envOr("FACTORY_ADDRESS", address(0));
        require(
            factoryAddress != address(0),
            "Factory address must be provided"
        );

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the UUPS implementation
        BlueprintCrossBatchMinter implementation = new BlueprintCrossBatchMinter();

        // Prepare initializer calldata for proxy
        bytes memory initData = abi.encodeWithSelector(
            BlueprintCrossBatchMinter.initialize.selector,
            factoryAddress, // factory
            deployer // admin
        );

        // Deploy ERC1967 proxy pointing to implementation and initialize in constructor
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        BlueprintCrossBatchMinter minter = BlueprintCrossBatchMinter(
            address(proxy)
        );

        console.log(
            "Cross Batch Minter Implementation:",
            address(implementation)
        );
        console.log("Cross Batch Minter Proxy:", address(minter));
        console.log("Factory address used:", factoryAddress);
        console.log("Admin address:", deployer);

        // Sanity checks
        console.log("Initialized factory:", address(minter.factory()));

        vm.stopBroadcast();
    }
}
