/*
 * OWA WebView Bridge — page-side extractor.
 *
 * 注入到 outlook.office.com 页面(WKUserScript,隔离 content world),由 Swift 侧通过
 * callAsyncJavaScript 调用 `window.__owaBridge.run(command, argsJSON, correlationId)`。
 *
 * 结构:
 *   - providers:internalFetchProvider(页面内鉴权 fetch OWA 内部接口,首选)
 *                domProvider(基于无障碍树 / ARIA 的 DOM 兜底)
 *   - adapter:  集中、版本化的「原始数据 → 语义 schema」映射;OWA 改版只改这里
 *   - Trace:    记录尝试过的 provider、命中的锚点、警告、原始→schema 映射,供 debug 模式使用
 *
 * 红线:只在已登录页面上下文内读取当前用户自己的邮件;不读取、不返回任何 access token。
 *       X-OWA-CANARY(OWA 自身的反 CSRF cookie)只作为同源请求头使用,不出现在任何返回值里。
 */
(function (root, factory) {
  'use strict';
  var api = factory(root);
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  }
  if (root && root.document && root.location) {
    if (!root.__owaBridge || root.__owaBridge.version !== api.version) {
      root.__owaBridge = api.createBridge({});
      root.__owaBridge.announce();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis, function (root) {
  'use strict';

  var VERSION = '0.1.0';
  var ADAPTER_VERSION = 'owa-2026.10';

  // ---------------------------------------------------------------------------
  // 错误与工具
  // ---------------------------------------------------------------------------

  var STATUS_BY_CODE = {
    bad_request: 400,
    session_expired: 401,
    not_logged_in: 401,
    auth_failed: 401,
    not_found: 404,
    extract_failed: 502,
    timeout: 504
  };

  function BridgeError(code, message, extra) {
    var e = new Error(message || code);
    e.name = 'BridgeError';
    e.code = code;
    e.status = STATUS_BY_CODE[code] || 500;
    if (extra) {
      for (var k in extra) e[k] = extra[k];
    }
    return e;
  }

  function normalizeError(e) {
    if (e && e.name === 'BridgeError') return e;
    return BridgeError('extract_failed', (e && e.message) || String(e));
  }

  function now() {
    return (root.performance && root.performance.now) ? root.performance.now() : Date.now();
  }

  function trimText(s, max) {
    if (s == null) return '';
    var t = String(s).replace(/\s+/g, ' ').trim();
    if (max && t.length > max) t = t.slice(0, max) + '…';
    return t;
  }

  function isoDate(v) {
    if (!v) return null;
    var d = new Date(v);
    if (isNaN(d.getTime())) return null;
    return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
  }

  function domainOf(address) {
    if (!address || address.indexOf('@') < 0) return null;
    return address.split('@').pop().toLowerCase();
  }

  var EMAIL_RE = /[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;

  function hashString(s) {
    // FNV-1a 32bit,足够做合成 id。
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return ('0000000' + h.toString(16)).slice(-8);
  }

  function clampInt(v, def, min, max) {
    var n = parseInt(v, 10);
    if (isNaN(n)) n = def;
    return Math.max(min, Math.min(max, n));
  }

  // ---------------------------------------------------------------------------
  // Trace(debug 模式)
  // ---------------------------------------------------------------------------

  function Trace(level, correlationId) {
    this.level = level || 'off'; // off | basic | full
    this.correlationId = correlationId || null;
    this.attempted = [];
    this.anchors = [];
    this.warnings = [];
    this.steps = [];
    this.mapping = [];
    this.idSource = null;
    this.t0 = now();
  }
  Trace.prototype.attempt = function (provider, outcome) {
    this.attempted.push(provider + '(' + outcome + ')');
  };
  Trace.prototype.anchor = function (field, via, selector, matched) {
    this.anchors.push({ field: field, via: via, selector: selector, matched: matched });
  };
  Trace.prototype.warn = function (message) {
    if (this.warnings.indexOf(message) < 0) this.warnings.push(message);
  };
  Trace.prototype.step = function (message, detail) {
    if (this.level !== 'full') return;
    var entry = { atMs: Math.round(now() - this.t0), step: message };
    if (detail !== undefined) entry.detail = detail;
    this.steps.push(entry);
  };
  Trace.prototype.map = function (raw, mapped) {
    if (this.level !== 'full' || this.mapping.length >= 3) return;
    this.mapping.push({ raw: raw, mapped: mapped });
  };
  Trace.prototype.toDebug = function (provider) {
    if (this.level === 'off') return undefined;
    var d = {
      provider: provider || null,
      durationMs: Math.round(now() - this.t0),
      attempted: this.attempted,
      anchors: this.anchors,
      warnings: this.warnings,
      idSource: this.idSource,
      adapterVersion: ADAPTER_VERSION,
      extractorVersion: VERSION,
      correlationId: this.correlationId
    };
    if (this.level === 'full') {
      d.steps = this.steps;
      d.mapping = this.mapping;
    }
    return d;
  };

  // ---------------------------------------------------------------------------
  // Adapter:原始数据 → 语义 schema(唯一需要随 OWA 改版调整的映射层)
  // ---------------------------------------------------------------------------

  var DISTINGUISHED_FOLDERS = {
    inbox: 'inbox',
    sent: 'sentitems',
    sentitems: 'sentitems',
    drafts: 'drafts',
    deleted: 'deleteditems',
    deleteditems: 'deleteditems',
    trash: 'deleteditems',
    junk: 'junkemail',
    junkemail: 'junkemail',
    archive: 'archive',
    outbox: 'outbox'
  };

  var adapter = {
    version: ADAPTER_VERSION,

    // ---- internal (OWA service.svc, EWS JSON) ----

    requestHeader: function () {
      return {
        __type: 'JsonRequestHeaders:#Exchange',
        RequestServerVersion: 'Exchange2013',
        TimeZoneContext: {
          __type: 'TimeZoneContext:#Exchange',
          TimeZoneDefinition: { __type: 'TimeZoneDefinitionType:#Exchange', Id: 'UTC' }
        }
      };
    },

    folderIdFor: function (folder) {
      var key = String(folder || 'inbox').toLowerCase();
      if (DISTINGUISHED_FOLDERS[key]) {
        return { __type: 'DistinguishedFolderId:#Exchange', Id: DISTINGUISHED_FOLDERS[key] };
      }
      return null;
    },

    findFolderRequest: function () {
      return {
        __type: 'FindFolderJsonRequest:#Exchange',
        Header: adapter.requestHeader(),
        Body: {
          __type: 'FindFolderRequest:#Exchange',
          FolderShape: { __type: 'FolderResponseShape:#Exchange', BaseShape: 'Default' },
          ParentFolderIds: [{ __type: 'DistinguishedFolderId:#Exchange', Id: 'msgfolderroot' }],
          Traversal: 'Deep'
        }
      };
    },

    findItemRequest: function (folderId, top, unreadOnly) {
      var body = {
        __type: 'FindItemRequest:#Exchange',
        ItemShape: {
          __type: 'ItemResponseShape:#Exchange',
          BaseShape: 'Default',
          AdditionalProperties: [
            { __type: 'PropertyUri:#Exchange', FieldURI: 'item:Preview' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'item:ConversationId' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'item:DisplayTo' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'item:HasAttachments' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'item:Importance' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'message:IsRead' },
            { __type: 'PropertyUri:#Exchange', FieldURI: 'message:From' }
          ]
        },
        ParentFolderIds: [folderId],
        Traversal: 'Shallow',
        Paging: {
          __type: 'IndexedPageView:#Exchange',
          BasePoint: 'Beginning',
          Offset: 0,
          MaxEntriesReturned: top
        },
        SortOrder: [{
          __type: 'SortResults:#Exchange',
          Order: 'Descending',
          Path: { __type: 'PropertyUri:#Exchange', FieldURI: 'item:DateTimeReceived' }
        }]
      };
      if (unreadOnly) {
        body.Restriction = {
          __type: 'RestrictionType:#Exchange',
          Item: {
            __type: 'IsEqualTo:#Exchange',
            Item: { __type: 'PropertyUri:#Exchange', FieldURI: 'message:IsRead' },
            FieldURIOrConstant: {
              __type: 'FieldURIOrConstantType:#Exchange',
              Item: { __type: 'Constant:#Exchange', Value: 'false' }
            }
          }
        };
      }
      return { __type: 'FindItemJsonRequest:#Exchange', Header: adapter.requestHeader(), Body: body };
    },

    getItemRequest: function (id, bodyType) {
      return {
        __type: 'GetItemJsonRequest:#Exchange',
        Header: adapter.requestHeader(),
        Body: {
          __type: 'GetItemRequest:#Exchange',
          ItemShape: {
            __type: 'ItemResponseShape:#Exchange',
            BaseShape: 'AllProperties',
            BodyType: bodyType === 'html' ? 'HTML' : 'Text'
          },
          ItemIds: [{ __type: 'ItemId:#Exchange', Id: id }]
        }
      };
    },

    mailbox: function (x) {
      if (!x) return null;
      var m = x.Mailbox || x;
      if (!m || (!m.Name && !m.EmailAddress)) return null;
      return { name: m.Name || '', address: m.EmailAddress || '' };
    },

    recipients: function (list) {
      if (!Array.isArray(list)) return null;
      return list.map(adapter.mailbox).filter(Boolean);
    },

    displayList: function (s) {
      if (!s) return [];
      return String(s).split(';').map(function (n) { return n.trim(); }).filter(Boolean)
        .map(function (n) { return { name: n, address: EMAIL_RE.test(n) ? n.match(EMAIL_RE)[0] : '' }; });
    },

    importance: function (v) {
      var s = String(v || 'normal').toLowerCase();
      return (s === 'high' || s === 'low') ? s : 'normal';
    },

    fromOwaListItem: function (it) {
      return {
        id: (it.ItemId && it.ItemId.Id) || null,
        conversationId: (it.ConversationId && it.ConversationId.Id) || null,
        subject: it.Subject || '',
        from: adapter.mailbox(it.From) || adapter.mailbox(it.Sender),
        to: adapter.recipients(it.ToRecipients) || adapter.displayList(it.DisplayTo),
        receivedDateTime: isoDate(it.DateTimeReceived),
        bodyPreview: it.Preview || '',
        isRead: !!it.IsRead,
        hasAttachments: !!it.HasAttachments,
        importance: adapter.importance(it.Importance)
      };
    },

    fromOwaItem: function (it) {
      var base = adapter.fromOwaListItem(it);
      var body = it.Body || it.UniqueBody || {};
      base.cc = adapter.recipients(it.CcRecipients) || [];
      base.bcc = adapter.recipients(it.BccRecipients) || [];
      base.body = {
        contentType: String(body.BodyType || 'Text').toLowerCase() === 'html' ? 'html' : 'text',
        content: body.Value || ''
      };
      base.attachments = (Array.isArray(it.Attachments) ? it.Attachments : []).map(function (a) {
        return {
          name: a.Name || '',
          size: typeof a.Size === 'number' ? a.Size : null,
          contentType: a.ContentType || null,
          isInline: !!a.IsInline
        };
      });
      if (!base.bodyPreview && base.body.contentType === 'text') {
        base.bodyPreview = trimText(base.body.content, 255);
      }
      return base;
    },

    fromSessionData: function (json) {
      var cfg = (json && (json.owaUserConfig || json.OwaUserConfig)) || json || {};
      var ss = cfg.SessionSettings || cfg.sessionSettings || {};
      var address = ss.UserEmailAddress || ss.LogonEmailAddress || ss.UserPrincipalName || '';
      if (!address) return null;
      return {
        displayName: ss.UserDisplayName || '',
        address: address,
        tenant: ss.TenantDomain || ss.DefaultDomain || domainOf(address),
        loggedIn: true
      };
    },

    /** EWS 响应:取第一个 ResponseMessage,失败时转换成 BridgeError。 */
    responseMessage: function (json, action) {
      var items = json && json.Body && json.Body.ResponseMessages && json.Body.ResponseMessages.Items;
      if (!Array.isArray(items) || !items.length) {
        throw BridgeError('extract_failed', action + ': unexpected response shape');
      }
      var m = items[0];
      if (m.ResponseClass && m.ResponseClass !== 'Success') {
        var code = m.ResponseCode || 'Error';
        if (/ItemNotFound|InvalidIdMalformed|InvalidId|FolderNotFound|InvalidIdNotAnItemAttachmentId/.test(code)) {
          throw BridgeError('not_found', action + ': ' + code, { authoritative: true });
        }
        throw BridgeError('extract_failed', action + ': ' + code + (m.MessageText ? ' — ' + m.MessageText : ''));
      }
      return m;
    },

    // ---- DOM(ARIA 锚点) ----

    dom: {
      listLabel: /message list|邮件列表|郵件清單|mail list|messages/i,
      readingPaneBody: [
        '[aria-label="Message body"]',
        '[aria-label="邮件正文"]',
        '[aria-label="郵件內文"]',
        '[aria-label*="Message body"]',
        '[id^="UniqueMessageBody"]'
      ],
      unreadLabel: /(^|[,，\s])(unread|未读|未讀)([,，\s]|$)/i,
      attachmentLabel: /attachment|附件/i,
      highImportanceLabel: /high importance|重要性高|高重要性|important/i,
      timeText: /^(\d{1,2}:\d{2}(\s?[AP]M)?|[AP]M\s?\d{1,2}:\d{2}|(上午|下午)\s?\d{1,2}:\d{2}|yesterday|today|昨天|今天|周[一二三四五六日天]|星期[一二三四五六日天]|(mon|tue|wed|thu|fri|sat|sun)\w*(\s.*)?|\d{4}[\/-]\d{1,2}[\/-]\d{1,2}.*|\d{1,2}[\/-]\d{1,2}([\/-]\d{2,4})?.*)$/i,
      inboxFolder: /^(inbox|收件箱|收件匣)\b/i,
      accountLabel: [
        /account manager for (.+)/i,
        /(.+?)\s*的帐户管理器/,
        /(.+?)\s*的帳戶管理員/
      ]
    }
  };

  // ---------------------------------------------------------------------------
  // Bridge 实例(env 可注入,便于测试)
  // ---------------------------------------------------------------------------

  function createBridge(envOverrides) {
    var env = {
      window: root,
      document: root.document,
      location: root.location,
      fetch: root.fetch ? root.fetch.bind(root) : null
    };
    for (var k in envOverrides) env[k] = envOverrides[k];

    var state = {
      internalDisabledUntil: 0,
      internalDisabledReason: null,
      idCache: {},
      lastProvider: null
    };

    // ---- 页面状态 ----

    function hostIsLogin() {
      var host = (env.location && env.location.hostname || '').toLowerCase();
      return !!host && !/^outlook\.(office|office365|live)\.com$|^outlook\.cloud\.microsoft$/.test(host);
    }

    function onLoginPage() {
      if (hostIsLogin()) return true;
      var d = env.document;
      return !!(d && d.querySelector('input[name="loginfmt"], input[type="password"][name="passwd"]'));
    }

    function mailUIPresent() {
      var d = env.document;
      if (!d) return false;
      var main = d.querySelector('[role="main"]');
      var nav = d.querySelector('[role="tree"], [role="navigation"]');
      var list = d.querySelector('[role="listbox"], [role="grid"]');
      return !!(main && (nav || list));
    }

    function readCookie(name) {
      var d = env.document;
      if (!d || !d.cookie) return null;
      var parts = d.cookie.split(';');
      for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim();
        var eq = p.indexOf('=');
        if (eq > 0 && p.slice(0, eq).toLowerCase() === name.toLowerCase()) {
          return decodeURIComponent(p.slice(eq + 1));
        }
      }
      return null;
    }

    function origin() {
      return (env.location && env.location.origin) || 'https://outlook.office.com';
    }

    // ---- internalFetchProvider ----

    function owaFetch(path, action, body, trace) {
      if (!env.fetch) return Promise.reject(BridgeError('extract_failed', 'fetch unavailable'));
      var headers = {
        'Content-Type': 'application/json; charset=utf-8',
        'X-Req-Source': 'Mail'
      };
      if (action) headers.Action = action;
      var canary = readCookie('X-OWA-CANARY');
      if (canary) {
        headers['X-OWA-CANARY'] = canary;
      } else {
        trace.warn('X-OWA-CANARY cookie not found; internal API may reject the request');
      }
      var url = origin() + path;
      trace.step('fetch', { url: url, action: action || null, canary: canary ? 'present' : 'missing' });
      return env.fetch(url, {
        method: 'POST',
        credentials: 'include',
        headers: headers,
        body: body ? JSON.stringify(body) : ''
      }).then(function (res) {
        trace.step('response', { status: res.status, redirected: !!res.redirected });
        if (res.redirected && res.url && !/^https:\/\/outlook\./i.test(res.url)) {
          throw BridgeError('session_expired', 'internal API redirected to sign-in');
        }
        if (res.status === 401 || res.status === 403 || res.status === 440) {
          throw BridgeError('auth_failed', (action || path) + ' returned ' + res.status, { httpStatus: res.status });
        }
        if (!res.ok) {
          throw BridgeError('extract_failed', (action || path) + ' returned ' + res.status, { httpStatus: res.status });
        }
        return res.text().then(function (text) {
          try {
            return JSON.parse(text);
          } catch (e) {
            throw BridgeError('extract_failed', (action || path) + ' returned non-JSON', { httpStatus: 'non-json' });
          }
        });
      }, function (e) {
        throw BridgeError('extract_failed', 'network error: ' + (e && e.message), { httpStatus: 'network' });
      });
    }

    function service(action, body, trace) {
      return owaFetch('/owa/service.svc?action=' + action + '&app=Mail', action, body, trace);
    }

    function resolveFolderId(folder, trace) {
      var distinguished = adapter.folderIdFor(folder);
      if (distinguished) {
        trace.step('folder', { requested: folder, distinguished: distinguished.Id });
        return Promise.resolve(distinguished);
      }
      return service('FindFolder', adapter.findFolderRequest(), trace).then(function (json) {
        var m = adapter.responseMessage(json, 'FindFolder');
        var folders = (m.RootFolder && m.RootFolder.Folders) || [];
        var wanted = String(folder).toLowerCase();
        for (var i = 0; i < folders.length; i++) {
          if (String(folders[i].DisplayName || '').toLowerCase() === wanted && folders[i].FolderId) {
            trace.step('folder', { requested: folder, resolved: folders[i].DisplayName });
            return { __type: 'FolderId:#Exchange', Id: folders[i].FolderId.Id };
          }
        }
        throw BridgeError('not_found', 'folder not found: ' + folder, { authoritative: true });
      });
    }

    var internalFetchProvider = {
      name: 'internalFetchProvider',
      available: function () {
        if (Date.now() < state.internalDisabledUntil) return 'disabled: ' + state.internalDisabledReason;
        if (!env.fetch) return 'no fetch';
        return true;
      },
      me: function (args, trace) {
        var paths = ['/owa/sessiondata.ashx?app=Mail', '/owa/0/sessiondata.ashx?app=Mail'];
        function attempt(i) {
          return owaFetch(paths[i], null, null, trace).then(function (json) {
            var me = adapter.fromSessionData(json);
            if (!me) throw BridgeError('extract_failed', 'sessiondata has no user address');
            trace.map({ source: 'sessiondata.SessionSettings' }, me);
            return me;
          }).catch(function (e) {
            if (i + 1 < paths.length && e.code === 'extract_failed') return attempt(i + 1);
            throw e;
          });
        }
        return attempt(0);
      },
      messages: function (args, trace) {
        return resolveFolderId(args.folder, trace).then(function (folderId) {
          return service('FindItem', adapter.findItemRequest(folderId, args.top, args.unread), trace);
        }).then(function (json) {
          var m = adapter.responseMessage(json, 'FindItem');
          var items = (m.RootFolder && m.RootFolder.Items) || [];
          trace.idSource = 'owa-item-id';
          var messages = items.map(function (it) {
            var mapped = adapter.fromOwaListItem(it);
            trace.map(it, mapped);
            return mapped;
          });
          if (args.unread) messages = messages.filter(function (x) { return !x.isRead; });
          return messages.slice(0, args.top);
        });
      },
      message: function (args, trace) {
        return service('GetItem', adapter.getItemRequest(args.id, args.bodyType), trace).then(function (json) {
          var m = adapter.responseMessage(json, 'GetItem');
          var it = m.Items && m.Items[0];
          if (!it) throw BridgeError('not_found', 'GetItem returned no item', { authoritative: true });
          trace.idSource = 'owa-item-id';
          var mapped = adapter.fromOwaItem(it);
          trace.map(it, mapped);
          return mapped;
        });
      }
    };

    // ---- domProvider ----

    function textOf(el) {
      return el ? trimText(el.innerText != null ? el.innerText : el.textContent) : '';
    }

    function labelOf(el) {
      if (!el) return '';
      var label = el.getAttribute('aria-label');
      if (label) return trimText(label);
      var by = el.getAttribute('aria-labelledby');
      if (by && env.document) {
        return trimText(by.split(/\s+/).map(function (id) {
          var n = env.document.getElementById(id);
          return n ? textOf(n) : '';
        }).join(' '));
      }
      return '';
    }

    function findMessageList(trace) {
      var d = env.document;
      var candidates = Array.prototype.slice.call(d.querySelectorAll('[role="listbox"], [role="grid"], [role="list"]'));
      var best = null;
      var bestScore = -1;
      candidates.forEach(function (el) {
        var items = listItems(el);
        if (!items.length) return;
        var score = 0;
        if (adapter.dom.listLabel.test(labelOf(el))) score += 3;
        if (el.closest('[role="main"]')) score += 1;
        if (el.querySelector('[data-convid]')) score += 2;
        if (items.length > 2) score += 1;
        if (score > bestScore) {
          best = el;
          bestScore = score;
        }
      });
      if (best) {
        trace.anchor('messageList', 'role+aria-label', '[role=' + best.getAttribute('role') + '][aria-label="' + labelOf(best) + '"]', 1);
      }
      return best;
    }

    function listItems(list) {
      var role = list.getAttribute('role');
      var itemRole = role === 'grid' ? 'row' : role === 'list' ? 'listitem' : 'option';
      return Array.prototype.slice.call(list.querySelectorAll('[role="' + itemRole + '"]')).filter(function (el) {
        return el.closest('[role="listbox"], [role="grid"], [role="list"]') === list;
      });
    }

    function leafTexts(el) {
      var out = [];
      var walker = env.document.createTreeWalker(el, 4 /* NodeFilter.SHOW_TEXT */);
      var node;
      while ((node = walker.nextNode())) {
        var parent = node.parentElement;
        if (parent && (parent.closest('[aria-hidden="true"]') || /^(SCRIPT|STYLE)$/.test(parent.tagName))) continue;
        var t = trimText(node.nodeValue);
        if (t && out.indexOf(t) < 0) out.push(t);
      }
      return out;
    }

    function parseDomItem(el, index, trace, counters) {
      var label = labelOf(el);
      var texts = leafTexts(el);
      var convid = el.getAttribute('data-convid') || (el.querySelector('[data-convid]') && el.querySelector('[data-convid]').getAttribute('data-convid')) || null;

      // from:优先 title 中带邮箱地址的元素
      var from = null;
      var emailEl = el.querySelector('[title*="@"]');
      if (emailEl && EMAIL_RE.test(emailEl.getAttribute('title'))) {
        from = { name: textOf(emailEl) || emailEl.getAttribute('title'), address: emailEl.getAttribute('title').match(EMAIL_RE)[0] };
        counters.fromViaTitle++;
      } else if (texts.length) {
        from = { name: texts[0], address: '' };
        counters.fromViaText++;
      }

      // receivedDateTime:带可解析 title 的元素(OWA 在时间元素 title 中放完整时间)
      var received = null;
      var timeText = null;
      var titled = el.querySelectorAll('[title]');
      for (var i = 0; i < titled.length; i++) {
        var title = titled[i].getAttribute('title');
        if (title && !EMAIL_RE.test(title) && /\d/.test(title)) {
          var iso = isoDate(title);
          if (iso) {
            received = iso;
            timeText = textOf(titled[i]);
            counters.timeViaTitle++;
            break;
          }
        }
      }

      var rest = texts.filter(function (t) {
        if (from && (t === from.name || t === from.address)) return false;
        if (timeText && t === timeText) return false;
        if (adapter.dom.timeText.test(t)) {
          if (!timeText) timeText = t;
          return false;
        }
        return true;
      });
      var subject = rest[0] || '';
      var preview = rest.slice(1).sort(function (a, b) { return b.length - a.length; })[0] || '';
      if (!received && timeText) counters.timeTextOnly++;

      var hasAttachments = adapter.dom.attachmentLabel.test(label) ||
        !!el.querySelector('[data-icon-name*="Attach" i], [aria-label*="ttachment"], [aria-label*="附件"]');
      var isRead = !adapter.dom.unreadLabel.test(label);
      var importance = adapter.dom.highImportanceLabel.test(label) ? 'high' : 'normal';

      var idSeed = convid || (label + '|' + (from && from.name) + '|' + subject + '|' + (timeText || ''));
      var id = 'dom:' + hashString(idSeed) + (convid ? '' : '-' + index);
      var msg = {
        id: id,
        conversationId: convid,
        subject: subject,
        from: from,
        to: [],
        receivedDateTime: received,
        bodyPreview: preview,
        isRead: isRead,
        hasAttachments: hasAttachments,
        importance: importance
      };
      state.idCache[id] = { message: msg, receivedText: timeText };
      trace.map({ ariaLabel: label, texts: texts.slice(0, 8), convid: convid }, msg);
      return msg;
    }

    function selectedFolderName() {
      var sel = env.document.querySelector('[role="tree"] [role="treeitem"][aria-selected="true"]');
      if (!sel) return null;
      var name = sel.getAttribute('title') || labelOf(sel) || textOf(sel);
      return trimText(name);
    }

    function folderMatches(requested, current) {
      var r = String(requested).toLowerCase();
      var c = String(current).toLowerCase();
      if (r === 'inbox') return adapter.dom.inboxFolder.test(current);
      if (r === 'sent' || r === 'sentitems') return /^(sent|已发送|寄件備份|已傳送)/i.test(current);
      return c === r || c.indexOf(r) === 0;
    }

    var domProvider = {
      name: 'domProvider',
      available: function () {
        if (!env.document) return 'no document';
        return true;
      },
      me: function (args, trace) {
        var d = env.document;
        var displayName = '';
        var address = '';
        var primary = d.getElementById('mectrl_currentAccount_primary');
        var secondary = d.getElementById('mectrl_currentAccount_secondary');
        if (primary) {
          displayName = textOf(primary);
          trace.anchor('displayName', 'id', '#mectrl_currentAccount_primary', 1);
        }
        if (secondary && EMAIL_RE.test(textOf(secondary))) {
          address = textOf(secondary).match(EMAIL_RE)[0];
          trace.anchor('address', 'id', '#mectrl_currentAccount_secondary', 1);
        }
        if (!displayName || !address) {
          var buttons = d.querySelectorAll('#O365_MainLink_Me, button[aria-label], [role="button"][aria-label]');
          for (var i = 0; i < buttons.length && (!displayName || !address); i++) {
            var lbl = labelOf(buttons[i]);
            for (var j = 0; j < adapter.dom.accountLabel.length; j++) {
              var m = lbl.match(adapter.dom.accountLabel[j]);
              if (m) {
                var who = trimText(m[1]);
                if (!address && EMAIL_RE.test(who)) address = who.match(EMAIL_RE)[0];
                if (!displayName) displayName = trimText(who.replace(EMAIL_RE, '').replace(/[()（）<>]/g, ''));
                trace.anchor('displayName', 'aria-label', 'button[aria-label~="account manager"]', 1);
              }
            }
            var title = buttons[i].getAttribute('title');
            if (!address && title && EMAIL_RE.test(title)) address = title.match(EMAIL_RE)[0];
          }
        }
        if (!address) {
          var me = d.querySelector('#O365_MainLink_Me [title*="@"], [data-testid*="account" i] [title*="@"]');
          if (me) {
            address = me.getAttribute('title').match(EMAIL_RE)[0];
            trace.anchor('address', 'title', '#O365_MainLink_Me [title*="@"]', 1);
          }
        }
        if (!displayName && d.title) {
          // "Mail - Wenjin Zhang - Outlook"
          var parts = d.title.split(/\s[-–]\s/);
          if (parts.length >= 3) {
            displayName = trimText(parts[1]);
            trace.warn('displayName from document.title heuristic');
          }
        }
        if (!displayName && !address) {
          throw BridgeError('extract_failed', 'could not locate the account control in the DOM');
        }
        if (!address) trace.warn('address not found in DOM; open the account menu once or rely on internalFetchProvider');
        return Promise.resolve({
          displayName: displayName,
          address: address,
          tenant: domainOf(address),
          loggedIn: true
        });
      },
      messages: function (args, trace) {
        var current = selectedFolderName();
        if (current) {
          trace.anchor('folder', 'role=treeitem[aria-selected]', '[role=tree] [role=treeitem][aria-selected=true]', 1);
          if (!folderMatches(args.folder, current)) {
            throw BridgeError('extract_failed', 'domProvider can only read the folder currently open in OWA ("' + current + '"), requested "' + args.folder + '"');
          }
        } else {
          trace.warn('could not determine the selected folder; assuming it is "' + args.folder + '"');
        }
        var list = findMessageList(trace);
        if (!list) throw BridgeError('extract_failed', 'message list not found (no [role=listbox|grid|list] with items)');
        var items = listItems(list);
        var counters = { fromViaTitle: 0, fromViaText: 0, timeViaTitle: 0, timeTextOnly: 0 };
        var messages = items.map(function (el, i) { return parseDomItem(el, i, trace, counters); });
        var itemRole = list.getAttribute('role') === 'grid' ? 'row' : list.getAttribute('role') === 'list' ? 'listitem' : 'option';
        trace.anchor('item', 'role', '[role=' + list.getAttribute('role') + '] [role=' + itemRole + ']', items.length);
        trace.anchor('from', 'title@', '[role=' + itemRole + '] [title*="@"]', counters.fromViaTitle);
        trace.anchor('receivedDateTime', 'title', '[role=' + itemRole + '] [title]', counters.timeViaTitle);
        if (counters.fromViaText) trace.warn('from 字段回退到文本启发式 (' + counters.fromViaText + ' items)');
        if (counters.timeTextOnly) trace.warn('receivedDateTime unavailable for ' + counters.timeTextOnly + ' items (only relative time text in DOM)');
        trace.warn('subject/bodyPreview 使用文本启发式;to 字段在列表 DOM 中不可用');
        trace.idSource = 'synthetic (dom hash' + (list.querySelector('[data-convid]') ? ' of data-convid' : '') + ')';
        if (args.unread) messages = messages.filter(function (m) { return !m.isRead; });
        if (messages.length < args.top && items.length < args.top) {
          trace.warn('only ' + items.length + ' items are rendered in the virtualized list');
        }
        return Promise.resolve(messages.slice(0, args.top));
      },
      message: function (args, trace) {
        var cached = state.idCache[args.id];
        if (!cached) {
          throw BridgeError('not_found', 'unknown DOM message id (call GET /messages first; synthetic ids live in the list cache)');
        }
        var d = env.document;
        var bodyEl = null;
        for (var i = 0; i < adapter.dom.readingPaneBody.length && !bodyEl; i++) {
          bodyEl = d.querySelector(adapter.dom.readingPaneBody[i]);
          if (bodyEl) trace.anchor('body', 'aria-label', adapter.dom.readingPaneBody[i], 1);
        }
        var msg = JSON.parse(JSON.stringify(cached.message));
        var paneText = bodyEl ? textOf(bodyEl) : '';
        var main = d.querySelector('[role="main"]');
        var paneHeading = main ? textOf(main.querySelector('[role="heading"]')) : '';
        if (!bodyEl || (msg.subject && paneHeading && paneHeading.indexOf(msg.subject) < 0 && msg.subject.indexOf(paneHeading) < 0)) {
          throw BridgeError('extract_failed', 'message is not open in the reading pane; the DOM fallback does not open messages because that would mark them as read');
        }
        msg.cc = [];
        msg.bcc = [];
        msg.body = args.bodyType === 'html'
          ? { contentType: 'html', content: bodyEl.innerHTML }
          : { contentType: 'text', content: paneText };
        msg.attachments = [];
        trace.warn('cc/attachments are not extracted by domProvider');
        trace.idSource = 'synthetic (dom list cache)';
        return Promise.resolve(msg);
      }
    };

    var providers = [internalFetchProvider, domProvider];

    // ---- provider 调度 ----

    function runProviders(op, args, trace, list) {
      list = list || providers;
      var lastErr = null;
      var i = 0;

      function next() {
        if (i >= list.length) {
          if (lastErr && lastErr.code !== 'auth_failed') throw lastErr;
          throw BridgeError('extract_failed', 'all providers failed' + (lastErr ? ': ' + lastErr.message : ''));
        }
        var p = list[i++];
        var avail = p.available(op, args);
        if (avail !== true) {
          trace.attempt(p.name, 'skipped: ' + avail);
          return next();
        }
        var started = now();
        trace.step('provider.start', { provider: p.name, op: op });
        return Promise.resolve().then(function () {
          return p[op](args, trace);
        }).then(function (data) {
          trace.attempt(p.name, 'ok');
          trace.step('provider.ok', { provider: p.name, ms: Math.round(now() - started) });
          state.lastProvider = p.name;
          return { provider: p.name, data: data };
        }, function (e) {
          var err = normalizeError(e);
          trace.attempt(p.name, 'failed: ' + (err.httpStatus || err.code));
          trace.step('provider.failed', { provider: p.name, code: err.code, message: err.message });
          if (err.code === 'session_expired') throw err;
          if (err.code === 'not_found' && err.authoritative) throw err;
          if (err.code === 'auth_failed') {
            if (onLoginPage() || !mailUIPresent()) {
              throw BridgeError('session_expired', 'OWA rejected the session (' + err.message + ')');
            }
            if (p === internalFetchProvider) {
              // 页面登录正常但内部接口不接受 cookie 鉴权:暂停 5 分钟,直接走 DOM。
              state.internalDisabledUntil = Date.now() + 5 * 60 * 1000;
              state.internalDisabledReason = err.message;
              trace.warn('internal API rejected cookie auth (' + err.httpStatus + '); falling back to DOM for 5 minutes');
            }
          }
          if (p === internalFetchProvider && err.httpStatus === 404) {
            state.internalDisabledUntil = Date.now() + 5 * 60 * 1000;
            state.internalDisabledReason = err.message;
          }
          lastErr = err;
          return next();
        });
      }

      return Promise.resolve().then(next);
    }

    // ---- 无障碍树 ----

    var IMPLICIT_ROLES = {
      A: function (el) { return el.hasAttribute('href') ? 'link' : null; },
      ARTICLE: 'article',
      ASIDE: 'complementary',
      BUTTON: 'button',
      DIALOG: 'dialog',
      FOOTER: 'contentinfo',
      FORM: 'form',
      H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
      HEADER: 'banner',
      HR: 'separator',
      IMG: 'img',
      INPUT: function (el) {
        var t = (el.getAttribute('type') || 'text').toLowerCase();
        return { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button', search: 'searchbox', range: 'slider', hidden: null }[t] || (t === 'hidden' ? null : 'textbox');
      },
      LI: 'listitem',
      MAIN: 'main',
      NAV: 'navigation',
      OL: 'list',
      OPTION: 'option',
      SECTION: function (el) { return (el.getAttribute('aria-label') || el.getAttribute('aria-labelledby')) ? 'region' : null; },
      SELECT: 'combobox',
      TABLE: 'table',
      TD: 'cell',
      TEXTAREA: 'textbox',
      TH: 'columnheader',
      TR: 'row',
      UL: 'list',
      IFRAME: 'document'
    };

    var NAME_FROM_CONTENT = /^(button|link|heading|option|treeitem|tab|menuitem|menuitemcheckbox|menuitemradio|cell|columnheader|rowheader|row|listitem|checkbox|radio|switch|tooltip)$/;

    function roleOf(el) {
      var explicit = el.getAttribute('role');
      if (explicit) return explicit.split(/\s+/)[0];
      var r = IMPLICIT_ROLES[el.tagName];
      return typeof r === 'function' ? r(el) : (r || null);
    }

    function isHidden(el) {
      if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
      if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|PATH)$/i.test(el.tagName)) return true;
      if (typeof el.checkVisibility === 'function') return !el.checkVisibility();
      var win = env.window;
      if (win && win.getComputedStyle) {
        var cs = win.getComputedStyle(el);
        return cs.display === 'none' || cs.visibility === 'hidden';
      }
      return false;
    }

    function accessibleName(el, role) {
      var n = labelOf(el);
      if (n) return trimText(n, 200);
      if (el.tagName === 'IMG' || (el.tagName === 'INPUT' && el.getAttribute('type') === 'image')) {
        if (el.getAttribute('alt')) return trimText(el.getAttribute('alt'), 200);
      }
      if (role && NAME_FROM_CONTENT.test(role)) {
        var t = textOf(el);
        if (t) return trimText(t, 200);
      }
      if (el.getAttribute('title')) return trimText(el.getAttribute('title'), 200);
      if (el.getAttribute('placeholder')) return trimText(el.getAttribute('placeholder'), 200);
      return '';
    }

    function buildAriaTree(rootEl, opts) {
      var maxDepth = opts.maxDepth;
      var maxNodes = opts.maxNodes;
      var includeText = opts.includeText;
      var count = 0;
      var truncated = false;

      function visit(el, depth) {
        if (count >= maxNodes) {
          truncated = true;
          return [];
        }
        if (el.nodeType === 3) {
          if (!includeText) return [];
          var t = trimText(el.nodeValue, 200);
          if (!t) return [];
          count++;
          return [{ role: 'text', name: t }];
        }
        if (el.nodeType !== 1 || isHidden(el)) return [];

        var role = roleOf(el);
        if (role === 'presentation' || role === 'none' || role === 'generic') role = null;
        var children = [];
        var kids = el.childNodes;
        var nextDepth = role ? depth + 1 : depth;
        if (nextDepth <= maxDepth) {
          for (var i = 0; i < kids.length; i++) {
            children = children.concat(visit(kids[i], nextDepth));
          }
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument && el.contentDocument.body) children = children.concat(visit(el.contentDocument.body, nextDepth));
            } catch (e) { /* cross-origin */ }
          }
        } else if (kids.length) {
          truncated = true;
        }
        if (!role) return children;

        count++;
        var node = { role: role };
        var name = accessibleName(el, role);
        // 名字由内容计算出来时,子节点的纯文本是冗余的
        if (name) {
          node.name = name;
          if (NAME_FROM_CONTENT.test(role) && !labelOf(el)) {
            children = children.filter(function (c) { return c.role !== 'text'; });
          }
        }
        if (role === 'heading') {
          var lvl = el.getAttribute('aria-level') || (/^H(\d)$/.exec(el.tagName) || [])[1];
          if (lvl) node.level = parseInt(lvl, 10);
        }
        ['aria-selected', 'aria-expanded', 'aria-checked', 'aria-disabled', 'aria-current', 'aria-pressed'].forEach(function (a) {
          var v = el.getAttribute(a);
          if (v != null && v !== 'false') {
            node.states = node.states || {};
            node.states[a.slice(5)] = v === 'true' ? true : v;
          }
        });
        if (el.id) node.id = el.id;
        var convid = el.getAttribute('data-convid');
        if (convid) node.convid = convid;
        if ((role === 'textbox' || role === 'searchbox' || role === 'combobox') && el.value != null) {
          node.value = el.type === 'password' ? '••••' : trimText(el.value, 200);
        }
        if (children.length) node.children = children;
        return [node];
      }

      var tree = visit(rootEl, 0);
      return { nodeCount: count, truncated: truncated, tree: tree };
    }

    // ---- 序列化(/debug/eval)----

    function serialize(value, depth, seen) {
      depth = depth || 0;
      seen = seen || [];
      if (value === undefined) return null;
      if (value === null || typeof value === 'number' || typeof value === 'boolean' || typeof value === 'string') {
        return (typeof value === 'number' && !isFinite(value)) ? String(value) : value;
      }
      if (typeof value === 'bigint') return value.toString();
      if (typeof value === 'function') return '[Function ' + (value.name || 'anonymous') + ']';
      if (typeof value === 'symbol') return value.toString();
      if (depth > 6) return '[MaxDepth]';
      if (seen.indexOf(value) >= 0) return '[Circular]';
      if (value instanceof Error) return { error: value.name, message: value.message };
      if (value && typeof value.nodeType === 'number') {
        if (value.nodeType === 1) return { node: value.tagName.toLowerCase(), outerHTML: trimText(value.outerHTML, 4000) };
        if (value.nodeType === 3) return { node: '#text', text: trimText(value.nodeValue, 4000) };
        return { node: value.nodeName };
      }
      seen = seen.concat([value]);
      if (Array.isArray(value) || (typeof value.length === 'number' && typeof value.item === 'function')) {
        var arr = [];
        for (var i = 0; i < value.length && i < 500; i++) arr.push(serialize(value[i], depth + 1, seen));
        return arr;
      }
      if (value instanceof Date) return isNaN(value.getTime()) ? null : value.toISOString();
      if (typeof Map !== 'undefined' && value instanceof Map) {
        var mo = {};
        value.forEach(function (v, k) { mo[String(k)] = serialize(v, depth + 1, seen); });
        return mo;
      }
      if (typeof Set !== 'undefined' && value instanceof Set) {
        return serialize(Array.from(value), depth, seen);
      }
      var out = {};
      var keys = Object.keys(value).slice(0, 500);
      for (var j = 0; j < keys.length; j++) {
        try {
          out[keys[j]] = serialize(value[keys[j]], depth + 1, seen);
        } catch (e) {
          out[keys[j]] = '[Unreadable]';
        }
      }
      return out;
    }

    // ---- 命令 ----

    function parseMessagesArgs(args) {
      return {
        folder: args.folder ? String(args.folder) : 'inbox',
        top: clampInt(args.top, 10, 1, 50),
        unread: !!args.unread
      };
    }

    var commands = {
      probe: function () {
        var login = onLoginPage();
        var ready = !login && mailUIPresent();
        return Promise.resolve({
          data: {
            onLoginPage: login,
            mailReady: ready,
            host: env.location ? env.location.hostname : null,
            url: env.location ? env.location.href : null,
            title: env.document ? env.document.title : null
          }
        });
      },

      status: function () {
        return Promise.resolve({
          data: {
            extractorVersion: VERSION,
            adapterVersion: ADAPTER_VERSION,
            lastProvider: state.lastProvider,
            internalProvider: Date.now() < state.internalDisabledUntil
              ? { enabled: false, reason: state.internalDisabledReason, retryInMs: state.internalDisabledUntil - Date.now() }
              : { enabled: true },
            cachedDomIds: Object.keys(state.idCache).length
          }
        });
      },

      me: function (args, trace) {
        return runProviders('me', args, trace);
      },

      messages: function (args, trace) {
        var a = parseMessagesArgs(args);
        return runProviders('messages', a, trace).then(function (r) {
          return { provider: r.provider, data: { folder: a.folder, count: r.data.length, messages: r.data } };
        });
      },

      message: function (args, trace) {
        if (!args.id) return Promise.reject(BridgeError('bad_request', 'id is required'));
        var a = { id: String(args.id), bodyType: args.bodyType === 'html' ? 'html' : 'text' };
        var list = a.id.indexOf('dom:') === 0 ? [domProvider] : providers;
        if (list.length === 1) trace.attempt(internalFetchProvider.name, 'skipped: synthetic dom id');
        return runProviders('message', a, trace, list);
      },

      dom: function (args) {
        var d = env.document;
        var selector = args.selector || 'body';
        var el;
        var matched;
        try {
          matched = d.querySelectorAll(selector).length;
          el = d.querySelector(selector);
        } catch (e) {
          return Promise.reject(BridgeError('bad_request', 'invalid selector: ' + selector));
        }
        if (!el) return Promise.reject(BridgeError('not_found', 'no element matches ' + selector));
        var maxLength = clampInt(args.maxLength, 200000, 1, 5000000);
        var html = el.outerHTML || '';
        return Promise.resolve({
          data: {
            selector: selector,
            matched: matched,
            url: env.location ? env.location.href : null,
            length: html.length,
            truncated: html.length > maxLength,
            html: html.length > maxLength ? html.slice(0, maxLength) : html
          }
        });
      },

      aria: function (args) {
        var d = env.document;
        var selector = args.selector || 'body';
        var el;
        try {
          el = d.querySelector(selector);
        } catch (e) {
          return Promise.reject(BridgeError('bad_request', 'invalid selector: ' + selector));
        }
        if (!el) return Promise.reject(BridgeError('not_found', 'no element matches ' + selector));
        var result = buildAriaTree(el, {
          maxDepth: clampInt(args.maxDepth, 40, 1, 200),
          maxNodes: clampInt(args.maxNodes, 5000, 1, 50000),
          includeText: args.includeText !== false
        });
        result.selector = selector;
        result.url = env.location ? env.location.href : null;
        result.title = d.title;
        return Promise.resolve({ data: result });
      },

      extract: function (args, trace) {
        var target = args.target || 'messages';
        var cmd = { messages: 'messages', message: 'message', me: 'me' }[target];
        if (!cmd) return Promise.reject(BridgeError('bad_request', 'target must be messages, message or me'));
        trace.level = 'full';
        trace.step('extract.start', { target: target, args: args });
        return commands[cmd](args, trace).then(function (r) {
          return { provider: r.provider, data: { target: target, ok: true, provider: r.provider, trace: trace.toDebug(r.provider), result: r.data } };
        }, function (e) {
          var err = normalizeError(e);
          return { provider: null, data: { target: target, ok: false, error: err.code, message: err.message, trace: trace.toDebug(null) } };
        });
      }
    };

    function run(command, argsJSON, correlationId) {
      var args = {};
      try {
        args = argsJSON ? JSON.parse(argsJSON) : {};
      } catch (e) {
        args = {};
      }
      var trace = new Trace(args.debug ? 'basic' : 'off', correlationId);
      var handler = commands[command];
      var p = handler
        ? Promise.resolve().then(function () { return handler(args, trace); })
        : Promise.reject(BridgeError('bad_request', 'unknown command: ' + command));
      return p.then(function (out) {
        return safeStringify({ ok: true, status: 200, provider: out.provider || null, data: out.data, debug: trace.toDebug(out.provider) });
      }, function (e) {
        var err = normalizeError(e);
        var code = err.code === 'auth_failed' ? 'extract_failed' : err.code;
        return safeStringify({ ok: false, status: STATUS_BY_CODE[code] || err.status, error: code, message: err.message, debug: trace.toDebug(null) });
      });
    }

    function safeStringify(obj) {
      try {
        return JSON.stringify(obj);
      } catch (e) {
        return JSON.stringify({ ok: false, status: 500, error: 'extract_failed', message: 'result not serializable: ' + e.message });
      }
    }

    /** 页面就绪 / 登录页时主动通知 Swift(WKScriptMessageHandler "owaBridge")。 */
    function announce() {
      var win = env.window;
      var handler = win && win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.owaBridge;
      if (!handler) return;
      var post = function (type) {
        try { handler.postMessage({ type: type }); } catch (e) { /* ignore */ }
      };
      if (onLoginPage()) {
        post('loginPage');
        return;
      }
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        if (mailUIPresent()) {
          clearInterval(timer);
          post('mailReady');
        } else if (onLoginPage()) {
          clearInterval(timer);
          post('loginPage');
        } else if (tries > 120) {
          clearInterval(timer);
        }
      }, 1000);
    }

    return {
      version: VERSION,
      adapterVersion: ADAPTER_VERSION,
      run: run,
      serialize: serialize,
      announce: announce,
      _internal: {
        state: state,
        providers: providers,
        runProviders: runProviders,
        buildAriaTree: buildAriaTree,
        commands: commands
      }
    };
  }

  return {
    version: VERSION,
    adapterVersion: ADAPTER_VERSION,
    adapter: adapter,
    Trace: Trace,
    BridgeError: BridgeError,
    createBridge: createBridge
  };
});
