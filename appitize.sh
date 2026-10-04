#!/bin/bash
#
# appitize.sh
#
# Interactively generate a standalone macOS "web app" (.app) that opens a URL
# in Google Chrome (app mode) through a proxy.
#
# The app name and icon are read from the target site. Because sites behind
# Cloudflare reject plain curl requests, the lookup is done with a real Chrome
# instance (launched offscreen) driven over the DevTools protocol -- that runs
# the JS challenge, so it works where curl gets a 403. Plain HTTP scraping is
# kept only as a fallback.
#
set -e

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# proxy args used for every curl call (filled in after the proxy prompt)
CURL_PROXY=()

# how long to wait for the offscreen Chrome to render the page
BROWSER_WAIT="${BROWSER_WAIT:-30}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# prompt <var> <message> [default]
prompt() {
    local __var="$1" __msg="$2" __default="$3" __input=""
    if [ -n "$__default" ]; then
        read -r -p "$__msg [$__default]: " __input || true
    else
        read -r -p "$__msg: " __input || true
    fi
    [ -z "$__input" ] && __input="$__default"
    printf -v "$__var" '%s' "$__input"
}

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# domain_label <host>  ->  the main label of a hostname
#   www.chatgpt.com  -> chatgpt
#   chat.openai.com  -> openai
#   github.com       -> github
domain_label() {
    local host="$1" n idx suffix name
    host="${host%%:*}"          # drop port
    host="${host%%/*}"          # drop path
    host="${host#www.}"         # drop leading www.
    [ -z "$host" ] && return 0

    # IP address: keep as-is, there is no meaningful label
    case "$host" in
        *[!0-9.]*) ;;
        *) printf '%s' "$host"; return 0 ;;
    esac

    local IFS='.'
    local parts=($host)
    n=${#parts[@]}
    [ "$n" -eq 0 ] && return 0

    suffix=1
    if [ "$n" -ge 2 ]; then
        case ".${parts[$((n-2))]}.${parts[$((n-1))]}" in
            .co.uk|.org.uk|.ac.uk|.gov.uk|.com.cn|.net.cn|.org.cn|.gov.cn|\
            .com.au|.net.au|.org.au|.co.nz|.co.jp|.co.kr|.co.in|.com.br|\
            .com.tw|.com.hk|.com.sg|.com.mx|.com.ar|.co.za)
                suffix=2 ;;
        esac
    fi

    idx=$((n - 1 - suffix))
    [ "$idx" -lt 0 ] && idx=0
    name="${parts[$idx]}"
    [ -z "$name" ] && name="$host"
    printf '%s' "$name"
}

# detect_lan_cidrs -> one CIDR per line for the local network(s)
#   reads the IPv4 address + netmask of the physical interfaces (en*/eth*)
detect_lan_cidrs() {
    ifconfig 2>/dev/null | perl -ne '
        if (/^([a-z]+\d+):\s/) { $if = $1 }
        next unless defined $if;
        next unless $if =~ /^(en|eth)\d+$/;
        if (/inet\s+(\d+)\.(\d+)\.(\d+)\.(\d+)\s+netmask\s+0x([0-9a-fA-F]+)/) {
            my ($a, $b, $c, $d, $m) = ($1, $2, $3, $4, hex($5));
            my $ip = ($a << 24) | ($b << 16) | ($c << 8) | $d;
            next if ($ip >> 24) == 127;          # loopback
            next if ($ip >> 16) == 0xa9fe;       # link-local 169.254/16
            my $net = $ip & $m;
            my $prefix = sprintf("%032b", $m) =~ tr/1//;
            printf "%d.%d.%d.%d/%d\n",
                ($net >> 24) & 255, ($net >> 16) & 255, ($net >> 8) & 255, $net & 255, $prefix;
        }
    ' | sort -u
}

# shorten_title -> trim "Site - Tagline" / "Site · Tagline" style titles
shorten_title() {
    perl -0777 -ne '
        my $t = $_;
        $t =~ s/\s+/ /g;
        $t =~ s/^\s+|\s+$//g;
        my @p = grep { /\S/ } split /\s*(?:[|·•–—]|\s-\s)\s*/, $t;
        if (@p > 1) {
            @p = sort { length($a) <=> length($b) } @p;
            $t = $p[0] if length($p[0]) >= 2;
        }
        print $t;
    '
}

# resolve a possibly-relative URL against the current page origin
resolve_url() {
    case "$1" in
        http://*|https://*) printf '%s' "$1" ;;
        //*)                printf '%s:%s' "$SCHEME" "$1" ;;
        /*)                 printf '%s://%s%s' "$SCHEME" "$HOST" "$1" ;;
        *)                  printf '%s://%s/%s' "$SCHEME" "$HOST" "$1" ;;
    esac
}

# build_icns <source-image> <output.icns>
build_icns() {
    local src="$1" out="$2" work iconset name px base pair
    work="$(mktemp -d)"
    iconset="$work/AppIcon.iconset"
    mkdir -p "$iconset"

    if ! sips -z 1024 1024 "$src" --out "$work/master.png" >/dev/null 2>&1; then
        cp "$src" "$work/master.png"
    fi

    for pair in "16 16" "32 16" "32 32" "64 32" "128 128" \
                "256 128" "256 256" "512 256" "512 512" "1024 512"; do
        px="${pair%% *}"; base="${pair##* }"
        if [ "$px" = "$base" ]; then
            name="icon_${base}x${base}.png"
        else
            name="icon_${base}x${base}@2x.png"
        fi
        sips -z "$px" "$px" "$work/master.png" --out "$iconset/$name" >/dev/null 2>&1 || true
    done

    if iconutil -c icns "$iconset" -o "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
        rm -rf "$work"
        return 0
    fi
    rm -rf "$work"
    return 1
}

# image_to_icns <source-image> <output.icns>   (converts then builds .icns)
image_to_icns() {
    local src="$1" out="$2" tmp
    tmp="$(mktemp -d)"
    if sips -s format png "$src" --out "$tmp/src.png" >/dev/null 2>&1 \
       && [ -s "$tmp/src.png" ] \
       && build_icns "$tmp/src.png" "$out"; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

# download_icns <url> <output.icns>
download_icns() {
    local url="$1" dest="$2" tmp
    tmp="$(mktemp -d)"
    if curl -sL --compressed --max-time 25 -A "$UA" "${CURL_PROXY[@]}" -o "$tmp/dl" "$url" \
       && [ -s "$tmp/dl" ] \
       && image_to_icns "$tmp/dl" "$dest"; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

# browser_fetch <url> <proxy> <bypass> <workdir>
#   Opens the URL in a real (offscreen) Chrome and writes:
#     <workdir>/title.txt  <workdir>/og.txt  <workdir>/icon.bin  <workdir>/icon.url
#   Uses only the Python standard library. Always returns 0.
browser_fetch() {
    python3 - "$1" "$2" "$3" "$4" "$BROWSER_WAIT" <<'PYEOF' || true
import base64, json, os, socket, struct, subprocess, sys, tempfile, time, shutil, http.client, urllib.parse

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHALLENGE = ("\u8bf7\u7a0d\u5019", "Just a moment", "Attention Required", "Checking your browser")


class WS:
    def __init__(self, url, timeout=90):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (("?" + u.query) if u.query else "")
        req = (
            "GET %s HTTP/1.1\r\nHost: %s:%s\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
            "Origin: http://127.0.0.1\r\n\r\n" % (path, u.hostname, u.port, key)
        )
        self.sock.sendall(req.encode())
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            hdr += self.sock.recv(4096)
        self.buf = hdr.split(b"\r\n\r\n", 1)[1]

    def _rx(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise RuntimeError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        p = text.encode(); h = bytearray([0x81]); n = len(p)
        if n < 126:
            h.append(0x80 | n)
        elif n < 65536:
            h.append(0x80 | 126); h += struct.pack(">H", n)
        else:
            h.append(0x80 | 127); h += struct.pack(">Q", n)
        m = os.urandom(4); h += m
        self.sock.sendall(bytes(h) + bytes(b ^ m[i % 4] for i, b in enumerate(p)))

    def recv(self):
        data = b""
        while True:
            b0, b1 = self._rx(2)
            fin = b0 & 0x80; ln = b1 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._rx(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._rx(8))[0]
            data += self._rx(ln)
            if fin:
                break
        return data.decode()


class CDP:
    def __init__(self, url):
        self.ws = WS(url); self.i = 0

    def call(self, method, params=None):
        self.i += 1
        self.ws.send(json.dumps({"id": self.i, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.i:
                return msg

    def ev(self, expr, timeout_ms=40000):
        try:
            r = self.call("Runtime.evaluate", {"expression": expr, "returnByValue": True,
                                               "awaitPromise": True, "timeout": timeout_ms})
        except Exception:
            return None
        if r.get("result", {}).get("exceptionDetails"):
            return None
        return r.get("result", {}).get("result", {}).get("value")


ICON_JS = """(() => {
    const links = Array.from(document.querySelectorAll('link')).filter(l => /icon/i.test(l.getAttribute('rel')||''));
    const sc = l => {
        const rel = (l.getAttribute('rel')||'').toLowerCase();
        const sz = parseInt((l.getAttribute('sizes')||'').split('x')[0], 10) || 0;
        const h = l.href || '';
        let s = sz;
        if (rel.includes('apple-touch-icon')) s += 5000;
        if (/\\.png$/i.test(h)) s += 1000;
        if (/\\.svg$/i.test(h)) s -= 500;
        if (/\\.ico$/i.test(h)) s -= 200;
        return s;
    };
    const best = links.slice().sort((a,b) => sc(b) - sc(a))[0];
    const og = document.querySelector('meta[property="og:site_name"]');
    return JSON.stringify({
        title: document.title,
        og: og ? og.getAttribute('content') : null,
        icon: best ? best.href : null,
        all: links.map(l => l.href)
    });
})()"""

FETCH_JS = """(async () => {
    try {
        const r = await fetch(%s, {cache: 'force-cache', credentials: 'include'});
        if (!r.ok) return '';
        const bytes = new Uint8Array(await r.arrayBuffer());
        let bin = '';
        const CH = 0x8000;
        for (let i = 0; i < bytes.length; i += CH)
            bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
        return btoa(bin);
    } catch (e) { return ''; }
})()"""


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def write(path, text):
    try:
        with open(path, "w") as f:
            f.write(text)
    except Exception:
        pass


def main():
    url = sys.argv[1]
    proxy = sys.argv[2]
    bypass = sys.argv[3]
    work = sys.argv[4]
    wait = float(sys.argv[5]) if len(sys.argv) > 5 else 30.0

    port = free_port()
    profile = tempfile.mkdtemp(prefix="proxywebapp-")
    args = [CHROME, "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled", "--remote-allow-origins=*",
            "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding", "--disable-features=CalculateNativeWinOcclusion",
            "--use-mock-keychain", "--password-store=basic",
            f"--remote-debugging-port={port}",
            f"--user-data-dir={profile}", "--window-size=1280,900",
            "--window-position=-2000,0"]
    if proxy:
        args += [f"--proxy-server={proxy}", f"--proxy-bypass-list={bypass}"]
    args.append(url)

    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(150):
            try:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
                c.request("GET", "/json/version")
                break
            except Exception:
                time.sleep(0.2)

        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", "/json")
        targets = json.loads(c.getresponse().read())
        page = next((t for t in targets if t.get("type") == "page"
                     and t.get("url", "").startswith("http")), None)
        if not page:
            page = next((t for t in targets if t.get("type") == "page"), None)
        if not page:
            return

        cdp = CDP(page["webSocketDebuggerUrl"])
        cdp.call("Runtime.enable")

        t0 = time.time()
        title = ""
        data = {}
        while time.time() - t0 < wait:
            title = cdp.ev("document.title") or ""
            if title and not any(k in title for k in CHALLENGE):
                data = json.loads(cdp.ev(ICON_JS) or "{}")
                if data.get("icon"):
                    break
            time.sleep(1)

        if not data.get("title"):
            data = json.loads(cdp.ev(ICON_JS) or "{}")

        if data.get("title"):
            write(os.path.join(work, "title.txt"), data["title"])
        if data.get("og"):
            write(os.path.join(work, "og.txt"), data["og"])

        # download the icon bytes from inside the page so the browser's
        # cookies / TLS session are used (Cloudflare would block curl)
        icon = data.get("icon")
        if icon:
            candidates = [icon] + [u for u in (data.get("all") or []) if u != icon]
            for cand in candidates:
                if cand.lower().endswith(".svg"):
                    continue
                val = cdp.ev(FETCH_JS % json.dumps(cand), timeout_ms=30000)
                if not val:
                    continue
                try:
                    raw = base64.b64decode(val, validate=False)
                except Exception:
                    continue
                ok = (raw[:8] == b"\x89PNG\r\n\x1a\n"
                      or raw[:6] in (b"GIF89a", b"GIF87a")
                      or raw[:2] == b"\xff\xd8"
                      or raw[:4] == b"\x00\x00\x01\x00")
                if not ok:
                    continue
                with open(os.path.join(work, "icon.bin"), "wb") as f:
                    f.write(raw)
                write(os.path.join(work, "icon.url"), cand)
                break
    except Exception:
        pass
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


main()
PYEOF
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

if [ ! -x "$CHROME" ]; then
    echo "error: Google Chrome not found at: $CHROME" >&2
    exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found. Install the command line tools: xcode-select --install" >&2
    exit 1
fi

echo "==> New proxy web app"

# ---------------------------------------------------------------------------
# 1. proxy settings (asked first so the site lookup below goes through it)
# ---------------------------------------------------------------------------

echo
prompt PROXY  "Proxy address"     "http://localhost:1080"

DEFAULT_BYPASS="localhost;127.0.0.1;::1"
LAN_CIDRS="$(detect_lan_cidrs || true)"
if [ -n "$LAN_CIDRS" ]; then
    while IFS= read -r cidr; do
        [ -n "$cidr" ] && DEFAULT_BYPASS="$DEFAULT_BYPASS;$cidr"
    done <<< "$LAN_CIDRS"
    echo "    detected LAN: $(printf '%s' "$LAN_CIDRS" | tr '\n' ' ')"
else
    DEFAULT_BYPASS="$DEFAULT_BYPASS;192.168.*"
fi

prompt BYPASS "Proxy bypass list" "$DEFAULT_BYPASS"

CURL_PROXY=()
if [ -n "$PROXY" ]; then
    CURL_PROXY=(--proxy "$PROXY")
fi

# ---------------------------------------------------------------------------
# 2. URL
# ---------------------------------------------------------------------------

echo
prompt APP_URL "URL" ""
while [ -z "$APP_URL" ]; do
    echo "  URL cannot be empty."
    prompt APP_URL "URL" ""
done

# add a scheme if the user typed a bare host such as "www.chatgpt.com"
case "$APP_URL" in
    http://*|https://*) ;;
    *) APP_URL="https://$APP_URL" ;;
esac

SCHEME="${APP_URL%%://*}"
REST="${APP_URL#*://}"
HOST="${REST%%/*}"
ORIGIN="$SCHEME://$HOST"

# ---------------------------------------------------------------------------
# 3. fetch default name + icon (real Chrome first, curl as fallback)
# ---------------------------------------------------------------------------

echo
WORKDIR="$(mktemp -d)"
FETCH_TITLE=""
FETCH_OG=""
BROWSER_ICON=""
ICON_HREF=""

if command -v python3 >/dev/null 2>&1; then
    echo "==> Opening $APP_URL in Chrome to read its name and icon ..."
    browser_fetch "$APP_URL" "$PROXY" "$BYPASS" "$WORKDIR"
    [ -s "$WORKDIR/title.txt" ] && FETCH_TITLE="$(cat "$WORKDIR/title.txt")"
    [ -s "$WORKDIR/og.txt" ]    && FETCH_OG="$(cat "$WORKDIR/og.txt")"
    [ -s "$WORKDIR/icon.bin" ]  && BROWSER_ICON="$WORKDIR/icon.bin"
fi

if [ -z "$FETCH_TITLE" ] && [ -z "$BROWSER_ICON" ]; then
    echo "==> Chrome lookup unavailable; falling back to a plain HTTP fetch ..."
    PAGE="$(mktemp)"
    HTTP_CODE="$(curl -sL --compressed --max-time 25 -A "$UA" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "${CURL_PROXY[@]}" -o "$PAGE" -w '%{http_code}' "$APP_URL" || true)"
    [ -s "$PAGE" ] || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "200" ] && ! grep -qi 'cf_chl_opt\|challenge-platform\|Just a moment' "$PAGE"; then
        FETCH_TITLE="$(perl -0777 -ne '
            if (m{<title[^>]*>(.*?)</title>}is) { print $1 }
        ' "$PAGE" 2>/dev/null || true)"
        FETCH_OG="$(perl -0777 -ne '
            if (m{<meta[^>]*property\s*=\s*["\x27]og:site_name["\x27][^>]*>}is) {
                my $tag = $&;
                if ($tag =~ /content\s*=\s*["\x27]([^"\x27]*)["\x27]/i) { print $1; exit }
            }
        ' "$PAGE" 2>/dev/null || true)"
        ICON_HREF="$(perl -0777 -ne '
            my @tags = m{<link\b[^>]*>}sig;
            my $best;
            for my $t (@tags) {
                my ($rel)  = $t =~ /rel\s*=\s*["\x27]([^"\x27]*)["\x27]/i;
                my ($href) = $t =~ /href\s*=\s*["\x27]([^"\x27]*)["\x27]/i;
                next unless defined $href;
                if (defined $rel && $rel =~ /apple-touch-icon/i) { print $href; exit }
                $best = $href if !defined $best && defined $rel && $rel =~ /(^|\s)icon(\s|$)/i;
            }
            print $best if defined $best;
        ' "$PAGE" 2>/dev/null || true)"
        echo "    falling back to plain HTTP (HTTP ${HTTP_CODE})" >&2
    fi
    rm -f "$PAGE"
fi

# default name: og:site_name > shortened <title> > main domain label
DEFAULT_NAME=""
if [ -n "$FETCH_OG" ]; then
    DEFAULT_NAME="$FETCH_OG"
elif [ -n "$FETCH_TITLE" ]; then
    DEFAULT_NAME="$(printf '%s' "$FETCH_TITLE" | shorten_title)"
else
    DEFAULT_NAME="$(domain_label "$HOST")"
    echo "    could not read the page; default name derived from the domain"
fi
[ -z "$DEFAULT_NAME" ] && DEFAULT_NAME="$(domain_label "$HOST")"

# ---------------------------------------------------------------------------
# 4. app name
# ---------------------------------------------------------------------------

echo
prompt APP_NAME "App name" "$DEFAULT_NAME"
[ -z "$APP_NAME" ] && APP_NAME="$DEFAULT_NAME"

# strip characters that would break the generated plist / swift source
DISPLAY_NAME="$(printf '%s' "$APP_NAME" | sed -E 's/["`$\\]//g')"
[ -z "$DISPLAY_NAME" ] && DISPLAY_NAME="$DEFAULT_NAME"

# ---------------------------------------------------------------------------
# 5. icon
# ---------------------------------------------------------------------------

ICON_TMP="$(mktemp -d)"
ICON_ICNS="$ICON_TMP/AppIcon.icns"
ICON_SOURCE=""

# 1) icon downloaded by the real browser (works even through Cloudflare)
if [ -n "$BROWSER_ICON" ] && image_to_icns "$BROWSER_ICON" "$ICON_ICNS"; then
    if [ -s "$WORKDIR/icon.url" ]; then
        ICON_SOURCE="$(cat "$WORKDIR/icon.url")"
    else
        ICON_SOURCE="$APP_URL"
    fi
fi

# 2) icon referenced by the HTML (curl fallback only)
if [ -z "$ICON_SOURCE" ] && [ -n "$ICON_HREF" ]; then
    cand="$(resolve_url "$ICON_HREF")"
    if download_icns "$cand" "$ICON_ICNS"; then
        ICON_SOURCE="$cand"
    fi
fi

# 3) well-known icon locations
if [ -z "$ICON_SOURCE" ]; then
    for cand in "$ORIGIN/apple-touch-icon.png" \
                "$ORIGIN/apple-touch-icon-precomposed.png" \
                "$ORIGIN/favicon.ico"; do
        if download_icns "$cand" "$ICON_ICNS"; then
            ICON_SOURCE="$cand"
            break
        fi
    done
fi

if [ -n "$ICON_SOURCE" ]; then
    echo "    icon: $ICON_SOURCE"
else
    echo "    no usable icon found, continuing without one"
fi

# ---------------------------------------------------------------------------
# 6. build the app bundle
# ---------------------------------------------------------------------------

SLUG="$(slugify "$DISPLAY_NAME")"
[ -z "$SLUG" ] && SLUG="$(slugify "$HOST")"

# install into /Applications, falling back to ~/Applications when not writable
if [ -w /Applications ]; then
    APPS_BASE="/Applications"
else
    APPS_BASE="$HOME/Applications"
    echo "    /Applications is not writable; installing to ~/Applications instead"
fi

APP_DIR="$APPS_BASE/$DISPLAY_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
PROFILE="$HOME/Library/Application Support/Chrome-$SLUG"
BUNDLE_ID="com.local.webapp.$SLUG"

if [ -n "$PROXY" ]; then
    PROXY_SWIFT_ARGS="    \"--proxy-server=$PROXY\",
    \"--proxy-bypass-list=$BYPASS\","
else
    PROXY_SWIFT_ARGS=""
fi

if [ -n "$ICON_SOURCE" ]; then
    ICON_PLIST="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
else
    ICON_PLIST=""
fi

echo
echo "==> Creating $DISPLAY_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RES_DIR"

cat > "$MACOS_DIR/launcher.swift" <<EOF
import Foundation

let chrome = "$CHROME"

let process = Process()
process.executableURL = URL(fileURLWithPath: chrome)

process.arguments = [
    "--user-data-dir=$PROFILE",
    "--use-mock-keychain",
    "--password-store=basic",
$PROXY_SWIFT_ARGS
    "--app=$APP_URL"
]

process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice

try process.run()
EOF

swiftc \
    "$MACOS_DIR/launcher.swift" \
    -o "$MACOS_DIR/launcher"

rm "$MACOS_DIR/launcher.swift"

if [ -n "$ICON_SOURCE" ]; then
    cp "$ICON_ICNS" "$RES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>

    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>

    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>

    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>

    <key>CFBundleExecutable</key>
    <string>launcher</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleVersion</key>
    <string>1.0</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0</string>

$ICON_PLIST

    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>

</dict>
</plist>
EOF

# nudge Finder to pick up the (possibly new) icon
touch "$APP_DIR"

rm -rf "$ICON_TMP" "$WORKDIR"

# ---------------------------------------------------------------------------
# 7. done
# ---------------------------------------------------------------------------

echo "==> App created:"
echo "$APP_DIR"

echo
echo "==> Launching..."
open "$APP_DIR"

echo
echo "Done."
echo
echo "App:     $APP_DIR"
echo "URL:     $APP_URL"
echo "Proxy:   ${PROXY:-(none)}"
echo "Bypass:  ${BYPASS:-(none)}"
echo "Icon:    ${ICON_SOURCE:-(none)}"
echo "Profile: $PROFILE"
