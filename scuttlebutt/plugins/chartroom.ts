/// <reference path="../types/fresh.d.ts" />

// Chartroom — the deck's live-mission-awareness plugin (Phase 5, last piece).
// Runs in the chartroom tmux window (ship/bin/sail's window 1, launched as
// `fresh mission.md` with cwd = the charter's .ship/ dir) -- every relative
// path below is resolved against that, same convention ship/bin/bosun and
// ship/bin/purser-totals already use.
//
// Three things per docs/agentic-engineering-plan.md: commands to open the
// current mission's orders/reports, highlight SOS reports, and jump to a
// crew member's tmux window from their report. Built against Fresh's real
// API surface -- scuttlebutt/types/{fresh,plugins}.d.ts were captured from a
// real `fresh` run on this ship (re-verified live before writing this file,
// not trusted as hand-typed leftovers), and the bundled `dashboard` plugin's
// registerSection is what makes this "live", not just request/response
// commands -- matching CLAUDE.md's own vocabulary entry: "Chartroom |
// Scuttlebutt window watching .ship/ live".
//
// No `import` of types/plugins.d.ts's exported DashboardApi/DashboardContext
// types -- found live (fresh-*.log: "Cannot resolve import '../types/plugins'
// ... Skipping") that Fresh's real plugin bundler tries to resolve every
// import at runtime, `import type` included, and a .d.ts has no runtime body
// to bundle. Minimal local interfaces below cover only the members this file
// actually calls -- same avoid-the-bundler choice hello_world.ts's simpler,
// import-free style already makes, git_grep.ts's `./lib/finder.ts` import
// works only because that's a real .ts file with a runtime body.
//
// Deliberately does NOT overlay-highlight SOS text inline in an opened
// report: getActiveBufferId() right after openFile() reads a stale snapshot
// per fresh.d.ts's own documented race ("markFileReadOnly" doc comment,
// resolved by path for exactly this reason) -- a wrong buffer id would
// highlight the wrong file's content. editor.warn() + the dashboard's SOS
// listing (both read the report file directly, no buffer id involved) give
// the same "highlight" value without that race.

const editor = getEditor();

interface RosterEntry {
	task: string;
	name: string;
	branch: string;
	window: string;
	started: string;
	status: string;
}

function chartroomCharterName(): string {
	const cwd = editor.getCwd();
	const parts = cwd.split("/").filter((p) => p.length > 0);
	// cwd is ".../fleet/<charter>/.ship" -- charter name is second-to-last.
	return parts.length >= 2 ? parts[parts.length - 2] : "unknown";
}

function chartroomRoster(): RosterEntry[] {
	const raw = editor.readFile("roster.json");
	if (!raw) return [];
	try {
		return JSON.parse(raw) as RosterEntry[];
	} catch {
		return [];
	}
}

function chartroomListFiles(dir: string): string[] {
	try {
		return editor
			.readDir(dir)
			.filter((e) => e.is_file && e.name.endsWith(".md"))
			.map((e) => e.name)
			.sort();
	} catch {
		return [];
	}
}

// crew.md's report contract is freeform prose ("status SOS"), not a strict
// field -- same greppable-not-structured tradeoff every other officer
// script here already accepts (bosun's Budget field, first-mate's Scope
// field). Case-insensitive, tolerant of markdown bold/heading decoration.
function chartroomIsSOS(content: string): boolean {
	return /status[^\n]{0,10}\bSOS\b/i.test(content);
}

function chartroomPickFile(files: string[], input: string, kind: string): string | null {
	const matches = files.filter((f) => f.toLowerCase().startsWith(input.toLowerCase()));
	if (matches.length === 0) {
		editor.error(`chartroom: no ${kind} matching '${input}'`);
		return null;
	}
	if (matches.length > 1) {
		editor.error(`chartroom: '${input}' matches more than one ${kind}: ${matches.join(", ")} -- be more specific`);
		return null;
	}
	return matches[0];
}

async function chartroomJumpToEntry(entry: RosterEntry): Promise<void> {
	const charter = chartroomCharterName();
	const target = `ship-${charter}:${entry.window}`;
	const result = await editor.spawnProcess("tmux", ["select-window", "-t", target], editor.getCwd());
	if (result.exit_code === 0) {
		editor.setStatus(`chartroom: jumped to ${entry.name}'s window (${target})`);
	} else {
		editor.error(`chartroom: couldn't select tmux window ${target}: ${(result.stderr || result.stdout).trim()}`);
	}
}

async function chartroom_open_mission(): Promise<void> {
	if (!editor.fileExists("mission.md")) {
		editor.error("chartroom: no mission.md yet -- no active voyage");
		return;
	}
	editor.openFile("mission.md", null, null);
}
registerHandler("chartroom_open_mission", chartroom_open_mission);

async function chartroom_open_order(): Promise<void> {
	const files = chartroomListFiles("orders");
	if (files.length === 0) {
		editor.error("chartroom: no orders yet");
		return;
	}
	editor.info(`orders: ${files.join(", ")}`);
	const input = await editor.prompt("Open which order (task id or prefix)?", "");
	if (!input) return;
	const chosen = chartroomPickFile(files, input, "order");
	if (chosen) editor.openFile(`orders/${chosen}`, null, null);
}
registerHandler("chartroom_open_order", chartroom_open_order);

async function chartroom_open_report(): Promise<void> {
	const files = chartroomListFiles("reports");
	if (files.length === 0) {
		editor.error("chartroom: no reports yet");
		return;
	}
	const labeled = files.map((f) => (chartroomIsSOS(editor.readFile(`reports/${f}`) || "") ? `${f} (SOS)` : f));
	editor.info(`reports: ${labeled.join(", ")}`);
	const input = await editor.prompt("Open which report (task id or prefix)?", "");
	if (!input) return;
	const chosen = chartroomPickFile(files, input, "report");
	if (!chosen) return;
	editor.openFile(`reports/${chosen}`, null, null);
	if (chartroomIsSOS(editor.readFile(`reports/${chosen}`) || "")) {
		editor.warn(`chartroom: ${chosen} is an SOS report`);
	}
}
registerHandler("chartroom_open_report", chartroom_open_report);

async function chartroom_jump_to_crew(): Promise<void> {
	const roster = chartroomRoster();
	if (roster.length === 0) {
		editor.error("chartroom: roster is empty -- no crew mustered yet");
		return;
	}

	// Contextual: "jump to a crew member's tmux window from their report"
	// (per the plan's own wording) -- if the active buffer is a report
	// file, resolve its task directly rather than asking.
	const activePath = editor.getBufferPath(editor.getActiveBufferId());
	const reportMatch = activePath ? activePath.match(/reports\/([^/]+)\.report\.md$/) : null;
	let entry = reportMatch ? roster.find((r) => r.task === reportMatch[1]) : undefined;

	if (!entry) {
		const listing = roster.map((r) => `${r.task} (${r.name}, ${r.status})`).join(", ");
		editor.info(`crew: ${listing}`);
		const input = await editor.prompt("Jump to which task's crew window?", "");
		if (!input) return;
		entry = roster.find((r) => r.task === input) || roster.find((r) => r.task.toLowerCase().startsWith(input.toLowerCase()));
		if (!entry) {
			editor.error(`chartroom: no roster entry matching '${input}'`);
			return;
		}
	}

	await chartroomJumpToEntry(entry);
}
registerHandler("chartroom_jump_to_crew", chartroom_jump_to_crew);

// --- live dashboard section: the actual "watching .ship/ live" part ---
// Minimal local shapes for the subset of the bundled dashboard plugin's API
// this file actually calls (see the file-header note on why this isn't an
// import of types/plugins.d.ts's own DashboardApi/DashboardContext).
interface ChartroomDashboardCtx {
	text(s: string, opts?: { color?: string; bold?: boolean; onClick?: () => void }): void;
	newline(): void;
	error(message: string): void;
}
interface ChartroomDashboardApi {
	registerSection(name: string, refresh: (ctx: ChartroomDashboardCtx) => Promise<void>): () => void;
	setAutoOpen(enabled: boolean): void;
}

const tradeWindRoles = ["captain", "crew", "first-mate", "quartermaster"];

interface BackendState {
	[role: string]: string;
}

interface BackendRegistry {
	[name: string]: { label?: string };
}

async function chartroomTradeWinds(ctx: ChartroomDashboardCtx): Promise<void> {
	let state: BackendState = {};
	try {
		state = JSON.parse(editor.readFile("backend.json") || "{}") as BackendState;
	} catch {
		ctx.error("Trade Winds: backend.json is invalid");
		return;
	}

	const registryResult = await editor.spawnProcess(
		"bash",
		["-lc", "cat \"$HOME/shipyard/ship/backends.json\""],
		editor.getCwd(),
	);
	let registry: BackendRegistry = {};
	try {
		registry = JSON.parse(registryResult.stdout || "{}") as BackendRegistry;
	} catch {
		ctx.error("Trade Winds: backend registry unavailable");
		return;
	}

	ctx.text("Trade Winds", { bold: true, color: "accent" });
	ctx.newline();
	for (const role of tradeWindRoles) {
		const backend = state[role] || "deepinfra";
		const wind = registry[backend]?.label || backend;
		ctx.text(`${role}: `, { color: "value" });
		ctx.text(wind);
		ctx.newline();
	}
}

async function chartroom_dashboard(ctx: ChartroomDashboardCtx): Promise<void> {
	const roster = chartroomRoster();
	await chartroomTradeWinds(ctx);
	ctx.newline();
	if (!editor.fileExists("mission.md") && roster.length === 0) {
		ctx.text("no active voyage", { color: "muted" });
		ctx.newline();
		return;
	}

	for (const r of roster) {
		const color = r.status === "working" ? "accent" : r.status === "merged" ? "ok" : r.status === "rejected" || r.status === "failed" ? "err" : "muted";
		ctx.text(`${r.task} `, { color: "value" });
		ctx.text(`${r.name} `, {});
		ctx.text(r.status, { color, onClick: () => void chartroomJumpToEntry(r) });
		ctx.newline();
	}

	const sosReports = chartroomListFiles("reports").filter((f) => chartroomIsSOS(editor.readFile(`reports/${f}`) || ""));
	for (const f of sosReports) {
		ctx.error(`SOS: ${f.replace(/\.report\.md$/, "")}`);
	}
}

const chartroomDashboardApi = editor.getPluginApi("dashboard") as ChartroomDashboardApi | null;
if (chartroomDashboardApi) {
	chartroomDashboardApi.registerSection("chartroom", chartroom_dashboard);
	chartroomDashboardApi.setAutoOpen(true);
} else {
	editor.debug("chartroom: dashboard plugin API not available -- skipping live section, commands still work");
}

// --- command palette entries ---
editor.registerCommand("Chartroom: Open Mission", "Open the current mission.md", "chartroom_open_mission");
editor.registerCommand("Chartroom: Open Order", "Open a work order by task id", "chartroom_open_order");
editor.registerCommand("Chartroom: Open Report", "Open a crew report by task id (flags SOS)", "chartroom_open_report");
editor.registerCommand(
	"Chartroom: Jump to Crew Window",
	"tmux select-window for a crew member (contextual from their report)",
	"chartroom_jump_to_crew",
);

editor.debug("Chartroom plugin loaded");
