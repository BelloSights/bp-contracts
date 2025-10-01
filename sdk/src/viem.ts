import dotenv from "dotenv";
import path from "path";
import {
  createThirdwebClient,
  defineChain as defineChainThirdweb,
  getRpcClient,
} from "thirdweb";
import {
  Account,
  Address,
  Chain,
  ChainContract,
  createPublicClient,
  createWalletClient,
  defineChain,
  EIP1193RequestFn,
  EIP1474Methods,
  http,
  PublicClient,
  Transport,
  WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { blueprintERC1155FactoryAbi, rewardPoolFactoryAbi } from "../abis";

dotenv.config({
  path: path.resolve(__dirname, "../../.env"),
});

export const TOKEN_TYPES = {
  ERC20: 0,
  ERC721: 1,
  ERC1155: 2,
  NATIVE: 3,
} as const;

export const QUEST_TYPES = {
  QUEST: 0,
  STREAK: 1,
} as const;

export const DIFFICULTIES = {
  BEGINNER: 0,
  INTERMEDIATE: 1,
  ADVANCED: 2,
} as const;

export type Incentive = {
  questId: bigint;
  nonce: bigint;
  toAddress: Address;
  walletProvider: string;
  embedOrigin: string;
  transactions: { txHash: string; networkChainId: string }[];
  reward: {
    tokenAddress: Address;
    chainId: bigint;
    amount: bigint;
    tokenId: bigint;
    tokenType: number;
    rakeBps: bigint;
    factoryAddress: Address;
  };
};

const PRIVATE_KEY = process.env.PRIVATE_KEY as `0x${string}`;
const BASE_SEPOLIA_RPC = process.env.BASE_SEPOLIA_RPC;
const INCENTIVE_PROXY_ADDRESS = process.env
  .INCENTIVE_PROXY_ADDRESS as `0x${string}`;
const FACTORY_PROXY_ADDRESS = process.env
  .FACTORY_PROXY_ADDRESS as `0x${string}`;
const STOREFRONT_PROXY_ADDRESS = process.env
  .STOREFRONT_PROXY_ADDRESS as `0x${string}`;
const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS as `0x${string}`;

if (!PRIVATE_KEY) {
  throw new Error("PRIVATE_KEY is not set");
}
if (!BASE_SEPOLIA_RPC) {
  throw new Error("BASE_SEPOLIA_RPC is not set");
}
if (!INCENTIVE_PROXY_ADDRESS) {
  throw new Error("INCENTIVE_PROXY_ADDRESS is not set");
}
if (!FACTORY_PROXY_ADDRESS) {
  throw new Error("FACTORY_PROXY_ADDRESS is not set");
}
if (!STOREFRONT_PROXY_ADDRESS) {
  throw new Error("STOREFRONT_PROXY_ADDRESS is not set");
}

// Define Base Sepolia chain configuration
export const baseSepolia = defineChain({
  id: 84532,
  name: "Base Sepolia",
  network: "base-sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: ["https://sepolia.base.org"],
    },
  },
  blockExplorers: {
    default: {
      name: "Basescan",
      url: "https://sepolia.basescan.org",
    },
  },
  testnet: true,
});

// Create clients
export const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(BASE_SEPOLIA_RPC),
});

export const walletClient = createWalletClient({
  chain: baseSepolia,
  transport: http(BASE_SEPOLIA_RPC),
  account: privateKeyToAccount(PRIVATE_KEY),
});

const clientId = process.env.THIRDWEB_CLIENT_ID;
const secretKey = process.env.THIRDWEB_SECRET_KEY;
if (!clientId || !secretKey) {
  throw new Error("THIRDWEB_CLIENT_ID and THIRDWEB_SECRET_KEY must be set");
}

export const THIRDWEB_CLIENT = createThirdwebClient({
  clientId: clientId,
  secretKey: secretKey,
});

// Create Viem Wallet and Public Clients
export const createViemClients = async (
  chainId: number
): Promise<{
  walletClient: WalletClient<Transport, Chain, Account>;
  publicClient: PublicClient<Transport, Chain>;
  rpcClient: EIP1193RequestFn<EIP1474Methods>;
}> => {
  const privateKey = process.env.PRIVATE_KEY_WITHOUT_0X;
  if (!privateKey) {
    throw new Error("PRIVATE_KEY must be set in your environment variables");
  }
  const viemConfig = getViemConfigFromChainId(chainId);

  const chain = defineChain(viemConfig);

  const publicClient = createPublicClient({
    chain: chain,
    transport: http(viemConfig.rpcUrls.default.http[0]),
  });

  const walletClient = createWalletClient({
    chain: chain,
    transport: http(viemConfig.rpcUrls.default.http[0]),
    account: privateKeyToAccount(`0x${privateKey}`),
  });

  const rpcClient = getRpcClient({
    client: THIRDWEB_CLIENT,
    chain: {
      id: chain.id,
      rpc: viemConfig.rpcUrls.default.http[0],
    },
  }) as EIP1193RequestFn<EIP1474Methods>;

  return { walletClient, publicClient, rpcClient };
};

// Get Viem Config from Chain ID
export const getViemConfigFromChainId = (chainId: number): Chain => {
  const thirdwebChain = defineChainThirdweb(chainId);
  const rpcUrl = thirdwebChain.rpc;
  if (!rpcUrl) {
    throw new Error(`No RPC URL found for chain ${chainId}`);
  }
  const viemConfig: Chain = {
    ...thirdwebChain,
    name: thirdwebChain.name || `Chain ${chainId}`,
    nativeCurrency: {
      name: thirdwebChain.nativeCurrency?.name || "ETH",
      symbol: thirdwebChain.nativeCurrency?.symbol || "ETH",
      decimals: thirdwebChain.nativeCurrency?.decimals || 18,
    },
    rpcUrls: {
      default: { http: [rpcUrl] },
      public: { http: [rpcUrl] },
    },
    blockExplorers: {
      default: {
        name: thirdwebChain.blockExplorers?.[0]?.name || "Default",
        url: thirdwebChain.blockExplorers?.[0]?.url || "",
      },
    },
    contracts: {
      multicall3:
        "0xcA11bde05977b3631167028862bE2a173976CA11" as unknown as ChainContract,
    },
    testnet: chainId === 84532 || chainId === 4457845,
  };
  return viemConfig;
};

// Function to get contract addresses based on chain ID
export const getContractAddresses = (chainId: number) => {
  let dropFactoryProxyAddress: `0x${string}`;
  let rewardPoolFactoryAddress: `0x${string}`;
  let creatorRewardPoolFactoryAddress: `0x${string}`;

  switch (chainId) {
    case 8453: // Base Mainnet
      dropFactoryProxyAddress = process.env
        .BASE_ERC1155_FACTORY_PROXY_ADDRESS as `0x${string}`;
      rewardPoolFactoryAddress = process.env
        .BASE_REWARD_POOL_FACTORY_PROXY_ADDRESS as `0x${string}`;
      creatorRewardPoolFactoryAddress = process.env
        .BASE_CREATOR_REWARD_POOL_FACTORY_PROXY_ADDRESS as `0x${string}`;
      break;
    case 84532: // Base Sepolia
      dropFactoryProxyAddress = process.env
        .BASE_SEPOLIA_ERC1155_FACTORY_PROXY_ADDRESS as `0x${string}`;
      rewardPoolFactoryAddress = process.env
        .BASE_SEPOLIA_REWARD_POOL_FACTORY_PROXY_ADDRESS as `0x${string}`;
      creatorRewardPoolFactoryAddress = process.env
        .BASE_SEPOLIA_CREATOR_REWARD_POOL_FACTORY_PROXY_ADDRESS as `0x${string}`;
      break;
    case 543210: // Zero Network
      dropFactoryProxyAddress = process.env
        .ZERO_ERC1155_FACTORY_PROXY_ADDRESS as `0x${string}`;
      rewardPoolFactoryAddress = process.env
        .ZERO_REWARD_POOL_FACTORY_ADDRESS as `0x${string}`;
      creatorRewardPoolFactoryAddress = process.env
        .ZERO_CREATOR_REWARD_POOL_FACTORY_ADDRESS as `0x${string}`;
      break;
    default:
      throw new Error(
        `Unsupported chain ID: ${chainId}. Only Base Mainnet (8453), Base Sepolia (84532), Zero Network (543210), and Zero Sepolia Testnet (4457845) are supported.`
      );
  }

  if (!dropFactoryProxyAddress) {
    throw new Error(
      `ERC1155_FACTORY_PROXY_ADDRESS for chain ID ${chainId} is not set`
    );
  }
  if (!rewardPoolFactoryAddress) {
    throw new Error(
      `REWARD_POOL_FACTORY_ADDRESS for chain ID ${chainId} is not set`
    );
  }
  if (!creatorRewardPoolFactoryAddress) {
    throw new Error(
      `CREATOR_REWARD_POOL_FACTORY_ADDRESS for chain ID ${chainId} is not set`
    );
  }

  return {
    dropFactoryProxyAddress,
    rewardPoolFactoryAddress,
    creatorRewardPoolFactoryAddress,
  };
};

// Function to create contract instances for any chain ID
export const getContractsForChain = (chainId: number) => {
  const chain = getViemConfigFromChainId(chainId);
  const { dropFactoryProxyAddress, rewardPoolFactoryAddress, creatorRewardPoolFactoryAddress } =
    getContractAddresses(chainId);

  return {
    dropFactoryContract: {
      address: dropFactoryProxyAddress,
      abi: blueprintERC1155FactoryAbi,
      chain,
    },
    rewardPoolFactoryContract: {
      address: rewardPoolFactoryAddress,
      abi: rewardPoolFactoryAbi,
      chain,
    },
    creatorRewardPoolFactoryContract: {
      address: creatorRewardPoolFactoryAddress,
      abi: rewardPoolFactoryAbi,
      chain,
    },
  };
};
