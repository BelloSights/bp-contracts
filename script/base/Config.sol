// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";


/// @notice Shared configuration between scripts
contract Config {
    /// @dev populated with default anvil addresses
    IERC20 constant token0 = IERC20(address(0x0165878A594ca255338adfa4d48449f69242Eb8F));
    IERC20 constant token1 = IERC20(address(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853));
}
