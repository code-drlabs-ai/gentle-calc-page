import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { supabaseConfig } from "./env";

/**
 * REST client for our SELF-HOSTED PostgREST (there is no managed Supabase, and no GoTrue).
 *
 * `supabase-js` is used purely as a typed PostgREST client. `VITE_SUPABASE_URL` is the
 * Front Door hostname; supabase-js calls `<url>/rest/v1/<table>`, Front Door routes
 * `/rest/v1/*` to the PostgREST Container App (stripping the prefix), and PostgREST
 * validates the bearer token against Auth0's JWKS directly. So the Auth0 access token IS
 * the database credential, RLS reads the caller from `auth.jwt_sub()`, and no custom
 * server and no shared JWT secret sit in the path — see db/bootstrap, supabase/migrations,
 * postgrest/README.md, and PIPELINE-SETUP.md.
 *
 * `VITE_SUPABASE_ANON_KEY` is only here because supabase-js requires an `apikey`. PostgREST
 * ignores that header (it authorizes on the Auth0 bearer alone), so the value is a
 * non-secret placeholder, not a credential. The Postgres `service_role` must NEVER appear
 * in this bundle or on any request-path container — it bypasses RLS.
 */

export type Database = {
  public: {
    Tables: {
      calculations: {
        Row: {
          id: string;
          user_id: string;
          expression: string;
          result: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          expression: string;
          result: string;
          created_at?: string;
        };
        // History is append-only. No UPDATE policy exists, so any update is rejected by
        // RLS at the database regardless of what this type would permit.
        Update: Record<string, never>;
        Relationships: [];
      };
    };
    // Required by supabase-js's GenericSchema constraint. Omitting them silently widens
    // every query result to `never` instead of raising an error at the createClient call.
    Views: Record<string, never>;
    Functions: Record<string, never>;
  };
};

export type AppSupabaseClient = SupabaseClient<Database>;

/**
 * `getToken` is called by supabase-js before every request, so a rotated or refreshed
 * Auth0 token is picked up without rebuilding the client.
 */
export function createSupabaseClient(
  getToken: () => Promise<string | undefined>,
): AppSupabaseClient | undefined {
  if (!supabaseConfig) return undefined;

  return createClient<Database>(supabaseConfig.url, supabaseConfig.anonKey, {
    accessToken: async () => (await getToken()) ?? null,
    auth: {
      // Third-Party Auth owns the session; Supabase's own auth must stay out of the way.
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}
