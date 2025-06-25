import { ethers } from 'ethers';
import { Address, PublicClient, WalletClient } from 'viem';
import { rewardPoolAbi, rewardPoolFactoryAbi } from '../abis';
import { createViemClients, getContractsForChain } from './viem';

/**
 * RewardPool System:
 *
 * The RewardPool system allows XP-based proportional reward distribution.
 * Users can claim rewards for multiple token types (ETH and ERC20) using EIP-712 signatures.
 * Each user has independent nonce tracking to prevent signature replay attacks.
 *
 * Key Features:
 * - XP-based proportional distribution: (userXP / totalXP) * poolRewards
 * - Multi-token support: Native ETH and ERC20 tokens
 * - Per-user nonce management: Independent nonce tracking per user
 * - Double claim protection: Users cannot claim same reward type twice
 * - Upgradeable architecture: UUPS proxy pattern
 */

export enum TokenType {
  ERC20 = 0,
  NATIVE = 1,
}

export type PoolInfo = {
  name: string;
  description: string;
  active: boolean;
  totalXP: bigint;
  userCount: bigint;
};

export type ClaimData = {
  user: Address;
  nonce: bigint;
  tokenAddress: Address;
  tokenType: TokenType;
};

export type RewardBalance = {
  tokenAddress: Address;
  tokenType: TokenType;
  totalRewards: bigint;
  totalClaimed: bigint;
  availableRewards: bigint;
};

export type UserInfo = {
  xp: bigint;
  isUser: boolean;
  hasClaimed: { [tokenAddress: string]: { [tokenType: number]: boolean } };
};

export type ClaimEligibility = {
  canClaim: boolean;
  allocation: bigint;
  userXP: bigint;
  totalXP: bigint;
};

export class RewardPoolSDK {
  private publicClient!: PublicClient;
  private walletClient!: WalletClient;
  private chainId: number;
  private FACTORY_ADDRESS!: Address;

  // EIP-712 constants
  private readonly SIGNING_DOMAIN = 'BP_REWARD_POOL';
  private readonly SIGNATURE_VERSION = '1';

  constructor(chainId: number) {
    this.chainId = chainId;
  }

  async initialize() {
    const { publicClient, walletClient } = await createViemClients(this.chainId);
    this.publicClient = publicClient;
    this.walletClient = walletClient;
    
    // Set factory address from chain configuration
    const contracts = getContractsForChain(this.chainId);
    this.FACTORY_ADDRESS = contracts.rewardPoolFactoryContract.address;
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
    bypassSimulation?: boolean;
  }) {
    if (!this.walletClient.account) {
      throw new Error('Wallet account not available');
    }

    try {
      // Wait for a short period to allow previous transactions to complete
      await new Promise(resolve => setTimeout(resolve, 2000));

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
          if (!params.bypassSimulation) {
            // Try simulation first
            simulationResult = await this.publicClient.simulateContract({
              address: this.formatAddress(params.address),
              abi: params.abi,
              functionName: params.functionName,
              args: params.args,
              value: params.value,
              account: this.walletClient.account,
            });
          }
          simulationSuccess = true;
        } catch (error: any) {
          // Check if this is a rate limit error (HTTP 429)
          const is429Error =
            error.message?.includes('HTTP request failed') &&
            error.message?.includes('Status: 429');

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
          await new Promise(resolve => setTimeout(resolve, simulationBackoffMs));

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
          // Send the transaction (either from simulation or direct)
          hash = await this.walletClient.writeContract({
            address: this.formatAddress(params.address),
            abi: params.abi,
            functionName: params.functionName,
            args: params.args,
            value: params.value,
            account: this.walletClient.account,
            chain,
          });
          break;
        } catch (error: any) {
          attempt++;

          // Check for rate limit errors
          const is429Error =
            error.message?.includes('HTTP request failed') &&
            error.message?.includes('Status: 429');

          // Handle different error types
          if (is429Error && attempt < maxAttempts) {
            console.warn(
              `Rate limited (429) during transaction. Retrying in ${txBackoffMs}ms... (Attempt ${attempt}/${maxAttempts})`
            );

            // Wait with exponential backoff
            await new Promise(resolve => setTimeout(resolve, txBackoffMs));

            // Increase backoff for next attempt (exponential with randomness)
            txBackoffMs = Math.min(txBackoffMs * 1.5 * (1 + 0.2 * Math.random()), 15000);
          } else if (
            error.message?.includes('replacement transaction underpriced') &&
            attempt < maxAttempts
          ) {
            console.log(`Retry attempt ${attempt} after replacement transaction error...`);
            await new Promise(resolve => setTimeout(resolve, 3000 * attempt));
          } else if (attempt >= maxAttempts) {
            throw error;
          }
        }
      }

      if (!hash) {
        throw new Error('Failed to send transaction after multiple attempts');
      }

      // Wait for the transaction to complete with increased timeout
      // Default to 90 seconds for testnet, which can be slow
      const waitTimeoutMs = params.waitTimeoutMs || 90_000;
      console.log(`Waiting up to ${waitTimeoutMs / 1000} seconds for transaction confirmation...`);

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
            error.message?.includes('HTTP request failed') &&
            error.message?.includes('Status: 429');

          if (is429Error && receiptAttempt < maxReceiptAttempts) {
            console.warn(
              `Rate limited (429) while waiting for receipt. Retrying in ${receiptBackoffMs}ms... (Attempt ${receiptAttempt}/${maxReceiptAttempts})`
            );

            // Wait with exponential backoff
            await new Promise(resolve => setTimeout(resolve, receiptBackoffMs));

            // Increase backoff for next attempt
            receiptBackoffMs = Math.min(receiptBackoffMs * 1.5 * (1 + 0.2 * Math.random()), 15000);
          } else {
            console.log(
              `Receipt attempt ${receiptAttempt}/${maxReceiptAttempts} failed. Retrying...`
            );

            // If we've reached max attempts, rethrow the error
            if (receiptAttempt >= maxReceiptAttempts) {
              console.error(`Transaction was sent with hash ${hash} but confirmation timed out.`);
              console.error(
                `You can check the transaction status manually at: https://sepolia.basescan.org/tx/${hash}`
              );
              throw error;
            }

            // Wait a bit longer before retrying
            await new Promise(resolve => setTimeout(resolve, 5000 * receiptAttempt));
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
          error.message?.includes('HTTP request failed') && error.message?.includes('Status: 429');

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
        await new Promise(resolve => setTimeout(resolve, backoffMs));

        // Increase backoff for next attempt (exponential with some randomness)
        backoffMs = Math.min(backoffMs * 1.5 * (1 + 0.2 * Math.random()), 15000);
        retryCount++;
      }
    }
  }

  // Helper to ensure addresses are properly formatted
  private formatAddress(address: Address): Address {
    return ethers.getAddress(address) as Address;
  }

  /**
   * Generate EIP-712 signature for claim data
   */
  async generateClaimSignature(claimData: ClaimData, poolAddress: Address): Promise<`0x${string}`> {
    if (!this.walletClient.account) {
      throw new Error('Wallet account not available');
    }

    // Add retry logic for RPC calls
    let retryCount = 0;
    const maxRetries = 3;
    let backoffMs = 1000;

    while (retryCount <= maxRetries) {
      try {
        const chainId = await this.publicClient.getChainId();

        const domain = {
          name: this.SIGNING_DOMAIN,
          version: this.SIGNATURE_VERSION,
          chainId: chainId,
          verifyingContract: poolAddress,
        };

        const types = {
          ClaimData: [
            { name: 'user', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'tokenAddress', type: 'address' },
            { name: 'tokenType', type: 'uint8' },
          ],
        };

        return this.walletClient.signTypedData({
          account: this.walletClient.account,
          domain,
          types,
          primaryType: 'ClaimData',
          message: claimData,
        });
      } catch (error: any) {
        // Check if this is a rate limit error (HTTP 429)
        const is429Error =
          error.message?.includes('HTTP request failed') && error.message?.includes('Status: 429');

        if (is429Error && retryCount < maxRetries) {
          console.warn(
            `Rate limited (429) during signature generation. Retrying in ${backoffMs}ms... (Attempt ${
              retryCount + 1
            }/${maxRetries})`
          );

          // Wait with exponential backoff
          await new Promise(resolve => setTimeout(resolve, backoffMs));

          // Increase backoff for next attempt
          backoffMs = Math.min(backoffMs * 1.5 * (1 + 0.2 * Math.random()), 10000);
          retryCount++;
        } else {
          throw error;
        }
      }
    }

    throw new Error('Failed to generate signature after multiple attempts');
  }

  /**
   * Factory methods
   */

  /**
   * Create a new reward pool
   */
  async createRewardPool({ name, description }: { name: string; description: string }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'createRewardPool',
      args: [name, description],
    });

    console.log('Transaction sent successfully. Hash:', tx);

    // Get transaction receipt to find the pool address from event
    const receipt = await this.publicClient.waitForTransactionReceipt({
      hash: tx,
    });

    console.log('Transaction receipt status:', receipt.status);
    console.log('Total logs in receipt:', receipt.logs.length);

    // Log all events for debugging
    receipt.logs.forEach((log, index) => {
      console.log(`Log ${index}:`, {
        address: log.address,
        topics: log.topics,
        data: log.data,
      });
    });

    // Look for the PoolCreated event
    // Event signature: PoolCreated(uint256 indexed poolId, address indexed pool, string name, string description)
    const poolCreatedEventHash =
      '0xaecc11792b43fbaf646e780661f7ece62df2de577db695f2afa589709709bab1';
    const event = receipt.logs.find(log => log.topics[0] === poolCreatedEventHash);

    if (!event) {
      console.error('Failed to find pool creation event in transaction logs');
      console.error('Expected event hash:', poolCreatedEventHash);
      console.error(
        'Available events:',
        receipt.logs.map(log => log.topics[0])
      );
      throw new Error('Pool creation event not found in logs');
    }

    // Extract pool ID and address from event topics
    // topics[0] = event signature
    // topics[1] = poolId (indexed)
    // topics[2] = pool address (indexed)
    const poolId = BigInt(event.topics[1] || '0');
    const poolAddress = this.formatAddress(('0x' + event.topics[2]?.slice(26)) as Address);

    console.log('Extracted pool ID:', poolId.toString());
    console.log('Extracted pool address:', poolAddress);

    return { tx, poolId, poolAddress };
  }

  /**
   * Add a user to a reward pool with XP
   */
  async addUser({ poolId, userAddress, xp }: { poolId: bigint; userAddress: Address; xp: bigint }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'addUser',
      args: [poolId, this.formatAddress(userAddress), xp],
    });

    return { tx };
  }

  /**
   * Update user XP (only before pool activation)
   */
  async updateUserXP({
    poolId,
    userAddress,
    newXP,
  }: {
    poolId: bigint;
    userAddress: Address;
    newXP: bigint;
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'updateUserXP',
      args: [poolId, this.formatAddress(userAddress), newXP],
    });

    return { tx };
  }

  /**
   * Penalize user by reducing XP (only before pool activation)
   */
  async penalizeUser({
    poolId,
    userAddress,
    xpToRemove,
  }: {
    poolId: bigint;
    userAddress: Address;
    xpToRemove: bigint;
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'penalizeUser',
      args: [poolId, this.formatAddress(userAddress), xpToRemove],
    });

    return { tx };
  }

  /**
   * Add rewards to a pool (complex method with potential issues)
   */
  async addRewards({
    poolId,
    tokenAddress,
    amount,
    tokenType,
    value,
    bypassSimulation,
  }: {
    poolId: bigint;
    tokenAddress: Address;
    amount: bigint;
    tokenType: TokenType;
    value?: bigint;
    bypassSimulation?: boolean;
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'addRewards',
      args: [poolId, this.formatAddress(tokenAddress), amount, tokenType],
      value: tokenType === TokenType.ERC20 ? value || amount : undefined,
      bypassSimulation,
    });

    return { tx };
  }

  /**
   * Activate a reward pool (locks XP values)
   */
  async activatePool({ poolId }: { poolId: bigint }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'activatePool',
      args: [poolId],
    });

    return { tx };
  }

  /**
   * Deactivate a reward pool
   */
  async deactivatePool({ poolId }: { poolId: bigint }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'deactivatePool',
      args: [poolId],
    });

    return { tx };
  }

  /**
   * Take a snapshot of current balances for reward distribution
   * This must be called after activating a pool for users to be able to claim
   */
  async takeSnapshot({
    poolId,
    tokenAddresses = [],
  }: {
    poolId: bigint;
    tokenAddresses?: Address[];
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'takeSnapshot',
      args: [poolId, tokenAddresses],
    });

    return { tx };
  }

  /**
   * Take a snapshot of only native ETH for reward distribution
   * This is simpler when you only need to snapshot ETH rewards
   */
  async takeNativeSnapshot({ poolId }: { poolId: bigint }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'takeNativeSnapshot',
      args: [poolId],
    });

    return { tx };
  }

  /**
   * Grant signer role to an address
   */
  async grantSignerRole({ poolId, signerAddress }: { poolId: bigint; signerAddress: Address }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'grantSignerRole',
      args: [poolId, this.formatAddress(signerAddress)],
    });

    return { tx };
  }

  /**
   * Revoke signer role from an address
   */
  async revokeSignerRole({ poolId, signerAddress }: { poolId: bigint; signerAddress: Address }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'revokeSignerRole',
      args: [poolId, this.formatAddress(signerAddress)],
    });

    return { tx };
  }

  /**
   * Emergency withdraw from a pool (admin only)
   */
  async emergencyWithdraw({
    poolId,
    tokenAddress,
    to,
    amount,
    tokenType,
  }: {
    poolId: bigint;
    tokenAddress: Address;
    to: Address;
    amount: bigint;
    tokenType: TokenType;
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'emergencyWithdraw',
      args: [poolId, this.formatAddress(tokenAddress), this.formatAddress(to), amount, tokenType],
    });

    return { tx };
  }

  /**
   * Pool methods
   */

  /**
   * Claim rewards from a pool using EIP-712 signature
   */
  async claimReward({
    poolAddress,
    claimData,
    signature,
  }: {
    poolAddress: Address;
    claimData: ClaimData;
    signature: `0x${string}`;
  }) {
    const tx = await this.signAndSendTransaction({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'claimReward',
      args: [claimData, signature],
    });

    return { tx };
  }

  /**
   * Helper method to claim rewards with automatic signature generation
   */
  async claimRewardWithSigner({
    poolAddress,
    userAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    userAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }) {
    // Get next nonce for user
    const nonce = await this.getNextNonce({
      poolAddress,
      userAddress,
    });

    // Create claim data
    const claimData: ClaimData = {
      user: this.formatAddress(userAddress),
      nonce,
      tokenAddress: this.formatAddress(tokenAddress),
      tokenType,
    };

    // Generate signature
    const signature = await this.generateClaimSignature(claimData, poolAddress);

    // Submit claim
    return await this.claimReward({
      poolAddress,
      claimData,
      signature,
    });
  }

  /**
   * Read methods
   */

  /**
   * Get pool information
   */
  async getPoolInfo({ poolId }: { poolId: bigint }): Promise<PoolInfo> {
    const result = await this.readContractWithRetry<any>({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'getPoolInfo',
      args: [poolId],
    });

    // The result is an object with named properties, not an array
    if (
      result &&
      typeof result === 'object' &&
      result.pool &&
      result.pool !== '0x0000000000000000000000000000000000000000'
    ) {
      const poolAddress = this.formatAddress(result.pool as Address);

      // Get additional info from the pool contract
      const [totalXP, userCount] = await Promise.all([
        this.getTotalXP({ poolAddress }),
        this.getUserCount({ poolAddress }),
      ]);

      return {
        name: result.name as string,
        description: result.description as string,
        active: result.active as boolean,
        totalXP,
        userCount,
      };
    }

    // If the pool address is zero, it means the pool doesn't exist
    if (
      result &&
      typeof result === 'object' &&
      result.pool === '0x0000000000000000000000000000000000000000'
    ) {
      throw new Error(`Pool with ID ${poolId} does not exist`);
    }

    throw new Error('Invalid PoolInfo data format');
  }

  /**
   * Get pool address by ID
   */
  async getPoolAddress({ poolId }: { poolId: bigint }): Promise<Address> {
    return this.readContractWithRetry<Address>({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'getPoolAddress',
      args: [poolId],
    });
  }

  /**
   * Get total number of pools (using s_nextPoolId)
   */
  async getPoolCount(): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 's_nextPoolId',
    });
  }

  /**
   * Check if user can claim rewards
   */
  async checkClaimEligibility({
    poolAddress,
    userAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    userAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<ClaimEligibility> {
    const result = await this.readContractWithRetry<any>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'checkClaimEligibility',
      args: [this.formatAddress(userAddress), this.formatAddress(tokenAddress), tokenType],
    });

    // ABI shows only 2 outputs: canClaim (bool) and allocation (uint256)
    if (Array.isArray(result) && result.length >= 2) {
      // Get userXP and totalXP separately
      const [userXP, totalXP] = await Promise.all([
        this.readContractWithRetry<bigint>({
          address: this.formatAddress(poolAddress),
          abi: rewardPoolAbi,
          functionName: 'getUserXP',
          args: [this.formatAddress(userAddress)],
        }),
        this.getTotalXP({ poolAddress }),
      ]);

      return {
        canClaim: result[0] as boolean,
        allocation: result[1] as bigint,
        userXP,
        totalXP,
      };
    }

    throw new Error('Invalid ClaimEligibility data format');
  }

  /**
   * Get user information
   */
  async getUserInfo({
    poolAddress,
    userAddress,
  }: {
    poolAddress: Address;
    userAddress: Address;
  }): Promise<UserInfo> {
    const [xp, isUser] = await Promise.all([
      this.readContractWithRetry<bigint>({
        address: this.formatAddress(poolAddress),
        abi: rewardPoolAbi,
        functionName: 's_userXP',
        args: [this.formatAddress(userAddress)],
      }),
      this.readContractWithRetry<boolean>({
        address: this.formatAddress(poolAddress),
        abi: rewardPoolAbi,
        functionName: 's_isUser',
        args: [this.formatAddress(userAddress)],
      }),
    ]);

    return {
      xp,
      isUser,
      hasClaimed: {}, // This would need to be populated by checking specific tokens
    };
  }

  /**
   * Check if user has claimed specific reward
   */
  async hasClaimed({
    poolAddress,
    userAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    userAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<boolean> {
    return this.readContractWithRetry<boolean>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'hasClaimed',
      args: [this.formatAddress(userAddress), this.formatAddress(tokenAddress), tokenType],
    });
  }

  /**
   * Get next nonce for user
   */
  async getNextNonce({
    poolAddress,
    userAddress,
  }: {
    poolAddress: Address;
    userAddress: Address;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'getNextNonce',
      args: [this.formatAddress(userAddress)],
    });
  }

  /**
   * Check if nonce is used by user
   */
  async isNonceUsed({
    poolAddress,
    userAddress,
    nonce,
  }: {
    poolAddress: Address;
    userAddress: Address;
    nonce: bigint;
  }): Promise<boolean> {
    return this.readContractWithRetry<boolean>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'isNonceUsed',
      args: [this.formatAddress(userAddress), nonce],
    });
  }

  /**
   * Get user nonce counter
   */
  async getUserNonceCounter({
    poolAddress,
    userAddress,
  }: {
    poolAddress: Address;
    userAddress: Address;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'getUserNonceCounter',
      args: [this.formatAddress(userAddress)],
    });
  }

  /**
   * Get total claimed for token type
   */
  async getTotalClaimed({
    poolAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'getTotalClaimed',
      args: [this.formatAddress(tokenAddress), tokenType],
    });
  }

  /**
   * Get available rewards for token type
   */
  async getAvailableRewards({
    poolAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'getAvailableRewards',
      args: [this.formatAddress(tokenAddress), tokenType],
    });
  }

  /**
   * Get reward balance information
   * Note: Uses getAvailableRewards with TokenType.ERC20 for reliable results
   */
  async getRewardBalance({
    poolAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<RewardBalance> {
    let totalRewards: bigint;

    if (tokenType === TokenType.ERC20) {
      // For ETH/native tokens, get the contract's ETH balance + already claimed with retry
      let contractBalance: bigint = 0n;
      let balanceAttempts = 0;
      const maxAttempts = 3;

      while (balanceAttempts < maxAttempts) {
        try {
          balanceAttempts++;
          contractBalance = await this.publicClient.getBalance({
            address: this.formatAddress(poolAddress),
          });
          break;
        } catch (error: any) {
          const is429Error =
            error.message?.includes('429') || error.message?.includes('rate limit');

          if (is429Error && balanceAttempts < maxAttempts) {
            console.warn(
              `Rate limited during balance check. Retrying in ${1000 * balanceAttempts}ms...`
            );
            await new Promise(resolve => setTimeout(resolve, 1000 * balanceAttempts));
          } else if (balanceAttempts >= maxAttempts) {
            console.warn(
              'Unable to get contract balance due to rate limiting. Using 0 as fallback.'
            );
            contractBalance = 0n;
            break;
          } else {
            throw error;
          }
        }
      }

      const totalClaimed = await this.getTotalClaimed({ poolAddress, tokenAddress, tokenType });
      totalRewards = contractBalance + totalClaimed;
    } else {
      // For ERC20 tokens, use getAvailableRewards with TokenType.ERC20
      // Note: Always use TokenType.ERC20 (1) as TokenType.ERC20 (0) has known issues
      const availableRewards = await this.readContractWithRetry<bigint>({
        address: this.formatAddress(poolAddress),
        abi: rewardPoolAbi,
        functionName: 'getAvailableRewards',
        args: [this.formatAddress(tokenAddress), TokenType.ERC20],
      });

      const totalClaimed = await this.getTotalClaimed({ poolAddress, tokenAddress, tokenType });
      totalRewards = availableRewards + totalClaimed;
    }

    const [totalClaimed, availableRewards] = await Promise.all([
      this.getTotalClaimed({ poolAddress, tokenAddress, tokenType }),
      this.getAvailableRewards({ poolAddress, tokenAddress, tokenType }),
    ]);

    return {
      tokenAddress: this.formatAddress(tokenAddress),
      tokenType,
      totalRewards,
      totalClaimed,
      availableRewards,
    };
  }

  /**
   * Get pool activity status
   */
  async isPoolActive({ poolAddress }: { poolAddress: Address }): Promise<boolean> {
    return this.readContractWithRetry<boolean>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 's_active',
    });
  }

  /**
   * Get total XP in pool
   */
  async getTotalXP({ poolAddress }: { poolAddress: Address }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 's_totalXP',
    });
  }

  /**
   * Get user count in pool (using getTotalUsers)
   */
  async getUserCount({ poolAddress }: { poolAddress: Address }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName: 'getTotalUsers',
    });
  }

  /**
   * Utility methods
   */

  /**
   * Get the factory address
   */
  get factoryAddress(): Address {
    return this.FACTORY_ADDRESS;
  }

  /**
   * Get EIP-712 domain for a pool
   */
  getEIP712Domain(poolAddress: Address) {
    return {
      name: this.SIGNING_DOMAIN,
      version: this.SIGNATURE_VERSION,
      chainId: this.chainId,
      verifyingContract: poolAddress,
    };
  }

  /**
   * Get EIP-712 types for ClaimData
   */
  getEIP712Types() {
    return {
      ClaimData: [
        { name: 'user', type: 'address' },
        { name: 'nonce', type: 'uint256' },
        { name: 'tokenAddress', type: 'address' },
        { name: 'tokenType', type: 'uint8' },
      ],
    };
  }

  /**
   * Batch operations for efficiency
   */

  /**
   * Add multiple users to a pool
   */
  async addMultipleUsers({
    poolId,
    users,
  }: {
    poolId: bigint;
    users: { address: Address; xp: bigint }[];
  }): Promise<{ tx: any }[]> {
    const transactions: { tx: any }[] = [];

    for (const user of users) {
      const result = await this.addUser({
        poolId,
        userAddress: user.address,
        xp: user.xp,
      });
      transactions.push(result);

      // Add delay between transactions to avoid rate limits
      await new Promise(resolve => setTimeout(resolve, 1000));
    }

    return transactions;
  }

  /**
   * Check multiple claim eligibilities
   */
  async checkMultipleClaimEligibilities({
    poolAddress,
    checks,
  }: {
    poolAddress: Address;
    checks: {
      userAddress: Address;
      tokenAddress: Address;
      tokenType: TokenType;
    }[];
  }): Promise<ClaimEligibility[]> {
    const results = await Promise.all(
      checks.map(check =>
        this.checkClaimEligibility({
          poolAddress,
          userAddress: check.userAddress,
          tokenAddress: check.tokenAddress,
          tokenType: check.tokenType,
        })
      )
    );

    return results;
  }

  /**
   * Get comprehensive pool status
   */
  async getPoolStatus({ poolId }: { poolId: bigint }): Promise<{
    info: PoolInfo;
    address: Address;
    isActive: boolean;
    totalXP: bigint;
    userCount: bigint;
  }> {
    const poolAddress = await this.getPoolAddress({ poolId });

    const [info, isActive, totalXP, userCount] = await Promise.all([
      this.getPoolInfo({ poolId }),
      this.isPoolActive({ poolAddress }),
      this.getTotalXP({ poolAddress }),
      this.getUserCount({ poolAddress }),
    ]);

    return {
      info,
      address: poolAddress,
      isActive,
      totalXP,
      userCount,
    };
  }

  /**
   * Check if an address has admin role
   */
  async hasAdminRole(address: Address): Promise<boolean> {
    const DEFAULT_ADMIN_ROLE = '0x0000000000000000000000000000000000000000000000000000000000000000';
    return this.readContractWithRetry<boolean>({
      address: this.FACTORY_ADDRESS,
      abi: [...rewardPoolFactoryAbi, ...rewardPoolAbi],
      functionName: 'hasRole',
      args: [DEFAULT_ADMIN_ROLE, this.formatAddress(address)],
    });
  }

  /**
   * Get current account address
   */
  get currentAccount(): Address {
    return this.walletClient.account?.address as Address;
  }

  /**
   * Read from a pool contract directly
   */
  async readPoolContract<T>({
    poolAddress,
    functionName,
    args = [],
  }: {
    poolAddress: Address;
    functionName: string;
    args?: any[];
  }): Promise<T> {
    return this.readContractWithRetry<T>({
      address: this.formatAddress(poolAddress),
      abi: rewardPoolAbi,
      functionName,
      args,
    });
  }

  /**
   * Get account balance
   */
  async getAccountBalance(address: Address): Promise<bigint> {
    return this.publicClient.getBalance({
      address: this.formatAddress(address),
    });
  }

  /**
   * Get public client for direct contract calls (debugging)
   */
  get client() {
    return this.publicClient;
  }

  /**
   * Send ETH rewards directly to a pool contract (simpler alternative to addRewards)
   */
  async sendETHToPool({ poolAddress, amount }: { poolAddress: Address; amount: bigint }) {
    if (!this.walletClient.account) {
      throw new Error('Wallet account not available');
    }

    // Get the chain configuration
    const { chain } = getContractsForChain(this.chainId).rewardPoolFactoryContract;

    // Send ETH directly to the pool contract
    const hash = await this.walletClient.sendTransaction({
      to: this.formatAddress(poolAddress),
      value: amount,
      account: this.walletClient.account,
      chain,
    });

    return { tx: hash };
  }

  /**
   * Check if a pool has taken a snapshot
   */
  async isSnapshotTaken({ poolAddress }: { poolAddress: Address }): Promise<boolean> {
    return this.readContractWithRetry<boolean>({
      address: poolAddress,
      abi: rewardPoolAbi,
      functionName: 's_snapshotTaken',
      args: [],
    });
  }

  /**
   * Get snapshot amount for a token type
   */
  async getSnapshotAmount({
    poolAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: poolAddress,
      abi: rewardPoolAbi,
      functionName: 'getSnapshotAmount',
      args: [this.formatAddress(tokenAddress), tokenType],
    });
  }

  /**
   * Get total rewards (snapshot + claimed)
   */
  async getTotalRewards({
    poolAddress,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    tokenAddress: Address;
    tokenType: TokenType;
  }): Promise<bigint> {
    return this.readContractWithRetry<bigint>({
      address: poolAddress,
      abi: rewardPoolAbi,
      functionName: 'getTotalRewards',
      args: [this.formatAddress(tokenAddress), tokenType],
    });
  }
}
