# W3C helper: the Python parsers for w3c-linux.sh.
# Invoked as `python3 -I -B lib/w3c_helper.py SUBCOMMAND ARGS...` by the py_* wrappers. Each subcommand's stdin, argv and
# stdout contract is documented above its py_* wrapper. -I keeps PYTHONPATH, the user site and this directory off sys.path.
import datetime, glob, json, os, re, shlex, shutil, sys, tempfile

def entry():
    def out(*f):
        if any("\0" in x for x in f):
            f = ("unreadable",)
        sys.stdout.buffer.write(b"\0".join(x.encode("utf-8", "surrogateescape") for x in f) + b"\0")
        sys.exit(0)

    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        out("unreadable")
    if not isinstance(d, list):
        out("unreadable")
    bn = [e for e in d if isinstance(e, dict) and e.get("gameid") == "battlenet"]
    if len(bn) != 1:
        out("count", str(len(bn)))
    e = bn[0]
    g = lambda k: e[k] if isinstance(e.get(k), str) else ""
    ex = lambda s: os.path.expandvars(os.path.expanduser(s))
    la = g("launch_arguments")
    env, st = [], "ok"
    try:
        for t in shlex.split(ex(la), posix=True):
            if "=" in t:
                k, v = t.split("=", 1)
                if k.isidentifier():
                    env.append(t)
    except ValueError:
        st = "ok-badargs"
    out(st, g("prefix"), g("runner"), la, g("path"), ex(g("prefix")), *env)


def env():
    def load(p):
        try:
            with open(p, encoding="utf-8") as fh:
                return json.load(fh), True
        except FileNotFoundError:
            return None, True
        except Exception:
            return None, False

    cfg, okc = load(sys.argv[1])
    env, oke = load(sys.argv[2])
    if not isinstance(cfg, dict):
        okc = okc and cfg is None
        cfg = {}
    if not isinstance(env, list):
        oke = oke and env is None
        env = []
    pre = [v for k, v in (("discrete-gpu", "DRI_PRIME=1"), ("wayland-driver", "PROTON_ENABLE_WAYLAND=1"),
                          ("wow64-enabled", "PROTON_USE_WOW64=1")) if cfg.get(k) == "True"]
    post = {}
    for line in env:
        if not isinstance(line, str) or "\0" in line:
            continue
        line = line.strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if not k:
            continue
        post.pop(k, None)
        post[k] = v   # last occurrence wins and takes the last position
    pre = [p for p in pre if p.split("=", 1)[0] not in post]
    f = ["ok" if okc else "bad", "ok" if oke else "bad", str(len(pre))] + pre + [f"{k}={v}" for k, v in post.items()]
    sys.stdout.buffer.write(b"\0".join(x.encode("utf-8", "surrogateescape") for x in f) + b"\0")


def release():
    SAFE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
    BASE = "https://github.com/davex32/proton-ge-w3c/releases/download/"

    def out(*f):
        sys.stdout.buffer.write(b"\0".join(x.encode("utf-8", "surrogateescape") for x in f) + b"\0")
        sys.exit(0)

    try:
        r = json.load(sys.stdin.buffer)
    except Exception:
        out("bad", "response is not JSON")
    if not isinstance(r, dict):
        out("bad", "response is not a JSON object")
    tag = r.get("tag_name")
    if not isinstance(tag, str) or not SAFE.fullmatch(tag):
        out("bad", "unsafe or missing tag_name")
    assets = r.get("assets")
    if not isinstance(assets, list):
        out("bad", "no assets list")
    assets = [a for a in assets if isinstance(a, dict) and isinstance(a.get("name"), str)]
    tg = [a for a in assets if a["name"].endswith(".tar.gz")]
    sm = [a for a in assets if a["name"] == "SHA256SUMS"]
    if len(tg) != 1 or len(sm) != 1:
        out("bad", "expected exactly one .tar.gz and one SHA256SUMS asset")
    for a in (tg[0], sm[0]):
        if not SAFE.fullmatch(a["name"]) or a.get("browser_download_url") != BASE + tag + "/" + a["name"]:
            out("bad", "unexpected asset name or download URL")
    sz = tg[0].get("size")
    size = "%.1f GB" % (sz / 1e9) if isinstance(sz, int) and not isinstance(sz, bool) and sz > 0 else "size unknown"
    out("ok", tag, tg[0]["name"], tg[0]["browser_download_url"], size, sm[0]["browser_download_url"])


def games():
    def out(*f):
        sys.stdout.buffer.write(b"\0".join(x.encode("utf-8", "surrogateescape") for x in f) + b"\0")
        sys.exit(0)

    op = sys.argv[1]
    if op == "running-idle":
        # a missing file is idle; anything but an empty dict, including an unparseable file, is busy
        try:
            with open(sys.argv[2], encoding="utf-8") as fh:
                d = json.load(fh)
        except FileNotFoundError:
            out("idle")
        except Exception:
            out("busy")
        out("idle" if d == {} else "busy")
    if op == "set-runner":
        path, old, new, bdir = sys.argv[2:6]
        tmp = None
        try:
            real = os.path.realpath(path)   # a symlinked games.json stays a symlink
            mode = os.stat(real).st_mode & 0o7777
            with open(real, encoding="utf-8") as fh:
                data = json.load(fh)
            bn = [e for e in data if isinstance(e, dict) and e.get("gameid") == "battlenet"] if isinstance(data, list) else []
            if len(bn) != 1:
                out("cas")   # the file changed under us: compare-and-swap lost
            cur = bn[0].get("runner")
            if (cur if isinstance(cur, str) else "") != old:   # a missing or null runner reads as "" exactly like py_entry
                out("cas")
            os.makedirs(bdir, exist_ok=True)
            # names sort chronologically and cannot collide within a second
            bak = os.path.join(bdir, "games.json." + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".bak")
            shutil.copy2(real, bak)
            bn[0]["runner"] = new   # same key position; an entry that had no runner key necessarily gains this one
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".tmp-")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=4, ensure_ascii=False)   # what Faugus's save_json_file writes
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, mode)
            os.replace(tmp, real)
        except Exception:
            if tmp and os.path.exists(tmp):
                os.remove(tmp)
            out("bad")
        out("ok", bak)
    if op == "pick-backup":
        bdir, tag = sys.argv[2:4]
        try:
            names = sorted((n for n in os.listdir(bdir) if n.startswith("games.json.") and n.endswith(".bak")), reverse=True)
        except OSError:
            out("none")
        for n in names:
            try:
                with open(os.path.join(bdir, n), encoding="utf-8") as fh:
                    d = json.load(fh)
            except Exception:
                continue
            bn = [e for e in d if isinstance(e, dict) and e.get("gameid") == "battlenet"] if isinstance(d, list) else []
            if len(bn) != 1:
                continue
            r = bn[0].get("runner")
            if not isinstance(r, str):
                r = ""   # missing or null: Faugus's UMU-Proton Latest, as py_entry reads it
            if "\0" in r or (tag and r == tag) or r.endswith("-W3C"):
                continue
            out("ok", os.path.join(bdir, n), r)
        out("none")
    if op == "uses-runner":
        try:
            with open(sys.argv[2], encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            out("yes")   # cannot tell: fail closed so nothing offers to delete a runner that may be in use
        out("yes" if isinstance(d, list) and any(isinstance(e, dict) and e.get("runner") == sys.argv[3] for e in d) else "no")
    out("bad")


def launcher():
    VER = re.compile(r"[0-9]+(\.[0-9]+){1,3}")
    BASE = "https://github.com/w3champions/launcher-e-release/releases/download/"

    def out(*f):
        sys.stdout.buffer.write(b"\0".join(x.encode("utf-8", "surrogateescape") for x in f) + b"\0")
        sys.exit(0)

    try:
        r = json.load(sys.stdin.buffer)
    except Exception:
        out("bad", "response is not JSON")
    v = r.get("version") if isinstance(r, dict) else None
    if not isinstance(v, str) or not VER.fullmatch(v):
        out("bad", "unsafe or missing version")
    p = r.get("platforms")
    m = p.get("windows-x86_64-msi") if isinstance(p, dict) else None
    u = m.get("url") if isinstance(m, dict) else None
    if not isinstance(u, str) or u != BASE + v + "/W3Champions_" + v + "_x64_en-US.msi":
        out("bad", "unexpected MSI url")
    out("ok", v, u)


def json_str():
    try:
        v = json.load(sys.stdin.buffer).get(sys.argv[1])
        if isinstance(v, str) and "\0" not in v:
            sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape"))
    except Exception:
        pass


def icd():
    root = sys.argv[1]

    def show(p):
        return p[len(root):] if root and p.startswith(root) else p

    def arch(p):
        try:
            with open(p, "rb") as f:
                h = f.read(20)
        except OSError:
            return None
        if len(h) == 20 and h[:4] == b"\x7fELF":
            return {62: "x86_64", 3: "i686"}.get(h[18] | h[19] << 8)
        return None

    def resolve(lp, base):
        # a path with a slash is relative to the manifest's directory when not absolute, as the Vulkan loader treats it
        if "/" in lp:
            cands = [root + lp if lp.startswith("/") else os.path.join(base, lp)]
        else:
            # ponytail: default lib dirs only, not ld.so.conf or LD_LIBRARY_PATH; walk ld.so.cache if a report shows a false missing
            cands = [root + "/" + d + "/" + lp for d in ("usr/lib", "usr/lib64", "usr/lib32", "usr/lib/x86_64-linux-gnu", "usr/lib/i386-linux-gnu")]
        r = {}
        for c in cands:
            a = arch(c)
            if a and a not in r:
                r[a] = show(c)
        return "x86_64 %s  i686 %s" % (r.get("x86_64", "missing"), r.get("i686", "missing"))

    def jsons(d):
        return sorted(glob.glob(os.path.join(glob.escape(d), "*.json")))

    ms = jsons(root + "/etc/vulkan/icd.d") + jsons(root + "/usr/share/vulkan/icd.d")
    for var in ("VK_DRIVER_FILES", "VK_ICD_FILENAMES"):
        v = os.environ.get(var)
        if v:
            print("%s=%s (replaces the default ICD search)" % (var, v))
            for e in v.split(":"):
                if e:
                    ms += jsons(e) if os.path.isdir(e) else [e]
    for m in ms:
        try:
            with open(m, encoding="utf-8") as f:
                lp = json.load(f)["ICD"]["library_path"]
            if not isinstance(lp, str):
                raise ValueError
        except Exception:
            print("%s  unreadable" % show(m))
            continue
        print("%s  %s  %s" % (show(m), lp, resolve(lp, os.path.dirname(m))))
    if not ms:
        print("no ICD manifests in /etc/vulkan/icd.d or /usr/share/vulkan/icd.d")
    print("loader libvulkan.so.1  " + resolve("libvulkan.so.1", ""))


def faugus_version():
    # Reads faugus/launcher.py as text and never imports faugus or any of its modules: importing pulls in GTK and runs its code.
    try:
        if sys.argv[1]:
            dirs = [os.path.join(sys.argv[1], "faugus")]
        else:
            import importlib.util
            spec = importlib.util.find_spec("faugus")   # a namespace package: the directories are in submodule_search_locations, origin is None
            dirs = list(spec.submodule_search_locations) if spec else []
        for d in dirs:
            with open(os.path.join(d, "launcher.py"), encoding="utf-8", errors="replace") as fh:
                m = re.search(r"""^VERSION\s*=\s*["']([0-9][0-9A-Za-z.+-]*)["']""", fh.read(), re.M)
            if m:
                sys.stdout.write(m.group(1))
                return
    except Exception:
        pass


COMMANDS = {"entry": entry, "env": env, "release": release, "games": games, "launcher": launcher,
            "json-str": json_str, "icd": icd, "faugus-version": faugus_version}

if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
    sys.exit(2)
sub = sys.argv.pop(1)
COMMANDS[sub]()
