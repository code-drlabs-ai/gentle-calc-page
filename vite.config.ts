// @lovable.dev/vite-tanstack-config already includes the following — do NOT add them manually
// or the app will break with duplicate plugins:
//   - TanStack devtools (dev-only, first), tanstackStart, viteReact, tailwindcss, tsConfigPaths,
//     nitro (build-only using cloudflare as a default target), VITE_* env injection, @ path alias,
//     React/TanStack dedupe, error logger plugins, and sandbox detection (port/host/strictPort).
// You can pass additional config via defineConfig({ vite: { ... }, etc... }) if needed.
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
import { loadEnv, type Plugin } from "vite";

import { envSchema, formatEnvIssues, readEnvSource } from "./src/lib/env.contract";

// Mirrors isSandboxEnvironment() in @lovable.dev/vite-tanstack-config. Inside Lovable the wrapper
// force-pins Nitro to cloudflare-module and owns the output layout; outside it we own the build.
const isLovableSandbox =
  process.env.LOVABLE_SANDBOX === "1" || !!process.env.DEV_SERVER__PROJECT_PATH;

/**
 * Refuses to produce a bundle for a secured environment (sit/uat/production) unless the full
 * Auth0 + Supabase configuration is present. The gate lives in the build — not behind a runtime
 * flag — so there is no combination of settings that ships a real environment with auth disabled.
 */
function validateEnvironmentPlugin(): Plugin {
  return {
    name: "certaintyai:validate-environment",
    enforce: "pre",
    config(_config, { mode }) {
      const source = { ...loadEnv(mode, process.cwd(), "VITE_"), ...process.env };
      const result = envSchema.safeParse(readEnvSource(source));

      if (!result.success) {
        throw new Error(
          `\n[env] Refusing to build with invalid environment configuration:\n${formatEnvIssues(result.error)}\n`,
        );
      }
    },
  };
}

export default defineConfig({
  plugins: [validateEnvironmentPlugin()],
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    // nitro/vite builds from this
    server: { entry: "server" },
    // Ship a prerendered shell + client bundle. Azure Static Web Apps serves static assets only,
    // and Auth0 PKCE / Supabase are both browser-side, so no request-time server is needed.
    // Skip inside the Lovable sandbox: nitro owns the output layout there and the preview
    // server plugin can't find the nitro-emitted entry (index.mjs vs. expected server.js),
    // which makes prerender crawl `/` return 500 and fail the build.
    spa: { enabled: !isLovableSandbox },
    prerender: { enabled: !isLovableSandbox },
  },
  // `nitro: false` is checked BEFORE the wrapper's sandbox branch, so setting it unconditionally
  // would also disable Nitro inside Lovable and break the citizen developer's preview build.
  // Outside the sandbox (our CI) we skip Nitro entirely and emit plain static output for SWA.
  nitro: isLovableSandbox ? undefined : false,
});
