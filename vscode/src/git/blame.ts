import { execFile } from "child_process";
import { extractTaskId } from "../core/task-id-parser";

export interface BlameLine {
    sha: string;
    summary: string;
    taskId: string | null;
    line: number;
}

/**
 * Run git blame for a specific line range. Returns task attribution per line.
 * Uses --porcelain for machine-readable output.
 */
export async function blameLines(
    filePath: string,
    startLine: number,
    endLine: number,
    cwd: string,
    prefix?: string
): Promise<BlameLine[]> {
    return new Promise((resolve) => {
        const args = [
            "blame", "--porcelain",
            `-L`, `${startLine},${endLine}`,
            "--", filePath,
        ];

        execFile("git", args, { cwd, maxBuffer: 1024 * 1024 }, (err, stdout) => {
            if (err) return resolve([]);
            resolve(parsePorcelainBlame(stdout, prefix));
        });
    });
}

function parsePorcelainBlame(output: string, prefix?: string): BlameLine[] {
    const lines = output.split("\n");
    const results: BlameLine[] = [];
    let currentSha = "";
    let currentLine = 0;
    let currentSummary = "";

    for (const line of lines) {
        // Commit header: <sha> <orig-line> <final-line> [<num-lines>]
        const commitMatch = line.match(/^([0-9a-f]{40}) \d+ (\d+)/);
        if (commitMatch) {
            currentSha = commitMatch[1];
            currentLine = parseInt(commitMatch[2], 10);
            continue;
        }

        if (line.startsWith("summary ")) {
            currentSummary = line.slice(8);
            continue;
        }

        // Content line (starts with tab) marks end of a blame entry
        if (line.startsWith("\t")) {
            results.push({
                sha: currentSha,
                summary: currentSummary,
                taskId: extractTaskId(currentSummary, prefix),
                line: currentLine,
            });
        }
    }

    return results;
}
