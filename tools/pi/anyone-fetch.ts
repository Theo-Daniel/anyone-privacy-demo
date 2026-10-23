import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { promisify } from "node:util";
import { isIP } from "node:net";

const run = promisify(execFile);

// One credential per Pi process. Anyone's IsolateSOCKSAuth isolates this
// research traffic from other applications using its SOCKS listener.
const socksIdentity = randomBytes(24).toString("hex");
const allowedURLs = new Set([
  "https://api.ipify.org",
  "https://www.iana.org/domains/reserved",
]);

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "anyone_fetch",
    label: "Anyone Fetch",
    description:
      "Fetch an allowlisted HTTPS research page through Anyone, never directly. " +
      "Allowed URLs: https://api.ipify.org and https://www.iana.org/domains/reserved. " +
      "Use this tool when asked for Anyone exit IP or IANA reserved domains.",
    parameters: Type.Object({
      url: Type.String({ description: "The exact allowlisted HTTPS URL to fetch" }),
    }),
    async execute(_toolCallId, params) {
      if (!allowedURLs.has(params.url)) {
        throw new Error("Blocked: URL is not in the Anyone research allowlist");
      }

      // Explicit proxy and remote DNS; do not inherit NO_PROXY exceptions.
      // No shell interpolation, no redirects and no direct fallback.
      const { stdout } = await run(
        "/usr/bin/curl",
        [
          "--fail",
          "--silent",
          "--show-error",
          "--max-time", "45",
          "--max-filesize", "131072",
          "--proto", "=https",
          "--proxy", "socks5h://127.0.0.1:9150",
          "--proxy-user", `${socksIdentity}:pi`,
          "--noproxy", "",
          "--write-out", "\nANYONE_HTTP_CODE:%{http_code}",
          params.url,
        ],
        { timeout: 50_000, maxBuffer: 150_000 },
      );

      const match = stdout.match(/\nANYONE_HTTP_CODE:(\d{3})$/);
      if (!match || match[1] !== "200") {
        throw new Error("Anyone routed fetch failed or received a non-200 response");
      }
      const body = stdout.slice(0, match.index);

      if (params.url === "https://api.ipify.org") {
        const exitIP = body.trim();
        if (!isIP(exitIP)) throw new Error("Invalid Anyone exit IP result");
        return {
          content: [{ type: "text", text: `Anyone exit IP: ${exitIP}` }],
          details: { transport: "Anyone SOCKS5 authentication", exitIP },
        };
      }

      const title = (body.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "(title unavailable)")
        .replace(/\s+/g, " ").trim();
      const main = body.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1] ?? body;
      const excerpt = main
        .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
        .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
        .replace(/<[^>]+>/g, " ")
        .replace(/&nbsp;|&#160;/gi, " ")
        .replace(/&amp;/gi, "&")
        .replace(/\s+/g, " ").trim().slice(0, 2200);
      return {
        content: [{ type: "text", text: `Anyone-routed HTTPS fetch succeeded.\nTitle: ${title}\nPage text: ${excerpt}` }],
        details: { transport: "Anyone SOCKS5 authentication", url: params.url },
      };
    },
  });
}
