#!/usr/bin/env node
import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { getConfig } from "./config.js";
import { buildClients, type Clients } from "./clients.js";
import {
  evaluateAll,
  getMarginStatus,
  getMarginCallHistory,
  getRequirement,
} from "./marginManager.js";
import { updatePrice, resolveAssetId, getLatestPrice } from "./valuationOracle.js";
import { printEvaluation, printStatus, printHistory } from "./format.js";

async function withClients(opts: { rpcUrl?: string; providerKey?: string; operatorKey?: string }, fn: (c: Clients) => Promise<void>) {
  const cfg = getConfig(opts);
  const clients = buildClients(cfg.rpcUrl, cfg.providerKey, cfg.operatorKey, cfg.deployment);
  try {
    await fn(clients);
  } catch (e) {
    console.error(chalk.red("error:"), (e as Error).message);
    process.exitCode = 1;
  }
}

function obligation(cfgObligation: string, arg?: string): string {
  const o = arg ?? cfgObligation;
  if (!o) throw new Error("obligation id required (pass as arg or set OBLIGATION_ID)");
  return o;
}

const program = new Command();

program
  .name("margin-monitor")
  .description("Two-actor margin automation for the Collateral Network (Anvil)")
  .version("1.0.0")
  .option("--rpc-url <url>", "RPC endpoint", process.env.RPC_URL ?? "http://127.0.0.1:8545")
  .option("--provider-key <key>", "VALUATION_PROVIDER private key", process.env.VALUATION_PROVIDER_KEY)
  .option("--operator-key <key>", "COLLATERAL_AGENT private key", process.env.COLLATERAL_AGENT_KEY);

// ---------------------------------------------------------------------------
// deploy
// ---------------------------------------------------------------------------
program
  .command("deploy")
  .description("Deploy the network to the configured Anvil node and write deployments/anvil.json")
  .action(async () => {
    console.log(chalk.cyan("Deploying network (forge script script/Deploy.s.sol) ..."));
    execFileSync("forge", ["script", "script/Deploy.s.sol", "--rpc-url", program.opts().rpcUrl, "--broadcast"], {
      stdio: "inherit",
    });
    console.log(chalk.green("Deployment complete. Wrote deployments/anvil.json"));
  });

// ---------------------------------------------------------------------------
// price update
// ---------------------------------------------------------------------------
program
  .command("price")
  .description("Price commands (data provider role)")
  .command("update")
  .description("Submit a signed market price as VALUATION_PROVIDER")
  .argument("<asset>", "asset name (e.g. T-BOND-001) or 32-byte hex id")
  .argument("<priceCents>", "price in USD cents, e.g. 9200 = $92.00")
  .action(async (asset: string, priceCents: string) => {
    await withClients(program.opts(), async (c) => {
      const id = resolveAssetId(c, asset);
      console.log(chalk.cyan(`Submitting price for ${asset} = $${(Number(priceCents) / 100).toFixed(2)} ...`));
      const tx = await updatePrice(c, id, BigInt(priceCents));
      console.log(chalk.green(`Price updated (tx ${tx.slice(0, 10)}...).`));
      const { price } = await getLatestPrice(c, id);
      console.log(`  oracle now reports $${(Number(price) / 100).toFixed(2)}`);
    });
  });

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------
program
  .command("check")
  .description("Evaluate obligation(s) as COLLATERAL_AGENT; raises a margin call on shortfall")
  .argument("[obligationId]", "obligation id (hex); defaults to OBLIGATION_ID env")
  .action(async (obligationId?: string) => {
    await withClients(program.opts(), async (c) => {
      const cfg = getConfig(program.opts());
      const id = obligation(cfg.obligationId, obligationId);
      console.log(chalk.cyan(`Evaluating obligation ${id} ...`));
      const evals = await evaluateAll(c, [id]);
      for (const e of evals) {
        printEvaluation(e);
        if (!e.isAdequate) {
          console.log(chalk.yellow("  -> margin call raised (system asks for more collateral)"));
        } else {
          console.log(chalk.green("  -> adequate; no margin call"));
        }
      }
    });
  });

// ---------------------------------------------------------------------------
// watch
// ---------------------------------------------------------------------------
program
  .command("watch")
  .description("Continuously (re)evaluate an obligation; raises calls automatically on shortfall")
  .argument("[obligationId]", "obligation id (hex); defaults to OBLIGATION_ID env")
  .option("--interval <ms>", "poll interval in milliseconds", "5000")
  .action(async (obligationId: string | undefined, options: { interval: string }) => {
    await withClients(program.opts(), async (c) => {
      const cfg = getConfig(program.opts());
      const id = obligation(cfg.obligationId, obligationId);
      const interval = Number(options.interval);
      console.log(chalk.cyan(`Watching obligation ${id} every ${interval}ms. Ctrl-C to stop.`));
      let first = true;
      // eslint-disable-next-line no-constant-condition
      while (true) {
        try {
          const evals = await evaluateAll(c, [id]);
          for (const e of evals) {
            if (!e.isAdequate) {
              const was = first ? "" : " raised";
              console.log(`${chalk.yellow("[!!]")} SHORTFALL ${chalk.yellow(printShortfall(e.shortfall))}${was}`);
            } else if (first) {
              console.log(`${chalk.green("[ok]")} adequate (no shortfall)`);
            }
          }
        } catch (e) {
          console.error(chalk.red("watch error:"), (e as Error).message);
        }
        first = false;
        await new Promise((r) => setTimeout(r, interval));
      }
    });
  });

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------
program
  .command("status")
  .description("Read the current margin call status (read-only)")
  .argument("<obligationId>", "obligation id (hex)")
  .action(async (obligationId: string) => {
    await withClients(program.opts(), async (c) => {
      console.log(chalk.cyan(`Status of obligation ${obligationId}:`));
      printStatus(await getMarginStatus(c, obligationId));
    });
  });

// ---------------------------------------------------------------------------
// history
// ---------------------------------------------------------------------------
program
  .command("history")
  .description("Show margin-call history for an obligation (read-only)")
  .argument("<obligationId>", "obligation id (hex)")
  .action(async (obligationId: string) => {
    await withClients(program.opts(), async (c) => {
      console.log(chalk.cyan(`Margin-call history for ${obligationId}:`));
      const req = await getRequirement(c, obligationId);
      console.log(`  requirement : ${requireHdr(req)}`);
      printHistory(await getMarginCallHistory(c, obligationId));
    });
  });

function printShortfall(shortfall: bigint): string {
  return `$${(Number(shortfall) / 100).toFixed(2)}`;
}

function requireHdr(req: bigint): string {
  return req === 0n ? "(none set)" : `$${(Number(req) / 100).toFixed(2)}`;
}

program.parseAsync(process.argv).catch((e) => {
  console.error(chalk.red("fatal:"), (e as Error).message);
  process.exit(1);
});
