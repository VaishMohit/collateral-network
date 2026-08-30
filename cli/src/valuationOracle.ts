import { encodeAbiParameters, keccak256 } from "viem";
import type { Clients } from "./clients.js";
import type { Address } from "viem";

/**
 * Resolve a human asset name (e.g. "T-BOND-001") or raw 32-byte id to the
 * bytes32 asset id used on-chain.
 */
export function resolveAssetId(c: Clients, input: string): `0x${string}` {
  const trimmed = input.trim();
  if (trimmed.startsWith("0x")) {
    return (trimmed as `0x${string}`).padEnd(66, "0") as `0x${string}`;
  }
  const d = c.deployment as Record<string, unknown>;
  const assets = d["assets"] as Record<string, string> | undefined;
  const upper = trimmed.toUpperCase();
  if (assets) {
    for (const [k, v] of Object.entries(assets)) {
      if (k.toLowerCase() === `tBondAssetId`.toLowerCase() && upper.includes("T-BOND")) return v as `0x${string}`;
      if (k.toLowerCase() === `corpBondAssetId`.toLowerCase() && upper.includes("CORP")) return v as `0x${string}`;
    }
  }
  // Fall back to left-padding the ASCII bytes to 32 bytes.
  const hex = Buffer.from(trimmed, "utf8").toString("hex");
  return ("0x" + hex.padEnd(64, "0")) as `0x${string}`;
}

export async function getLatestPrice(c: Clients, assetId: `0x${string}`): Promise<{ price: bigint; timestamp: bigint }> {
  const raw = (await c.publicClient.readContract({
    address: c.deployment.valuationOracle as Address,
    abi: c.oracleAbi,
    functionName: "getLatestPrice",
    args: [assetId],
  })) as readonly [bigint, bigint];
  return { price: raw[0], timestamp: raw[1] };
}

/**
 * Submit a signed price update as the VALUATION_PROVIDER. Uses the oracle's
 * per-provider monotonic nonce (providerNonce + 1) and an ERC-191 signature so
 * it matches ValuationOracle.updatePrice exactly.
 */
export async function updatePrice(c: Clients, assetId: `0x${string}`, price: bigint): Promise<`0x${string}`> {
  const providerAddress = c.walletProvider.account!.address as Address;
  const currentNonce = (await c.publicClient.readContract({
    address: c.deployment.valuationOracle as Address,
    abi: c.oracleAbi,
    functionName: "providerNonce",
    args: [providerAddress],
  })) as bigint;
  const nonce = currentNonce + 1n;

  // Use the chain's current block time (not the local clock) so the freshly
  // submitted price is fresh relative to the node — the oracle rejects prices
  // older than MAX_PRICE_AGE.
  const block = await c.publicClient.getBlock();
  const timestamp = block.timestamp;
  // keccak256(abi.encode(assetId, price, timestamp, nonce))
  const hash = keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [assetId, price, timestamp, nonce],
    ),
  );

  const signature = (await (c.walletProvider.signMessage as any)({
    account: providerAddress,
    message: { raw: hash },
  })) as `0x${string}`;
  const { v, r, s } = splitSig(signature);

  const tx = (await (c.walletProvider.writeContract as any)({
    address: c.deployment.valuationOracle as Address,
    abi: c.oracleAbi,
    functionName: "updatePrice",
    args: [assetId, price, timestamp, v, r, s],
  })) as `0x${string}`;
  await c.publicClient.waitForTransactionReceipt({ hash: tx });
  return tx;
}

function splitSig(sig: `0x${string}`): { v: number; r: `0x${string}`; s: `0x${string}` } {
  const hex = sig.slice(2);
  const r = ("0x" + hex.slice(0, 64)) as `0x${string}`;
  const s = ("0x" + hex.slice(64, 128)) as `0x${string}`;
  const v = parseInt(hex.slice(128, 130), 16);
  return { v, r, s };
}
