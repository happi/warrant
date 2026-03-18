import * as vscode from "vscode";
import { ApiClient } from "../core/api-client";

/**
 * Shows a tooltip when hovering over a task ID (e.g., ZIN-42) in any file.
 */
export class TaskHoverProvider implements vscode.HoverProvider {
    private pattern: RegExp;

    constructor(private api: ApiClient, prefix?: string) {
        this.pattern = prefix
            ? new RegExp(`\\b(${prefix}-\\d+)\\b`, "i")
            : /\b([A-Z]{1,10}-\d+)\b/;
    }

    async provideHover(
        document: vscode.TextDocument,
        position: vscode.Position,
    ): Promise<vscode.Hover | null> {
        const range = document.getWordRangeAtPosition(position, this.pattern);
        if (!range) return null;

        const word = document.getText(range).toUpperCase();
        const task = await this.api.getTask(word);
        if (!task) return null;

        const md = new vscode.MarkdownString();
        md.isTrusted = true;

        const statusEmoji = {
            open: "\u26aa", in_progress: "\ud83d\udfe1", in_review: "\ud83d\udfe0",
            done: "\u2705", blocked: "\ud83d\udd34", cancelled: "\u26ab",
        }[task.status] ?? "\u2753";

        md.appendMarkdown(`**${task.id}**: ${task.title}\n\n`);
        md.appendMarkdown(`${statusEmoji} ${task.status}`);
        if (task.priority) md.appendMarkdown(` | Priority: **${task.priority}**`);
        md.appendMarkdown("\n\n");

        if (task.intent) {
            md.appendMarkdown(`*Intent:* ${task.intent}\n\n`);
        }

        if (task.assigned_to) {
            md.appendMarkdown(`Assigned to: ${task.assigned_to}\n\n`);
        }

        if (task.lease) {
            md.appendMarkdown(`\ud83d\udd12 Leased by **${task.lease.owner}** until ${task.lease.expires_at}\n\n`);
        }

        if (task.labels.length > 0) {
            md.appendMarkdown(`Labels: ${task.labels.map(l => `\`${l}\``).join(" ")}\n\n`);
        }

        const linkCount = task.links.length;
        if (linkCount > 0) {
            md.appendMarkdown(`${linkCount} linked artifact${linkCount > 1 ? "s" : ""}\n\n`);
        }

        md.appendMarkdown(`[Show Trace](command:warrant.showTrace)`);

        return new vscode.Hover(md, range);
    }
}
