import { useMemo, useRef } from "react";

import { useAuth } from "@/lib/auth";
import { createSupabaseClient, type AppSupabaseClient } from "@/lib/supabase";

/**
 * A stable Supabase client bound to the current Auth0 session.
 *
 * The client is built once; the token getter is read through a ref on each request so
 * token refreshes are picked up without tearing down and rebuilding the client (which
 * would drop in-flight requests and realtime subscriptions).
 *
 * Returns undefined when Supabase is not configured (local without a project).
 */
export function useSupabase(): AppSupabaseClient | undefined {
  const { getAccessToken } = useAuth();

  const getAccessTokenRef = useRef(getAccessToken);
  getAccessTokenRef.current = getAccessToken;

  return useMemo(() => createSupabaseClient(() => getAccessTokenRef.current()), []);
}
