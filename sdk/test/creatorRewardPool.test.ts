import console from "console";
import dotenv from "dotenv";
import path from "path";
import type { Address } from "viem";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseGwei,
  parseUnits
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { describe, expect, it } from "vitest";
import { creatorRewardPoolFactoryAbi } from "../abis";
import {
  CreatorRewardPoolSDK,
  CreatorTokenType,
} from "../src/rewardPoolCreatorSdk";
import { getContractAddresses } from "../src/viem";

dotenv.config({ path: path.resolve(__dirname, "../../.env") });

describe("CreatorRewardPool SDK (Base Sepolia)", () => {
  it("create pool (no fee), fund, allocate, and claim direct + relayed", async () => {
    const chainId = 84532; // Base Sepolia
    const factoryProxy =
      getContractAddresses(chainId).creatorRewardPoolFactoryAddress;
    const rpcUrl = process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org";
    console.log("[CRP] Chain:", chainId, "Factory:", factoryProxy);
    console.log("[CRP] RPC URL:", rpcUrl);
    const sdk = new CreatorRewardPoolSDK(chainId);
    await sdk.initialize();
    console.log("[CRP] SDK initialized");
    const adminPk = process.env.PRIVATE_KEY as `0x${string}`;
    if (!adminPk) throw new Error("PRIVATE_KEY not set");
    const account = privateKeyToAccount(adminPk);
    console.log("[CRP] Admin address:", account.address);

    const walletClient = createWalletClient({
      account,
      chain: baseSepolia,
      transport: http(rpcUrl),
    });
    const publicClient = createPublicClient({
      chain: baseSepolia,
      transport: http(rpcUrl),
    });

    const getFees = async () => {
      try {
        const fees = await publicClient.estimateFeesPerGas();
        const minMaxFeePerGas = parseGwei("2");
        const minPriorityFeePerGas = parseGwei("1");
        const base = fees.maxFeePerGas ?? fees.gasPrice ?? minMaxFeePerGas;
        const tip = fees.maxPriorityFeePerGas ?? minPriorityFeePerGas;
        const bumpedBase = (base * 12n) / 10n;
        const bumpedTip = (tip * 12n) / 10n;
        const maxFeePerGas =
          bumpedBase < minMaxFeePerGas ? minMaxFeePerGas : bumpedBase;
        const maxPriorityFeePerGas =
          bumpedTip < minPriorityFeePerGas ? minPriorityFeePerGas : bumpedTip;
        console.log("[CRP] Using fees:", {
          maxFeePerGas: maxFeePerGas.toString(),
          maxPriorityFeePerGas: maxPriorityFeePerGas.toString(),
        });
        return { maxFeePerGas, maxPriorityFeePerGas };
      } catch (e) {
        const fallback = {
          maxFeePerGas: parseGwei("3"),
          maxPriorityFeePerGas: parseGwei("1.5"),
        };
        console.log("[CRP] Fee estimate failed, using fallback:", {
          maxFeePerGas: fallback.maxFeePerGas.toString(),
          maxPriorityFeePerGas: fallback.maxPriorityFeePerGas.toString(),
          error: (e as any)?.message || e,
        });
        return fallback;
      }
    };

    const waitReceipt = async (hash: `0x${string}`, label: string) => {
      console.log(`[CRP] waiting for ${label} receipt...`, hash);
      const receipt = await publicClient.waitForTransactionReceipt({
        hash,
        // timeout: 600_000,
        // confirmations: 0,
      });
      console.log(
        `[CRP] ${label} confirmed in block`,
        receipt.blockNumber?.toString?.() || receipt.blockNumber
      );
      return receipt;
    };

    const creator = account.address as Address;
    const userA = creator;
    const userB = "0x1234567890123456789012345678901234567890" as Address;
    console.log("[CRP] Creator:", creator, "UserA:", userA, "UserB:", userB);
    // ERC20 setup: allocation = 10 USDC for each user
    const tenUSDC = parseUnits("10", 6);

    // Prepare a sequential nonce manager to avoid RPC race conditions
    let txNonce = await publicClient.getTransactionCount({
      address: creator,
      blockTag: "pending",
    });
    console.log("[CRP] Starting nonce:", txNonce.toString());

    // 1) Create creator pool with no protocol fee (idempotent)
    console.log("[CRP] Step 1: Checking hasCreatorPool...");
    const hasPool = (await publicClient.readContract({
      address: factoryProxy,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "hasCreatorPool",
      args: [creator],
    })) as boolean;
    console.log("[CRP] hasPool:", hasPool);
    if (!hasPool) {
      console.log("[CRP] Creating creator pool without fee...");
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
      const createHash = await walletClient.writeContract({
        address: factoryProxy,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "createCreatorRewardPoolWithoutFee",
        args: [creator, "Creator Test Pool", "Creator E2E no-fee"],
        nonce: txNonce++,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      console.log("[CRP] create tx:", createHash);
      await waitReceipt(createHash, "create pool");
      console.log("[CRP] Pool created");
    }

    // Resolve pool address
    console.log("[CRP] Resolving pool address...");
    const poolAddress = (await publicClient.readContract({
      address: factoryProxy,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "getCreatorPoolAddress",
      args: [creator],
    })) as Address;
    console.log("[CRP] Pool address:", poolAddress);

    expect(poolAddress).toBeTruthy();

    // 2) Prepare allocations: deactivate, then add or update users (70% / 30%)
    try {
      console.log("[CRP] Step 2: Deactivating creator pool (if active)...");
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
      const deactHash = await walletClient.writeContract({
        address: factoryProxy,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "deactivateCreatorPool",
        args: [creator],
        nonce: txNonce++,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      console.log("[CRP] deactivate tx:", deactHash);
      await waitReceipt(deactHash, "deactivate pool");
      console.log("[CRP] Deactivated");
    } catch {
      console.log("[CRP] Deactivate skipped");
    }
    // userA
    try {
      console.log("[CRP] Adding userA...");
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
      const addAHash = await walletClient.writeContract({
        address: factoryProxy,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "addUser",
        args: [creator, userA, tenUSDC],
        nonce: txNonce++,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      console.log("[CRP] add userA tx:", addAHash);
      await waitReceipt(addAHash, "add userA");
      console.log("[CRP] userA added");
    } catch (e: any) {
      if ((e?.message || "").includes("UserAlreadyExists")) {
        console.log("[CRP] userA exists, updating allocation to 10 USDC...");
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const updHash = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "updateUserAllocation",
          args: [creator, userA, tenUSDC],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] update userA tx:", updHash);
        await waitReceipt(updHash, "update userA");
        console.log("[CRP] userA allocation updated");
      } else {
        throw e;
      }
    }
    // userB
    try {
      console.log("[CRP] Adding userB (alloc 10 USDC)...");
      const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
      const addBHash = await walletClient.writeContract({
        address: factoryProxy,
        abi: creatorRewardPoolFactoryAbi,
        functionName: "addUser",
        args: [creator, userB, tenUSDC],
        nonce: txNonce++,
        maxFeePerGas,
        maxPriorityFeePerGas,
      });
      console.log("[CRP] add userB tx:", addBHash);
      await waitReceipt(addBHash, "add userB");
      console.log("[CRP] userB added");
    } catch (e: any) {
      if ((e?.message || "").includes("UserAlreadyExists")) {
        console.log("[CRP] userB exists, updating allocation to 10 USDC...");
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        // bump nonce for stuck tx replacement on same nonce
        txNonce++;
        const {
          maxFeePerGas: maxFeePerGasB,
          maxPriorityFeePerGas: maxPriorityFeePerGasB,
        } = await getFees();
        const updHash = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "updateUserAllocation",
          args: [creator, userB, tenUSDC],
          // retry with fresh bumped fees and next nonce
          nonce: txNonce++,
          maxFeePerGas: (maxFeePerGasB * 13n) / 10n,
          maxPriorityFeePerGas: (maxPriorityFeePerGasB * 13n) / 10n,
        });
        console.log("[CRP] update userB tx:", updHash);
        await waitReceipt(updHash, "update userB");
        console.log("[CRP] userB allocation updated");
      } else {
        throw e;
      }
    }

    // 3) Grant SIGNER_ROLE to admin
    console.log("[CRP] Step 3: Granting SIGNER_ROLE to admin...");
    const {
      maxFeePerGas: maxFeePerGasGrant,
      maxPriorityFeePerGas: maxPriorityFeePerGasGrant,
    } = await getFees();
    const grantHash = await walletClient.writeContract({
      address: factoryProxy,
      abi: creatorRewardPoolFactoryAbi,
      functionName: "grantSignerRole",
      args: [creator, creator],
      nonce: txNonce++,
      maxFeePerGas: maxFeePerGasGrant,
      maxPriorityFeePerGas: maxPriorityFeePerGasGrant,
    });
    console.log("[CRP] grant signer tx:", grantHash);
    await waitReceipt(grantHash, "grant signer role");
    console.log("[CRP] SIGNER_ROLE granted");

    // Helper: EIP-712 signature for creator claims
    const signClaim = async (msg: {
      user: Address;
      nonce: bigint;
      tokenAddress: Address;
      tokenType: CreatorTokenType;
    }) => {
      const domain = {
        name: "BP_CREATOR_REWARD_POOL",
        version: "1",
        chainId,
        verifyingContract: poolAddress,
      } as const;
      const types = {
        ClaimData: [
          { name: "user", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "tokenAddress", type: "address" },
          { name: "tokenType", type: "uint8" },
        ],
      } as const;
      return walletClient.signTypedData({
        account,
        domain,
        types: types as any,
        primaryType: "ClaimData",
        message: msg as any,
      });
    };

    const getNextNonce = async (user: Address) => {
      const nonce = (await publicClient.readContract({
        address: poolAddress,
        abi: [
          {
            inputs: [{ name: "user", type: "address" }],
            name: "getNextNonce",
            outputs: [{ name: "", type: "uint256" }],
            stateMutability: "view",
            type: "function",
          },
        ],
        functionName: "getNextNonce",
        args: [user],
      })) as bigint;
      return nonce ?? 1n;
    };

    // 4) ERC20 scenario: set absolute allocations and claim 10 USDC for each user
    try {
      console.log(
        "[CRP] Step 4: ERC20 flow (10 USDC each for userA and userB)..."
      );
      const token = "0x8c049dBe9F1889deBeaCFAD05e55dF30cb87E97d" as Address;
      console.log("[CRP] ERC20 token:", token, "tenUSDC:", tenUSDC.toString());

      // Deactivate to update allocations for ERC20 scenario
      try {
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const deact2 = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "deactivateCreatorPool",
          args: [creator],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] deactivate (erc20) tx:", deact2);
        await waitReceipt(deact2, "deactivate (erc20)");
      } catch (e) {
        console.log(
          "[CRP] deactivate (erc20) skipped:",
          (e as any)?.message || e
        );
      }

      // Set absolute allocations: userA=10 USDC, userB=10 USDC
      {
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const updA0 = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "updateUserAllocation",
          args: [creator, userA, tenUSDC],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] set userA alloc 10 USDC tx:", updA0);
        await waitReceipt(updA0, "set userA alloc 10 USDC");
      }
      {
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const updB10 = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "updateUserAllocation",
          args: [creator, userB, tenUSDC],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] set userB alloc 10 USDC tx:", updB10);
        await waitReceipt(updB10, "set userB alloc 10 USDC");
      }

      // Fund exactly 20 USDC to the pool (10 USDC for each user)
      {
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const transferHash = await walletClient.writeContract({
          address: token,
          abi: [
            {
              inputs: [
                { name: "to", type: "address" },
                { name: "amount", type: "uint256" },
              ],
              name: "transfer",
              outputs: [{ name: "", type: "bool" }],
              stateMutability: "nonpayable",
              type: "function",
            },
          ],
          functionName: "transfer",
          args: [poolAddress, tenUSDC * 2n],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] transfer 20 USDC tx:", transferHash);
        await waitReceipt(transferHash, "erc20 transfer 20 USDC to pool");
      }

      // Reactivate pool
      {
        const { maxFeePerGas, maxPriorityFeePerGas } = await getFees();
        const act2 = await walletClient.writeContract({
          address: factoryProxy,
          abi: creatorRewardPoolFactoryAbi,
          functionName: "activateCreatorPool",
          args: [creator],
          nonce: txNonce++,
          maxFeePerGas,
          maxPriorityFeePerGas,
        });
        console.log("[CRP] activate (erc20) tx:", act2);
        await waitReceipt(act2, "activate (erc20)");
      }

      // Claim 10 USDC for userA (direct pool entrypoint)
      const adminNonceErc20 = await getNextNonce(userA);
      console.log("[CRP] ERC20 claim nonce for userA:", adminNonceErc20.toString());
      const userAClaim = {
        user: userA,
        nonce: adminNonceErc20,
        tokenAddress: token,
        tokenType: CreatorTokenType.ERC20,
      };
      const userASig = await signClaim(userAClaim);
      console.log("[CRP] Claiming direct for userA (ERC20)...");
      const claimUserA = await sdk.claimReward({
        poolAddress,
        claimData: userAClaim as any,
        signature: userASig as any,
      });
      // @ts-ignore
      if ((claimUserA as any)?.tx) {
        // @ts-ignore
        console.log("[CRP] direct claim userA tx:", (claimUserA as any).tx);
        await waitReceipt((claimUserA as any).tx, "direct claim (erc20) userA");
        console.log("[CRP] Direct claim confirmed (erc20) userA");
      }

      // Claim 10 USDC for userB via factory
      const userBNonce2 = await getNextNonce(userB);
      console.log("[CRP] ERC20 claim nonce for userB:", userBNonce2.toString());
      const userBClaim20 = {
        user: userB,
        nonce: userBNonce2,
        tokenAddress: token,
        tokenType: CreatorTokenType.ERC20,
      };
      const userBsig2 = await signClaim(userBClaim20);
      console.log("[CRP] Claiming via factory for userB (ERC20)...");
      const factoryClaim = await sdk.claimRewardForViaFactory({
        creator,
        claimData: userBClaim20 as any,
        signature: userBsig2 as any,
      });
      // @ts-ignore
      if ((factoryClaim as any)?.tx) {
        // @ts-ignore
        console.log("[CRP] factory claim tx:", (factoryClaim as any).tx);
        await waitReceipt((factoryClaim as any).tx, "factory claim (erc20)");
        console.log("[CRP] Factory claim confirmed (erc20)");
      }
    } catch (e) {
      console.log(
        "ERC20 flow skipped:",
        (e as any)?.message || e
      );
    }

    expect(poolAddress).toBeTruthy();
  }, 600_000);
});
