import * as vscode from "vscode";
import { TaskLookup, Task, TaskSummary } from "../core/types";
import { getCurrentTaskId } from "../git/branch";

export class CurrentTaskProvider implements vscode.TreeDataProvider<TaskTreeItem> {
    private _onDidChange = new vscode.EventEmitter<void>();
    readonly onDidChangeTreeData = this._onDidChange.event;

    constructor(private api: TaskLookup, private prefix: string) {}

    refresh(): void { this._onDidChange.fire(); }

    getTreeItem(element: TaskTreeItem): vscode.TreeItem { return element; }

    async getChildren(element?: TaskTreeItem): Promise<TaskTreeItem[]> {
        if (element) return element.children ?? [];

        const taskId = await getCurrentTaskId(this.prefix);
        if (!taskId) {
            return [new TaskTreeItem("No task on current branch", "", "info")];
        }

        const task = await this.api.getTask(taskId);
        if (!task) {
            return [new TaskTreeItem(`${taskId} (not found)`, "", "warning")];
        }

        const root = new TaskTreeItem(
            `${task.id}: ${task.title}`,
            task.status,
            "task",
        );

        const children: TaskTreeItem[] = [
            new TaskTreeItem(`Status: ${task.status}`, "", "field"),
        ];
        if (task.priority) children.push(new TaskTreeItem(`Priority: ${task.priority}`, "", "field"));
        if (task.intent) children.push(new TaskTreeItem(`Intent: ${task.intent}`, "", "field"));
        if (task.assigned_to) children.push(new TaskTreeItem(`Assigned: ${task.assigned_to}`, "", "field"));
        if (task.lease) children.push(new TaskTreeItem(`Leased by: ${task.lease.owner}`, "", "field"));

        const branches = task.links.filter(l => l.kind === "branch");
        const commits = task.links.filter(l => l.kind === "commit");
        const prs = task.links.filter(l => l.kind === "pr");

        if (branches.length) children.push(new TaskTreeItem(
            `Branches (${branches.length})`, "", "group",
            branches.map(l => new TaskTreeItem(l.ref, "", "link")),
        ));
        if (commits.length) children.push(new TaskTreeItem(
            `Commits (${commits.length})`, "", "group",
            commits.map(l => new TaskTreeItem(l.ref.slice(0, 8), l.ref, "link")),
        ));
        if (prs.length) children.push(new TaskTreeItem(
            `PRs (${prs.length})`, "", "group",
            prs.map(l => new TaskTreeItem(`#${l.ref}`, l.url ?? "", "link")),
        ));

        root.children = children;
        root.collapsibleState = vscode.TreeItemCollapsibleState.Expanded;
        return [root];
    }
}

export class TaskListProvider implements vscode.TreeDataProvider<TaskTreeItem> {
    private _onDidChange = new vscode.EventEmitter<void>();
    readonly onDidChangeTreeData = this._onDidChange.event;

    constructor(private api: TaskLookup) {}

    refresh(): void { this._onDidChange.fire(); }

    getTreeItem(element: TaskTreeItem): vscode.TreeItem { return element; }

    async getChildren(element?: TaskTreeItem): Promise<TaskTreeItem[]> {
        if (element) return element.children ?? [];

        const tasks = await this.api.listTasks();
        if (tasks.length === 0) {
            return [new TaskTreeItem("No tasks found", "", "info")];
        }

        // Group by status
        const groups: Record<string, TaskSummary[]> = {};
        for (const t of tasks) {
            const s = t.status;
            (groups[s] ??= []).push(t);
        }

        const order = ["in_progress", "open", "in_review", "blocked", "done", "cancelled"];
        const result: TaskTreeItem[] = [];

        for (const status of order) {
            const items = groups[status];
            if (!items?.length) continue;

            const group = new TaskTreeItem(
                `${status} (${items.length})`,
                "",
                "group",
                items.map(t => {
                    const item = new TaskTreeItem(`${t.id}: ${t.title}`, t.id, "task");
                    item.command = {
                        command: "warrant.openTask",
                        title: "Open Task",
                        arguments: [t.id],
                    };
                    return item;
                }),
            );
            group.collapsibleState = status === "in_progress" || status === "open"
                ? vscode.TreeItemCollapsibleState.Expanded
                : vscode.TreeItemCollapsibleState.Collapsed;
            result.push(group);
        }

        return result;
    }
}

export class PlaceholderProvider implements vscode.TreeDataProvider<vscode.TreeItem> {
    constructor(private message: string) {}
    getTreeItem(element: vscode.TreeItem): vscode.TreeItem { return element; }
    getChildren(): vscode.TreeItem[] {
        const item = new vscode.TreeItem(this.message);
        item.iconPath = new vscode.ThemeIcon("info");
        return [item];
    }
}

class TaskTreeItem extends vscode.TreeItem {
    children?: TaskTreeItem[];

    constructor(
        label: string,
        public taskRef: string,
        public kind: "task" | "field" | "group" | "link" | "info" | "warning",
        children?: TaskTreeItem[],
    ) {
        const collapsible = children?.length
            ? vscode.TreeItemCollapsibleState.Collapsed
            : vscode.TreeItemCollapsibleState.None;
        super(label, collapsible);
        this.children = children;

        switch (kind) {
            case "task": this.iconPath = new vscode.ThemeIcon("tasklist"); break;
            case "group": this.iconPath = new vscode.ThemeIcon("folder"); break;
            case "link": this.iconPath = new vscode.ThemeIcon("link"); break;
            case "info": this.iconPath = new vscode.ThemeIcon("info"); break;
            case "warning": this.iconPath = new vscode.ThemeIcon("warning"); break;
        }
    }
}
