import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/lib/auth";
import { useSupabase } from "./use-supabase";

const HISTORY_LIMIT = 20;

export type CalculationInput = { expression: string; result: string };

/**
 * Per-user calculation history.
 *
 * Note what is NOT sent: user_id. The column defaults to the caller's Auth0 subject
 * (`auth.jwt() ->> 'sub'`) and the RLS WITH CHECK re-verifies it, so a client cannot write
 * a row attributed to someone else even by sending an explicit user_id. Scoping on read is
 * likewise RLS's job, not the query's — the select below is deliberately unfiltered because
 * the policy, not the client, decides which rows exist.
 */
export function useCalculationHistory() {
  const supabase = useSupabase();
  const { isAuthenticated, user } = useAuth();
  const queryClient = useQueryClient();

  const enabled = Boolean(supabase) && isAuthenticated;
  const queryKey = ["calculations", user?.sub] as const;

  const history = useQuery({
    queryKey,
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase!
        .from("calculations")
        .select("id, user_id, expression, result, created_at")
        .order("created_at", { ascending: false })
        .limit(HISTORY_LIMIT);

      if (error) throw new Error(error.message);
      return data;
    },
  });

  const save = useMutation({
    mutationFn: async (input: CalculationInput) => {
      const { error } = await supabase!.from("calculations").insert(input);
      if (error) throw new Error(error.message);
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey }),
  });

  const clear = useMutation({
    mutationFn: async () => {
      // RLS scopes the delete to the caller's own rows; the neq filter is required
      // because PostgREST rejects an unfiltered DELETE.
      const { error } = await supabase!.from("calculations").delete().neq("id", "00000000-0000-0000-0000-000000000000");
      if (error) throw new Error(error.message);
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey }),
  });

  return { enabled, history, save, clear };
}
