import type { Clients } from "./clients.js";
import type { Address } from "viem";

export interface MarginEvaluation {
  isAdequate: boolean;
  shortfall: bigint;
  requiredValue: bigint;
  currentValue: bigint;
}

export interface MarginCallStatus {
  obligationId: string;
  requiredValue: bigint;
  currentValue: bigint;
  shortfall: bigint;
  createdAt: bigint;
  active: boolean;
  satisfied: boolean;
}

export interface MarginCallRecord {
  obligationId: string;
  shortfall: bigint;
  currentValue: bigint;
  requiredValue: bigint;
  timestamp: bigint;
  satisfied: boolean;
  cancelled: boolean;
}

const asEval = (r: MarginEvaluation): MarginEvaluation => r;

export async function evaluateMargin(c: Clients, obligationId: string): Promise<MarginEvaluation> {
  const r = (await c.publicClient.readContract({
    address: c.deployment.marginManager as Address,
    abi: c.marginManagerAbi,
    functionName: "evaluateMargin",
    args: [obligationId],
  })) as MarginEvaluation;
  return asEval(r);
}

export async function evaluateAll(c: Clients, obligationIds: string[]): Promise<MarginEvaluation[]> {
  const hash = (await (c.walletOperator.writeContract as any)({
    address: c.deployment.marginManager as Address,
    abi: c.marginManagerAbi,
    functionName: "evaluateAll",
    args: [obligationIds],
  })) as `0x${string}`;
  await c.publicClient.waitForTransactionReceipt({ hash });
  // Re-read per obligation to surface evaluations after the state change.
  const out: MarginEvaluation[] = [];
  for (const id of obligationIds) {
    out.push(await evaluateMargin(c, id));
  }
  return out;
}

export async function getMarginStatus(c: Clients, obligationId: string): Promise<MarginCallStatus> {
  return (await c.publicClient.readContract({
    address: c.deployment.marginManager as Address,
    abi: c.marginManagerAbi,
    functionName: "getMarginStatus",
    args: [obligationId],
  })) as MarginCallStatus;
}

export async function getMarginCallHistory(c: Clients, obligationId: string): Promise<MarginCallRecord[]> {
  return (await c.publicClient.readContract({
    address: c.deployment.marginManager as Address,
    abi: c.marginManagerAbi,
    functionName: "getMarginCallHistory",
    args: [obligationId],
  })) as MarginCallRecord[];
}

export async function getRequirement(c: Clients, obligationId: string): Promise<bigint> {
  return (await c.publicClient.readContract({
    address: c.deployment.marginManager as Address,
    abi: c.marginManagerAbi,
    functionName: "getRequirement",
    args: [obligationId],
  })) as bigint;
}
