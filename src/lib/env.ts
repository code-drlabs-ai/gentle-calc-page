import {
  envSchema,
  formatEnvIssues,
  isSecuredEnvironment,
  readEnvSource,
  type AppEnv,
} from "./env.contract";

/**
 * Runtime view of the validated environment.
 *
 * vite.config.ts runs the same schema at build time, so a secured build that reaches
 * here is already known-good. This second pass is defence in depth for the case where
 * a bundle is served with values that were never checked (e.g. hand-edited output).
 */

function loadEnv(): AppEnv {
  const result = envSchema.safeParse(
    readEnvSource(import.meta.env as unknown as Record<string, unknown>),
  );

  if (!result.success) {
    // Fail closed. A secured environment with broken config must not render an
    // unauthenticated app; refusing to boot is the safe outcome.
    throw new Error(`Invalid environment configuration:\n${formatEnvIssues(result.error)}`);
  }

  return result.data;
}

export const env = loadEnv();

/** True in sit/uat/production: a user must hold a valid Auth0 session to use the app. */
export const authRequired = isSecuredEnvironment(env.VITE_APP_ENV);

/**
 * Auth0 is wired up whenever it is configured. In "local" it is optional, so the Lovable
 * sandbox renders the app without a tenant; configuring it locally opts into the real flow.
 */
export const auth0Config =
  env.VITE_AUTH0_DOMAIN && env.VITE_AUTH0_CLIENT_ID
    ? {
        domain: env.VITE_AUTH0_DOMAIN,
        clientId: env.VITE_AUTH0_CLIENT_ID,
        audience: env.VITE_AUTH0_AUDIENCE,
      }
    : undefined;

export const supabaseConfig =
  env.VITE_SUPABASE_URL && env.VITE_SUPABASE_ANON_KEY
    ? { url: env.VITE_SUPABASE_URL, anonKey: env.VITE_SUPABASE_ANON_KEY }
    : undefined;

if (authRequired && !auth0Config) {
  throw new Error(
    `VITE_APP_ENV="${env.VITE_APP_ENV}" requires Auth0, but no Auth0 configuration was compiled into this bundle.`,
  );
}
