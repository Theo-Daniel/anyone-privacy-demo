#!/usr/bin/env bash
# Anyone Protocol + Pi + zkAPI Mainnet recording demo.
# Uses real paid Claude Haiku 5.5 inference. Does not fund the wallet.
# Requires an already running Anyone SOCKS5 client and zkapi-clientd serve.
# Cover traffic and research are independently Anyone-routed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI="$ROOT/tools/pi/node_modules/.bin/pi"
ZKAPI="$ROOT/tools/zkapi-clientd-isolated-test"
RESEARCH="$ROOT/tools/pi/anyone-research-demo.ts"
COVER="$ROOT/tools/anyone-cover-demo"

COVER_RATE="${COVER_RATE:-0.10}"
COVER_DURATION="${COVER_DURATION:-120s}"

if { [[ -t 1 ]] || [[ "${FORCE_COLOR:-0}" == 1 ]]; } && [[ -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  CYAN=$'\033[38;5;51m'; BLUE=$'\033[38;5;75m'
  GREEN=$'\033[38;5;82m'; YELLOW=$'\033[38;5;220m'
  MAGENTA=$'\033[38;5;177m'; RED=$'\033[38;5;203m'
else
  RESET=''; BOLD=''; DIM=''; CYAN=''; BLUE=''
  GREEN=''; YELLOW=''; MAGENTA=''; RED=''
fi

fail() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
for file in "$PI" "$ZKAPI" "$RESEARCH" "$COVER"; do
  [[ -f "$file" ]] || fail "Missing required component: $file"
done
for port in 9150 8787; do
  if ! /usr/bin/nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
    [[ "$port" == 9150 ]] && fail 'Anyone SOCKS5 client is not running on port 9150.'
    fail 'zkAPI Mainnet server is not running on port 8787. Start serve first.'
  fi
done

export PI_CODING_AGENT_DIR="$ROOT/profiles/pi"
export PI_CODING_AGENT_SESSION_DIR="$ROOT/profiles/pi/sessions"
export PI_OFFLINE=1 PI_TELEMETRY=0
mkdir -p "$PI_CODING_AGENT_SESSION_DIR" "$ROOT/pi-workspace" "$ROOT/.cache"

# Secret stays in memory; never printed by the script.
export ZKAPI_PI_API_KEY="$("$ZKAPI" --config-dir "$ROOT/profiles/mainnet" config --api-key)"
[[ -n "$ZKAPI_PI_API_KEY" ]] || fail 'Unable to read the local zkAPI API key.'
# A fresh inference SOCKS identity is used per recording session.
export ANYONE_ISOLATION="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
SESSION_ID="anyone-zkapi-$(date +%Y%m%d-%H%M%S)-$$"
# The private session remains resumable even though its ID is hidden on camera.
printf '%s\n' "$SESSION_ID" > "$ROOT/.cache/last-anyone-zkapi-session-id"

TMP_DIR="$(mktemp -d "$ROOT/.cache/anyone-paid-demo.XXXXXX")"
cover_pid=''; cover_reader_pid=''; stderr_reader_pid=''
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [[ -n "$cover_pid" ]] && kill -0 "$cover_pid" 2>/dev/null; then
    kill -TERM "$cover_pid" 2>/dev/null || true
  fi
  [[ -z "$cover_pid" ]] || wait "$cover_pid" 2>/dev/null || true
  [[ -z "$cover_reader_pid" ]] || wait "$cover_reader_pid" 2>/dev/null || true
  [[ -z "$stderr_reader_pid" ]] || wait "$stderr_reader_pid" 2>/dev/null || true
  rm -rf -- "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$TMP_DIR/format-events.py" <<'PY'
import html
import json
import os
import re
import shutil
import sys
import textwrap
from pathlib import Path
from urllib.parse import urlsplit

status_file = Path(sys.argv[1])
color = (sys.stdout.isatty() or os.getenv("FORCE_COLOR") == "1") and not os.getenv("NO_COLOR")
C = lambda n: f"\x1b[38;5;{n}m" if color else ""
R = "\x1b[0m" if color else ""
B = "\x1b[1m" if color else ""
CYAN, BLUE, GREEN, YELLOW, RED, DIM = C(51), C(75), C(82), C(220), C(203), C(244)
W = max(60, min(82, shutil.get_terminal_size((84, 24)).columns - 4))

calls = successful = searches = successful_searches = successful_reads = failed_reads = 0
read_urls = set()
active = []
by_id = {}
settled = False
aborted = False
table_rows = 0
verified_rows = 0


def clean(value):
    value = html.unescape(str(value))
    value = re.sub(r"\\([*`_-])", r"\1", value)
    value = re.sub(r"\*\*(.*?)\*\*", r"\1", value)
    value = re.sub(r"\[([^\]]+)\]\(https?://[^)]*\)", r"\1", value)
    return value.strip()


def brief(value, limit=110):
    value = " ".join(clean(value).split())
    value = re.sub(r"--proxy-user\s+\S+", "--proxy-user [redacted]", value)
    value = re.sub(r"Bearer\s+[A-Za-z0-9._~-]+", "Bearer [redacted]", value)
    return textwrap.shorten(value, width=limit, placeholder="…") if value else ""


def wrap(value, indent="      ", max_lines=3):
    content = " ".join(clean(value).split())
    if not content:
        return
    width = max(45, W - len(indent))
    lines = textwrap.wrap(content, width=width, break_long_words=False, break_on_hyphens=False)
    for line in lines[:max_lines]:
        print(indent + line, flush=True)
    if len(lines) > max_lines:
        print(indent + f"{DIM}…{R}", flush=True)


def domain(url):
    try:
        return urlsplit(url).netloc.removeprefix("www.")
    except ValueError:
        return ""


def normal_url(url):
    return url.strip().rstrip("/ ")


def matching_source(url):
    return any(normal_url(url) == normal_url(seen) for seen in read_urls)


def parse_table(answer):
    lines = answer.splitlines()
    result = []
    found_header = False
    for line in lines:
        line = line.strip()
        if not found_header:
            if (line.startswith("|") and "Restaurant" in line and
                    "Why Visit" in line and "Source" in line):
                found_header = True
            continue
        if not line.startswith("|"):
            if result:
                break
            continue
        if re.fullmatch(r"[\s|:\-]+", line):
            continue
        raw = [x.strip() for x in line.strip("|").split("|")]
        cells = [clean(x) for x in raw]
        if len(cells) >= 3 and cells[0]:
            # Keep the Markdown link target even when the displayed label is short.
            result.append((cells[0], cells[1], raw[2]))
    return result


def display_recommendations(answer):
    global table_rows, verified_rows
    rows = parse_table(answer)
    if not rows:
        return False
    table_rows = len(rows)
    verified_rows = 0
    print(f"\n{BLUE}{'─' * 12}  03  /  RESEARCH FINDINGS  {'─' * 12}{R}", flush=True)
    for index, (name, why, source) in enumerate(rows, 1):
        match = re.search(r"https?://[^\s)\]]+", source)
        url = match.group(0).rstrip(".,") if match else ""
        verified = bool(url and matching_source(url))
        verified_rows += int(verified)
        host = domain(url) if url else "source unavailable"
        print(f"  {CYAN}{B}{index:02d}{R}  {B}{brief(name, 66)}{R}", flush=True)
        wrap(why, max_lines=3)
        if verified:
            print(f"      {DIM}Source  {host}{R}\n", flush=True)
        else:
            print(f"      {YELLOW}Source not verified: {host}{R}\n", flush=True)
    return True


for line in sys.stdin:
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    kind = event.get("type")
    if kind == "tool_execution_start":
        calls += 1
        name = event.get("toolName", "unknown")
        args = event.get("args") or {}
        if not isinstance(args, dict):
            args = {}
        info = {"name": name, "url": args.get("url", ""),
                "query": args.get("query", ""), "used": False}
        active.append(info)
        call_id = event.get("toolCallId") or event.get("tool_call_id")
        if call_id:
            by_id[call_id] = info
        if name == "anyone_search":
            searches += 1
            print(f"\n{BLUE}{B}  SEARCH {searches:02d}{R}  {brief(info['query'], W-19)}", flush=True)
        elif name == "anyone_read":
            host = domain(str(info['url']))
            print(f"\n{BLUE}{B}  READ{R}       {host or brief(info['url'], W-19)}", flush=True)
        else:
            print(f"\n{BLUE}{B}  TOOL{R}       {brief(name, W-19)}", flush=True)

    elif kind == "tool_execution_end":
        call_id = event.get("toolCallId") or event.get("tool_call_id")
        info = by_id.get(call_id) if call_id else None
        if info is None:
            name = event.get("toolName")
            info = next((item for item in active if not item['used'] and
                         (not name or item['name'] == name)), None)
        if info is not None:
            info['used'] = True
        name = (info or {}).get('name', event.get('toolName', 'unknown'))
        result = event.get('result') or {}
        contents = result.get('content', []) if isinstance(result, dict) else []
        combined = '\n'.join(item.get('text', '') for item in contents
                             if isinstance(item, dict) and item.get('type') == 'text')
        ok = not event.get('isError', False)
        successful += int(ok)
        if ok and name == 'anyone_search':
            successful_searches += 1
            print(f"      {GREEN}✓ Results retrieved through Anyone{R}", flush=True)
        elif name == 'anyone_search':
            print(f"      {YELLOW}✕ Search unavailable · continuing{R}", flush=True)
        elif name == 'anyone_read':
            if ok:
                successful_reads += 1
                match = re.search(r'(?m)^Source URL:\s*(\S+)', combined)
                url = match.group(1).strip() if match else str((info or {}).get('url', ''))
                if url:
                    read_urls.add(url)
                match = re.search(r'(?m)^Title:\s*(.+)$', combined)
                title = brief(match.group(1), W-29) if match else domain(url)
                print(f"      {GREEN}✓ Source retrieved{R}  {DIM}{title}{R}", flush=True)
            else:
                failed_reads += 1
                error = brief(combined or 'Website unavailable', W-15)
                # The site may block anonymous fetches or exceed our fetch size limit.
                if 'too little readable text' in error.lower():
                    error = 'Not enough readable text'
                elif 'max-filesize' in error.lower() or 'file size' in error.lower():
                    error = 'Page exceeds fetch limit'
                else:
                    error = 'Source unavailable'
                print(f"      {YELLOW}✕ {error} · trying another source{R}", flush=True)
        elif not ok:
            print(f"      {YELLOW}✕ Tool request failed{R}", flush=True)

    elif kind == 'message_end':
        message = event.get('message') or {}
        if message.get('role') == 'assistant':
            parts = message.get('content') or []
            answer = '\n'.join(part.get('text', '') for part in parts
                               if isinstance(part, dict) and part.get('type') == 'text').strip()
            if answer:
                if display_recommendations(answer):
                    pass
                elif not table_rows and re.search(r'(?m)^\s*\|\s*Restaurant\s*\|', answer):
                    print(f"\n{YELLOW}  [REVIEW] Final table was not readable.{R}", flush=True)
                # Intermediate model narration is deliberately omitted from the video.

    elif kind in ('agent_end', 'agent_settled'):
        settled = True
        aborted = bool(event.get('aborted', False))

status_file.write_text(json.dumps({
    'calls': calls, 'successful': successful, 'searches': searches,
    'successful_searches': successful_searches, 'successful_reads': successful_reads,
    'failed_reads': failed_reads, 'distinct_read_urls': len(read_urls),
    'table_rows': table_rows, 'verified_rows': verified_rows,
    'settled': settled, 'aborted': aborted,
}))
PY
# Restore the original cyan boxed header from the first recording.
printf '\n%s%s╔══════════════════════════════════════════════════════════════╗%s\n' "$CYAN" "$BOLD" "$RESET"
printf '%s%s║      ANYONE PROTOCOL  •  PRIVATE AI AGENT DEMO             ║%s\n' "$CYAN" "$BOLD" "$RESET"
printf '%s%s╚══════════════════════════════════════════════════════════════╝%s\n' "$CYAN" "$BOLD" "$RESET"
printf '\n  %sMODEL%s     Claude Haiku 5.5  •  paid zkAPI Mainnet\n' "$CYAN" "$RESET"
printf '  %sAGENT%s     Pi  •  live multi-source web research\n' "$BLUE" "$RESET"
printf '  %sNETWORK%s   Anyone SOCKS5  •  isolated sessions\n' "$MAGENTA" "$RESET"
printf '\n%s  ───────────────  01  /  NETWORK VERIFICATION  ──────────────%s\n' "$BLUE" "$RESET"
SOCKS_USER="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
if ! exit_ip="$(/usr/bin/curl -q --fail --silent --show-error --max-time 45 \
  --proto '=https' --proxy 'socks5h://127.0.0.1:9150' \
  --proxy-user "${SOCKS_USER}:anyone-demo" 'https://api.ipify.org')"; then
  fail 'Anyone exit IP verification failed. No paid inference was started.'
fi
if [[ ! "$exit_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  fail 'Unexpected exit IP result. No paid inference was started.'
fi
printf '  %s✓%s Anyone exit verified    %s%s%s\n' "$GREEN" "$RESET" "$CYAN" "$exit_ip" "$RESET"
printf '\n%s  ──────────────────  02  /  LIVE RESEARCH  ──────────────────%s\n' "$BLUE" "$RESET"

mkfifo "$TMP_DIR/cover-pipe"
printf '0' > "$TMP_DIR/cover-successes"
(
  last_milestone=0
  while IFS= read -r line; do
    if [[ "$line" =~ succeeded=([0-9]+) ]]; then
      succeeded="${BASH_REMATCH[1]}"
      printf '%s' "$succeeded" > "$TMP_DIR/cover-successes"
      # Quiet progress: print at most one line for each three new successes.
      # Never use carriage-return rewrites: Pi's output is concurrent.
      if (( succeeded >= last_milestone + 3 )); then
        last_milestone=$(( (succeeded / 3) * 3 ))
        printf '  %sCOVER%s   ✓ %s anonymous requests completed\n' "$YELLOW" "$RESET" "$succeeded"
      fi
    fi
    if [[ "$line" != '[COVER]'* && "$line" != '[COVER FINISHED]'* ]]; then
      printf '  %sCOVER WARNING%s  %s\n' "$YELLOW" "$RESET" "$line" >&2
    fi
  done < "$TMP_DIR/cover-pipe"
) &
cover_reader_pid=$!

printf '\n  %sCOVER%s   Background traffic started · bounded run\n' "$YELLOW" "$RESET"
"$COVER" -url 'https://check.en.anyone.tech/api/ip' \
  -rate "$COVER_RATE" -duration "$COVER_DURATION" > "$TMP_DIR/cover-pipe" 2>&1 &
cover_pid=$!
sleep 2
if ! kill -0 "$cover_pid" 2>/dev/null; then
  fail 'Cover process exited before the AI agent started.'
fi

printf '  %sTASK%s    Five vegan restaurants in Tallinn · three sources\n' "$BLUE" "$RESET"

# Drain stderr live; suppress Pi's harmless new-session notice.
mkfifo "$TMP_DIR/pi-stderr-pipe"
(
  while IFS= read -r line; do
    if [[ "$line" == Warning:\ No\ project\ session\ found\ with\ id* ]]; then
      continue
    else
      line="${line//$ZKAPI_PI_API_KEY/[redacted]}"
      line="${line//$ANYONE_ISOLATION/[redacted]}"
      printf '%s\n' "$line" >&2
    fi
  done < "$TMP_DIR/pi-stderr-pipe"
) &
stderr_reader_pid=$!

PI_ARGS=(
  --mode json
  --provider zkapi
  --model anthropic/claude-haiku-5.5
  --extension "$RESEARCH"
  --tools anyone_search,anyone_read
  --no-mcp
  --session-id "$SESSION_ID"
)

PROMPT='Research five vegan restaurants in Tallinn, Estonia.
1. Use anyone_search to search for best vegan restaurants Tallinn.
2. Use anyone_search again for Tallinn vegan restaurants 2026 guide.
3. Use anyone_read to examine THREE DIFFERENT relevant websites from the searches. Never read the same URL twice. If a website fails, choose another.
4. Compare the retrieved information and recommend EXACTLY FIVE restaurants in a Markdown table with columns Restaurant | Why Visit | Source URL.
5. Cite only URLs actually retrieved through anyone_read. Never invent a source.
Complete the research and finish with the table.'

cd "$ROOT/pi-workspace"
if "$PI" "${PI_ARGS[@]}" -p "$PROMPT" 2> "$TMP_DIR/pi-stderr-pipe" \
  | python3 -u "$TMP_DIR/format-events.py" "$TMP_DIR/agent-status.json"; then
  pi_rc=0
else
  pi_rc=$?
fi
wait "$stderr_reader_pid" || true
stderr_reader_pid=''

# Do not extend cover traffic indefinitely if slow paid inference takes minutes.
# If agent finishes early, let at least 45 seconds elapse for a useful sample.
if kill -0 "$cover_pid" 2>/dev/null; then
  # A live cover process is already bounded by COVER_DURATION.
  # If it has 3 successes, allow enough time for the display; otherwise wait
  # no more than 45 additional seconds after the agent finishes.
  for ((i=0; i<45; i++)); do
    succeeded="$(cat "$TMP_DIR/cover-successes" 2>/dev/null || printf 0)"
    [[ "$succeeded" =~ ^[0-9]+$ ]] || succeeded=0
    if (( succeeded >= 3 )); then break; fi
    if ! kill -0 "$cover_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  kill -TERM "$cover_pid" 2>/dev/null || true
fi
wait "$cover_pid" || true
cover_pid=''
wait "$cover_reader_pid" || true
cover_reader_pid=''

python3 - "$TMP_DIR/agent-status.json" "$TMP_DIR/cover-successes" "$pi_rc" <<'PY'
import json
import os
import sys
from pathlib import Path
path, coverpath, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    agent = json.loads(Path(path).read_text())
except (OSError, ValueError):
    agent = {}
try:
    cover = int(Path(coverpath).read_text() or "0")
except (OSError, ValueError):
    cover = 0
colors = sys.stdout.isatty() or os.getenv("FORCE_COLOR") == "1"
if os.getenv("NO_COLOR"):
    colors = False
okcolor = "\033[38;5;82m" if colors else ""
warncolor = "\033[38;5;220m" if colors else ""
bluecolor = "\033[38;5;75m" if colors else ""
reset = "\033[0m" if colors else ""
print(f"\n{bluecolor}  ──────────────────  04  /  RUN SUMMARY  ──────────────────{reset}")
print(f"  Searches     {agent.get('successful_searches', 0)} / {agent.get('searches', 0)} successful")
print(f"  Sources      {agent.get('distinct_read_urls', 0)} different pages read")
print(f"  Findings     {agent.get('table_rows', 0)} restaurants · {agent.get('verified_rows', 0)} cited to retrieved URLs")
print(f"  Cover        {cover} successful anonymous requests")
passed = (rc == 0 and agent.get('settled', False) and not agent.get('aborted', False)
          and agent.get('searches', 0) >= 2
          and agent.get('successful_searches', 0) >= 1
          and agent.get('successful_reads', 0) >= 3
          and agent.get('distinct_read_urls', 0) >= 3
          and agent.get('table_rows', 0) == 5
          and agent.get('verified_rows', 0) == 5
          and cover >= 2)
if passed:
    print(f"\n  {okcolor}✓  DEMO COMPLETE{reset}  ·  Real inference, web research and cover traffic")
else:
    print(f"\n  {warncolor}!  REVIEW NEEDED{reset}  ·  Check results before recording again")

PY
printf '%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$BLUE" "$RESET"
