// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
/// @notice Shared constants used in scripts
contract Constants {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev populated with default anvil addresses
    IERC20 constant BLUEPRINT_TOKEN = IERC20(address(0x0000000000000000000000000000000000000000));
}
