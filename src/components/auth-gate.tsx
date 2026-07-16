import type { ReactNode } from "react";

import { Button } from "@/components/ui/button";
import { authRequired, useAuth } from "@/lib/auth";

/**
 * Blocks the app until the user holds a valid Auth0 session, in environments that require
 * one (sit/uat/production). In "local" — a developer machine or the Lovable sandbox —
 * `authRequired` is false and children render straight through, so the citizen developer
 * never meets a login wall while ideating.
 *
 * `authRequired` is derived from VITE_APP_ENV at build time and the build refuses to
 * produce a secured bundle without Auth0 config (see vite.config.ts), so this gate cannot
 * be turned off by anything a running client controls.
 */
export function AuthGate({ children }: { children: ReactNode }) {
  const { isLoading, isAuthenticated, login } = useAuth();

  if (!authRequired) return <>{children}</>;

  if (isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background px-4">
        <p className="text-sm text-muted-foreground">Checking your session…</p>
      </div>
    );
  }

  if (!isAuthenticated) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background px-4">
        <div className="w-full max-w-sm rounded-2xl border border-border bg-card p-6 text-center shadow-lg">
          <h1 className="text-lg font-semibold text-card-foreground">Sign in to continue</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            This environment requires an account. You'll be redirected to your identity provider.
          </p>
          <Button className="mt-6 w-full" onClick={login}>
            Sign in
          </Button>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}
