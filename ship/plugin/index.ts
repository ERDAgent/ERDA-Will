/**
 * Shipyard extension — Phase 4 plugin v1 (see docs/agentic-engineering-plan.md §9).
 *
 * Adds four slash commands to the Captain's bridge session: /mission, /muster,
 * /harbor, /debrief. Per the plan, this extension "only manages files, tmux,
 * and worktrees" — it deliberately does NOT reimplement any planning or
 * review intelligence. /muster and /harbor are pure deterministic wrappers
 * around the already-proven ship/bin/muster and .ship/roster.json + reports
 * (no LLM turn at all — there's nothing to reason about, just files and one
 * subprocess call). /mission and /debrief gather deterministic ground truth
 * (the raw goal text; the real roster/git/ledger data) and hand it to the
 * Captain's own conversation via sendUserMessage — planning and narrative
 * summarization are language tasks the already-proven captain.md system
 * prompt already handles; this extension's job is only to make sure the
 * Captain never has to construct the exact bash invocation or remember to
 * check the ledger, not to replace its judgment.
 *
 * Loaded globally (symlinked by fitout.sh into ~/.pi/agent/extensions/shipyard/),
 * so it's active in every charter's bridge window without per-charter setup.
 * All four commands assume ctx.cwd is the charter root — true for the bridge
 * window (sail starts it at $DIR, never a berth) but checked defensively
 * anyway rather than assumed.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

interface RosterEntry {
	task: string;
	name: string;
	branch: string;
	window: string;
	started: string;
	status: string;
}

function charterInfo(ctx: ExtensionCommandContext): { dir: string; name: string } | undefined {
	const dir = ctx.cwd;
	if (!existsSync(join(dir, ".ship"))) {
		ctx.ui.notify(`no .ship/ bus at ${dir} -- this doesn't look like a charter root`, "error");
		return undefined;
	}
	return { dir, name: basename(dir) };
}

function readRoster(charterDir: string): RosterEntry[] {
	const rosterPath = join(charterDir, ".ship", "roster.json");
	if (!existsSync(rosterPath)) return [];
	try {
		return JSON.parse(readFileSync(rosterPath, "utf8")) as RosterEntry[];
	} catch {
		return [];
	}
}

function showReport(charterDir: string, entry: RosterEntry, ctx: ExtensionCommandContext): void {
	const reportPath = join(charterDir, ".ship", "reports", `${entry.task}.report.md`);
	if (existsSync(reportPath)) {
		ctx.ui.notify(`${entry.task} (${entry.name}, ${entry.status}):\n\n${readFileSync(reportPath, "utf8")}`, "info");
	} else {
		ctx.ui.notify(`${entry.task} (${entry.name}): ${entry.status} on ${entry.branch}, no report yet`, "info");
	}
}

// Real per-call cost from cost-proxy's ledger (see ship/bin/cost-proxy,
// docs/system-overview.md's Purser section) — the whole point of reading this
// file directly here, rather than asking the LLM to `cat` it, is that a
// human-narrated summary is only as trustworthy as the numbers it's built on.
function summarizeLedger(charterDir: string): string {
	const ledgerPath = join(charterDir, ".ship", "log", "ledger.tsv");
	if (!existsSync(ledgerPath)) return "no ledger data yet (no DeepInfra calls logged)";
	const lines = readFileSync(ledgerPath, "utf8").trim().split("\n").filter(Boolean);
	if (lines.length === 0) return "no ledger data yet (no DeepInfra calls logged)";

	let total = 0;
	const byRole: Record<string, number> = {};
	for (const line of lines) {
		const cols = line.split("\t");
		const cost = Number.parseFloat(cols[8] ?? "0") || 0;
		total += cost;
		byRole[cols[1] ?? "unknown"] = (byRole[cols[1] ?? "unknown"] ?? 0) + cost;
	}
	const breakdown = Object.entries(byRole)
		.map(([role, cost]) => `${role}: $${cost.toFixed(4)}`)
		.join(", ");
	return `$${total.toFixed(4)} across ${lines.length} real DeepInfra call${lines.length === 1 ? "" : "s"} (${breakdown})`;
}

export default function (pi: ExtensionAPI) {
	pi.registerCommand("mission", {
		description: "Plan a mission: write mission.md + work orders (the Captain does the planning)",
		handler: async (args, ctx) => {
			const charter = charterInfo(ctx);
			if (!charter) return;
			const goal = args.trim();
			if (!goal) {
				ctx.ui.notify("usage: /mission <what you want to accomplish>", "error");
				return;
			}
			mkdirSync(join(charter.dir, ".ship", "orders"), { recursive: true });
			pi.sendUserMessage(
				`Plan a new mission: ${goal}\n\n` +
					"Follow the PLAN step: write .ship/mission.md summarizing the mission, decompose it into " +
					"work orders under .ship/orders/ (one file per order, following ship/prompts/order-template.md's " +
					"structure -- objective, scope, acceptance criteria, budget, SOS conditions), then show me the " +
					"plan and STOP. Do not muster any crew yet -- I approve the plan first.",
			);
		},
	});

	pi.registerCommand("muster", {
		description: "Spawn a crew member for a work order (wraps ship/bin/muster)",
		getArgumentCompletions: (prefix) => {
			// Best-effort only -- runs relative to process.cwd(), which matches
			// the bridge window's charter root in the real case this is used for.
			const ordersDir = join(process.cwd(), ".ship", "orders");
			if (!existsSync(ordersDir)) return null;
			const items = readdirSync(ordersDir)
				.filter((f) => f.endsWith(".md") && f.startsWith(prefix))
				.map((f) => ({ value: f.replace(/\.md$/, ""), label: f }));
			return items.length > 0 ? items : null;
		},
		handler: async (args, ctx) => {
			const charter = charterInfo(ctx);
			if (!charter) return;
			const parts = args.trim().split(/\s+/).filter(Boolean);
			const taskId = parts[0];
			if (!taskId) {
				ctx.ui.notify("usage: /muster <task-id> [order-file]", "error");
				return;
			}

			let orderFile = parts[1];
			const ordersDir = join(charter.dir, ".ship", "orders");
			if (!orderFile) {
				const matches = existsSync(ordersDir) ? readdirSync(ordersDir).filter((f) => f.startsWith(taskId)) : [];
				if (matches.length === 0) {
					ctx.ui.notify(`no order file found for '${taskId}' in .ship/orders/`, "error");
					return;
				}
				if (matches.length > 1) {
					ctx.ui.notify(`multiple order files match '${taskId}': ${matches.join(", ")} -- specify one`, "error");
					return;
				}
				orderFile = join(ordersDir, matches[0]);
			} else if (!isAbsolute(orderFile)) {
				orderFile = join(charter.dir, orderFile);
			}

			ctx.ui.notify(`mustering ${taskId}...`, "info");
			try {
				const result = await pi.exec("muster", [charter.name, taskId, orderFile], { cwd: charter.dir, timeout: 30000 });
				if (result.code === 0) {
					ctx.ui.notify(result.stdout.trim() || `mustered ${taskId}`, "info");
				} else {
					ctx.ui.notify(`muster failed (exit ${result.code}): ${(result.stderr || result.stdout).trim()}`, "error");
				}
			} catch (err) {
				ctx.ui.notify(`muster failed to run: ${err instanceof Error ? err.message : String(err)}`, "error");
			}
		},
	});

	pi.registerCommand("review", {
		description: "Review & merge-gate a crew work order (wraps ship/bin/quartermaster)",
		getArgumentCompletions: (prefix) => {
			// Best-effort, same shape as /muster's completion: reads roster.json
			// directly rather than asking pi.exec for it, since this only needs
			// to run relative to process.cwd() for tab-completion, not a real
			// subprocess round-trip.
			const rosterPath = join(process.cwd(), ".ship", "roster.json");
			if (!existsSync(rosterPath)) return null;
			try {
				const roster = JSON.parse(readFileSync(rosterPath, "utf8")) as RosterEntry[];
				const items = roster
					.filter((r) => r.status !== "working" && r.task.startsWith(prefix))
					.map((r) => ({ value: r.task, label: `${r.task} (${r.status})` }));
				return items.length > 0 ? items : null;
			} catch {
				return null;
			}
		},
		handler: async (args, ctx) => {
			const charter = charterInfo(ctx);
			if (!charter) return;
			const taskId = args.trim().split(/\s+/)[0];
			if (!taskId) {
				ctx.ui.notify("usage: /review <task-id>", "error");
				return;
			}

			ctx.ui.notify(`quartermaster reviewing ${taskId}...`, "info");
			try {
				// No fixed timeout: a real dry-dock test suite can run long, and
				// the review LLM call is a real DeepInfra round-trip on top of
				// that -- unlike /muster's spawn-and-return, this command waits
				// for the whole review to finish before reporting back.
				const result = await pi.exec("quartermaster", [charter.name, taskId], { cwd: charter.dir, timeout: 600000 });
				const output = (result.stdout || result.stderr).trim();
				ctx.ui.notify(output || `quartermaster exited ${result.code}`, result.code === 0 ? "info" : "error");
			} catch (err) {
				ctx.ui.notify(`quartermaster failed to run: ${err instanceof Error ? err.message : String(err)}`, "error");
			}
		},
	});

	pi.registerCommand("harbor", {
		description: "Show crew status from roster.json + reports",
		handler: async (args, ctx) => {
			const charter = charterInfo(ctx);
			if (!charter) return;
			const roster = readRoster(charter.dir);
			if (roster.length === 0) {
				ctx.ui.notify("roster is empty -- no crew mustered yet", "info");
				return;
			}

			const requested = args.trim();
			if (requested) {
				const target = roster.find((r) => r.task === requested);
				if (!target) {
					ctx.ui.notify(`no roster entry for task '${requested}'`, "error");
					return;
				}
				showReport(charter.dir, target, ctx);
				return;
			}

			const items = roster.map((r) => `${r.task} · ${r.name} · ${r.status} · ${r.branch}`);
			const selected = await ctx.ui.select("Harbor — crew status", items);
			if (!selected) return;
			const chosenTask = selected.split(" · ")[0];
			const chosen = roster.find((r) => r.task === chosenTask);
			if (chosen) showReport(charter.dir, chosen, ctx);
		},
	});

	pi.registerCommand("debrief", {
		description: "Summarize the mission: what shipped, what's blocked, real cost from the ledger",
		handler: async (_args, ctx) => {
			const charter = charterInfo(ctx);
			if (!charter) return;

			const roster = readRoster(charter.dir);
			const rosterSummary = roster.length
				? roster.map((r) => `- ${r.task} (${r.name}): ${r.status}, branch ${r.branch}`).join("\n")
				: "(no crew mustered this session)";

			const costLine = summarizeLedger(charter.dir);

			let recentCommits = "(none)";
			try {
				const log = await pi.exec("git", ["-C", ".hold.git", "log", "--oneline", "-n", "10", "main"], {
					cwd: charter.dir,
					timeout: 10000,
				});
				if (log.code === 0 && log.stdout.trim()) recentCommits = log.stdout.trim();
			} catch {
				// no .hold.git, or main doesn't exist yet -- not an error worth surfacing here
			}

			pi.sendUserMessage(
				"Debrief this mission for Eric. Here is the real, deterministic data -- use it, don't " +
					"re-derive or guess at it:\n\n" +
					`Crew roster:\n${rosterSummary}\n\n` +
					`Recent commits on main:\n${recentCommits}\n\n` +
					`Real cost (from cost-proxy's ledger, not an estimate): ${costLine}\n\n` +
					"Summarize: what shipped, what's blocked or still open, and the real cost. Be terse.",
			);
		},
	});
}
