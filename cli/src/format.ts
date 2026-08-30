import chalk from "chalk";
import type { MarginEvaluation, MarginCallStatus, MarginCallRecord } from "./marginManager.js";

export function usd(cents: bigint): string {
  const c = Number(cents);
  const sign = c < 0 ? "-" : "";
  const abs = Math.abs(c);
  const dollars = Math.floor(abs / 100);
  const rem = abs % 100;
  return `$${sign}${dollars}.${rem.toString().padStart(2, "0")}`;
}

export function printEvaluation(e: MarginEvaluation): void {
  const status = e.isAdequate ? chalk.green("ADEQUATE") : chalk.yellow("SHORTFALL");
  console.log(`  requirement : ${usd(e.requiredValue)}`);
  console.log(`  collateral  : ${usd(e.currentValue)}`);
  console.log(`  shortfall   : ${usd(e.shortfall)}`);
  console.log(`  status      : ${status}`);
}

export function printStatus(s: MarginCallStatus): void {
  if (s.obligationId === "0x0000000000000000000000000000000000000000000000000000000000000000") {
    console.log("  no active margin call");
    return;
  }
  const state = s.active ? chalk.yellow("ACTIVE") : s.satisfied ? chalk.green("SATISFIED") : "CANCELLED";
  console.log(`  obligation : ${s.obligationId}`);
  console.log(`  required   : ${usd(s.requiredValue)}`);
  console.log(`  current    : ${usd(s.currentValue)}`);
  console.log(`  shortfall  : ${usd(s.shortfall)}`);
  console.log(`  created    : ${new Date(Number(s.createdAt) * 1000).toISOString()}`);
  console.log(`  state      : ${state}`);
}

export function printHistory(records: MarginCallRecord[]): void {
  if (records.length === 0) {
    console.log("  (none)");
    return;
  }
  for (let i = 0; i < records.length; i++) {
    const r = records[i];
    const tag = r.cancelled ? chalk.gray("CANCELLED") : r.satisfied ? chalk.green("SATISFIED") : chalk.yellow("CREATED");
    console.log(
      `  [${i}] ${tag} shortfall=${usd(r.shortfall)} at ${new Date(Number(r.timestamp) * 1000).toISOString()}`,
    );
  }
}
