import * as vscode from "vscode";
import { resolveConfig } from "./core/config";
import { ApiClient } from "./core/api-client";
import { Cache } from "./core/cache";
import { createStatusBar, refreshStatusBar } from "./status-bar";
import { TaskHoverProvider } from "./providers/hover-provider";
import { BlameDecorator } from "./providers/blame-decorator";
import { CurrentTaskProvider, TaskListProvider, PlaceholderProvider } from "./providers/tree-provider";
import { registerStatusCommands } from "./commands/start-task";
import { registerLinkCommands } from "./commands/link-commit";
import { registerCreateCommand } from "./commands/create-task";
import { registerTraceCommands } from "./commands/show-trace";

let blameDecorator: BlameDecorator | undefined;

export function activate(context: vscode.ExtensionContext): void {
    const config = resolveConfig();

    if (!config) {
        // Register placeholder providers so the views don't show errors
        context.subscriptions.push(
            vscode.window.registerTreeDataProvider("warrant.currentTask",
                new PlaceholderProvider("No .warrant/.env found")),
            vscode.window.registerTreeDataProvider("warrant.tasks",
                new PlaceholderProvider("Configure Warrant to see tasks")),
        );
        return;
    }

    const log = vscode.window.createOutputChannel("Warrant");
    log.appendLine(`Config: url=${config.url} org=${config.org} project=${config.project} prefix=${config.prefix} token=${config.token.slice(0, 6)}...`);

    const cache = new Cache();
    const api = new ApiClient(config, cache, log);
    const prefix = config.prefix;

    // Status bar
    const statusBar = createStatusBar(api, prefix);
    context.subscriptions.push(statusBar);

    // Refresh status bar on branch change
    const gitHeadWatcher = vscode.workspace.createFileSystemWatcher("**/.git/HEAD");
    gitHeadWatcher.onDidChange(() => refreshStatusBar(api, prefix));
    context.subscriptions.push(gitHeadWatcher);

    // Sidebar tree views — registered early so VS Code never sees missing providers
    const currentTaskProvider = new CurrentTaskProvider(api, prefix);
    const taskListProvider = new TaskListProvider(api);

    context.subscriptions.push(
        vscode.window.registerTreeDataProvider("warrant.currentTask", currentTaskProvider),
        vscode.window.registerTreeDataProvider("warrant.tasks", taskListProvider),
    );

    // Refresh on window focus
    context.subscriptions.push(
        vscode.window.onDidChangeWindowState(e => {
            if (e.focused) {
                refreshStatusBar(api, prefix);
                currentTaskProvider.refresh();
            }
        }),
    );

    // Hover provider — works in all file types
    context.subscriptions.push(
        vscode.languages.registerHoverProvider({ scheme: "file" }, new TaskHoverProvider(api, prefix)),
    );

    // Blame decorations
    const blameEnabled = vscode.workspace.getConfiguration("warrant").get("blameEnabled", true);
    if (blameEnabled) {
        blameDecorator = new BlameDecorator(api, cache, prefix);
        context.subscriptions.push(blameDecorator);
    }

    // Commands
    context.subscriptions.push(
        ...registerStatusCommands(api, prefix),
        ...registerLinkCommands(api, prefix),
        ...registerCreateCommand(api),
        ...registerTraceCommands(api, prefix),
        vscode.commands.registerCommand("warrant.refreshTasks", () => {
            api.invalidateAll();
            currentTaskProvider.refresh();
            taskListProvider.refresh();
            refreshStatusBar(api, prefix);
        }),
    );
}

export function deactivate(): void {
    blameDecorator?.dispose();
}
