import "dotenv/config";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface Deployment {
  marginManager: string;
  valuationOracle: string;
  tBondToken: string;
  corpBondToken: string;
  chainId: number;
  [key: string]: unknown;
}

interface LoadedConfig {
  rpcUrl: string;
  providerKey: string;
  operatorKey: string;
  assetId: string;
  obligationId: string;
  deploymentPath: string;
  deployment: Deployment;
}

export interface Config extends LoadedConfig {}

function loadDeployment(path: string): Deployment {
  // Anchor relative to the repo root (deploymentDir), not cwd.
  const full = resolve(path);
  return JSON.parse(readFileSync(full, "utf-8")) as Deployment;
}

export function getConfig(opts: { rpcUrl?: string; providerKey?: string; operatorKey?: string }): Config {
  // deploymentDir is the repo root (parent of cli/); anchor the deployment file there.
  const repoRoot = deploymentDir;
  const relative = process.env.DEPLOY_JSON ?? "deployments/anvil.json";
  const deploymentPath = resolve(repoRoot, relative);

  let loaded: Deployment;
  try {
    loaded = loadDeployment(deploymentPath);
  } catch (e) {
    throw new Error(
      `Could not load deployment JSON at ${deploymentPath} (set DEPLOY_JSON or run 'forge script script/Deploy.s.sol' first): ${(e as Error).message}`,
    );
  }

  const providerKey =
    opts.providerKey ?? process.env.VALUATION_PROVIDER_KEY ?? "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e";
  const operatorKey =
    opts.operatorKey ?? process.env.COLLATERAL_AGENT_KEY ?? "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba";

  return {
    rpcUrl: opts.rpcUrl ?? process.env.RPC_URL ?? "http://127.0.0.1:8545",
    providerKey,
    operatorKey,
    assetId: process.env.ASSET_ID ?? "T-BOND-001",
    obligationId: process.env.OBLIGATION_ID ?? "",
    deploymentPath,
    deployment: loaded,
  };
}

export { loadDeployment };
export const deploymentDir = join(__dirname, "..", "..");
