import { z } from "zod";

/**
 * Single source of truth for environment configuration, shared by the build-time
 * gate in vite.config.ts and the runtime loader in src/lib/env.ts. Keep it free of
 * `import.meta.env` / `process.env` access so both callers can supply their own source.
 */

export const APP_ENVIRONMENTS = ["local", "sit", "uat", "production"] as const;
export type AppEnvironment = (typeof APP_ENVIRONMENTS)[number];

/**
 * Environments that serve real users and real data. Authentication is not optional
 * in these — see SECURED_ENV_REQUIRED_KEYS.
 *
 * "local" covers both a developer machine and the Lovable preview sandbox, where the
 * citizen developer must be able to ideate without an Auth0 tenant.
 */
export const SECURED_ENVIRONMENTS = [
  "sit",
  "uat",
  "production",
] as const satisfies readonly AppEnvironment[];

/** Config that MUST be present before a secured environment is allowed to build or boot. */
export const SECURED_ENV_REQUIRED_KEYS = [
  "VITE_AUTH0_DOMAIN",
  "VITE_AUTH0_CLIENT_ID",
  "VITE_AUTH0_AUDIENCE",
  "VITE_SUPABASE_URL",
  "VITE_SUPABASE_ANON_KEY",
] as const;

export function isSecuredEnvironment(
  value: unknown,
): value is (typeof SECURED_ENVIRONMENTS)[number] {
  return SECURED_ENVIRONMENTS.includes(value as (typeof SECURED_ENVIRONMENTS)[number]);
}

const optionalNonEmpty = z
  .string()
  .trim()
  .min(1)
  .optional()
  // Treat "" the same as unset: CI exports empty strings for undefined secrets, and an
  // empty Auth0 domain must never read as "configured".
  .catch(undefined);

const baseEnvSchema = z.object({
  VITE_APP_ENV: z.enum(APP_ENVIRONMENTS).default("local"),
  VITE_AUTH0_DOMAIN: optionalNonEmpty,
  VITE_AUTH0_CLIENT_ID: optionalNonEmpty,
  VITE_AUTH0_AUDIENCE: optionalNonEmpty,
  VITE_SUPABASE_URL: z.string().url().optional().catch(undefined),
  VITE_SUPABASE_ANON_KEY: optionalNonEmpty,
});

/**
 * Fails closed: in sit/uat/production every secured key is mandatory, so there is no
 * build or boot path that produces a running app with authentication switched off.
 */
export const envSchema = baseEnvSchema.superRefine((value, ctx) => {
  if (!isSecuredEnvironment(value.VITE_APP_ENV)) return;

  for (const key of SECURED_ENV_REQUIRED_KEYS) {
    if (!value[key]) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: [key],
        message: `${key} is required when VITE_APP_ENV="${value.VITE_APP_ENV}". Secured environments cannot run unauthenticated.`,
      });
    }
  }
});

export type AppEnv = z.infer<typeof envSchema>;

/** Normalises an arbitrary env bag (import.meta.env / process.env) into just our keys. */
export function readEnvSource(source: Record<string, unknown>): Record<string, unknown> {
  return {
    VITE_APP_ENV: source.VITE_APP_ENV,
    VITE_AUTH0_DOMAIN: source.VITE_AUTH0_DOMAIN,
    VITE_AUTH0_CLIENT_ID: source.VITE_AUTH0_CLIENT_ID,
    VITE_AUTH0_AUDIENCE: source.VITE_AUTH0_AUDIENCE,
    VITE_SUPABASE_URL: source.VITE_SUPABASE_URL,
    VITE_SUPABASE_ANON_KEY: source.VITE_SUPABASE_ANON_KEY,
  };
}

export function formatEnvIssues(error: z.ZodError): string {
  return error.issues.map((issue) => `  - ${issue.message}`).join("\n");
}
