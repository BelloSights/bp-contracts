import console from "console";
import dotenv from "dotenv";
import path from "path";
import { erc20Abi, parseEther } from "viem";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { StorefrontSDK } from "../src/storefrontSdk";
import {
  publicClient,
  storefrontContract,
  walletClient,
} from "../src/viem";
import {
  TEST_ITEM_ID,
  TEST_ITEM_PRICE,
  TEST_ITEM_PRODUCT_TYPE,
  TEST_ITEM_SUPPLY,
  TEST_PURCHASE_DATA,
} from "./mocks";

dotenv.config({
  path: path.resolve(__dirname, "../../.env"),
});

describe.skip("Storefront SDK", () => {
  let sdk: StorefrontSDK;

  beforeAll(async () => {
    sdk = new StorefrontSDK(publicClient, walletClient);

    // --- Blueprint Token Setup ---
    // Approve the storefront contract to spend Blueprint tokens on behalf of the user.
    const approvalTx = await walletClient.writeContract({
      address: "0x0000000000000000000000000000000000000000",
      abi: erc20Abi,
      functionName: "approve",
      args: [storefrontContract.address, parseEther("100")],
    });
    await publicClient.waitForTransactionReceipt({ hash: approvalTx });
    console.log("User approved storefront contract for Blueprint tokens");

    // --- List a New Item ---
    // Use "setItem" to list the item on-chain.
    const listTx = await sdk.setItem(
      TEST_ITEM_ID,
      TEST_ITEM_PRICE,
      TEST_ITEM_SUPPLY,
      TEST_ITEM_PRODUCT_TYPE,
      true
    );
    await publicClient.waitForTransactionReceipt({ hash: listTx });
    console.log("Item listed:", TEST_ITEM_ID);

    // Optionally update the item to ensure the latest settings
    const updateTx = await sdk.updateItem(
      TEST_ITEM_ID,
      TEST_ITEM_PRICE,
      TEST_ITEM_SUPPLY,
      true
    );
    await publicClient.waitForTransactionReceipt({ hash: updateTx });
    console.log("Item updated:", TEST_ITEM_ID);
  }, 60_000);

  describe("Item Lifecycle", () => {
    it("should retrieve listed item details", async () => {
      const details = await sdk.getItemDetails(TEST_ITEM_ID);
      console.log("Item details:", details);
      expect(details).toBeDefined();
      // Additional assertions can be added based on the returned structure.
    });

    it("should purchase an item with a valid signature", async () => {
      // Generate an EIP‑712 signature for the purchase data
      const signature = await sdk.generatePurchaseSignature(TEST_PURCHASE_DATA);
      // Since payment is in Blueprint tokens (an ERC‑20), no ETH override is needed.
      const purchaseTx = await sdk.purchaseItem(TEST_PURCHASE_DATA, signature);
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: purchaseTx,
      });
      console.log("Purchase tx receipt:", receipt);
      expect(receipt.status).toBe("success");
    });
  }, 60_000);

  afterAll(async () => {
    // Emergency withdraw: recover Blueprint tokens from the storefront contract.
    const withdrawTx = await sdk.emergencyWithdraw(
      "0x0000000000000000000000000000000000000000",
      parseEther("10")
    );
    const receipt = await publicClient.waitForTransactionReceipt({
      hash: withdrawTx,
    });
    console.log("Emergency withdraw receipt:", receipt);
    expect(receipt.status).toBe("success");
  }, 60_000);
}, 60_000);
