import { Address, PublicClient, WalletClient } from "viem";
import { creatorRewardPoolAbi, creatorRewardPoolFactoryAbi } from "../abis";
import { createViemClients, getContractsForChain } from "./viem";

export enum CreatorTokenType {
  ERC20 = 0,
  NATIVE = 1,
}

export type CreatorClaimData = {
  user: Address;
  nonce: bigint;
  tokenAddress: Address;
  tokenType: CreatorTokenType;
};

export class CreatorRewardPoolSDK {
  private publicClient!: PublicClient;
  private walletClient!: WalletClient;
  private chainId: number;
  private FACTORY_ADDRESS!: Address;

  constructor(chainId: number) {
    this.chainId = chainId;
  }

  async initialize() {
    const { publicClient, walletClient } = await createViemClients(
      this.chainId
    );
    this.publicClient = publicClient;
    this.walletClient = walletClient;

    const contracts = getContractsForChain(this.chainId);
    this.FACTORY_ADDRESS = contracts.creatorRewardPoolFactoryContract.address;
  }

  async createCreatorPool({
    creator,
    name,
    description,
    protocolFeeBps,
  }: {
    creator: Address;
    name: string;
    description: string;
    protocolFeeBps?: number; // 0-1000
  }) {
    const chain =
      getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain;
    let hash: `0x${string}`;
    if (protocolFeeBps === undefined) {
      hash = await this.walletClient.writeContract({
        address: this.FACTORY_ADDRESS,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "createCreatorRewardPool",
        args: [creator, name, description] as const,
        account: this.walletClient.account!,
        chain,
      });
    } else if (protocolFeeBps === 0) {
      hash = await this.walletClient.writeContract({
        address: this.FACTORY_ADDRESS,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "createCreatorRewardPoolWithoutFee",
        args: [creator, name, description] as const,
        account: this.walletClient.account!,
        chain,
      });
    } else {
      hash = await this.walletClient.writeContract({
        address: this.FACTORY_ADDRESS,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "createCreatorRewardPoolWithCustomFee",
        args: [creator, name, description, BigInt(protocolFeeBps)] as const,
        account: this.walletClient.account!,
        chain,
      });
    }
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
    return { tx: hash, receipt };
  }

  async addUser({
    creator,
    user,
    allocation,
  }: {
    creator: Address;
    user: Address;
    allocation: bigint;
  }) {
    const hash = await this.walletClient.writeContract({
      address: this.FACTORY_ADDRESS,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "addUser",
      args: [creator, user, allocation],
      account: this.walletClient.account!,
      chain: getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain,
    });
    return { tx: hash };
  }

  async activateCreatorPool({ creator }: { creator: Address }) {
    const hash = await this.walletClient.writeContract({
      address: this.FACTORY_ADDRESS,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "activateCreatorPool",
      args: [creator],
      account: this.walletClient.account!,
      chain: getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain,
    });
    return { tx: hash };
  }

  async checkClaimEligibility({
    poolAddress,
    user,
    tokenAddress,
    tokenType,
  }: {
    poolAddress: Address;
    user: Address;
    tokenAddress: Address;
    tokenType: CreatorTokenType;
  }) {
    const [canClaim, allocation, protocolFee] =
      (await this.publicClient.readContract({
        address: poolAddress,
        abi: creatorRewardPoolAbi as any,
        functionName: "checkClaimEligibility",
        args: [user, tokenAddress, tokenType],
      })) as any;
    return {
      canClaim,
      allocation: allocation as bigint,
      protocolFee: protocolFee as bigint,
    };
  }

  async claimReward({
    poolAddress,
    claimData,
    signature,
  }: {
    poolAddress: Address;
    claimData: CreatorClaimData;
    signature: `0x${string}`;
  }) {
    const hash = await this.walletClient.writeContract({
      address: poolAddress,
      abi: creatorRewardPoolAbi as any,
      functionName: "claimReward",
      args: [claimData, signature],
      account: this.walletClient.account!,
      chain: getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain,
    });
    return { tx: hash };
  }

  async claimRewardFor({
    poolAddress,
    claimData,
    signature,
  }: {
    poolAddress: Address;
    claimData: CreatorClaimData;
    signature: `0x${string}`;
  }) {
    const hash = await this.walletClient.writeContract({
      address: poolAddress,
      abi: creatorRewardPoolAbi as any,
      functionName: "claimRewardFor",
      args: [claimData, signature],
      account: this.walletClient.account!,
      chain: getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain,
    });
    return { tx: hash };
  }

  async claimRewardForViaFactory({
    creator,
    claimData,
    signature,
  }: {
    creator: Address;
    claimData: CreatorClaimData;
    signature: `0x${string}`;
  }) {
    const hash = await this.walletClient.writeContract({
      address: this.FACTORY_ADDRESS,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "claimRewardFor",
      args: [creator, claimData, signature],
      account: this.walletClient.account!,
      chain: getContractsForChain(this.chainId).creatorRewardPoolFactoryContract.chain,
    });
    return { tx: hash };
  }
}
