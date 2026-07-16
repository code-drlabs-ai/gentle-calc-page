import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { supabaseConfig } from "./env";

/**
 * Supabase client wired to Auth0 via Supabase Third-Party Auth.
 *
 * Supabase is configured to trust our Auth0 tenant as an OIDC issuer and validates the
 * token against Auth0's JWKS. That means the Auth0 access token IS the database
 * credential, RLS reads the caller identity from `auth.jwt() ->> 'sub'`, and there is no
 * shared JWT secret and no custom server in the path — see supabase/migrations and
 * PIPELINE-SETUP.md, Part 7.
 *
 * The anon key compiled into this bundle is public by design: it grants nothing on its own
 * because every table is RLS default-deny. The service_role key must NEVER appear here —
 * it bypasses RLS entirely and belongs only in server-side automation.
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
