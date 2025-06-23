// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {Utils} from "./Utils.sol";

/**
 * String finder functions using Forge's string cheatcodes.
 * For internal use only.
 */
library StringFinder {
    /**
     * @dev Returns true if the `needle` is found within the `haystack`.
     */
    function contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);

        if (needleBytes.length == 0) {
            return true; // an empty needle is always found
        }

        if (needleBytes.length > haystackBytes.length) {
            return false;
        }

        // Loop through the haystack and check for a matching substring
        for (uint256 i = 0; i <= haystackBytes.length - needleBytes.length; i++) {
            bool matchFound = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) {
                return true;
            }
        }
        return false;
    }

    /**
     * Returns whether the subject string starts with the search string.
     */
    function startsWith(string memory subject, string memory search) internal pure returns (bool) {
        Vm vm = Vm(Utils.CHEATCODE_ADDRESS);
        uint256 index = vm.indexOf(subject, search);
        return index == 0;
    }

    /**
     * Returns whether the subject string ends with the search string.
     */
    function endsWith(string memory subject, string memory search) internal pure returns (bool) {
        Vm vm = Vm(Utils.CHEATCODE_ADDRESS);
        string[] memory tokens = vm.split(subject, search);
        return tokens.length > 1 && bytes(tokens[tokens.length - 1]).length == 0;
    }

    /**
     * Returns the number of non-overlapping occurrences of the search string in the subject string.
     */
    function count(string memory subject, string memory search) internal pure returns (uint256) {
        Vm vm = Vm(Utils.CHEATCODE_ADDRESS);
        string[] memory tokens = vm.split(subject, search);
        return tokens.length - 1;
    }
}
