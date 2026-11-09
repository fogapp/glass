/** Only a path on this host. A fog sign-in carries where the person was
 *  headed through the browser (a URL fragment, the link endpoint's answer),
 *  which is the browser's to tamper with — so anything that could leave the
 *  host ("//evil.example", "/\\evil.example", an absolute URL) becomes "/". */
export function safeReturnPath(raw: string | null | undefined): string {
  return raw && raw.startsWith("/") && !raw.startsWith("//") && !raw.includes("\\") ? raw : "/";
}
