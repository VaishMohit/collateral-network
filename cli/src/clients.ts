import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import type { Deployment } from "./config.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
// __dirname is cli/dist (or cli/src in dev); repo root is two levels up.
const repoRoot = join(__dirname, "..", "..");

export type Abi = unknown[];

function loadContractJson(name: string): { abi: Abi } {
  // Foundry writes artifacts to <repoRoot>/out/<Name>.sol/<Name>.json.
  const c = resolve(repoRoot, `out/${name}.sol/${name}.json`);
  try {
    return JSON.parse(readFileSync(c, "utf-8")) as { abi: Abi };
  } catch (e) {
    throw new Error(`Could not load ABI for ${name} at ${c}. Run 'forge build' first. (${(e as Error).message})`);
  }
}

export interface Clients {
  publicClient: ReturnType<typeof createPublicClient>;
  walletProvider: ReturnType<typeof createWalletClient>;
  walletOperator: ReturnType<typeof createWalletClient>;
  deployment: Deployment;
  marginManagerAbi: Abi;
  oracleAbi: Abi;
  abiOf: (name: string) => Abi;
}

export function buildClients(rpcUrl: string, providerKey: string, operatorKey: string, deployment: Deployment): Clients {
  const publicClient = createPublicClient({
    chain: foundry,
    transport: http(rpcUrl),
  });

  const walletProvider = createWalletClient({
    chain: foundry,
    account: privateKeyToAccount(providerKey as `0x${string}`),
    transport: http(rpcUrl),
  });

  const walletOperator = createWalletClient({
    chain: foundry,
    account: privateKeyToAccount(operatorKey as `0x${string}`),
    transport: http(rpcUrl),
  });

  const fileName = (camel: string) => {
    // Convert marginManager -> MarginManager etc.
    return camel.charAt(0).toUpperCase() + camel.slice(1);
  };

  return {
    publicClient,
    walletProvider,
    walletOperator,
    deployment,
    marginManagerAbi: loadContractJson("MarginManager").abi,
    oracleAbi: loadContractJson("ValuationOracle").abi,
    abiOf: (name: string) => loadContractJson(fileName(name)).abi,
  };
}
