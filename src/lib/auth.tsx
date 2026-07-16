import { Auth0Provider, useAuth0 } from "@auth0/auth0-react";
import type { ReactNode } from "react";

import { auth0Config, authRequired } from "./env";

/**
 * Auth0 Authorization Code flow with PKCE (the SPA / public-client flow — no client secret
 * is present in, or needed by, this bundle).
 *
 * Token storage: cacheLocation="memory" keeps access and refresh tokens out of
 * localStorage, so an XSS bug cannot exfiltrate a long-lived credential. The cost is that
 * a page reload has no local session and must silently re-authenticate against the Auth0
 * session cookie. That silent call is a third-party request unless Auth0 is served from a
 * custom domain on the app's own site, so SIT/UAT/Production each require an Auth0 custom
 * domain — see PIPELINE-SETUP.md, Part 6. Without it, users get bounced to the login page
 * on every reload.
 */

function redirectUri(): string | undefined {
  // Guarded for the prerender pass, which renders the shell in Node where window is absent.
  return typeof window === "undefined" ? undefined : window.location.origin;
}

/** Strips Auth0's ?code=&state= from the address bar after the redirect completes. */
function onRedirectCallback(): void {
  if (typeof window === "undefined") return;
  window.history.replaceState({}, document.title, window.location.pathname);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  // In "local" (developer machine / Lovable sandbox) Auth0 is optional, so the citizen
  // developer can ideate without a tenant. env.ts guarantees auth0Config exists whenever
  // authRequired is true, so this branch can never drop auth in a secured environment.
  if (!auth0Config) return <>{children}</>;

  return (
    <Auth0Provider
      domain={auth0Config.domain}
      clientId={auth0Config.clientId}
      authorizationParams={{
        redirect_uri: redirectUri(),
        audience: auth0Config.audience,
      }}
      // Refresh token rotation: each refresh invalidates the previous token, so a stolen
      // one is single-use and detectable as reuse by Auth0.
      useRefreshTokens
      // Do not fall back to iframe silent auth when a refresh token is unavailable; the
      // fallback depends on third-party cookies and fails open in confusing ways.
      useRefreshTokensFallback={false}
      cacheLocation="memory"
      onRedirectCallback={onRedirectCallback}
    >
      {children}
    </Auth0Provider>
  );
}

export type AuthState = {
  isLoading: boolean;
  isAuthenticated: boolean;
  user?: { name?: string; email?: string; sub?: string };
  login: () => void;
  logout: () => void;
  getAccessToken: () => Promise<string | undefined>;
};

/**
 * Auth state for the app. When Auth0 is not configured (local only), reports an
 * unauthenticated, non-blocking session so the calculator still renders.
 */
export function useAuth(): AuthState {
  const auth0 = useAuth0();

  if (!auth0Config) {
    return {
      isLoading: false,
      isAuthenticated: false,
      user: undefined,
      login: () => {},
      logout: () => {},
      getAccessToken: async () => undefined,
    };
  }

  return {
    isLoading: auth0.isLoading,
    isAuthenticated: auth0.isAuthenticated,
    user: auth0.user,
    login: () => void auth0.loginWithRedirect(),
    logout: () =>
      auth0.logout({
        logoutParams: {
          returnTo: typeof window === "undefined" ? undefined : window.location.origin,
        },
      }),
    getAccessToken: async () => {
      try {
        return await auth0.getAccessTokenSilently();
      } catch {
        // No usable session. Callers treat this as signed-out rather than crashing.
        return undefined;
      }
    },
  };
}

export { authRequired };
