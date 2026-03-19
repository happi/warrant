import * as vscode from "vscode";
import { resolveWarrantConfig } from "./core/config";
import { ApiClient } from "./core/api-client";
import { LocalTaskReader } from "./core/local-tasks";
import { Cache } from "./core/cache";
import { createStatusBar, refreshStatusBar } from "./status-bar";
import { TaskHoverProvider } from "./providers/hover-provider";
import { BlameDecorator } from "./providers/blame-decorator";
import { CurrentTaskProvider, TaskListProvider, PlaceholderProvider } from "./providers/tree-provider";
import { registerStatusCommands } from "./commands/start-task";
import { registerLinkCommands } from "./commands/link-commit";
import { registerCreateCommand } from "./commands/create-task";
import { registerTraceCommands } from "./commands/show-trace";
import { Task, TaskSummary, Trace } from "./core/types";

let blameDecorator: BlameDecorator | undefined;

/**
 * Unified task source: local files first, API fallback.
 */
export class TaskSource {
    constructor(
        private local: LocalTaskReader,
        private api: ApiClient | null,
    ) {}

    async getTask(taskId: string): Promise<Task | null> {
        return await this.local.getTask(taskId) ?? await this.api?.getTask(taskId) ?? null;
    }

    async listTasks(): Promise<TaskSummary[]> {
        const localTasks = await this.local.listTasks();
        if (localTasks.length > 0) return localTasks;
        return await this.api?.listTasks() ?? [];
    }

    async getTrace(taskId: string): Promise<Trace | null> {
        return await this.local.getTrace(taskId) ?? await this.api?.getTrace(taskId) ?? null;
    }
}

export function activate(context: vscode.ExtensionContext): void {
    const config = resolveWarrantConfig();

    if (!config) {
        context.subscriptions.push(
            vscode.window.registerTreeDataProvider("warrant.currentTask",
                new PlaceholderProvider("No .warrant/ directory found")),
            vscode.window.registerTreeDataProvider("warrant.tasks",
                new PlaceholderProvider("Create .warrant/config.yaml to get started")),
        );
        return;
    }

    const log = vscode.window.createOutputChannel("Warrant");
    const cache = new Cache();
    const local = new LocalTaskReader(config.tasksDir);

    let api: ApiClient | null = null;
    if (config.server) {
        log.appendLine(`Server: ${config.server.url} org=${config.server.org} project=${config.server.project}`);
        api = new ApiClient(config.server, cache, log);
    } else {
        log.appendLine("Local-only mode (no server configured)");
    }
    log.appendLine(`Tasks: ${config.tasksDir}`);
    log.appendLine(`Prefix: ${config.prefix || "(auto-detect)"}`);

    const source = new TaskSource(local, api);
    const prefix = config.prefix;

    // Status bar
    const statusBar = createStatusBar(source, prefix);
    context.subscriptions.push(statusBar);

    // Refresh on branch change
    const gitHeadWatcher = vscode.workspace.createFileSystemWatcher("**/.git/HEAD");
    gitHeadWatcher.onDidChange(() => refreshStatusBar(source, prefix));
    context.subscriptions.push(gitHeadWatcher);

    // Refresh on task file changes
    const taskWatcher = vscode.workspace.createFileSystemWatcher("**/.warrant/tasks/*.md");
    const refreshAll = () => {
        currentTaskProvider.refresh();
        taskListProvider.refresh();
    };
    taskWatcher.onDidChange(refreshAll);
    taskWatcher.onDidCreate(refreshAll);
    taskWatcher.onDidDelete(refreshAll);
    context.subscriptions.push(taskWatcher);

    // Sidebar
    const currentTaskProvider = new CurrentTaskProvider(source, prefix);
    const taskListProvider = new TaskListProvider(source);

    context.subscriptions.push(
        vscode.window.registerTreeDataProvider("warrant.currentTask", currentTaskProvider),
        vscode.window.registerTreeDataProvider("warrant.tasks", taskListProvider),
    );

    // Refresh on window focus
    context.subscriptions.push(
        vscode.window.onDidChangeWindowState(e => {
            if (e.focused) {
                refreshStatusBar(source, prefix);
                currentTaskProvider.refresh();
            }
        }),
    );

    // Hover
    context.subscriptions.push(
        vscode.languages.registerHoverProvider({ scheme: "file" }, new TaskHoverProvider(source, prefix)),
    );

    // Blame
    const blameEnabled = vscode.workspace.getConfiguration("warrant").get("blameEnabled", true);
    if (blameEnabled) {
        blameDecorator = new BlameDecorator(source, cache, prefix);
        context.subscriptions.push(blameDecorator);
    }

    // Commands (CAS/leases need server — pass null if local-only)
    context.subscriptions.push(
        ...registerStatusCommands(api, prefix),
        ...registerLinkCommands(api, prefix),
        ...registerCreateCommand(api),
        ...registerTraceCommands(source, prefix),
        vscode.commands.registerCommand("warrant.refreshTasks", () => {
            api?.invalidateAll();
            currentTaskProvider.refresh();
            taskListProvider.refresh();
            refreshStatusBar(source, prefix);
        }),
        vscode.commands.registerCommand("warrant.toggleAnnotations", () => {
            if (blameDecorator) {
                blameDecorator.dispose();
                blameDecorator = undefined;
                vscode.window.showInformationMessage("Warrant annotations off");
            } else {
                blameDecorator = new BlameDecorator(source, cache, prefix);
                context.subscriptions.push(blameDecorator);
                vscode.window.showInformationMessage("Warrant annotations on");
            }
        }),
    );
}

export function deactivate(): void {
    blameDecorator?.dispose();
}
