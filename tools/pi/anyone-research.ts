/**
 * Anyone Protocol research tools for Pi 1.3.0.
 * All web traffic goes via Anyone's SOCKS5 listener, with remote DNS.
 * Search via DuckDuckGo HTML, then read only URLs discovered by that search.
 * No shell commands exposed to the agent; no direct or no-auth fallback.
 * Public, non-sensitive demo queries only. No assertion of anonymity from
 * search engines, destination sites, or the local environment.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { isIP } from "node:net";
import { promisify } from "node:util";

const run = promisify(execFile);
const socksIdentity = randomBytes(24).toString("hex");
const discovered = new Set<string>();
const MAX_DISCOVERED = 80;
const MAX_SEARCH_RESULTS = 8;

function decodeHtml(value: string): string {
  return value.replace(/&(#(?:x[0-9a-f]+|\d+)|amp|lt|gt|quot|apos|nbsp|ldquo|rdquo|lsquo|rsquo|ndash|mdash);/gi, (match, entity: string) => {
    const t = entity.toLowerCase();
    const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', ndash: "–", mdash: "—" };
    if (t in named) return named[t];
    if (t.startsWith("#")) {
      const num = t[1] === "x" ? parseInt(t.slice(2), 16) : parseInt(t.slice(1), 10);
      if (Number.isInteger(num) && num > 0 && num <= 0x10ffff && (num < 0xd800 || num > 0xdfff)) return String.fromCodePoint(num);
    }
    return match;
  });
}

function stripHtml(value: string): string {
  return decodeHtml(value
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(?:script|style|svg|noscript|header|footer|nav)\b[^>]*>[\s\S]*?<\/(?:script|style|svg|noscript|header|footer|nav)>/gi, " ")
    .replace(/<[^>]*>/g, " "))
    .replace(/\s+/g, " ").trim();
}

function safeURL(raw: string): string | null {
  try {
    if (raw.length > 1900 || /[\u0000-\u001f\u007f]/.test(raw)) return null;
    const u = new URL(raw);
    if (u.protocol !== "https:" || (u.port && u.port !== "443") || u.username || u.password || u.hash) return null;
    const host = u.hostname.toLowerCase().replace(/\.$/, "");
    if (!host.includes(".") || isIP(host) || host === "localhost" ||
        [".local", ".localhost", ".internal", ".test", ".invalid", ".onion"].some(s => host.endsWith(s))) return null;
    u.hash = "";
    return u.href;
  } catch {
    return null;
  }
}

function resultURL(raw: string): string | null {
  const href = decodeHtml(raw);
  try {
    const parsed = new URL(href, "https://html.duckduckgo.com/html/");
    const unwrapped = parsed.searchParams.get("uddg");
    return safeURL(unwrapped ?? parsed.href);
  } catch {
    return null;
  }
}

async function throughAnyone(url: string, maxBytes: number): Promise<string> {
  // `-q` as first curl argument disables ~/.curlrc. --noproxy "" suppresses
  // exclusions, while socks5h ensures DNS is performed by Anyone's exit.
  const args = [
    "-q", "--fail", "--silent", "--show-error", "--max-time", "45",
    "--max-filesize", String(maxBytes), "--proto", "=https",
    "--proxy", "socks5h://127.0.0.1:9150", "--proxy-user", `${socksIdentity}:pi-research`,
    "--noproxy", "", "--user-agent", "Mozilla/5.0 (compatible; AnyonePiResearch/1.0)",
    "--header", "Accept: text/html,application/xhtml+xml",
    "--write-out", "\nANYONE_HTTP_CODE:%{http_code}", url,
  ];
  const { stdout } = await run("/usr/bin/curl", args, {
    encoding: "utf8", timeout: 50_000, maxBuffer: maxBytes + 32_768,
    env: { PATH: "/usr/bin:/bin", HOME: process.env.HOME ?? "" },
  });
  const match = stdout.match(/\nANYONE_HTTP_CODE:(\d{3})$/);
  if (!match || match[1] !== "200") throw new Error("Anyone HTTPS request did not return HTTP 200");
  return stdout.slice(0, match.index);
}

function parseSearchResults(page: string): Array<{ title: string; url: string; snippet: string }> {
  const results: Array<{ title: string; url: string; snippet: string }> = [];
  const seen = new Set<string>();
  const links = /<a\b([^>]*?)>([\s\S]*?)<\/a>/gi;
  const snippets = [...page.matchAll(/<(?:a|div)\b[^>]*class\s*=\s*["'][^"']*\bresult__snippet\b[^"']*["'][^>]*>([\s\S]*?)<\/(?:a|div)>/gi)].map(m => stripHtml(m[1]));
  let match: RegExpExecArray | null;
  while ((match = links.exec(page)) && results.length < MAX_SEARCH_RESULTS) {
    const attrs = match[1];
    if (!/\bclass\s*=\s*["'][^"']*\bresult__a\b/i.test(attrs)) continue;
    const href = attrs.match(/\bhref\s*=\s*(["'])(.*?)\1/i)?.[2];
    if (!href) continue;
    const url = resultURL(href);
    const title = stripHtml(match[2]).slice(0, 180);
    if (!url || title.length < 3 || seen.has(url)) continue;
    seen.add(url);
    results.push({ title, url, snippet: (snippets[results.length] ?? "").slice(0, 220) });
  }
  return results;
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "anyone_search",
    label: "Anyone Web Search",
    description: "Search the public web through Anyone using DuckDuckGo HTML. Returns real result titles and source URLs, not guaranteed current or reliable. Use for independent source discovery. Never invent results.",
    parameters: Type.Object({ query: Type.String({ minLength: 3, maxLength: 120, description: "A concise public web-search query (no private data)" }) }),
    async execute(_id, { query }) {
      const q = query.trim();
      if (q.length < 3 || q.length > 120) throw new Error("Search query must be 3–120 characters");
      const searchURL = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(q)}&kl=wt-wt`;
      const body = await throughAnyone(searchURL, 450_000);
      const results = parseSearchResults(body);
      if (!results.length) {
        throw new Error("No parseable search results returned over Anyone (possibly blocked by search engine). Do not claim a search succeeded or invent sources.");
      }
      for (const item of results) {
        discovered.add(item.url);
        if (discovered.size > MAX_DISCOVERED) discovered.delete(discovered.values().next().value!);
      }
      const text = results.map((r, i) => `${i+1}. ${r.title}\n   URL: ${r.url}${r.snippet ? `\n   Snippet: ${r.snippet}` : ""}`).join("\n");
      return {
        content: [{ type: "text", text: `Anyone-routed web search succeeded. Search query: ${q}\n${text}\nRead specific sources with anyone_read using the exact URLs above. Search results are not verified facts.` }],
        details: { transport: "Anyone authenticated SOCKS5", count: results.length, source: "DuckDuckGo HTML" },
      };
    },
  });

  pi.registerTool({
    name: "anyone_read",
    label: "Anyone Read Webpage",
    description: "Read an HTTPS webpage found by anyone_search, through Anyone only. URL must appear exactly in recent search results. Returns its title, readable excerpt, and source URL; no JavaScript rendering or redirect following. Never infer unverified facts.",
    parameters: Type.Object({ url: Type.String({ description: "An exact HTTPS URL returned by anyone_search" }) }),
    async execute(_id, { url }) {
      const validated = safeURL(url);
      if (!validated || validated !== url || !discovered.has(url)) throw new Error("Blocked: URL was not returned by anyone_search or is not a permitted public HTTPS URL");
      const body = await throughAnyone(url, 700_000);
      if (/<(?:title|h1)[^>]*>[\s\S]{0,100}(captcha|verify you are human|access denied)/i.test(body)) {
        throw new Error("Site returned a verification or access-denied page; do not use it as research evidence");
      }
      const title = stripHtml(body.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? "(title not found)");
      const main = body.match(/<(?:main|article)\b[^>]*>([\s\S]*?)<\/(?:main|article)>/i)?.[1] ?? body;
      const text = stripHtml(main).slice(0, 4800);
      if (text.length < 80) throw new Error("Page contained too little readable text; choose another source");
      return {
        content: [{ type: "text", text: `Anyone-routed source fetched.\nSource URL: ${url}\nTitle: ${title}\nReadable text (excerpt, may omit later content): ${text}` }],
        details: { transport: "Anyone authenticated SOCKS5", url, characters: text.length },
      };
    },
  });
}
