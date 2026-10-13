'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const extractor = require(path.join(__dirname, '../../Resources/extractor.js'));

const OWA_LIST_HTML = `
<html><head><title>Mail - Wenjin Zhang - Outlook</title></head><body>
  <div role="navigation">
    <div role="tree" aria-label="Folders">
      <div role="treeitem" aria-selected="true" title="Inbox">Inbox <span>3</span></div>
      <div role="treeitem" aria-selected="false" title="Sent Items">Sent Items</div>
    </div>
  </div>
  <div role="main">
    <div role="listbox" aria-label="Message list">
      <div role="option" data-convid="CONV1" aria-label="Unread, Has attachments, Alice, Q4 compute plan, 8:12 AM, 附上最新的算力">
        <span title="alice@contoso.com">Alice</span>
        <span>Q4 compute plan</span>
        <span title="2026-10-13T08:12:00Z">8:12 AM</span>
        <span>附上最新的算力规划,请查收</span>
      </div>
      <div role="option" data-convid="CONV2" aria-label="Bob, Lunch?, Yesterday, Shall we grab lunch">
        <span>Bob</span>
        <span>Lunch?</span>
        <span>Yesterday</span>
        <span>Shall we grab lunch tomorrow</span>
      </div>
    </div>
    <div role="heading" aria-level="2">Q4 compute plan</div>
    <div aria-label="Message body">Hello Wenjin,
      the full plan is attached.</div>
  </div>
  <button id="O365_MainLink_Me" aria-label="Account manager for Wenjin Zhang"></button>
</body></html>`;

function makeDom(html, url = 'https://outlook.office.com/mail/') {
  const dom = new JSDOM(html, { url, pretendToBeVisual: true });
  return dom.window;
}

function bridgeFor(win, fetchImpl) {
  return extractor.createBridge({
    window: win,
    document: win.document,
    location: win.location,
    fetch: fetchImpl || null
  });
}

function jsonResponse(status, body) {
  return {
    status,
    ok: status >= 200 && status < 300,
    redirected: false,
    url: 'https://outlook.office.com/owa/service.svc',
    text: async () => JSON.stringify(body)
  };
}

async function call(bridge, command, args) {
  return JSON.parse(await bridge.run(command, JSON.stringify(args || {}), 'cid-1'));
}

// ---------------------------------------------------------------------------
// adapter
// ---------------------------------------------------------------------------

test('adapter maps OWA FindItem items to the semantic schema', () => {
  const m = extractor.adapter.fromOwaListItem({
    ItemId: { Id: 'AAMk1' },
    ConversationId: { Id: 'AAQk1' },
    Subject: 'Q4 compute plan',
    From: { Mailbox: { Name: 'Alice', EmailAddress: 'alice@contoso.com' } },
    DisplayTo: 'Wenjin; bob@contoso.com',
    DateTimeReceived: '2026-10-13T16:12:00+08:00',
    Preview: '附上最新的算力…',
    IsRead: false,
    HasAttachments: true,
    Importance: 'Normal'
  });
  assert.deepEqual(m, {
    id: 'AAMk1',
    conversationId: 'AAQk1',
    subject: 'Q4 compute plan',
    from: { name: 'Alice', address: 'alice@contoso.com' },
    to: [{ name: 'Wenjin', address: '' }, { name: 'bob@contoso.com', address: 'bob@contoso.com' }],
    receivedDateTime: '2026-10-13T08:12:00Z',
    bodyPreview: '附上最新的算力…',
    isRead: false,
    hasAttachments: true,
    importance: 'normal'
  });
});

test('adapter maps GetItem detail including body, cc and attachments', () => {
  const m = extractor.adapter.fromOwaItem({
    ItemId: { Id: 'AAMk1' },
    Subject: 'S',
    From: { Mailbox: { Name: 'Alice', EmailAddress: 'alice@contoso.com' } },
    ToRecipients: [{ Name: 'Wenjin', EmailAddress: 'wenjin@contoso.com' }],
    CcRecipients: [],
    DateTimeReceived: '2026-10-13T08:12:00Z',
    Body: { BodyType: 'Text', Value: 'full body' },
    Attachments: [{ Name: 'plan.xlsx', Size: 20480, ContentType: 'application/vnd.ms-excel' }],
    IsRead: true
  });
  assert.equal(m.body.contentType, 'text');
  assert.equal(m.body.content, 'full body');
  assert.deepEqual(m.to, [{ name: 'Wenjin', address: 'wenjin@contoso.com' }]);
  assert.deepEqual(m.cc, []);
  assert.deepEqual(m.attachments, [{ name: 'plan.xlsx', size: 20480, contentType: 'application/vnd.ms-excel', isInline: false }]);
  assert.equal(m.bodyPreview, 'full body');
});

test('adapter builds folder ids and unread restriction', () => {
  assert.equal(extractor.adapter.folderIdFor('sent').Id, 'sentitems');
  assert.equal(extractor.adapter.folderIdFor('Inbox').Id, 'inbox');
  assert.equal(extractor.adapter.folderIdFor('Projects'), null);
  const req = extractor.adapter.findItemRequest({ Id: 'inbox' }, 5, true);
  assert.equal(req.Body.Paging.MaxEntriesReturned, 5);
  assert.equal(req.Body.Restriction.Item.FieldURIOrConstant.Item.Value, 'false');
});

test('adapter turns EWS error responses into not_found / extract_failed', () => {
  assert.throws(
    () => extractor.adapter.responseMessage({ Body: { ResponseMessages: { Items: [{ ResponseClass: 'Error', ResponseCode: 'ErrorItemNotFound' }] } } }, 'GetItem'),
    (e) => e.code === 'not_found'
  );
  assert.throws(
    () => extractor.adapter.responseMessage({ Body: {} }, 'FindItem'),
    (e) => e.code === 'extract_failed'
  );
});

test('adapter reads /me from sessiondata', () => {
  const me = extractor.adapter.fromSessionData({
    owaUserConfig: { SessionSettings: { UserDisplayName: 'Wenjin', UserEmailAddress: 'wenjin@contoso.com', TenantDomain: 'contoso.onmicrosoft.com' } }
  });
  assert.deepEqual(me, { displayName: 'Wenjin', address: 'wenjin@contoso.com', tenant: 'contoso.onmicrosoft.com', loggedIn: true });
});

// ---------------------------------------------------------------------------
// internalFetchProvider
// ---------------------------------------------------------------------------

test('messages via internalFetchProvider sends canary and maps results', async () => {
  const win = makeDom(OWA_LIST_HTML);
  win.document.cookie = 'X-OWA-CANARY=canary-value';
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return jsonResponse(200, {
      Body: { ResponseMessages: { Items: [{ ResponseClass: 'Success', RootFolder: { Items: [
        { ItemId: { Id: 'A1' }, Subject: 'one', IsRead: false, DateTimeReceived: '2026-10-13T08:12:00Z' },
        { ItemId: { Id: 'A2' }, Subject: 'two', IsRead: true, DateTimeReceived: '2026-10-13T07:00:00Z' }
      ] } }] } }
    });
  };
  const bridge = bridgeFor(win, fetchImpl);
  const r = await call(bridge, 'messages', { top: 10, debug: true });
  assert.equal(r.ok, true);
  assert.equal(r.provider, 'internalFetchProvider');
  assert.equal(r.data.folder, 'inbox');
  assert.equal(r.data.count, 2);
  assert.equal(r.data.messages[0].id, 'A1');
  assert.deepEqual(r.debug.attempted, ['internalFetchProvider(ok)']);
  assert.equal(r.debug.idSource, 'owa-item-id');

  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /\/owa\/service\.svc\?action=FindItem/);
  assert.equal(calls[0].init.headers['X-OWA-CANARY'], 'canary-value');
  assert.equal(calls[0].init.credentials, 'include');
  // canary must never leak into the result / debug output
  assert.ok(!JSON.stringify(r).includes('canary-value'));
});

test('falls back to domProvider when internal API rejects cookie auth', async () => {
  const win = makeDom(OWA_LIST_HTML);
  let fetches = 0;
  const bridge = bridgeFor(win, async () => { fetches++; return jsonResponse(401, {}); });
  const r = await call(bridge, 'messages', { top: 10, debug: true });
  assert.equal(r.ok, true);
  assert.equal(r.provider, 'domProvider');
  assert.deepEqual(r.debug.attempted, ['internalFetchProvider(failed: 401)', 'domProvider(ok)']);
  assert.ok(r.debug.warnings.some((w) => w.includes('falling back to DOM')));

  // internal provider is paused after the auth failure
  const r2 = await call(bridge, 'messages', { debug: true });
  assert.equal(fetches, 1);
  assert.match(r2.debug.attempted[0], /^internalFetchProvider\(skipped: disabled/);
});

test('401 on a login page is reported as session_expired', async () => {
  const win = makeDom('<html><body><input name="loginfmt"></body></html>', 'https://login.microsoftonline.com/common/oauth2/authorize');
  const bridge = bridgeFor(win, async () => jsonResponse(401, {}));
  const r = await call(bridge, 'messages', {});
  assert.equal(r.ok, false);
  assert.equal(r.error, 'session_expired');
  assert.equal(r.status, 401);
});

test('authoritative not_found from GetItem is not masked by the DOM fallback', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, async () => jsonResponse(200, {
    Body: { ResponseMessages: { Items: [{ ResponseClass: 'Error', ResponseCode: 'ErrorItemNotFound' }] } }
  }));
  const r = await call(bridge, 'message', { id: 'AAMk-missing' });
  assert.equal(r.error, 'not_found');
  assert.equal(r.status, 404);
});

test('custom folder names are resolved with FindFolder', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const actions = [];
  const bridge = bridgeFor(win, async (url, init) => {
    const action = init.headers.Action;
    actions.push(action);
    if (action === 'FindFolder') {
      return jsonResponse(200, { Body: { ResponseMessages: { Items: [{ ResponseClass: 'Success', RootFolder: { Folders: [
        { DisplayName: 'Projects', FolderId: { Id: 'F-PROJ' } }
      ] } }] } } });
    }
    const body = JSON.parse(init.body);
    assert.equal(body.Body.ParentFolderIds[0].Id, 'F-PROJ');
    return jsonResponse(200, { Body: { ResponseMessages: { Items: [{ ResponseClass: 'Success', RootFolder: { Items: [] } }] } } });
  });
  const r = await call(bridge, 'messages', { folder: 'projects' });
  assert.equal(r.ok, true);
  assert.deepEqual(actions, ['FindFolder', 'FindItem']);
  assert.equal(r.data.count, 0);
});

// ---------------------------------------------------------------------------
// domProvider
// ---------------------------------------------------------------------------

test('domProvider extracts list items via ARIA anchors', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const r = await call(bridge, 'messages', { top: 10, debug: true });
  assert.equal(r.ok, true);
  assert.equal(r.provider, 'domProvider');
  const [a, b] = r.data.messages;
  assert.equal(a.subject, 'Q4 compute plan');
  assert.deepEqual(a.from, { name: 'Alice', address: 'alice@contoso.com' });
  assert.equal(a.receivedDateTime, '2026-10-13T08:12:00Z');
  assert.equal(a.bodyPreview, '附上最新的算力规划,请查收');
  assert.equal(a.isRead, false);
  assert.equal(a.hasAttachments, true);
  assert.equal(a.conversationId, 'CONV1');
  assert.match(a.id, /^dom:/);
  assert.equal(b.subject, 'Lunch?');
  assert.equal(b.isRead, true);
  assert.equal(b.receivedDateTime, null);
  assert.ok(r.debug.anchors.some((x) => x.field === 'messageList'));
  assert.ok(r.debug.anchors.some((x) => x.field === 'from' && x.matched === 1));
  assert.match(r.debug.idSource, /synthetic/);

  const unread = await call(bridge, 'messages', { unread: true });
  assert.equal(unread.data.count, 1);
});

test('domProvider refuses to read a folder that is not open', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const r = await call(bridge, 'messages', { folder: 'sent' });
  assert.equal(r.ok, false);
  assert.equal(r.error, 'extract_failed');
  assert.match(r.message, /currently open/);
});

test('domProvider detail reads the open reading pane for a cached synthetic id', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const list = await call(bridge, 'messages', {});
  const id = list.data.messages[0].id;
  const r = await call(bridge, 'message', { id, debug: true });
  assert.equal(r.ok, true);
  assert.equal(r.data.subject, 'Q4 compute plan');
  assert.match(r.data.body.content, /full plan is attached/);
  assert.equal(r.debug.attempted[0], 'internalFetchProvider(skipped: synthetic dom id)');

  // second message is not open -> no side-effectful clicking, explicit error
  const r2 = await call(bridge, 'message', { id: list.data.messages[1].id });
  assert.equal(r2.error, 'extract_failed');
  assert.match(r2.message, /reading pane/);

  const r3 = await call(bridge, 'message', { id: 'dom:unknown' });
  assert.equal(r3.error, 'not_found');
});

test('domProvider /me uses the account manager button label', async () => {
  const win = makeDom(OWA_LIST_HTML.replace('aria-label="Account manager for Wenjin Zhang"', 'aria-label="Account manager for Wenjin Zhang" title="wenjin@contoso.com"'));
  const bridge = bridgeFor(win, null);
  const r = await call(bridge, 'me', {});
  assert.equal(r.ok, true);
  assert.deepEqual(r.data, { displayName: 'Wenjin Zhang', address: 'wenjin@contoso.com', tenant: 'contoso.com', loggedIn: true });
});

// ---------------------------------------------------------------------------
// debug commands
// ---------------------------------------------------------------------------

test('aria command returns a semantic tree', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const r = await call(bridge, 'aria', { selector: '[role=main]' });
  assert.equal(r.ok, true);
  const main = r.data.tree[0];
  assert.equal(main.role, 'main');
  const listbox = main.children.find((c) => c.role === 'listbox');
  assert.equal(listbox.name, 'Message list');
  assert.equal(listbox.children.length, 2);
  assert.equal(listbox.children[0].role, 'option');
  assert.equal(listbox.children[0].convid, 'CONV1');
  const heading = main.children.find((c) => c.role === 'heading');
  assert.equal(heading.level, 2);

  const limited = await call(bridge, 'aria', { maxNodes: 2 });
  assert.equal(limited.data.truncated, true);
});

test('dom command truncates and validates selectors', async () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const r = await call(bridge, 'dom', { selector: '[role=listbox]', maxLength: 50 });
  assert.equal(r.data.truncated, true);
  assert.equal(r.data.html.length, 50);
  assert.equal(r.data.matched, 1);
  const bad = await call(bridge, 'dom', { selector: '[[[' });
  assert.equal(bad.error, 'bad_request');
  const none = await call(bridge, 'dom', { selector: '#nope' });
  assert.equal(none.error, 'not_found');
});

test('extract command returns a full trace even on failure', async () => {
  const win = makeDom('<html><body><div role="main"></div><div role="tree"></div></body></html>');
  const bridge = bridgeFor(win, async () => jsonResponse(500, {}));
  const r = await call(bridge, 'extract', { target: 'messages' });
  assert.equal(r.ok, true);
  assert.equal(r.data.ok, false);
  assert.equal(r.data.error, 'extract_failed');
  assert.deepEqual(r.data.trace.attempted, ['internalFetchProvider(failed: 500)', 'domProvider(failed: extract_failed)']);
  assert.ok(r.data.trace.steps.length > 0);
});

test('probe reports login page and mail readiness', async () => {
  const ready = await call(bridgeFor(makeDom(OWA_LIST_HTML), null), 'probe');
  assert.equal(ready.data.mailReady, true);
  assert.equal(ready.data.onLoginPage, false);
  const login = await call(bridgeFor(makeDom('<html><body></body></html>', 'https://login.microsoftonline.com/'), null), 'probe');
  assert.equal(login.data.onLoginPage, true);
  assert.equal(login.data.mailReady, false);
});

test('serialize handles DOM nodes, cycles and odd values', () => {
  const win = makeDom(OWA_LIST_HTML);
  const bridge = bridgeFor(win, null);
  const cyc = { a: 1 };
  cyc.self = cyc;
  const out = bridge.serialize({ n: win.document.querySelector('[role=main]'), cyc, u: undefined, f() {}, d: new Date(0), inf: Infinity });
  assert.equal(out.n.node, 'div');
  assert.equal(out.cyc.self, '[Circular]');
  assert.equal(out.u, null);
  assert.equal(out.f, '[Function f]');
  assert.equal(out.d, '1970-01-01T00:00:00.000Z');
  assert.equal(out.inf, 'Infinity');
});

test('unknown commands produce a structured error', async () => {
  const r = await call(bridgeFor(makeDom(OWA_LIST_HTML), null), 'nope');
  assert.equal(r.ok, false);
  assert.equal(r.error, 'bad_request');
});

test('script self-installs as window.__owaBridge when injected into a page', async () => {
  const fs = require('node:fs');
  const source = fs.readFileSync(path.join(__dirname, '../../Resources/extractor.js'), 'utf8');
  const dom = new JSDOM(OWA_LIST_HTML, { url: 'https://outlook.office.com/mail/', runScripts: 'outside-only', pretendToBeVisual: true });
  const posted = [];
  dom.window.webkit = { messageHandlers: { owaBridge: { postMessage: (m) => posted.push(m) } } };
  dom.window.eval(source);
  assert.equal(typeof dom.window.__owaBridge.run, 'function');
  const r = JSON.parse(await dom.window.__owaBridge.run('probe', '{}', 'cid'));
  assert.equal(r.data.mailReady, true);
  // re-injection of the same version keeps the existing instance (and its caches)
  const before = dom.window.__owaBridge;
  dom.window.eval(source);
  assert.equal(dom.window.__owaBridge, before);
  await new Promise((resolve) => setTimeout(resolve, 1100));
  assert.equal(JSON.stringify(posted), JSON.stringify([{ type: 'mailReady' }]));
  dom.window.close();
});
