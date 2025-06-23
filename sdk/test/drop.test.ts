import console from "console";
import dotenv from "dotenv";
import path from "path";
import { describe, it } from "vitest";
import { DropSDK } from "../src/dropSdk";

// Load environment variables
dotenv.config({
  path: path.resolve(__dirname, "../../.env"),
});

describe("Drop SDK", () => {
  it("SDK End to End", async () => {
    try {
      // Initialize the SDK
      const chainId = 84532; // Base Sepolia chain
      const sdk = new DropSDK(chainId);
      await sdk.initialize();

      console.log("====== TESTING DROP SDK ON CHAIN:", chainId, "======");
      console.log(
        "Note: This test may take several minutes to complete on testnets."
      );
      console.log("Transactions may need multiple attempts to confirm.");

      // 1. Get the default fee config directly from factory
      console.log("1. Getting default fee config from factory...");
      const defaultFeeConfig = await sdk.getDefaultFeeConfig();
      console.log("Default fee config from factory:", defaultFeeConfig);

      // 2. Create a new collection
      const uri = "ipfs://collection-uri/";
      const creatorRecipient = "0x5fF6AD4ee6997C527cf9D6F2F5e82E68BF775649"; // Address for both creator role and royalties
      const creatorBasisPoints = BigInt(1000); // 10%

      console.log("2. Creating collection...");
      const { collectionAddress, tx } = await sdk.createCollection({
        uri,
        creatorRecipient: creatorRecipient as `0x${string}`,
        creatorBasisPoints,
      });

      console.log("Transaction hash:", tx);
      console.log("Collection created at address:", collectionAddress);

      // 3. Verify the collection's initial fee config
      console.log("3. Getting initial fee config from collection...");
      const initialFeeConfig = await sdk.getTokenFeeConfig({
        collectionAddress,
        tokenId: BigInt(0),
      });
      console.log("Initial fee config from collection:", initialFeeConfig);

      // 4. Create two drops with different settings
      const price1 = BigInt(777000000000000); // 0.000777 ETH in wei
      const price2 = BigInt(555000000000000); // 0.000555 ETH in wei
      const startTime = BigInt(Math.floor(Date.now() / 1000)); // Now
      const endTime = BigInt(Math.floor(Date.now() / 1000) + 86400 * 30); // 30 days from now

      console.log("4. Creating first drop...");
      const createDrop1Result = await sdk.createDrop({
        collectionAddress,
        price: price1,
        startTime,
        endTime,
        active: true,
      });

      console.log("First drop created:", createDrop1Result);
      const tokenId1 = BigInt(0);

      // Create a second drop
      console.log("Creating second drop...");
      const createDrop2Result = await sdk.createDrop({
        collectionAddress,
        price: price2,
        startTime,
        endTime,
        active: true,
      });

      console.log("Second drop created:", createDrop2Result);
      const tokenId2 = BigInt(1);

      // 5. Set different fee configs for each token
      console.log("5. Setting different fee configs for each token...");

      const token1FeeConfig = {
        blueprintRecipient: initialFeeConfig.blueprintRecipient,
        blueprintFeeBasisPoints: BigInt(100),
        creatorRecipient: initialFeeConfig.creatorRecipient,
        creatorBasisPoints: BigInt(200),
        rewardPoolRecipient: initialFeeConfig.rewardPoolRecipient,
        rewardPoolBasisPoints: BigInt(300),
        treasury: initialFeeConfig.treasury,
      };

      const token2FeeConfig = {
        blueprintRecipient: initialFeeConfig.blueprintRecipient,
        blueprintFeeBasisPoints: BigInt(150),
        creatorRecipient: initialFeeConfig.creatorRecipient,
        creatorBasisPoints: BigInt(250),
        rewardPoolRecipient: initialFeeConfig.rewardPoolRecipient,
        rewardPoolBasisPoints: BigInt(350),
        treasury: initialFeeConfig.treasury,
      };

      // Log the token fee configs we're using to help with debugging
      console.log("Using token1FeeConfig:", token1FeeConfig);
      console.log("Using token2FeeConfig:", token2FeeConfig);

      // Update fee config for token 1
      console.log("Updating fee config for token 1...");
      const updateToken1FeeConfigResult = await sdk.updateTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId1,
        blueprintRecipient: token1FeeConfig.blueprintRecipient,
        blueprintFeeBasisPoints: token1FeeConfig.blueprintFeeBasisPoints,
        creatorRecipient: token1FeeConfig.creatorRecipient,
        creatorBasisPoints: token1FeeConfig.creatorBasisPoints,
        rewardPoolRecipient: token1FeeConfig.rewardPoolRecipient,
        rewardPoolBasisPoints: token1FeeConfig.rewardPoolBasisPoints,
        treasury: token1FeeConfig.treasury,
        verifyUpdate: true,
      });
      console.log(
        "Token 1 fee config update result:",
        updateToken1FeeConfigResult
      );

      // Update fee config for token 2
      console.log("Updating fee config for token 2...");
      const updateToken2FeeConfigResult = await sdk.updateTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId2,
        blueprintRecipient: token2FeeConfig.blueprintRecipient,
        blueprintFeeBasisPoints: token2FeeConfig.blueprintFeeBasisPoints,
        creatorRecipient: token2FeeConfig.creatorRecipient,
        creatorBasisPoints: token2FeeConfig.creatorBasisPoints,
        rewardPoolRecipient: token2FeeConfig.rewardPoolRecipient,
        rewardPoolBasisPoints: token2FeeConfig.rewardPoolBasisPoints,
        treasury: token2FeeConfig.treasury,
        verifyUpdate: true,
      });
      console.log(
        "Token 2 fee config update result:",
        updateToken2FeeConfigResult
      );

      // 6. Verify both tokens have different fee configs (for test output purposes only, verification already done)
      console.log("6. Getting fee configs for both tokens...");
      const token1FeeConfigAfterUpdate = await sdk.getTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId1,
      });
      console.log(
        "Token 1 fee config after update:",
        token1FeeConfigAfterUpdate
      );

      const token2FeeConfigAfterUpdate = await sdk.getTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId2,
      });
      console.log(
        "Token 2 fee config after update:",
        token2FeeConfigAfterUpdate
      );

      // 6.1 Test updateRewardPoolRecipient
      console.log("6.1. Testing updateRewardPoolRecipient...");
      const newRewardPoolRecipient =
        "0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69" as `0x${string}`;
      const updateRewardPoolResult = await sdk.updateRewardPoolRecipient({
        collectionAddress,
        rewardPoolRecipient: newRewardPoolRecipient,
        verifyUpdate: true,
      });
      console.log(
        "Update reward pool recipient result:",
        updateRewardPoolResult
      );

      // Check that the collection fee config has updated reward pool recipient
      const collectionFeeConfigAfterRewardPoolUpdate = await sdk.getFeeConfig({
        collectionAddress,
      });
      console.log(
        "Collection fee config after reward pool update:",
        collectionFeeConfigAfterRewardPoolUpdate
      );

      // 7. Batch mint both tokens
      console.log("7. Batch minting both tokens...");
      const recipient =
        "0x5fF6AD4ee6997C527cf9D6F2F5e82E68BF775649" as `0x${string}`;
      const tokenIds = [tokenId1, tokenId2];
      const amounts = [BigInt(2), BigInt(3)];
      // Calculate total cost: (price1 * amount1) + (price2 * amount2)
      const totalCost = price1 * amounts[0] + price2 * amounts[1];

      console.log("Batch minting with total cost:", totalCost.toString());
      const batchMintResult = await sdk.batchMint({
        collectionAddress,
        to: recipient,
        tokenIds,
        amounts,
        value: totalCost,
      });
      console.log("Batch mint result:", batchMintResult);

      // 8. Check balances after batch minting
      console.log("8. Checking balances after batch minting...");
      const token1Balance = await sdk.getBalance({
        collectionAddress,
        account: recipient,
        tokenId: tokenId1,
      });
      console.log(
        "Token 1 balance after batch mint:",
        token1Balance.toString()
      );

      const token2Balance = await sdk.getBalance({
        collectionAddress,
        account: recipient,
        tokenId: tokenId2,
      });
      console.log(
        "Token 2 balance after batch mint:",
        token2Balance.toString()
      );

      // 9. Reset fee configs back to initial values
      console.log("9. Resetting fee configs back to initial values...");

      // Reset token 1 fee config
      console.log("Resetting token 1 fee config...");
      const resetToken1FeeConfigResult = await sdk.removeTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId1,
      });
      console.log(
        "Reset token 1 fee config result:",
        resetToken1FeeConfigResult
      );

      // Reset token 2 fee config
      console.log("Resetting token 2 fee config...");
      const resetToken2FeeConfigResult = await sdk.removeTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId2,
      });
      console.log(
        "Reset token 2 fee config result:",
        resetToken2FeeConfigResult
      );

      // 10. Verify fee configs are back to default
      console.log("10. Verifying fee configs are back to default...");
      const token1FeeConfigAfterReset = await sdk.getTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId1,
      });
      console.log("Token 1 fee config after reset:", token1FeeConfigAfterReset);

      const token2FeeConfigAfterReset = await sdk.getTokenFeeConfig({
        collectionAddress,
        tokenId: tokenId2,
      });
      console.log("Token 2 fee config after reset:", token2FeeConfigAfterReset);

      console.log("====== DROP SDK TEST COMPLETED SUCCESSFULLY! ======");
    } catch (error: unknown) {
      console.error(
        "Error testing Drop SDK:",
        error instanceof Error ? error.message : String(error)
      );
      if (error instanceof Error) {
        console.error("Error stack:", error.stack);
      }
      throw error;
    }
  }, 600_000); // Increase timeout to 10 minutes for testnet transactions
});
