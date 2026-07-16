#!/usr/bin/env node
// Generates dist/client/staticwebapp.config.json after a build.
//
// Why generated rather than committed:
//  1. The Content-Security-Policy must name the exact Auth0 and Supabase origins, and those
//     differ per environment (sit/uat/production). One committed file cannot be correct for
//     all three.
//  2. TanStack Start emits inline <script> blocks (scroll restoration, stream barrier). We
//     allow them by SHA-256 hash instead of 'unsafe-inline', and the hashes change whenever
//     the framework's emitted script changes. Reading them off the actual build output keeps
//     the policy honest — a stale hand-maintained hash would fail closed in production only.
//
// Usage: node scripts/generate-swa-config.mjs [--out-dir dist/client]

import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const OUT_DIR = process.env.SWA_OUT_DIR ?? "dist/client";
const SHELL = "_shell.html";

/** Origin (scheme://host) of a URL, for use in a CSP source list. */
function originOf(value, label) {
  if (!value) return undefined;
  try {
    return new URL(value.startsWith("http") ? value : `https://${value}`).origin;
  } catch {
    throw new Error(`[swa-config] ${label} is not a valid URL/host: ${JSON.stringify(value)}`);
  }
}

/** SHA-256 of every inline <script> body in the shell, in CSP hash-source form. */
async function inlineScriptHashes(shellPath) {
  const html = await readFile(shellPath, "utf8");
  const hashes = new Set();

  // Inline = a <script> tag with no src attribute. Non-greedy body match; the shell is
  // framework-generated and contains no </script> inside string literals.
  const pattern = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;

  for (const match of html.matchAll(pattern)) {
    const body = match[1];
    if (body.length === 0) continue;
    hashes.add(`'sha256-${createHash("sha256").update(body, "utf8").digest("base64")}'`);
  }

  return [...hashes];
}

function buildCsp({ scriptHashes, auth0Origin, supabaseOrigin }) {
  // supabaseOrigin here is the Front Door hostname that fronts PostgREST for this env.
  const connect = ["'self'", auth0Origin, supabaseOrigin].filter(Boolean);

  return [
    "default-src 'self'",
    `script-src 'self' ${scriptHashes.join(" ")}`.trim(),
    // Inline styles only. React sets style attributes and Tailwind injects a style tag;
    // neither can execute code, so this is materially weaker than script 'unsafe-inline'.
    "style-src 'self' 'unsafe-inline'",
    // https: covers identity-provider avatar hosts, which vary per social connection.
    "img-src 'self' data: https:",
    "font-src 'self' data:",
    `connect-src ${connect.join(" ")}`,
    // auth0-spa-js runs its refresh-token exchange in a Worker created from a blob URL.
    // Without blob: here, silent token renewal fails with an opaque CSP violation.
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "upgrade-insecure-requests",
  ].join("; ");
}

async function main() {
  const appEnv = process.env.VITE_APP_ENV ?? "local";
  const auth0Origin = originOf(process.env.VITE_AUTH0_DOMAIN, "VITE_AUTH0_DOMAIN");
  const supabaseOrigin = originOf(process.env.VITE_SUPABASE_URL, "VITE_SUPABASE_URL");

  const scriptHashes = await inlineScriptHashes(join(OUT_DIR, SHELL));
  if (scriptHashes.length === 0) {
    // Never silently emit a policy that would block a script we failed to detect.
    throw new Error(
      `[swa-config] No inline scripts found in ${join(OUT_DIR, SHELL)}. The shell format likely changed; ` +
        `re-check the extraction regex before shipping, or the app will be blocked by CSP in production.`,
    );
  }

  const config = {
    // SPA routing: every non-asset path serves the prerendered shell, which then hydrates
    // and lets the client router resolve the route. Note the build emits _shell.html and no
    // index.html, so this rewrite is what makes deep links work at all.
    navigationFallback: {
      rewrite: `/${SHELL}`,
      exclude: [
        "/assets/*",
        "/favicon.ico",
        "*.{png,jpg,jpeg,gif,svg,webp,ico,css,js,map,txt,xml,json}",
      ],
    },
    globalHeaders: {
      "Content-Security-Policy": buildCsp({ scriptHashes, auth0Origin, supabaseOrigin }),
      // 2 years, preload-eligible. SWA terminates TLS and serves https by default.
      "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
      "X-Content-Type-Options": "nosniff",
      // Redundant with frame-ancestors for modern browsers; retained for older ones.
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      "Permissions-Policy":
        "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Resource-Policy": "same-origin",
    },
    routes: [
      {
        // Content-addressed filenames; safe to cache immutably.
        route: "/assets/*",
        headers: { "Cache-Control": "public, max-age=31536000, immutable" },
      },
      {
        // The shell must never be cached, or a deploy would keep serving stale asset
        // references (and a stale CSP) to returning users.
        route: `/${SHELL}`,
        headers: { "Cache-Control": "no-cache, no-store, must-revalidate" },
      },
    ],
    responseOverrides: {
      404: { rewrite: `/${SHELL}`, statusCode: 200 },
    },
  };

  const target = join(OUT_DIR, "staticwebapp.config.json");
  await writeFile(target, `${JSON.stringify(config, null, 2)}\n`, "utf8");

  console.log(`[swa-config] wrote ${target}`);
  console.log(`[swa-config] env=${appEnv} inline-script-hashes=${scriptHashes.length}`);
  console.log(
    `[swa-config] connect-src: auth0=${auth0Origin ?? "(none)"} supabase=${supabaseOrigin ?? "(none)"}`,
  );

  if (appEnv !== "local" && (!auth0Origin || !supabaseOrigin)) {
    throw new Error(
      `[swa-config] VITE_APP_ENV="${appEnv}" but Auth0/Supabase origins are missing; the CSP would block sign-in.`,
    );
  }
}

main().catch((error) => {
  console.error(error.message ?? error);
  process.exit(1);
});
