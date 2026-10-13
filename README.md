# OWA WebView Bridge

A Swift + WKWebView app that lives in the macOS menu bar. It keeps a signed-in `outlook.office.com` session
and exposes a **local HTTP API** so local AI agents can read your latest mail, message details and signed-in
identity. Content comes back in a **semantic schema** rather than raw DOM, and a **debug mode** lets an AI
analyze the page and repair the extraction.

> Read-only, and only your own mail. No app registration, no Graph/OAuth. The app **never reads, exports or
> forwards** any access token from the OWA session.

## Quick start

Requires macOS 13+ and Swift 5.9+ (Xcode 15+ or the Command Line Tools).

```bash
./scripts/build-app.sh          # produces build/OWABridge.app (ad-hoc signed)
open build/OWABridge.app
```

For development you can also just run `swift run OWABridge`.

1. On first launch the window opens automatically. Sign in to OWA, including MFA.
2. Once signed in, the window retracts into the menu bar (the WebView keeps running offscreen).
3. The menu bar icon shows the login state: ✉️ signed in / ⚠️ signed out or expired. The menu can show the window, reload, copy the base URL or token, and open the config folder.

The session lives in WebKit's persistent data store (`WKWebsiteDataStore.default()`), so you stay signed in
across restarts. The app stores no credentials itself.

## Calling the API

```bash
TOKEN=$(cat ~/.owa-bridge/token)
curl -s -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:5333/messages?top=10'
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:5333/messages/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$ID")"
curl -s -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:5333/me'
```

| Endpoint | Description |
|---|---|
| `GET /healthz` | Liveness probe `{ "ok": true }` (no token required) |
| `GET /status` | Login state, current provider, page URL, last extraction duration and result, queue depth |
| `GET /me` | Signed-in user `{displayName, address, tenant, loggedIn}` |
| `GET /messages?folder=inbox&top=10&unread=false` | Latest messages; `folder` accepts `inbox`/`sent`/`drafts`/`deleted`/`junk`/`archive` or a folder name; `top` is capped at 50 |
| `GET /messages/{id}?bodyType=text\|html` | Message detail (body, cc, attachment metadata). URL-encode the id (OWA ids contain `/` and `+`; unencoded `/` also works) |

Shared conventions:

- Listens on `127.0.0.1` only, default port 5333.
- Authentication uses `Authorization: Bearer <token>`. The token is generated on first launch and stored in `~/.owa-bridge/token` (0600). A missing or wrong token returns `403 {"error":"unauthorized"}`.
- Error body: `{ "error": "<code>", "message": "..." }`. Codes: `unauthorized` 403, `not_logged_in` / `session_expired` 401, `not_found` 404, `bad_request` 400, `extract_failed` 502, `timeout` 504.
- Requests are serialized into the WebView, each with a timeout (default 10s).

See PRD §6 for the response schema. `/messages` returns `{ folder, count, messages: [...] }`; the detail
response adds `cc`, `bcc`, `body: {contentType, content}` and `attachments: [{name, size, contentType, isInline}]`.

## Debug mode (for AI page analysis)

Add `?debug=true` to any data endpoint to get an extra `_debug` block:

```json
"_debug": {
  "provider": "domProvider",
  "durationMs": 42,
  "attempted": ["internalFetchProvider(failed: 401)", "domProvider(ok)"],
  "anchors": [{ "field": "from", "via": "title@", "selector": "[role=option] [title*=\"@\"]", "matched": 10 }],
  "warnings": ["subject/bodyPreview use a text heuristic; the to field is not available in the list DOM"],
  "idSource": "synthetic (dom hash of data-convid)",
  "adapterVersion": "owa-2026.10",
  "correlationId": "…", "bridgeMs": 51, "pageMs": 44
}
```

Dedicated endpoints (all require the token):

| Endpoint | Returns |
|---|---|
| `GET /debug/dom?selector=&maxLength=` | `outerHTML` of the node (default `body`), truncated |
| `GET /debug/aria?selector=&maxDepth=&maxNodes=&includeText=` | Accessibility tree (role / name / level / states as JSON), best suited to AI analysis |
| `GET /debug/snapshot` | `{width,height,base64}` PNG; `?format=png` returns the image directly |
| `GET /debug/extract?target=messages\|message\|me&id=…` | Full extraction trace: providers tried, anchors matched, steps, raw→schema mapping samples |
| `GET\|POST /debug/eval?code=` | Runs JS in the page context (**off by default**) |

`/debug/eval` must be switched on explicitly in the config. The code runs as the body of an async function;
a single-line expression gets an implicit `return`. For example:
`curl -H "Authorization: Bearer $TOKEN" --data 'return document.title' http://127.0.0.1:5333/debug/eval`.
The app cannot enforce "read-only" — anyone holding the local token can run arbitrary JS in the page context.

## Configuration `~/.owa-bridge/config.json`

A default config is written on first launch. Restart after editing.

```json
{
  "port": 5333,
  "requestTimeoutSeconds": 10,
  "enableDebugEval": false,
  "logLevel": "info",
  "logToFile": true,
  "startURL": "https://outlook.office.com/mail/",
  "autoShowLoginWindow": true,
  "applicationNameForUserAgent": "Version/17.4 Safari/605.1.15",
  "scriptWorld": "client",
  "probeIntervalSeconds": 30
}
```

- `scriptWorld`: `client` (default) runs the extraction script in an isolated JS world, so OWA's page scripts cannot see or tamper with it. Use `page` only when debugging requires access to page globals.
- Logs are written to stderr and `~/.owa-bridge/logs/bridge.log` as one JSON object per line, containing metadata only (path, status, duration, provider, correlationId). **Message bodies are never logged.** Debug output is returned over HTTP only and never written to disk.

## Architecture

```
Sources/OWABridgeCore/   Platform-neutral logic (unit-testable on Linux too)
  HTTPRequest/Response, Router, APIError, Queries      Minimal HTTP/1.1 + routing + parameter validation
  Config, TokenStore(BearerAuth), Paths, Log           Config / local token / structured logs
  Session                                              Login state machine loading→loggedIn/notLoggedIn/expired
  PageResult, DebugEval                                Page-result envelope decoding / eval wrapping
Sources/OWABridge/       macOS app
  App, AppDelegate, StatusBarController                Menu bar shell (LSUIElement), App Nap prevention
  WebViewHost                                          Persistent WKWebView, offscreen window keep-alive, login detection, snapshots
  JSBridge                                             HTTP→JS: correlationId, serial queue, timeouts
  HTTPServer                                           NWListener, binds 127.0.0.1 only
  BridgeAPI(+Debug)                                    Routing, auth, session gate, /status, /debug/*
Resources/extractor.js   Page-side extraction script (provider pattern + versioned adapter + Trace)
```

### Extraction layer (`Resources/extractor.js`)

1. **internalFetchProvider** (preferred): from the signed-in page context, makes same-origin `fetch` calls to
   OWA's own `service.svc` (`FindItem` / `GetItem` / `FindFolder`) and `sessiondata.ashx`. It sends only the
   page's existing cookies plus OWA's anti-CSRF `X-OWA-CANARY` request header, which never appears in any
   response or debug output.
2. **domProvider** (fallback): locates content through the accessibility tree / ARIA (`listbox`/`option`,
   `treeitem[aria-selected]`, `title` attributes containing an email address, the reading pane's
   `aria-label`). It **never clicks or opens a message** (opening would mark it read). It can only read the
   folder currently open in OWA, and details are available only for the message open in the reading pane.
   Message ids are synthetic (`dom:…`).
3. Scheduling: if the internal API returns 401/440 while the page itself looks signed in (common when new OWA
   tenants require bearer tokens), the internal provider is paused for 5 minutes and requests fall back to the
   DOM. If the page is on a sign-in page, the result is `session_expired`: the menu bar switches to "signed
   out" and the window pops up for re-login.
4. **adapter**: every raw→schema mapping (EWS request bodies, field names, ARIA anchors, regexes) lives in one
   versioned `adapter`. When OWA ships a redesign, only this layer needs to change. Use `/debug/aria` and
   `/debug/extract` to have an AI rebuild the mapping.

### Keeping the WebView alive

"Hiding" the window actually moves it offscreen while it stays in the window hierarchy, so the WebView keeps
rendering and running JS. The close button means "hide". The app calls `ProcessInfo.beginActivity` to prevent
App Nap. On macOS 14+ it also sets `WKPreferences.inactiveSchedulingPolicy = .none`.

## Development and testing

```bash
swift build && swift test                 # macOS: build + Core unit tests
npm ci && npm test                        # extractor.js unit tests (Node + jsdom, 21 tests)
./scripts/test-core-linux.sh              # Linux/Docker: Core unit tests only
OWA_BRIDGE_EXTRACTOR=$PWD/Resources/extractor.js swift run   # use the extraction script from the source tree
OWA_BRIDGE_HOME=/tmp/owa-dev swift run                       # use a separate config/token directory
```

CI (`.github/workflows/ci.yml`) builds and bundles the app on a macOS runner and runs both test suites.

## Known limitations

- It depends on OWA's unpublished endpoints and DOM, so a redesign can break it. That is the cost of this approach (see PRD §3); debug mode exists to fix it quickly.
- The internal endpoint request format (EWS JSON field names) is based on public EWS semantics. Some tenants or new OWA versions may reject cookie authentication; in that case it falls back to the DOM automatically, which yields fewer fields (no `to`/`cc`/attachments; `receivedDateTime` may be `null`).
- Single account only. Read-only (no sending or modifying mail).
