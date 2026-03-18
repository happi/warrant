/**
 * Simple LRU cache with TTL. Used to avoid flooding the API
 * on every scroll/hover/blame request.
 */

interface CacheEntry<T> {
    value: T;
    expiresAt: number;
}

export class Cache {
    private store = new Map<string, CacheEntry<unknown>>();
    private maxSize: number;

    constructor(maxSize = 500) {
        this.maxSize = maxSize;
    }

    get<T>(key: string): T | undefined {
        const entry = this.store.get(key);
        if (!entry) return undefined;
        if (Date.now() > entry.expiresAt) {
            this.store.delete(key);
            return undefined;
        }
        // Move to end (LRU)
        this.store.delete(key);
        this.store.set(key, entry);
        return entry.value as T;
    }

    set<T>(key: string, value: T, ttlMs: number): void {
        // Evict oldest if at capacity
        if (this.store.size >= this.maxSize) {
            const oldest = this.store.keys().next().value;
            if (oldest !== undefined) this.store.delete(oldest);
        }
        this.store.set(key, { value, expiresAt: Date.now() + ttlMs });
    }

    invalidate(key: string): void {
        this.store.delete(key);
    }

    clear(): void {
        this.store.clear();
    }
}
