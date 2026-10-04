#!/usr/bin/env python3
"""Bridge between Manga to Kindle and HaruNeko (the new HakuNeko), over Chrome DevTools Protocol.

  haru.py ensure [--restart] [--hide]   start HaruNeko with the debug port (or report that it runs without it)
  haru.py call <fn> [json-args]         run window.__mk.<fn>(...args) inside HaruNeko, print JSON result
  haru.py index [lang] [adult]          load every usable source's title list; '@@{json}' progress lines
  haru.py window show|hide              show / hide HaruNeko's window
"""
import json
import warnings
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from websockets.sync.client import connect

warnings.filterwarnings("ignore", category=DeprecationWarning)

PORT = int(os.environ.get("MK_HARU_PORT", "9333"))
MAIN_PORT = PORT + 1  # Node inspector of HaruNeko's main process (used only to hide/show it)
APP = os.environ.get("MK_HARU_APP", "/Applications/HakuNeko.app")
EXE = APP + "/Contents/MacOS/hakuneko-electron"
PAGE_JS = (Path(__file__).resolve().parent / "haru_page.js").read_text()


def emit(kind, **d):
    print("@@" + json.dumps({"type": kind, **d}, ensure_ascii=False), flush=True)


STATE_DIR = Path.home() / "Library/Application Support/MangaToKindle"
FAILED_FILE = STATE_DIR / "index_failed.json"
SKIP_FAILED_DAYS = 7


def page_ws(timeout=10):
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json", timeout=timeout) as r:
        targets = json.load(r)
    for t in targets:
        if t.get("type") == "page" and "hakuneko" in t.get("url", ""):
            return t["webSocketDebuggerUrl"]
    return None


def running_pids():
    r = subprocess.run(["pgrep", "-f", "HakuNeko.app/Contents/MacOS/hakuneko-electron"], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


class Page:
    def __init__(self):
        ws = page_ws()
        if not ws:
            raise RuntimeError("HaruNeko is not connected")
        self.ws = connect(ws, max_size=None, open_timeout=5)
        self.n = 0

    def eval(self, expr, timeout=600):
        self.n += 1
        self.ws.send(json.dumps({"id": self.n, "method": "Runtime.evaluate", "params": {
            "expression": expr, "awaitPromise": True, "returnByValue": True}}))
        deadline = time.time() + timeout
        while True:
            msg = json.loads(self.ws.recv(timeout=max(1, deadline - time.time())))
            if msg.get("id") != self.n:
                continue
            res = msg.get("result", {})
            if "exceptionDetails" in res:
                ex = res["exceptionDetails"]
                desc = ex.get("exception", {}).get("description") or ex.get("text")
                raise RuntimeError(desc)
            return res.get("result", {}).get("value")

    def ready(self):
        return self.eval("!!(window.HakuNeko && window.HakuNeko.PluginController && "
                         "window.HakuNeko.PluginController.WebsitePlugins.length)", 10)

    def inject(self):
        return self.eval(PAGE_JS, 30)

    def call(self, fn, args, timeout=600):
        self.inject()
        return self.eval(f"window.__mk.{fn}(...{json.dumps(args)})", timeout)

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def port_alive():
    import socket
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=2):
            return True
    except OSError:
        return False


def connected():
    for _ in range(5):
        try:
            if page_ws() is not None:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def wait_ready(seconds=90):
    end = time.time() + seconds
    while time.time() < end:
        try:
            p = Page()
            ok = p.ready()
            p.close()
            if ok:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def ensure(restart=False, hide=False):
    if not os.path.exists(EXE):
        return {"state": "missing", "message": f"HaruNeko not found at {APP}"}
    if port_alive() or connected():
        # our HaruNeko is already up (maybe busy loading sources) — never restart it
        ok = wait_ready(90)
        if hide and ok:
            window("hide")
        return {"state": "connected" if ok else "starting"}
    pids = running_pids()
    if pids and not restart:
        return {"state": "running-unconnected",
                "message": "HaruNeko is open without the connection Manga to Kindle needs. Restart it?"}
    if pids:
        subprocess.run(["osascript", "-e", 'quit app "HakuNeko"'], capture_output=True)
        for _ in range(20):
            if not running_pids():
                break
            time.sleep(0.5)
        for pid in running_pids():
            try:
                os.kill(pid, 15)
            except Exception:
                pass
        time.sleep(1)
    subprocess.Popen([EXE, f"--remote-debugging-port={PORT}", f"--inspect=127.0.0.1:{MAIN_PORT}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    ok = wait_ready(120)
    if ok and hide:
        window("hide")
    return {"state": "connected" if ok else "starting"}


def main_eval(expr):
    """Run JS in HaruNeko's Electron main process (needs --inspect)."""
    with urllib.request.urlopen(f"http://127.0.0.1:{MAIN_PORT}/json", timeout=3) as r:
        ws_url = json.load(r)[0]["webSocketDebuggerUrl"]
    ws = connect(ws_url, open_timeout=5)
    try:
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "returnByValue": True}}))
        while True:
            m = json.loads(ws.recv(timeout=10))
            if m.get("id") == 1:
                return m.get("result", {}).get("result", {}).get("value")
    finally:
        ws.close()


QUIET_JS = r"""(()=>{
  const e = process.mainModule.require('electron');
  if (!global.__mkq) {
    global.__mkq = { quiet: true, pending: {}, allow: new Set() };
    const q = global.__mkq;
    const mainId = () => Math.min(...e.BrowserWindow.getAllWindows().map(w => w.id));
    const guard = w => {
      w.on('show', () => {
        if (!q.quiet || q.allow.has(w.id)) return;
        if (w.id !== mainId()) q.pending[w.id] = { id: w.id, url: w.webContents.getURL(), since: Date.now() };
        setImmediate(() => { try { if (!w.isDestroyed()) w.hide(); } catch (_) {} });
        try { e.app.dock && e.app.dock.hide(); } catch (_) {}
      });
      w.on('closed', () => { delete q.pending[w.id]; q.allow.delete(w.id); });
    };
    e.BrowserWindow.getAllWindows().forEach(guard);
    e.app.on('browser-window-created', (_, w) => guard(w));
  }
  const q = global.__mkq;
  q.quiet = true;
  const all = e.BrowserWindow.getAllWindows();
  const main = Math.min(...all.map(w => w.id));
  for (const w of all) {
    if (w.isVisible() && !q.allow.has(w.id)) {
      if (w.id !== main) q.pending[w.id] = { id: w.id, url: w.webContents.getURL(), since: Date.now() };
      w.hide();
    }
  }
  e.app.dock && e.app.dock.hide();
  return true;
})()"""


def quiet():
    """Keep every HaruNeko window hidden; windows that want to show (captchas) are listed as pending."""
    return main_eval(QUIET_JS)


def pending_checks():
    js = ("(()=>{const e=process.mainModule.require('electron');const q=global.__mkq;if(!q)return [];"
          "return Object.values(q.pending).filter(p=>{const w=e.BrowserWindow.fromId(p.id);return w&&!w.isDestroyed()})"
          ".map(p=>{const w=e.BrowserWindow.fromId(p.id);return {...p,url:w.webContents.getURL()}})})()")
    return main_eval(js) or []


def close_stale(seconds):
    """Close verification windows nobody solved (background loading only) so the waiting source fails fast."""
    js = ("(()=>{const e=process.mainModule.require('electron');const q=global.__mkq;if(!q)return 0;let n=0;"
          "for(const p of Object.values(q.pending)){if(Date.now()-p.since>%d){const w=e.BrowserWindow.fromId(p.id);"
          "if(w&&!w.isDestroyed()){w.close();n++}delete q.pending[p.id]}}return n})()" % int(seconds * 1000))
    try:
        return main_eval(js)
    except Exception:
        return 0


UNBLOCK_OPEN = r"""(()=>{const e=process.mainModule.require('electron');const main=e.webContents.fromId(1);
 if(!global.__mkub||global.__mkub.webContents)global.__mkub={};
 const w=new e.BrowserWindow({show:false,width:1100,height:850,webPreferences:{session:main.session}});
 global.__mkub[w.id]=w; w.loadURL(%s,{userAgent:main.getUserAgent()}).catch(()=>{}); return w.id})()"""
UNBLOCK_TITLE = "(()=>{const w=(global.__mkub||{})[%d];return !w||w.isDestroyed()?null:w.webContents.getTitle()})()"
CHALLENGE = ("just a moment", "attention required", "verify you are human", "checking your browser", "security check")


def unblock(url, seconds=25):
    """Open a page that Cloudflare blocked in a hidden HaruNeko window (same cookies as HaruNeko).
    Returns clear (cookie earned, window closed) or human (window listed as a pending check for "Verify Now")."""
    quiet()
    wid = main_eval(UNBLOCK_OPEN % json.dumps(url))
    end = time.time() + seconds
    title = None
    while time.time() < end:
        time.sleep(2)
        title = main_eval(UNBLOCK_TITLE % wid)
        if title is None:
            return {"state": "gone"}
        if title and not any(c in title.lower() for c in CHALLENGE) and not title.startswith("http"):
            main_eval("(()=>{const w=global.__mkub[%d];if(w&&!w.isDestroyed())w.close();return 1})()" % wid)
            return {"state": "clear", "title": title}
    main_eval("(()=>{const w=global.__mkub[%d];const q=global.__mkq;if(w&&!w.isDestroyed()&&q)"
              "q.pending[w.id]={id:w.id,url:w.webContents.getURL(),since:Date.now()};return 1})()" % wid)
    return {"state": "human", "id": wid, "title": title}


def cfstate(win_id):
    """After "Verify Now": clear once the page is past the challenge (window closed by us), or gone if the user closed it."""
    title = main_eval(UNBLOCK_TITLE % int(win_id))
    if title is None:
        title = main_eval("(()=>{const e=process.mainModule.require('electron');const w=e.BrowserWindow.fromId(%d);"
                          "return !w||w.isDestroyed()?null:w.webContents.getTitle()})()" % int(win_id))
    if title is None:
        return {"state": "gone"}
    if title and not any(c in title.lower() for c in CHALLENGE) and not title.startswith("http"):
        main_eval("(()=>{const e=process.mainModule.require('electron');const w=e.BrowserWindow.fromId(%d);"
                  "if(w&&!w.isDestroyed())w.close();return 1})()" % int(win_id))
        return {"state": "clear", "title": title}
    return {"state": "waiting", "title": title}


def verify(win_id):
    """Show one pending verification window so the user can solve it."""
    js = ("(()=>{const e=process.mainModule.require('electron');const q=global.__mkq;const w=e.BrowserWindow.fromId(%d);"
          "if(!w||w.isDestroyed())return false;q.allow.add(w.id);delete q.pending[w.id];w.center();w.show();w.focus();"
          "e.app.focus({steal:true});return true})()" % int(win_id))
    return main_eval(js)


def window(action):
    """hide: no window, no Dock icon. show: bring HaruNeko back (e.g. to solve a captcha)."""
    if action == "hide":
        try:
            quiet()
            return {"ok": True}
        except Exception:
            pass
        js = ("(()=>{const e=process.mainModule.require('electron');"
              "e.BrowserWindow.getAllWindows().forEach(w=>{if(!w.isDestroyed())w.hide()});e.app.dock&&e.app.dock.hide();return true})()")
    else:
        js = ("(()=>{const e=process.mainModule.require('electron');const q=global.__mkq;"
              "e.BrowserWindow.getAllWindows().forEach(w=>q&&q.allow.add(w.id));e.app.dock&&e.app.dock.show();"
              "const w=e.BrowserWindow.getAllWindows().sort((a,b)=>b.getBounds().width-a.getBounds().width)[0];"
              "if(w){w.show();w.focus()}e.app.focus({steal:true});return true})()")
    try:
        main_eval(js)
        return {"ok": True}
    except Exception:
        # started without --inspect: fall back to HaruNeko's own window IPC (Dock icon stays)
        p = Page()
        ch = "ApplicationWindow::HideWindow" if action == "hide" else "ApplicationWindow::ShowWindow"
        try:
            p.eval(f"window.ipcRenderer.invoke('{ch}').then(()=>true)", 10)
        finally:
            p.close()
        return {"ok": True, "dock": False}


def index(lang="en", adult=False, force=False):
    p = Page()
    try:
        srcs = p.call("sources", [lang, adult])
        try:
            failed_before = json.loads(FAILED_FILE.read_text())
        except Exception:
            failed_before = {}
        now = time.time()
        recent = {k for k, t in failed_before.items() if now - t < SKIP_FAILED_DAYS * 86400}
        ids = [s["id"] for s in srcs if not s.get("regionLock") and (force or s["id"] not in recent)]
        try:
            quiet()
        except Exception:
            pass
        st = p.call("startIndex", [ids, 5, 120000, True])
        emit("index", done=st["done"], total=st["total"], current=st["current"])
        while True:
            time.sleep(1.5)
            st = p.eval("window.__mk.index", 30)
            close_stale(45)
            emit("index", done=st["done"], total=st["total"], current=st["current"], failed=len(st["failed"]))
            if not st["running"]:
                break
        for k in st["failed"]:
            failed_before[k] = now
        for k in st["ok"]:
            failed_before.pop(k, None)
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        FAILED_FILE.write_text(json.dumps(failed_before))
        status = p.call("status", [])
        emit("done", indexed=status["indexed"], titles=status["titles"], failed=len(st["failed"]))
    finally:
        p.close()


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 1
    cmd = a[0]
    try:
        if cmd == "ensure":
            print(json.dumps(ensure("--restart" in a, "--hide" in a)))
        elif cmd == "call":
            args = json.loads(a[2]) if len(a) > 2 else []
            p = Page()
            try:
                print(json.dumps(p.call(a[1], args), ensure_ascii=False))
            finally:
                p.close()
        elif cmd == "index":
            index(a[1] if len(a) > 1 else "en", len(a) > 2 and a[2] == "1", "--force" in a)
        elif cmd == "window":
            print(json.dumps(window(a[1])))
        elif cmd == "checks":
            print(json.dumps(pending_checks()))
        elif cmd == "verify":
            print(json.dumps({"ok": bool(verify(a[1]))}))
        elif cmd == "cfstate":
            print(json.dumps(cfstate(a[1])))
        elif cmd == "unblock":
            print(json.dumps(unblock(a[1])))
        elif cmd == "quiet":
            print(json.dumps({"ok": bool(quiet())}))
        else:
            print(__doc__)
            return 1
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
