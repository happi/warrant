/**
 * Extract task IDs from text. Matches patterns like ZIN-42, SF-103, HL-7.
 * When a prefix is provided, only matches that prefix.
 */

const GENERIC_PATTERN = /\b([A-Z]{1,10}-\d+)\b/g;

export function extractTaskId(text: string, prefix?: string): string | null {
    if (prefix) {
        const re = new RegExp(`\\b(${prefix}-\\d+)\\b`, "i");
        const m = text.match(re);
        return m ? m[1].toUpperCase() : null;
    }
    const m = text.match(GENERIC_PATTERN);
    return m ? m[0] : null;
}

export function extractAllTaskIds(text: string, prefix?: string): string[] {
    if (prefix) {
        const re = new RegExp(`\\b(${prefix}-\\d+)\\b`, "gi");
        return [...text.matchAll(re)].map(m => m[1].toUpperCase());
    }
    return [...text.matchAll(GENERIC_PATTERN)].map(m => m[1]);
}

/**
 * Extract task ID from a branch name like "task/ZIN-42-fix-auth"
 */
export function extractTaskIdFromBranch(branch: string, prefix?: string): string | null {
    return extractTaskId(branch, prefix);
}
