interface Failure {
  code?: string;
  message?: string;
  status?: number;
  details?: { status?: number; retryAfterMs?: number };
}

function retryDelay(error: unknown): number | undefined {
  if (!error || typeof error !== "object") return;
  const failure = error as Failure;
  if (failure.status !== 429 && failure.details?.status !== 429 &&
      failure.code !== "RATE_LIMITED" && !/^HTTP 429\b/.test(failure.message ?? "")) return;
  const hint = failure.details?.retryAfterMs;
  // CadencR 0.16's broker forwards the status, but not Retry-After. Its
  // fixed-window quota resets within one minute, so wait a complete window.
  return typeof hint === "number" && Number.isFinite(hint) && hint > 0 ? Math.max(1000, hint) : 60_000;
}

/** A shared cooldown for all requests from this guest, including queued keys.
 * Only a 429 is retried: the host rejected it before reaching Neovim. Retrying
 * transport timeouts or other failures could execute keyboard input twice. */
export class Requests {
  private blockedUntil = 0;
  private closed = false;

  constructor(private onHold: (waiting: boolean) => void) {}

  close(): void {
    this.closed = true;
  }

  async call<T>(send: () => Promise<T>): Promise<T> {
    for (;;) {
      while (!this.closed && Date.now() < this.blockedUntil) {
        await new Promise((resolve) => setTimeout(resolve, Math.min(250, this.blockedUntil - Date.now())));
      }
      if (this.closed) throw new Error("Review tab closed.");
      if (this.blockedUntil) {
        this.blockedUntil = 0;
        this.onHold(false);
      }
      try {
        return await send();
      } catch (problem) {
        const delay = retryDelay(problem);
        if (delay === undefined || this.closed) throw problem;
        this.blockedUntil = Math.max(this.blockedUntil, Date.now() + delay);
        this.onHold(true);
      }
    }
  }
}
