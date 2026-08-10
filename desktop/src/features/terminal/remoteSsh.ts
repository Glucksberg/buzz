import { useQuery } from "@tanstack/react-query";

import { invokeTauri } from "@/shared/api/tauri";

export function getRemoteSshUrl(): Promise<string | null> {
  return invokeTauri<string | null>("get_remote_ssh_url");
}

/**
 * Relay-advertised SSH entry point. The native command returns it only when
 * the current desktop identity matches the relay's NIP-11 operator pubkey.
 */
export function useRemoteSshUrl(currentPubkey?: string, relayScope?: string) {
  return useQuery({
    enabled: Boolean(currentPubkey && relayScope),
    queryKey: [
      "remoteSshUrl",
      currentPubkey?.toLowerCase() ?? null,
      relayScope ?? null,
    ],
    queryFn: getRemoteSshUrl,
    staleTime: 5 * 60 * 1000,
  });
}
