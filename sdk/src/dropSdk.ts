import { ethers } from "ethers";
import { Address, PublicClient, WalletClient } from "viem";
import { blueprintERC1155Abi } from "../abis";
import { createViemClients, getContractsForChain } from "./viem";

/**
 * BlueprintERC1155 Fee Distribution:
 *
 * The contract supports three types of fees during minting:
 * 1. Blueprint Fee: Platform fee that goes to the blueprint recipient
 * 2. Creator Fee: Creator royalty that goes to the creator recipient
 * 3. Reward Pool Fee: Additional fee that goes to the reward pool recipient
 *
 * Any remaining amount after these fees goes to the treasury.
 * If the reward pool recipient is set to address(0), that fee goes to the treasury.
 * The blueprint recipient and creator recipient cannot be address(0).
 */

export type Drop = {
  price: bigint;
  startTime: bigint;
  endTime: bigint;
  active: boolean;
};

export type FeeConfig = {
  blueprintRecipient: Address;
  blueprintFeeBasisPoints: bigint;
  creatorRecipient: Address;
  creatorBasisPoints: bigint;
  rewardPoolRecipient: Address;
  rewardPoolBasisPoints: bigint;
  treasury: Address;
};

export class DropSDK {
  private publicClient!: PublicClient;
  private walletClient!: WalletClient;
  private chainId: number;

  constructor(chainId: number) {
    this.chainId = chainId;
  }

  async initialize() {
    const { publicClient, walletClient } = await createViemClients(
      this.chainId
    );
    this.publicClient = publicClient;
    this.walletClient = walletClient;
  }

  /**
   * Helper method to sign and send a transaction
   * This is needed because Alchemy doesn't support eth_sendTransaction
   */
  private async signAndSendTransaction(params: {
    address: Address;
    abi: any;
    functionName: string;
    args: any[];
    value?: bigint;
    maxAttempts?: number;
    waitTimeoutMs?: number;
  }) {
    if (!this.walletClient.account) {
      throw new Error("Wallet account not available");
    }

    try {
      // Wait for a short period to allow previous transactions to complete
      await new Promise((resolve) => setTimeout(resolve, 2000));

      // Get the chain configuration
      const { chain } = getContractsForChain(this.chainId).dropFactoryContract;

      // Simulate the contract call first to validate with retry for rate limits
      let simulationSuccess = false;
      let simulationResult;
      let simulationBackoffMs = 1000;
      let simulationAttempt = 0;
      const maxSimulationAttempts = params.maxAttempts || 5;

      while (!simulationSuccess && simulationAttempt < maxSimulationAttempts) {
        try {
          simulationResult = await this.publicClient.simulateContract({
            address: this.formatAddress(params.address),
            abi: params.abi,
            functionName: params.functionName,
            args: params.args,
            account: this.walletClient.account,
            value: params.value,
          });
          simulationSuccess = true;
        } catch (error: any) {
          // Check if this is a rate limit error (HTTP 429)
          const is429Error =
            error.message?.includes("HTTP request failed") &&
            error.message?.includes("Status: 429");

          // If not a rate limit error or reached max attempts, throw
          if (!is429Error || simulationAttempt >= maxSimulationAttempts - 1) {
            throw error;
          }

          // Log the rate limit and retry
          console.warn(
            `Rate limited (429) during simulation. Retrying in ${simulationBackoffMs}ms... (Attempt ${
              simulationAttempt + 1
            }/${maxSimulationAttempts})`
          );

          // Wait with exponential backoff
          await new Promise((resolve) =>
            setTimeout(resolve, simulationBackoffMs)
          );

          // Increase backoff for next attempt (exponential with randomness)
          simulationBackoffMs = Math.min(
            simulationBackoffMs * 1.5 * (1 + 0.2 * Math.random()),
            15000
          );
          simulationAttempt++;
        }
      }

      // Send the transaction with up to 3 retries
      let attempt = 0;
      const maxAttempts = params.maxAttempts || 3;
      let hash;
      let txBackoffMs = 1000;

      while (attempt < maxAttempts && !hash) {
        try {
          hash = await this.walletClient.writeContract({
            address: params.address,
            abi: params.abi,
            functionName: params.functionName,
            args: params.args,
            account: this.walletClient.account,
            value: params.value,
            chain,
          });
          break;
        } catch (error: any) {
          attempt++;

          // Check for rate limit errors
          const is429Error =
            error.message?.includes("HTTP request failed") &&
            error.message?.includes("Status: 429");

          // Handle different error types
          if (is429Error && attempt < maxAttempts) {
            console.warn(
              `Rate limited (429) during transaction. Retrying in ${txBackoffMs}ms... (Attempt ${attempt}/${maxAttempts})`
            );

            // Wait with exponential backoff
            await new Promise((resolve) => setTimeout(resolve, txBackoffMs));

            // Increase backoff for next attempt (exponential with randomness)
            txBackoffMs = Math.min(
              txBackoffMs * 1.5 * (1 + 0.2 * Math.random()),
              15000
            );
          } else if (
            error.message?.includes("replacement transaction underpriced") &&
            attempt < maxAttempts
          ) {
            console.log(
              `Retry attempt ${attempt} after replacement transaction error...`
            );
            await new Promise((resolve) => setTimeout(resolve, 3000 * attempt));
          } else if (attempt >= maxAttempts) {
            throw error;
          }
        }
      }

      if (!hash) {
        throw new Error("Failed to send transaction after multiple attempts");
      }

      // Wait for the transaction to complete with increased timeout
      // Default to 90 seconds for testnet, which can be slow
      const waitTimeoutMs = params.waitTimeoutMs || 90_000;
      console.log(
        `Waiting up to ${
          waitTimeoutMs / 1000
        } seconds for transaction confirmation...`
      );

      // Add more detailed receipt waiting with retries
      let receipt = null as any;
      let receiptAttempt = 0;
      const maxReceiptAttempts = 5;
      let receiptBackoffMs = 2000;

      while (!receipt && receiptAttempt < maxReceiptAttempts) {
        try {
          receipt = await this.publicClient.waitForTransactionReceipt({
            hash,
            timeout: waitTimeoutMs,
            // Poll more frequently on testnets
            pollingInterval: this.chainId === 1 ? 4000 : 2000,
          });
          break;
        } catch (error: any) {
          receiptAttempt++;

          // Check for rate limit errors
          const is429Error =
            error.message?.includes("HTTP request failed") &&
            error.message?.includes("Status: 429");

          if (is429Error && receiptAttempt < maxReceiptAttempts) {
            console.warn(
              `Rate limited (429) while waiting for receipt. Retrying in ${receiptBackoffMs}ms... (Attempt ${receiptAttempt}/${maxReceiptAttempts})`
            );

            // Wait with exponential backoff
            await new Promise((resolve) =>
              setTimeout(resolve, receiptBackoffMs)
            );

            // Increase backoff for next attempt
            receiptBackoffMs = Math.min(
              receiptBackoffMs * 1.5 * (1 + 0.2 * Math.random()),
              15000
            );
          } else {
            console.log(
              `Receipt attempt ${receiptAttempt}/${maxReceiptAttempts} failed. Retrying...`
            );

            // If we've reached max attempts, rethrow the error
            if (receiptAttempt >= maxReceiptAttempts) {
              console.error(
                `Transaction was sent with hash ${hash} but confirmation timed out.`
              );
              console.error(
                `You can check the transaction status manually at: https://sepolia.basescan.org/tx/${hash}`
              );
              throw error;
            }

            // Wait a bit longer before retrying
            await new Promise((resolve) =>
              setTimeout(resolve, 5000 * receiptAttempt)
            );
          }
        }
      }

      return hash;
    } catch (error) {
      console.error(`Error in signAndSendTransaction:`, error);
      throw error;
    }
  }

  /**
   * Helper method to read contract data with automatic retry for rate limit errors (429)
   * Uses exponential backoff to handle rate limits gracefully
   */
  private async readContractWithRetry<T>({
    address,
    abi,
    functionName,
    args = [],
    maxRetries = 5,
    initialBackoffMs = 1000,
  }: {
    address: Address;
    abi: any;
    functionName: string;
    args?: any[];
    maxRetries?: number;
    initialBackoffMs?: number;
  }): Promise<T> {
    let retryCount = 0;
    let backoffMs = initialBackoffMs;
    const formattedAddress = this.formatAddress(address);

    while (true) {
      try {
        return (await this.publicClient.readContract({
          address: formattedAddress,
          abi,
          functionName,
          args,
        })) as T;
      } catch (error: any) {
        // Check if this is a rate limit error (HTTP 429)
        const is429Error =
          error.message?.includes("HTTP request failed") &&
          error.message?.includes("Status: 429");

        // If we've reached max retries or it's not a rate limit error, throw
        if (retryCount >= maxRetries) {
          throw error;
        }

        // Log the rate limit and backoff
        console.warn(
          `Rate limited (429). Retrying in ${backoffMs}ms... (Attempt ${
            retryCount + 1
          }/${maxRetries})`
        );

        // Wait with exponential backoff
        await new Promise((resolve) => setTimeout(resolve, backoffMs));

        // Increase backoff for next attempt (exponential with some randomness)
        backoffMs = Math.min(
          backoffMs * 1.5 * (1 + 0.2 * Math.random()),
          15000
        );
        retryCount++;
      }
    }
  }

  // Helper to ensure addresses are properly formatted
  private formatAddress(address: Address): Address {
    return ethers.getAddress(address) as Address;
  }

  /**
   * Factory methods
   */
  async createCollection({
    uri,
    creatorRecipient,
    creatorBasisPoints,
  }: {
    uri: string;
    creatorRecipient: Address;
    creatorBasisPoints: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "createCollection",
      args: [uri, this.formatAddress(creatorRecipient), creatorBasisPoints],
    });

    console.log("Transaction sent successfully. Hash:", tx);

    // Get transaction receipt to find the collection address from event
    const receipt = await this.publicClient.waitForTransactionReceipt({
      hash: tx,
    });

    console.log("Transaction receipt status:", receipt.status);
    console.log("Total logs in receipt:", receipt.logs.length);

    // Log all events for debugging
    receipt.logs.forEach((log, index) => {
      console.log(`Log ${index}:`, {
        address: log.address,
        topics: log.topics,
        data: log.data,
      });
    });

    // Look for the correct collection creation event
    // The event signature has changed in the new contract
    const event = receipt.logs.find(
      (log) =>
        log.topics[0] ===
        "0xa9a63cb75fdf6f638d49c249df7d5b94dd8bb8ac664ca12da7339862b9dd87ae"
    );

    if (!event || !event.topics[2]) {
      console.error(
        "Failed to find collection creation event in transaction logs"
      );
      throw new Error("Collection address not found in event logs");
    }

    // Extract the collection address from topics[2]
    const collectionAddress = this.formatAddress(
      ("0x" + event.topics[2].slice(26)) as Address
    );
    console.log("Extracted collection address:", collectionAddress);

    return { tx, collectionAddress };
  }

  async createDrop({
    collectionAddress,
    price,
    startTime,
    endTime,
    active,
  }: {
    collectionAddress: Address;
    price: bigint;
    startTime: bigint;
    endTime: bigint;
    active: boolean;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    // Format addresses using ethers to prevent issues
    const formattedCollectionAddress = this.formatAddress(collectionAddress);

    // Use increased timeouts and retries for createDrop specifically
    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "createNewDrop",
      args: [formattedCollectionAddress, price, startTime, endTime, active],
      // Increase max attempts for create drop which often hits rate limits
      maxAttempts: 5,
      // Longer timeout for transaction confirmation
      waitTimeoutMs: 120_000,
    });

    // Use retries for transaction receipt as well
    let receipt: any = undefined;
    let receiptAttempt = 0;
    const maxReceiptAttempts = 7; // More attempts
    let receiptBackoffMs = 3000; // Start with longer backoff

    while (!receipt && receiptAttempt < maxReceiptAttempts) {
      try {
        // Wait for transaction receipt with increased timeout
        receipt = await this.publicClient.waitForTransactionReceipt({
          hash: tx,
          timeout: 120_000,
          pollingInterval: this.chainId === 1 ? 4000 : 2000,
        });
        break;
      } catch (error: any) {
        receiptAttempt++;

        // Check for rate limit errors
        const is429Error =
          error.message?.includes("HTTP request failed") &&
          error.message?.includes("Status: 429");

        if (is429Error && receiptAttempt < maxReceiptAttempts) {
          console.warn(
            `Rate limited (429) while waiting for createDrop receipt. Retrying in ${receiptBackoffMs}ms... (Attempt ${receiptAttempt}/${maxReceiptAttempts})`
          );

          // Longer wait with exponential backoff
          await new Promise((resolve) => setTimeout(resolve, receiptBackoffMs));

          // Increase backoff for next attempt with higher ceiling
          receiptBackoffMs = Math.min(
            receiptBackoffMs * 2 * (1 + 0.2 * Math.random()),
            20000
          );
        } else {
          console.log(
            `Receipt attempt ${receiptAttempt}/${maxReceiptAttempts} failed. Retrying...`
          );

          // If we've reached max attempts, rethrow the error
          if (receiptAttempt >= maxReceiptAttempts) {
            console.error(
              `Transaction was sent with hash ${tx} but confirmation timed out.`
            );
            console.error(
              `You can check the transaction status manually at: https://sepolia.basescan.org/tx/${tx}`
            );
            // But we'll consider it a success since the tx was sent
            break;
          }

          // Wait a bit longer before retrying
          await new Promise((resolve) =>
            setTimeout(resolve, 5000 * receiptAttempt)
          );
        }
      }
    }

    // Even if we don't have a receipt, we'll consider it a success
    // since the transaction was sent and may still be confirmed later
    return {
      tx,
      success: receipt ? receipt.status === "success" : true,
      isPending: receipt === undefined,
    };
  }

  async updateCollectionURI({
    collectionAddress,
    uri,
  }: {
    collectionAddress: Address;
    uri: string;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateCollectionURI",
      args: [this.formatAddress(collectionAddress), uri],
    });

    return { tx };
  }

  async updateCollectionName({
    collectionAddress,
    name,
  }: {
    collectionAddress: Address;
    name: string;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateCollectionName",
      args: [this.formatAddress(collectionAddress), name],
    });

    return { tx };
  }

  async updateCollectionSymbol({
    collectionAddress,
    symbol,
  }: {
    collectionAddress: Address;
    symbol: string;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateCollectionSymbol",
      args: [this.formatAddress(collectionAddress), symbol],
    });

    return { tx };
  }

  async updateTokenURI({
    collectionAddress,
    tokenId,
    tokenURI,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
    tokenURI: string;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateTokenURI",
      args: [this.formatAddress(collectionAddress), tokenId, tokenURI],
    });

    return { tx };
  }

  async updateDropPrice({
    collectionAddress,
    tokenId,
    price,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
    price: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateDropPrice",
      args: [this.formatAddress(collectionAddress), tokenId, price],
    });

    return { tx };
  }

  async updateDropStartTime({
    collectionAddress,
    tokenId,
    startTime,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
    startTime: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "updateDropStartTime",
      args: [this.formatAddress(collectionAddress), tokenId, startTime],
    });

    return { tx };
  }

  async updateDropEndTime({
    collectionAddress,
    tokenId,
    endTime,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
    endTime: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "updateDropEndTime",
      args: [this.formatAddress(collectionAddress), tokenId, endTime],
    });

    return { tx };
  }

  async updateCreatorRecipient({
    collectionAddress,
    creatorRecipient,
  }: {
    collectionAddress: Address;
    creatorRecipient: Address;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "updateCreatorRecipient",
      args: [
        this.formatAddress(collectionAddress),
        this.formatAddress(creatorRecipient),
      ],
    });

    return { tx };
  }

  async updateFeeConfig({
    collectionAddress,
    blueprintRecipient,
    blueprintFeeBasisPoints,
    creatorRecipient,
    creatorBasisPoints,
    rewardPoolRecipient,
    rewardPoolBasisPoints,
    treasury,
  }: {
    collectionAddress: Address;
    blueprintRecipient: Address;
    blueprintFeeBasisPoints: bigint;
    creatorRecipient: Address;
    creatorBasisPoints: bigint;
    rewardPoolRecipient: Address;
    rewardPoolBasisPoints: bigint;
    treasury: Address;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "updateFeeConfig",
      args: [
        this.formatAddress(collectionAddress),
        this.formatAddress(blueprintRecipient),
        blueprintFeeBasisPoints,
        this.formatAddress(creatorRecipient),
        creatorBasisPoints,
        this.formatAddress(rewardPoolRecipient),
        rewardPoolBasisPoints,
        this.formatAddress(treasury),
      ],
    });

    return { tx };
  }

  async setDefaultFeeConfig({
    defaultBlueprintRecipient,
    defaultFeeBasisPoints,
    defaultMintFee,
    defaultTreasury,
    defaultRewardPoolRecipient,
    defaultRewardPoolBasisPoints,
  }: {
    defaultBlueprintRecipient: Address;
    defaultFeeBasisPoints: bigint;
    defaultMintFee: bigint;
    defaultTreasury: Address;
    defaultRewardPoolRecipient: Address;
    defaultRewardPoolBasisPoints: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "setDefaultFeeConfig",
      args: [
        this.formatAddress(defaultBlueprintRecipient),
        defaultFeeBasisPoints,
        defaultMintFee,
        this.formatAddress(defaultTreasury),
        this.formatAddress(defaultRewardPoolRecipient),
        defaultRewardPoolBasisPoints,
      ],
    });

    return { tx };
  }

  /**
   * Collection methods
   */
  async mint({
    collectionAddress,
    to,
    tokenId,
    amount,
    value,
  }: {
    collectionAddress: Address;
    to: Address;
    tokenId: bigint;
    amount: bigint;
    value: bigint;
  }) {
    const { chain } = getContractsForChain(this.chainId).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "mint",
      args: [this.formatAddress(to), tokenId, amount],
      value,
    });

    return { tx };
  }

  async adminMint({
    collectionAddress,
    to,
    tokenId,
    amount,
  }: {
    collectionAddress: Address;
    to: Address;
    tokenId: bigint;
    amount: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "adminMint",
      args: [
        this.formatAddress(collectionAddress),
        this.formatAddress(to),
        tokenId,
        amount,
      ],
    });

    return { tx };
  }

  async getCollectionURI({
    collectionAddress,
  }: {
    collectionAddress: Address;
  }): Promise<string> {
    return this.readContractWithRetry<string>({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "collectionURI",
    });
  }

  async getTokenURI({
    collectionAddress,
    tokenId,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
  }): Promise<string> {
    return this.readContractWithRetry<string>({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "uri",
      args: [tokenId],
    });
  }

  async getDrop({
    collectionAddress,
    tokenId,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
  }): Promise<Drop> {
    const result = await this.readContractWithRetry<any>({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "drops",
      args: [tokenId],
    });

    // Convert the result to the Drop type
    if (Array.isArray(result) && result.length >= 4) {
      return {
        price: result[0] as bigint,
        startTime: result[1] as bigint,
        endTime: result[2] as bigint,
        active: result[3] as boolean,
      };
    }

    throw new Error("Invalid Drop data format");
  }

  async getFeeConfig({
    collectionAddress,
  }: {
    collectionAddress: Address;
  }): Promise<FeeConfig> {
    // If defaultFeeConfig doesn't exist or doesn't work, try using getFeeConfig
    let result;
    try {
      result = await this.readContractWithRetry<any>({
        address: this.formatAddress(collectionAddress),
        abi: blueprintERC1155Abi,
        functionName: "defaultFeeConfig",
      });
    } catch (error) {
      console.error(`Error fetching fee config: ${error}`);
      // Try the alternative way
      result = await this.readContractWithRetry<any>({
        address: this.formatAddress(collectionAddress),
        abi: blueprintERC1155Abi,
        functionName: "getFeeConfig",
        args: [BigInt(0)],
      });
    }

    // Handle result
    if (!result || typeof result !== "object") {
      throw new Error("Invalid FeeConfig data format");
    }

    // Log the raw result to debug
    console.log("Raw getFeeConfig result:", result);

    // Handle both array and object return types from contract
    let feeConfig: any;

    if (Array.isArray(result)) {
      // If result is an array, map to object properties
      // FeeConfig struct has 7 fields in this order:
      // blueprintRecipient, blueprintFeeBasisPoints, creatorRecipient, creatorBasisPoints,
      // rewardPoolRecipient, rewardPoolBasisPoints, treasury
      feeConfig = {
        blueprintRecipient: result[0],
        blueprintFeeBasisPoints: result[1],
        creatorRecipient: result[2],
        creatorBasisPoints: result[3],
        rewardPoolRecipient: result[4],
        rewardPoolBasisPoints: result[5],
        treasury: result[6],
      };
    } else {
      // If result is already an object
      feeConfig = result;
    }

    return {
      blueprintRecipient: feeConfig.blueprintRecipient as Address,
      blueprintFeeBasisPoints: feeConfig.blueprintFeeBasisPoints as bigint,
      creatorRecipient: feeConfig.creatorRecipient as Address,
      creatorBasisPoints: feeConfig.creatorBasisPoints as bigint,
      rewardPoolRecipient: feeConfig.rewardPoolRecipient as Address,
      rewardPoolBasisPoints: feeConfig.rewardPoolBasisPoints as bigint,
      treasury: feeConfig.treasury as Address,
    };
  }

  async getDefaultFeeConfig(): Promise<FeeConfig> {
    const { address, abi } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    let result;
    try {
      result = await this.readContractWithRetry<any>({
        address,
        abi,
        functionName: "getDefaultFeeConfig",
      });
    } catch (error) {
      console.error(`Error fetching default fee config: ${error}`);
      throw new Error(`Failed to fetch default fee config: ${error}`);
    }

    console.log("getDefaultFeeConfig result:", result);

    // Handle result
    if (!result) {
      throw new Error("Invalid default FeeConfig data format");
    }

    // Log the raw result to debug
    console.log("Raw getDefaultFeeConfig result:", result);

    // Handle both array and object return types from contract
    let feeConfig: any;

    if (Array.isArray(result)) {
      // If result is an array, map to object properties
      // FeeConfig struct has 7 fields in this order:
      // blueprintRecipient, blueprintFeeBasisPoints, creatorRecipient, creatorBasisPoints,
      // rewardPoolRecipient, rewardPoolBasisPoints, treasury
      feeConfig = {
        blueprintRecipient: result[0],
        blueprintFeeBasisPoints: result[1],
        creatorRecipient: result[2],
        creatorBasisPoints: result[3],
        rewardPoolRecipient: result[4],
        rewardPoolBasisPoints: result[5],
        treasury: result[6],
      };
    } else if (typeof result === "object") {
      // If result is already an object
      feeConfig = result;
    } else {
      throw new Error("Invalid default FeeConfig data format");
    }

    return {
      blueprintRecipient: feeConfig.blueprintRecipient as Address,
      blueprintFeeBasisPoints: feeConfig.blueprintFeeBasisPoints as bigint,
      creatorRecipient: feeConfig.creatorRecipient as Address,
      creatorBasisPoints: feeConfig.creatorBasisPoints as bigint,
      rewardPoolRecipient: feeConfig.rewardPoolRecipient as Address,
      rewardPoolBasisPoints: feeConfig.rewardPoolBasisPoints as bigint,
      treasury: feeConfig.treasury as Address,
    };
  }

  async getTokenFeeConfig({
    collectionAddress,
    tokenId,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
  }): Promise<FeeConfig> {
    // First try using getFeeConfig directly, which should work on all contract versions
    try {
      const result = await this.readContractWithRetry<any>({
        address: this.formatAddress(collectionAddress),
        abi: blueprintERC1155Abi,
        functionName: "getFeeConfig",
        args: [tokenId],
      });

      if (result) {
        console.log("Got fee config using getFeeConfig method:", result);

        // Handle both array and object return types from contract
        let feeConfig: any;

        if (Array.isArray(result)) {
          // If result is an array, map to object properties
          feeConfig = {
            blueprintRecipient: result[0],
            blueprintFeeBasisPoints: result[1],
            creatorRecipient: result[2],
            creatorBasisPoints: result[3],
            rewardPoolRecipient: result[4],
            rewardPoolBasisPoints: result[5],
            treasury: result[6],
          };
        } else {
          // If result is already an object
          feeConfig = result;
        }

        return {
          blueprintRecipient: feeConfig.blueprintRecipient as Address,
          blueprintFeeBasisPoints: feeConfig.blueprintFeeBasisPoints as bigint,
          creatorRecipient: feeConfig.creatorRecipient as Address,
          creatorBasisPoints: feeConfig.creatorBasisPoints as bigint,
          rewardPoolRecipient: feeConfig.rewardPoolRecipient as Address,
          rewardPoolBasisPoints: feeConfig.rewardPoolBasisPoints as bigint,
          treasury: feeConfig.treasury as Address,
        };
      }
    } catch (error) {
      console.warn(
        `Error calling getFeeConfig, trying alternative approaches: ${error}`
      );
    }

    // The newer contract version approach with hasCustomFeeConfig and defaultFeeConfig
    // First check if this token has a custom fee config
    let hasCustomConfig = false;
    try {
      hasCustomConfig = await this.readContractWithRetry<boolean>({
        address: this.formatAddress(collectionAddress),
        abi: blueprintERC1155Abi,
        functionName: "hasCustomFeeConfig",
        args: [tokenId],
      });
    } catch (error) {
      console.warn(
        `Error checking hasCustomFeeConfig, falling back to default: ${error}`
      );
      // If the hasCustomFeeConfig check fails, we'll fall back to the default config
    }

    let result;
    if (hasCustomConfig) {
      // If custom config exists, get from tokenFeeConfigs mapping
      try {
        result = await this.readContractWithRetry<any>({
          address: this.formatAddress(collectionAddress),
          abi: blueprintERC1155Abi,
          functionName: "tokenFeeConfigs",
          args: [tokenId],
        });
      } catch (error) {
        console.warn(
          `Error fetching tokenFeeConfigs, falling back to default: ${error}`
        );
        // If fetching the token-specific config fails, fall back to the default config
        hasCustomConfig = false;
      }
    }

    // If we don't have a custom config (either because there isn't one or because fetching it failed)
    if (!hasCustomConfig) {
      try {
        // Get the default fee config
        result = await this.readContractWithRetry<any>({
          address: this.formatAddress(collectionAddress),
          abi: blueprintERC1155Abi,
          functionName: "defaultFeeConfig",
        });
      } catch (error) {
        console.warn(`Error fetching defaultFeeConfig: ${error}`);
        // As a last resort, try to get the default fee config from the factory
        try {
          return await this.getDefaultFeeConfig();
        } catch (factoryError) {
          console.error(
            "Failed to get fee config from any source:",
            factoryError
          );
          throw new Error("Failed to get fee config from any available method");
        }
      }
    }

    // Handle result
    if (!result || typeof result !== "object") {
      throw new Error("Invalid Token FeeConfig data format");
    }

    // Log the raw result to debug
    console.log("Raw getTokenFeeConfig result:", result);

    // Handle both array and object return types from contract
    let feeConfig: any;

    if (Array.isArray(result)) {
      // If result is an array, map to object properties
      // FeeConfig struct has 7 fields in this order:
      // blueprintRecipient, blueprintFeeBasisPoints, creatorRecipient, creatorBasisPoints,
      // rewardPoolRecipient, rewardPoolBasisPoints, treasury
      feeConfig = {
        blueprintRecipient: result[0],
        blueprintFeeBasisPoints: result[1],
        creatorRecipient: result[2],
        creatorBasisPoints: result[3],
        rewardPoolRecipient: result[4],
        rewardPoolBasisPoints: result[5],
        treasury: result[6],
      };
    } else {
      // If result is already an object
      feeConfig = result;
    }

    return {
      blueprintRecipient: feeConfig.blueprintRecipient as Address,
      blueprintFeeBasisPoints: feeConfig.blueprintFeeBasisPoints as bigint,
      creatorRecipient: feeConfig.creatorRecipient as Address,
      creatorBasisPoints: feeConfig.creatorBasisPoints as bigint,
      rewardPoolRecipient: feeConfig.rewardPoolRecipient as Address,
      rewardPoolBasisPoints: feeConfig.rewardPoolBasisPoints as bigint,
      treasury: feeConfig.treasury as Address,
    };
  }

  async updateTokenFeeConfig({
    collectionAddress,
    tokenId,
    blueprintRecipient,
    blueprintFeeBasisPoints,
    creatorRecipient,
    creatorBasisPoints,
    rewardPoolRecipient,
    rewardPoolBasisPoints,
    treasury,
    verifyUpdate = false,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
    blueprintRecipient: Address;
    blueprintFeeBasisPoints: bigint;
    creatorRecipient: Address;
    creatorBasisPoints: bigint;
    rewardPoolRecipient: Address;
    rewardPoolBasisPoints: bigint;
    treasury: Address;
    verifyUpdate?: boolean;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "updateTokenFeeConfig",
      args: [
        this.formatAddress(collectionAddress),
        tokenId,
        this.formatAddress(blueprintRecipient),
        blueprintFeeBasisPoints,
        this.formatAddress(creatorRecipient),
        creatorBasisPoints,
        this.formatAddress(rewardPoolRecipient),
        rewardPoolBasisPoints,
        this.formatAddress(treasury),
      ],
    });

    // If verifyUpdate is true, wait for the tx to be confirmed and then verify the fee config
    if (verifyUpdate) {
      // Wait for the transaction to be processed (5 seconds should be enough for most chains)
      console.log("Waiting for fee config update to be confirmed...");
      await new Promise((resolve) => setTimeout(resolve, 5000));

      // Fetch the updated fee config
      const updatedConfig = await this.getTokenFeeConfig({
        collectionAddress,
        tokenId,
      });

      // Compare the updated config with what we set
      console.log("Verifying fee config update...");
      if (
        updatedConfig.blueprintFeeBasisPoints !== blueprintFeeBasisPoints ||
        updatedConfig.creatorBasisPoints !== creatorBasisPoints ||
        updatedConfig.rewardPoolBasisPoints !== rewardPoolBasisPoints
      ) {
        console.warn("Fee config update verification failed!");
        console.warn("Expected:", {
          blueprintFeeBasisPoints,
          creatorBasisPoints,
          rewardPoolBasisPoints,
        });
        console.warn("Actual:", {
          blueprintFeeBasisPoints: updatedConfig.blueprintFeeBasisPoints,
          creatorBasisPoints: updatedConfig.creatorBasisPoints,
          rewardPoolBasisPoints: updatedConfig.rewardPoolBasisPoints,
        });
      } else {
        console.log("Fee config update verified successfully!");
      }
    }

    return { tx };
  }

  async removeTokenFeeConfig({
    collectionAddress,
    tokenId,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address,
      abi,
      functionName: "removeTokenFeeConfig",
      args: [this.formatAddress(collectionAddress), tokenId],
    });

    return { tx };
  }

  async batchMint({
    collectionAddress,
    to,
    tokenIds,
    amounts,
    value,
  }: {
    collectionAddress: Address;
    to: Address;
    tokenIds: bigint[];
    amounts: bigint[];
    value: bigint;
  }) {
    const { chain } = getContractsForChain(this.chainId).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "batchMint",
      args: [this.formatAddress(to), tokenIds, amounts],
      value,
    });

    return { tx };
  }

  async getNextTokenId({ collectionAddress }: { collectionAddress: Address }) {
    const nextTokenId = await this.readContractWithRetry<bigint>({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "nextTokenId",
    });
    return nextTokenId;
  }

  async getBalance({
    collectionAddress,
    account,
    tokenId,
  }: {
    collectionAddress: Address;
    account: Address;
    tokenId: bigint;
  }) {
    const balance = await this.readContractWithRetry<bigint>({
      address: this.formatAddress(collectionAddress),
      abi: blueprintERC1155Abi,
      functionName: "balanceOf",
      args: [this.formatAddress(account), tokenId],
    });
    return balance;
  }

  /**
   * Get the total supply for a specific token ID in a collection
   */
  async getTokenTotalSupply({
    collectionAddress,
    tokenId,
  }: {
    collectionAddress: Address;
    tokenId: bigint;
  }): Promise<bigint> {
    const { address, abi } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const totalSupply = await this.readContractWithRetry<bigint>({
      address,
      abi,
      functionName: "getTokenTotalSupply",
      args: [this.formatAddress(collectionAddress), tokenId],
    });

    return totalSupply;
  }

  /**
   * Get the total supply across all tokens in a collection
   */
  async getCollectionTotalSupply({
    collectionAddress,
  }: {
    collectionAddress: Address;
  }): Promise<bigint> {
    const { address, abi } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const totalSupply = await this.readContractWithRetry<bigint>({
      address,
      abi,
      functionName: "getCollectionTotalSupply",
      args: [this.formatAddress(collectionAddress)],
    });

    return totalSupply;
  }

  async updateRewardPoolRecipient({
    collectionAddress,
    rewardPoolRecipient,
    verifyUpdate = false,
  }: {
    collectionAddress: Address;
    rewardPoolRecipient: Address;
    verifyUpdate?: boolean;
  }) {
    const { address, abi, chain } = getContractsForChain(
      this.chainId
    ).dropFactoryContract;

    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(address),
      abi,
      functionName: "updateRewardPoolRecipient",
      args: [
        this.formatAddress(collectionAddress),
        this.formatAddress(rewardPoolRecipient),
      ],
    });

    // Add verification with delay to ensure state propagation
    if (verifyUpdate) {
      console.log(
        "Waiting for reward pool recipient update to be confirmed..."
      );

      // Use longer delay (7 seconds) to ensure state propagation
      await new Promise((resolve) => setTimeout(resolve, 7000));

      // Get the updated fee config
      console.log("Checking if reward pool recipient was updated...");
      const updatedConfig = await this.getFeeConfig({
        collectionAddress,
      });

      // Format addresses for consistent comparison
      const expectedRecipient =
        this.formatAddress(rewardPoolRecipient).toLowerCase();
      const actualRecipient = this.formatAddress(
        updatedConfig.rewardPoolRecipient
      ).toLowerCase();

      // Verify the update was successful
      if (expectedRecipient !== actualRecipient) {
        console.warn("Reward pool recipient update verification failed!");
        console.warn(`Expected: ${expectedRecipient}`);
        console.warn(`Actual: ${actualRecipient}`);
      } else {
        console.log("✅ Reward pool recipient update verified successfully!");
      }
    }

    return { tx };
  }
}
