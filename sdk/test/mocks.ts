import { parseEther } from "viem";
import { walletClient } from "../src/viem";

// Test configuration from .env
export const QUEST_ID = 3n;
export const TEST_TITLE = "Base Sepolia Quest";
export const TEST_COMMUNITIES = ["base-community"];
export const TEST_TAGS = ["DeFi", "Base"];

// Total funding amounts
export const TOTAL_NATIVE = parseEther("0.01");
export const TOTAL_ERC20 = parseEther("10");

// Per-user reward amounts
export const ERC20_TOKEN = "0x0000000000000000000000000000000000000000";
export const REWARD_NATIVE = parseEther("0.001");
export const REWARD_ERC20 = parseEther("10");
export const RAKE_BPS = 0n; // 0%

// Unique item ID for testing
export const TEST_ITEM_ID = 1001n;
export const TEST_ITEM_PRODUCT_TYPE = 0;
export const TEST_ITEM_NAME = "Blueprint T-Shirt";
export const TEST_ITEM_METADATA = "ipfs://item-metadata";
export const TEST_ITEM_PRICE = parseEther("0.05"); // Price in ETH
export const TEST_ITEM_SUPPLY = 100n;
export const TEST_PURCHASE_LIMIT = 2n;
export const CREATOR_ADDRESS = walletClient.account.address;
