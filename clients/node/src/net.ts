import type { IncomingMessage } from "node:http";
import { isIP } from "node:net";

/**
 * Keys whose values never leave the process, whatever the caller passed —
 * the gem's pattern exactly (`Glass::Config::FILTER_KEYS`), so a key is
 * filtered or not whichever client saw it. A filtered key is kept and its
 * value replaced with `FILTERED`, as the gem does.
 */
export const FILTER_KEYS = /password|passwd|secret|token(?!s)|api_key|apikey|access_key|auth|credential|cookie|session(?:_?id)?$/i;
export const FILTERED = "[FILTERED]";

export type Origin = "lan" | "vpn" | "tunnel" | "public";

/**
 * What an address is to us: a private hop (loopback, RFC 1918, link-local,
 * a ULA), the CGNAT range every home VPN hands out, or the public internet.
 * Null when it is not an address at all (a unix socket, junk): it does not
 * decide anything.
 */
export function addressKind(address: string): "private" | "vpn" | "public" | null {
  const name = address.trim().replace(/^\[|\]$/g, "").replace(/^::ffff:(?=\d+\.\d+\.\d+\.\d+$)/i, "");
  const family = isIP(name);
  if (family === 4) {
    const [a, b] = name.split(".").map(Number) as [number, number];
    if (a === 100 && b >= 64 && b <= 127) return "vpn";
    if (a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254)) return "private";
    return "public";
  }
  if (family === 6) return name === "::1" || /^f[cd]/i.test(name) || /^fe[89ab]/i.test(name) ? "private" : "public";
  return null;
}

/**
 * Where a request came from, as a network class, and the address that
 * decided it — hashed into an anonymous visitor, never sent. The gem's rule
 * (`Glass::Origin.classify_with_address`), case for case: the conformance
 * kit's `origin.json` holds both clients to it.
 *
 * Behind Cloudflare (`CF-Connecting-IP`, or a bare `CF-Ray`) it is a tunnel.
 * Otherwise the chain is X-Forwarded-For plus the socket's peer, walked from
 * the nearest hop outwards: the first address that is not private decides.
 * Walking from the near end means a client on the public internet cannot
 * claim the LAN, or someone else's address, with its own X-Forwarded-For —
 * the proxy appends the real address after it.
 */
export function originOf(
  remote: string | undefined,
  forwarded: string | undefined,
  cfConnectingIp?: string,
  cfRay?: string,
): { origin: Origin | null; address: string | null } {
  if (cfConnectingIp !== undefined) return { origin: "tunnel", address: cfConnectingIp.trim() };
  const chain = [...(forwarded ? forwarded.split(",").map((hop) => hop.trim()) : []), ...(remote ? [remote.trim()] : [])].filter(Boolean);
  if (cfRay !== undefined) return { origin: "tunnel", address: chain[0] ?? null };
  if (chain.length === 0) return { origin: null, address: null };
  for (let index = chain.length - 1; index >= 0; index -= 1) {
    const address = chain[index]!;
    const kind = addressKind(address);
    if (kind === "vpn" || kind === "public") return { origin: kind, address };
  }
  return { origin: "lan", address: chain[0]! };
}

/** `originOf` for a request as Node hands it over. */
export function requestOrigin(request: IncomingMessage): { origin: Origin | null; address: string | null } {
  return originOf(request.socket?.remoteAddress, headerOf(request, "x-forwarded-for"), headerOf(request, "cf-connecting-ip"), headerOf(request, "cf-ray"));
}

/** One request header as a string: a repeated header is joined, as HTTP says it means. */
export function headerOf(request: IncomingMessage, name: string): string | undefined {
  const value = request.headers[name];
  return Array.isArray(value) ? value.join(",") : value;
}
