import * as vscode from "vscode";
import * as path from "path";
import { blameLines, BlameLine } from "../git/blame";
import { ApiClient } from "../core/api-client";
import { Cache } from "../core/cache";

const BLAME_TTL = 300_000; // 5min
const DEBOUNCE_MS = 300;

const decorationType = vscode.window.createTextEditorDecorationType({
    after: {
        color: new vscode.ThemeColor("editorCodeLens.foreground"),
        margin: "0 0 0 3em",
        fontStyle: "italic",
    },
    isWholeLine: true,
});

export class BlameDecorator implements vscode.Disposable {
    private disposables: vscode.Disposable[] = [];
    private timer: ReturnType<typeof setTimeout> | null = null;
    private cache: Cache;
    private api: ApiClient;
    private prefix?: string;
    /** Map line number → blame data for the active editor, used by the hover */
    private currentBlame = new Map<number, BlameLine>();

    constructor(api: ApiClient, cache: Cache, prefix?: string) {
        this.api = api;
        this.cache = cache;
        this.prefix = prefix;

        this.disposables.push(
            vscode.window.onDidChangeActiveTextEditor(() => this.scheduleUpdate()),
            vscode.window.onDidChangeTextEditorVisibleRanges(() => this.scheduleUpdate()),
        );

        // Register a hover provider that enriches blame lines with task details
        this.disposables.push(
            vscode.languages.registerHoverProvider({ scheme: "file" }, {
                provideHover: (doc, pos) => this.provideBlameHover(doc, pos),
            }),
        );

        this.scheduleUpdate();
    }

    private scheduleUpdate(): void {
        if (this.timer) clearTimeout(this.timer);
        this.timer = setTimeout(() => this.update(), DEBOUNCE_MS);
    }

    private async update(): Promise<void> {
        const editor = vscode.window.activeTextEditor;
        if (!editor) return;

        const doc = editor.document;
        if (doc.uri.scheme !== "file") return;

        const cwd = vscode.workspace.getWorkspaceFolder(doc.uri)?.uri.fsPath;
        if (!cwd) return;

        const filePath = path.relative(cwd, doc.uri.fsPath);
        const visibleRanges = editor.visibleRanges;
        if (visibleRanges.length === 0) return;

        const startLine = visibleRanges[0].start.line + 1;
        const endLine = visibleRanges[visibleRanges.length - 1].end.line + 1;

        const cacheKey = `blame:${filePath}:${startLine}-${endLine}`;
        let blameData = this.cache.get<BlameLine[]>(cacheKey);

        if (!blameData) {
            blameData = await blameLines(filePath, startLine, endLine, cwd, this.prefix);
            if (blameData.length > 0) {
                this.cache.set(cacheKey, blameData, BLAME_TTL);
            }
        }

        // Update the line→blame map for hover
        this.currentBlame.clear();
        for (const bl of blameData) {
            this.currentBlame.set(bl.line - 1, bl); // 0-indexed
        }

        const decorations: vscode.DecorationOptions[] = [];
        const seen = new Set<number>();

        for (const bl of blameData) {
            if (!bl.taskId || seen.has(bl.line)) continue;
            seen.add(bl.line);

            const line = bl.line - 1;
            if (line < 0 || line >= doc.lineCount) continue;

            // Strip the task ID prefix from the summary to avoid repetition
            let summary = bl.summary;
            const colonIdx = summary.indexOf(": ");
            if (colonIdx > 0 && summary.slice(0, colonIdx).match(/^[A-Z]+-\d+$/)) {
                summary = summary.slice(colonIdx + 2);
            }

            const shortSummary = summary.length > 50 ? summary.slice(0, 49) + "\u2026" : summary;

            decorations.push({
                range: new vscode.Range(line, 0, line, 0),
                renderOptions: {
                    after: {
                        contentText: `  ${bl.taskId} \u2014 ${shortSummary}`,
                    },
                },
            });
        }

        editor.setDecorations(decorationType, decorations);
    }

    /**
     * When the user hovers over a line that has blame data, show the full
     * task title, intent, commit message, and linked PRs.
     */
    private async provideBlameHover(
        document: vscode.TextDocument,
        position: vscode.Position,
    ): Promise<vscode.Hover | null> {
        const bl = this.currentBlame.get(position.line);
        if (!bl?.taskId) return null;

        // Only trigger when hovering past the end of actual code (in the decoration zone)
        const lineText = document.lineAt(position.line).text;
        if (position.character < lineText.length) return null;

        const md = new vscode.MarkdownString();
        md.isTrusted = true;
        md.supportHtml = true;

        // Commit info (always available from blame)
        md.appendMarkdown(`**Commit** \`${bl.sha.slice(0, 8)}\`: ${bl.summary}\n\n`);
        md.appendMarkdown("---\n\n");

        // Fetch task details from the API
        const task = await this.api.getTask(bl.taskId);
        if (task) {
            const statusEmoji: Record<string, string> = {
                open: "\u26aa", in_progress: "\ud83d\udfe1", in_review: "\ud83d\udfe0",
                done: "\u2705", blocked: "\ud83d\udd34", cancelled: "\u26ab",
            };
            const emoji = statusEmoji[task.status] ?? "\u2753";

            md.appendMarkdown(`**${task.id}**: ${task.title}\n\n`);
            md.appendMarkdown(`${emoji} ${task.status}`);
            if (task.priority) md.appendMarkdown(` | **${task.priority}**`);
            md.appendMarkdown("\n\n");

            if (task.intent) {
                md.appendMarkdown(`*Intent:* ${task.intent}\n\n`);
            }

            // Show linked PRs
            const prs = task.links.filter(l => l.kind === "pr");
            if (prs.length > 0) {
                md.appendMarkdown("**PRs:**\n");
                for (const pr of prs) {
                    if (pr.url) {
                        md.appendMarkdown(`- [#${pr.ref}](${pr.url})\n`);
                    } else {
                        md.appendMarkdown(`- #${pr.ref}\n`);
                    }
                }
                md.appendMarkdown("\n");
            }

            // Show linked commits count
            const commits = task.links.filter(l => l.kind === "commit");
            if (commits.length > 0) {
                md.appendMarkdown(`${commits.length} linked commit${commits.length > 1 ? "s" : ""}\n\n`);
            }
        } else {
            md.appendMarkdown(`**${bl.taskId}** *(not found in ledger)*\n\n`);
        }

        md.appendMarkdown(`[Show Full Trace](command:warrant.showTrace?${encodeURIComponent(JSON.stringify(bl.taskId))})`);

        return new vscode.Hover(md);
    }

    dispose(): void {
        if (this.timer) clearTimeout(this.timer);
        for (const d of this.disposables) d.dispose();
    }
}
