// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BlueprintERC1155Factory} from "../src/nft/BlueprintERC1155Factory.sol";
import {BlueprintERC1155} from "../src/nft/BlueprintERC1155.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeBlueprintNFT is Script {
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() public {
        address proxyAddr = getProxyAddress();
        address admin = getAdminAddress();
        console.log("Upgrading Blueprint NFT Factory at:", proxyAddr);
        console.log("Admin address:", admin);

        // Log the current implementation before upgrade
        BlueprintERC1155Factory factory = BlueprintERC1155Factory(payable(proxyAddr));
        console.log("Current factory implementation:", factory.implementation());

        // Always deploy a new implementation contract first
        address newImplementationAddr = deployNewImplementation(admin);
        console.log("Deployed new ERC1155 implementation at:", newImplementationAddr);

        // Then update the factory to use the new implementation
        updateFactoryImplementation(admin, proxyAddr, newImplementationAddr);

        // Finally upgrade the factory logic itself
        upgradeFactory(admin, proxyAddr);

        // Log the final implementation address
        console.log("Final factory implementation:", factory.implementation());
    }

    function getProxyAddress() internal view returns (address) {
        if (block.chainid == 31337) {
            return abi.decode(
                vm.parseJson(
                    vm.readFile("broadcast/DeployBlueprintNFT.s.sol/31337/run-latest.json"),
                    ".transactions[1].contractAddress" // Assumes the proxy was deployed in the second transaction
                ),
                (address)
            );
        }

        // Base Sepolia
        if (block.chainid == 84532) {
            return vm.envAddress("BASE_SEPOLIA_ERC1155_FACTORY_PROXY_ADDRESS");
        }

        // Base Mainnet
        if (block.chainid == 8453) {
            return vm.envAddress("BASE_ERC1155_FACTORY_PROXY_ADDRESS");
        }

        return vm.envAddress("ERC1155_FACTORY_PROXY_ADDRESS");
    }

    function getAdminAddress() internal view returns (address) {
        if (block.chainid == 31337) {
            return vm.addr(DEFAULT_ANVIL_PRIVATE_KEY);
        }
        return vm.envAddress("DEPLOYER_ADDRESS");
    }

    function deployNewImplementation(address _admin) public returns (address) {
        console.log("Deploying new BlueprintERC1155 implementation");
        vm.startBroadcast(_admin);
        // Deploy the new implementation
        BlueprintERC1155 newImplementation = new BlueprintERC1155();
        vm.stopBroadcast();
        return address(newImplementation);
    }

    function updateFactoryImplementation(
        address _admin,
        address _factoryAddr,
        address _newImplementation
    ) public {
        vm.startBroadcast(_admin);
        // Update the implementation in the factory
        BlueprintERC1155Factory factory = BlueprintERC1155Factory(payable(_factoryAddr));
        factory.setImplementation(_newImplementation);
        console.log("Factory implementation updated");
        vm.stopBroadcast();
    }

    function upgradeFactory(address _admin, address _proxyAddress) public {
        console.log("Upgrading BlueprintERC1155Factory logic");
        vm.startBroadcast(_admin);
        Options memory opts;
        opts.unsafeSkipStorageCheck = block.chainid == 31337; // Only skip on Anvil
        Upgrades.upgradeProxy(_proxyAddress, "BlueprintERC1155Factory.sol", new bytes(0), opts);
        console.log("Factory upgrade complete");
        vm.stopBroadcast();
    }
}
