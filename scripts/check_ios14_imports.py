#!/usr/bin/env python3
"""Offline check that a built iOS .app / .ipa will not die in dyld on iOS 14.3.

For every Mach-O in the bundle (main executable, Frameworks/*.dylib,
Frameworks/*.framework/*, PlugIns, ...) it verifies:

  (a) minos (LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS) <= 14.3, platform iOS
  (b) every non-weak linked dylib exists: system dylibs must have a .tbd in the
      given iPhoneOS SDK, @rpath/@executable_path/@loader_path dylibs must be in the bundle
      ("Library not loaded" otherwise)
  (c) every non-weak imported symbol is exported by the dylib it is bound to
      ("Symbol not found" otherwise): SDK .tbd exports (following re-exports and
      umbrella frameworks) for system libs, `nm -gUj` for embedded dylibs

Weak imports that are missing are reported as "weak (nil at runtime on 14.3)" and do
not fail the check.

Usage:
    check_ios14_imports.py <App.app | App.ipa> <iPhoneOS14.3.sdk> [--max-minos 14.3]
                           [--arch arm64] [--limit N] [--verbose]

Exit status: 0 clean, 1 findings, 2 usage / tool error.
Requires macOS developer tools (otool, nm; dyld_info optional, preferred). Stdlib only.
Limitations: .tbd files carry no per-symbol availability, so the SDK version bounds what
can be caught (see scripts/fetch_ios14_sdk.sh); `$ld$` linker directive symbols are ignored.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from typing import Callable, Dict, FrozenSet, Iterable, List, Optional, Set, Tuple

DEFAULT_MAX_MINOS = "14.3"
DEFAULT_ARCH = "arm64"

# --------------------------------------------------------------------------- versions


def parse_version(text: str) -> Tuple[int, int, int]:
    parts = [int(p) for p in re.findall(r"\d+", text)[:3]]
    while len(parts) < 3:
        parts.append(0)
    return (parts[0], parts[1], parts[2])


def fmt_version(v: Optional[Tuple[int, ...]]) -> str:
    if v is None:
        return "?"
    v = tuple(v)
    while len(v) > 2 and v[-1] == 0:
        v = v[:-1]
    return ".".join(str(x) for x in v)


# --------------------------------------------------------------------------- .tbd parsing


@dataclass
class TbdDoc:
    install_name: Optional[str] = None
    symbols: Set[str] = field(default_factory=set)
    reexports: List[str] = field(default_factory=list)


# export-entry key -> template turning a listed name into the mangled symbol(s)
_SYMBOL_KEYS = {
    "symbols": ("{}",),
    "weak-symbols": ("{}",),
    "weak-def-symbols": ("{}",),
    "thread-local-symbols": ("{}",),
    "objc-classes": ("_OBJC_CLASS_$_{}", "_OBJC_METACLASS_$_{}"),
    "objc-eh-types": ("_OBJC_EHTYPE_$_{}",),
    "objc-ivars": ("_OBJC_IVAR_$_{}",),
}
_REEXPORT_KEYS = ("re-exports", "libraries")
_EXPORT_SECTIONS = ("exports", "reexports")
_LIST_SECTIONS = _EXPORT_SECTIONS + ("reexported-libraries",)

_KEY_RE = re.compile(r"^(\s*)(-\s+)?([A-Za-z][\w-]*):\s*(.*?)\s*$")


def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    return s


def _split_flow(value: str) -> List[str]:
    """Parse `[ a, 'b', c ]` (already joined onto one string) into items."""
    value = value.strip()
    if value.startswith("["):
        value = value[1:]
    if value.endswith("]"):
        value = value[:-1]
    return [_unquote(p) for p in value.split(",") if p.strip()]


def _entry_applies(entry: Dict[str, List[str]], arch: str) -> bool:
    if "archs" in entry:  # tbd v1-v3
        return arch in entry["archs"]
    if "targets" in entry:  # tbd v4
        return (arch + "-ios") in entry["targets"]
    return True


def _logical_lines(doc_lines: List[str]) -> Iterable[str]:
    """Join multi-line flow sequences (`key: [ a,\\n b ]`) onto a single line."""
    buf: Optional[str] = None
    for raw in doc_lines:
        line = raw.rstrip("\n")
        if buf is not None:
            buf += " " + line.strip()
            if "]" in line:
                yield buf
                buf = None
            continue
        if "[" in line and "]" not in line and not line.lstrip().startswith("#"):
            buf = line
            continue
        yield line
    if buf is not None:
        yield buf


def _parse_one_doc(lines: List[str], arch: str) -> TbdDoc:
    doc = TbdDoc()
    section: Optional[str] = None
    entry: Optional[Dict[str, List[str]]] = None
    entries: List[Dict[str, List[str]]] = []

    def flush():
        nonlocal entry
        if entry is not None and section in _LIST_SECTIONS:
            entries.append(entry)
        entry = None

    for line in _logical_lines(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _KEY_RE.match(line)
        if not m:
            continue
        indent, dash, key, value = len(m.group(1)), m.group(2), m.group(3), m.group(4)
        if indent == 0 and not dash:
            flush()
            section = key
            if key == "install-name" and value:
                doc.install_name = _unquote(value)
            continue
        if section not in _LIST_SECTIONS:
            continue
        if dash:
            flush()
            entry = {}
        if entry is None:
            continue
        entry[key] = _split_flow(value) if value.startswith("[") else ([_unquote(value)] if value else [])
        entry.setdefault("__section__", [section])

    flush()
    for e in entries:
        if not _entry_applies(e, arch):
            continue
        sect = e.get("__section__", [""])[0]
        if sect in _EXPORT_SECTIONS:
            for key, templates in _SYMBOL_KEYS.items():
                for name in e.get(key, []):
                    for t in templates:
                        doc.symbols.add(t.format(name))
        for key in _REEXPORT_KEYS:
            if (sect == "reexported-libraries" and key == "libraries") or (
                sect in _EXPORT_SECTIONS and key == "re-exports"
            ):
                doc.reexports.extend(e.get(key, []))
    return doc


def parse_tbd(text: str, arch: str = DEFAULT_ARCH) -> List[TbdDoc]:
    """Parse a tbd v3/v4 file into one TbdDoc per YAML document (first = the library)."""
    docs: List[List[str]] = []
    cur: Optional[List[str]] = None
    for line in text.splitlines():
        if line.startswith("---"):
            cur = []
            docs.append(cur)
        elif line.startswith("..."):
            cur = None
        elif cur is not None:
            cur.append(line)
    return [_parse_one_doc(d, arch) for d in docs]


# --------------------------------------------------------------------------- SDK index


class SdkIndex:
    """Lookup of dylib exports in an iPhoneOS SDK's .tbd stubs."""

    def __init__(self, root: str, arch: str = DEFAULT_ARCH):
        self.root = root
        self.arch = arch
        self._docs: Dict[str, List[TbdDoc]] = {}
        self._by_install: Optional[Dict[str, str]] = None
        self._exports: Dict[str, Optional[FrozenSet[str]]] = {}

    def _candidates(self, install_name: str) -> List[str]:
        rel = install_name.lstrip("/")
        base = rel[:-6] if rel.endswith(".dylib") else rel
        out = [os.path.join(self.root, base + ".tbd")]
        m = re.match(r"^(.*\.framework)/(?:Versions/[^/]+/)?([^/]+)$", rel)
        if m:
            out.append(os.path.join(self.root, m.group(1), m.group(2) + ".tbd"))
        return out

    def _install_index(self) -> Dict[str, str]:
        if self._by_install is None:
            idx: Dict[str, str] = {}
            pat = re.compile(r"^install-name:\s*['\"]?([^'\"\n]+?)['\"]?\s*$", re.M)
            for dirpath, _dirs, files in os.walk(self.root):
                for f in files:
                    if not f.endswith(".tbd"):
                        continue
                    p = os.path.join(dirpath, f)
                    try:
                        with open(p, "r", errors="replace") as fh:
                            head = fh.read(4096)
                    except OSError:
                        continue
                    m = pat.search(head)
                    if m:
                        idx.setdefault(m.group(1), p)
            self._by_install = idx
        return self._by_install

    def find_tbd(self, install_name: str) -> Optional[str]:
        for p in self._candidates(install_name):
            if os.path.isfile(p):
                return p
        return self._install_index().get(install_name)

    def has_library(self, install_name: str) -> bool:
        return self.find_tbd(install_name) is not None

    def _load(self, path: str) -> List[TbdDoc]:
        if path not in self._docs:
            with open(path, "r", errors="replace") as fh:
                self._docs[path] = parse_tbd(fh.read(), self.arch)
        return self._docs[path]

    def _collect(self, install_name: str, out: Set[str], seen: Set[str], inline: Dict[str, TbdDoc]) -> None:
        if install_name in seen:
            return
        seen.add(install_name)
        doc = inline.get(install_name)
        if doc is None:
            path = self.find_tbd(install_name)
            if path is None:
                return
            docs = self._load(path)
            if not docs:
                return
            inline = {d.install_name: d for d in docs[1:] if d.install_name}
            doc = docs[0]
        out.update(doc.symbols)
        for r in doc.reexports:
            self._collect(r, out, seen, inline)

    def exports(self, install_name: str) -> Optional[FrozenSet[str]]:
        """All symbols dyld can resolve through this dylib (own + re-exported); None if absent."""
        if install_name not in self._exports:
            if not self.has_library(install_name):
                self._exports[install_name] = None
            else:
                out: Set[str] = set()
                self._collect(install_name, out, set(), {})
                self._exports[install_name] = frozenset(out)
        return self._exports[install_name]


# --------------------------------------------------------------------------- tool output parsers


@dataclass(frozen=True)
class Import:
    symbol: str
    lib: Optional[str]  # leaf name as printed by the tool; None = flat / dynamic lookup
    weak: bool


# Lines look like "0x0023  _sym  [weak-import] (from Lib)"; the offset column is absent for
# binaries without chained fixups ("      _sym  (from Lib)").
_DYLD_INFO_RE = re.compile(r"^\s+(?:0x[0-9A-Fa-f]+\s+)?(\S+)(.*)$")
_FROM_RE = re.compile(r"\(from ([^)]+)\)")
_NM_RE = re.compile(r"^\s*\(undefined\)\s+(weak\s+)?(?:private\s+)?external\s+(\S+)(.*)$")


def parse_dyld_info_imports(text: str) -> List[Import]:
    out = []
    for line in text.splitlines():
        m = _DYLD_INFO_RE.match(line)
        if not m or line.rstrip().endswith(":"):
            continue
        rest = m.group(2)
        f = _FROM_RE.search(rest)
        out.append(Import(m.group(1), f.group(1).strip() if f else None, "[weak-import]" in rest))
    return out


def parse_nm_undefined(text: str) -> List[Import]:
    out = []
    for line in text.splitlines():
        m = _NM_RE.match(line)
        if not m:
            continue
        f = _FROM_RE.search(m.group(3))
        out.append(Import(m.group(2), f.group(1).strip() if f else None, bool(m.group(1))))
    return out


@dataclass(frozen=True)
class LinkedLib:
    path: str
    weak: bool = False
    reexport: bool = False


@dataclass
class MachOInfo:
    minos: Optional[Tuple[int, int, int]]
    platform: Optional[str]
    install_id: Optional[str]
    libs: List[LinkedLib]
    rpaths: List[str]


_PLATFORMS = {
    "1": "macos", "2": "ios", "3": "tvos", "4": "watchos", "5": "bridgeos", "6": "maccatalyst",
    "7": "ios-simulator", "8": "tvos-simulator", "9": "watchos-simulator", "10": "driverkit",
}
_LEGACY_MIN = {
    "LC_VERSION_MIN_IPHONEOS": "ios", "LC_VERSION_MIN_MACOSX": "macos",
    "LC_VERSION_MIN_TVOS": "tvos", "LC_VERSION_MIN_WATCHOS": "watchos",
}
_DYLIB_CMDS = {
    "LC_LOAD_DYLIB": (False, False), "LC_LOAD_WEAK_DYLIB": (True, False),
    "LC_REEXPORT_DYLIB": (False, True), "LC_LOAD_UPWARD_DYLIB": (False, False),
    "LC_LAZY_LOAD_DYLIB": (False, False),
}


def parse_otool_l(text: str) -> MachOInfo:
    info = MachOInfo(None, None, None, [], [])
    cmd: Optional[str] = None
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^cmd\s+(\S+)", s)
        if m:
            cmd = m.group(1)
            if cmd in _LEGACY_MIN and info.platform is None:
                info.platform = _LEGACY_MIN[cmd]
            continue
        if cmd == "LC_BUILD_VERSION" and info.minos is None:
            m = re.match(r"^platform\s+(\S+)", s)
            if m and info.platform is None:
                p = m.group(1)
                info.platform = _PLATFORMS.get(p, p.lower())
            m = re.match(r"^minos\s+(\S+)", s)
            if m:
                info.minos = parse_version(m.group(1))
        elif cmd in _LEGACY_MIN and info.minos is None:
            m = re.match(r"^version\s+(\S+)", s)
            if m:
                info.minos = parse_version(m.group(1))
        elif cmd in _DYLIB_CMDS or cmd == "LC_ID_DYLIB":
            m = re.match(r"^name\s+(.+?)\s+\(offset \d+\)", s)
            if m:
                if cmd == "LC_ID_DYLIB":
                    info.install_id = m.group(1)
                else:
                    weak, reexp = _DYLIB_CMDS[cmd]
                    info.libs.append(LinkedLib(m.group(1), weak, reexp))
        elif cmd == "LC_RPATH":
            m = re.match(r"^path\s+(.+?)\s+\(offset \d+\)", s)
            if m:
                info.rpaths.append(m.group(1))
    return info


def leaf_name(path: str) -> str:
    """Name tools print in `(from X)`: file name up to the first dot (libobjc.A.dylib -> libobjc)."""
    return os.path.basename(path).split(".", 1)[0]


def _leaf_candidates(path: str) -> Set[str]:
    b = os.path.basename(path)
    c = {leaf_name(path), b}
    if b.endswith(".dylib"):
        c.add(b[:-6])
    return c


# --------------------------------------------------------------------------- verdict logic


@dataclass
class LibResolution:
    status: str  # "found" | "missing" | "external"
    symbols: Optional[FrozenSet[str]] = None


@dataclass
class Finding:
    kind: str  # minos | platform | library | symbol | weak-symbol | weak-library | external-library
    binary: str
    lib: Optional[str] = None
    symbol: Optional[str] = None
    detail: str = ""
    count: int = 0


@dataclass
class BinaryReport:
    name: str
    minos: Optional[Tuple[int, int, int]]
    errors: List[Finding] = field(default_factory=list)
    notes: List[Finding] = field(default_factory=list)
    import_count: int = 0

    @property
    def ok(self) -> bool:
        return not self.errors


def format_finding(f: Finding) -> str:
    if f.kind == "minos":
        return f.detail
    if f.kind == "platform":
        return f.detail
    if f.kind == "library":
        return "library not loaded: %s (%d import%s affected)" % (f.lib, f.count, "" if f.count == 1 else "s")
    if f.kind == "symbol":
        return "%s: not exported by %s" % (f.symbol, f.lib or "any linked library")
    if f.kind == "weak-symbol":
        return "%s (from %s): weak (nil at runtime on 14.3)" % (f.symbol, f.lib)
    if f.kind == "weak-library":
        return "%s: weak library absent on 14.3 (%d import%s nil)" % (f.lib, f.count, "" if f.count == 1 else "s")
    if f.kind == "external-library":
        return "%s: not a system library, imports not verified (%d)" % (f.lib, f.count)
    return f.detail or f.kind


def evaluate_binary(
    name: str,
    info: MachOInfo,
    imports: List[Import],
    resolve: Callable[[LinkedLib], LibResolution],
    max_minos: Tuple[int, int, int] = parse_version(DEFAULT_MAX_MINOS),
) -> BinaryReport:
    rep = BinaryReport(name, info.minos, import_count=len(imports))

    if info.minos is None:
        rep.errors.append(Finding("minos", name, detail="no LC_BUILD_VERSION / LC_VERSION_MIN_* found"))
    elif info.minos > max_minos:
        rep.errors.append(
            Finding("minos", name, detail="minos %s > %s" % (fmt_version(info.minos), fmt_version(max_minos)))
        )
    if info.platform is not None and info.platform != "ios":
        rep.errors.append(Finding("platform", name, detail="platform is %s, expected ios" % info.platform))

    resolutions: Dict[LinkedLib, LibResolution] = {}
    by_leaf: Dict[str, LinkedLib] = {}
    for l in info.libs:
        resolutions[l] = resolve(l)
        for cand in _leaf_candidates(l.path):
            by_leaf.setdefault(cand, l)

    handled: Set[LinkedLib] = set()  # libs whose imports are not checked symbol by symbol
    for l, r in resolutions.items():
        if r.status == "found":
            continue
        handled.add(l)
        n = sum(1 for i in imports if i.lib is not None and i.lib in _leaf_candidates(l.path))
        if r.status == "external":
            rep.notes.append(Finding("external-library", name, lib=l.path, count=n))
        elif l.weak:
            rep.notes.append(Finding("weak-library", name, lib=l.path, count=n))
        else:
            rep.errors.append(Finding("library", name, lib=l.path, count=n))

    found_all = [r.symbols or frozenset() for l, r in resolutions.items() if r.status == "found"]

    for imp in imports:
        if imp.lib is None:  # flat / dynamic lookup: any linked library may satisfy it
            if any(imp.symbol in s for s in found_all):
                continue
            if handled and not found_all:
                continue
            (rep.notes if imp.weak else rep.errors).append(
                Finding("weak-symbol" if imp.weak else "symbol", name, lib=None, symbol=imp.symbol)
            )
            continue
        if imp.lib == WEAK_DEF_COALESCE:
            # Weak definitions (C++ operator new/delete, ...) are coalesced across every loaded
            # image at run time; they are not bound to one library, so there is no one to check.
            continue
        target = by_leaf.get(imp.lib)
        if target is None:
            (rep.notes if imp.weak else rep.errors).append(
                Finding("weak-symbol" if imp.weak else "symbol", name, lib=imp.lib, symbol=imp.symbol,
                        detail="library not linked")
            )
            continue
        if target in handled:
            continue
        syms = resolutions[target].symbols or frozenset()
        if imp.symbol in syms:
            continue
        if imp.weak:
            rep.notes.append(Finding("weak-symbol", name, lib=imp.lib, symbol=imp.symbol))
        else:
            rep.errors.append(Finding("symbol", name, lib=imp.lib, symbol=imp.symbol))
    return rep


# --------------------------------------------------------------------------- rpath handling


def expand_rpath_candidates(
    path: str, rpaths: List[str], executable_dir: str, loader_dir: str
) -> List[str]:
    def sub(p: str) -> str:
        return p.replace("@executable_path", executable_dir).replace("@loader_path", loader_dir)

    cands: List[str] = []
    if path.startswith("@rpath/"):
        rest = path[len("@rpath/"):]
        for rp in rpaths:
            cands.append(os.path.normpath(os.path.join(sub(rp), rest)))
    elif path.startswith("@executable_path/") or path.startswith("@loader_path/"):
        cands.append(os.path.normpath(sub(path)))
    out: List[str] = []
    for c in cands:
        if c not in out:
            out.append(c)
    return out


# --------------------------------------------------------------------------- real tools + bundle walk


WEAK_DEF_COALESCE = "<weak-def-coalesce>"


def system_rpath_install_names(rpaths: Iterable[str], rest: str) -> List[str]:
    """Absolute system install names an `@rpath/<rest>` load can resolve to through LC_RPATH
    entries such as /usr/lib/swift (how Swift back-deployment dylibs find libswiftCore)."""
    out: List[str] = []
    for rp in rpaths:
        if rp.startswith(("/usr/lib", "/System/Library")):
            name = rp.rstrip("/") + "/" + rest
            if name not in out:
                out.append(name)
    return out


class ToolError(RuntimeError):
    pass


def find_tool(name: str) -> Optional[str]:
    p = shutil.which(name)
    if p:
        return p
    xcrun = shutil.which("xcrun")
    if xcrun:
        r = subprocess.run([xcrun, "--find", name], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return None


def run(argv: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, errors="replace")


def macho_kind(path: str) -> Optional[str]:
    """'thin' | 'fat' | None, from the file magic."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(8)
    except OSError:
        return None
    if len(head) < 8:
        return None
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        return "thin"
    if head[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        (n,) = struct.unpack(">I", head[4:8])
        return "fat" if 0 < n <= 20 else None
    return None


def find_binaries(app_dir: str) -> List[str]:
    out = []
    for dirpath, dirs, files in os.walk(app_dir, followlinks=False):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(dirpath, d))]
        for f in files:
            p = os.path.join(dirpath, f)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            if macho_kind(p):
                out.append(p)
    return sorted(out)


def enclosing_bundle(path: str, app_dir: str) -> str:
    d = os.path.dirname(path)
    while True:
        if d.endswith((".app", ".appex")) or os.path.normpath(d) == os.path.normpath(app_dir):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.dirname(path)
        d = parent


class BundleChecker:
    def __init__(self, app_dir: str, sdk: SdkIndex, arch: str, max_minos: Tuple[int, int, int]):
        self.app_dir = os.path.realpath(app_dir)
        self.sdk = sdk
        self.arch = arch
        self.max_minos = max_minos
        self.otool = find_tool("otool")
        self.nm = find_tool("nm")
        self.dyld_info = find_tool("dyld_info")
        if not self.otool or not self.nm:
            raise ToolError("otool and nm are required (install Xcode command line tools)")
        self._info: Dict[str, MachOInfo] = {}
        self._embedded: Dict[str, Optional[FrozenSet[str]]] = {}

    def _arch_args(self, path: str) -> List[str]:
        return ["-arch", self.arch] if macho_kind(path) == "fat" else []

    def info(self, path: str) -> MachOInfo:
        if path not in self._info:
            r = run([self.otool, *self._arch_args(path), "-l", path])
            if r.returncode != 0:
                raise ToolError("otool -l failed for %s: %s" % (path, r.stderr.strip()))
            self._info[path] = parse_otool_l(r.stdout)
        return self._info[path]

    def imports(self, path: str) -> List[Import]:
        if self.dyld_info:
            r = run([self.dyld_info, *self._arch_args(path), "-imports", path])
            if r.returncode == 0:
                return parse_dyld_info_imports(r.stdout)
        r = run([self.nm, *self._arch_args(path), "-m", "-u", path])
        if r.returncode != 0:
            raise ToolError("nm failed for %s: %s" % (path, r.stderr.strip()))
        return parse_nm_undefined(r.stdout)

    # -- resolving linked libraries ------------------------------------------------
    def _bundle_candidates(self, linked_path: str, binary: str) -> List[str]:
        info = self.info(binary)
        exe_dir = enclosing_bundle(binary, self.app_dir)
        loader_dir = os.path.dirname(binary)
        cands = expand_rpath_candidates(linked_path, info.rpaths, exe_dir, loader_dir)
        if linked_path.startswith("@rpath/"):
            # dyld also honours rpaths of the loading chain; approximate with the app's Frameworks.
            rest = linked_path[len("@rpath/"):]
            for base in (os.path.join(self.app_dir, "Frameworks"), os.path.join(exe_dir, "Frameworks")):
                c = os.path.normpath(os.path.join(base, rest))
                if c not in cands:
                    cands.append(c)
        return cands

    def embedded_exports(self, path: str, _seen: Optional[Set[str]] = None) -> FrozenSet[str]:
        key = os.path.realpath(path)
        if key in self._embedded and self._embedded[key] is not None:
            return self._embedded[key]  # type: ignore[return-value]
        seen = _seen if _seen is not None else set()
        if key in seen:
            return frozenset()
        seen.add(key)
        r = run([self.nm, *self._arch_args(path), "-gUj", path])
        syms: Set[str] = set(l.strip() for l in r.stdout.splitlines() if l.strip())
        for l in self.info(path).libs:
            if l.reexport:
                res = self.resolve(l, path, seen)
                if res.status == "found" and res.symbols:
                    syms |= res.symbols
        result = frozenset(syms)
        if _seen is None:
            self._embedded[key] = result
        return result

    def resolve(self, linked: LinkedLib, binary: str, _seen: Optional[Set[str]] = None) -> LibResolution:
        p = linked.path
        if p.startswith("/usr/lib/") or p.startswith("/System/Library/"):
            syms = self.sdk.exports(p)
            return LibResolution("missing") if syms is None else LibResolution("found", syms)
        if p.startswith("@"):
            for cand in self._bundle_candidates(p, binary):
                if os.path.isfile(cand) and macho_kind(cand):
                    return LibResolution("found", self.embedded_exports(cand, _seen))
            if p.startswith("@rpath/"):
                # dyld searches the whole loading chain's rpaths, and the main executable's
                # include /usr/lib/swift, which is where the OS-provided libswift*.dylib live.
                rpaths = list(self.info(binary).rpaths)
                main_exe = os.path.join(self.app_dir, os.path.basename(self.app_dir)[: -len(".app")])
                if os.path.isfile(main_exe) and macho_kind(main_exe):
                    rpaths += self.info(main_exe).rpaths
                for name in system_rpath_install_names(rpaths, p[len("@rpath/"):]):
                    syms = self.sdk.exports(name)
                    if syms is not None:
                        return LibResolution("found", syms)
            return LibResolution("missing")
        return LibResolution("external")  # e.g. /Library/Frameworks/CydiaSubstrate...

    def check(self, binary: str) -> BinaryReport:
        rel = os.path.relpath(binary, os.path.dirname(self.app_dir))
        info = self.info(binary)
        imports = self.imports(binary)
        return evaluate_binary(
            rel, info, imports, lambda l: self.resolve(l, binary), self.max_minos
        )


# --------------------------------------------------------------------------- reporting


def render(reports: List[BinaryReport], limit: int, verbose: bool, max_minos: Tuple[int, int, int]) -> str:
    out: List[str] = []
    n_err = sum(len(r.errors) for r in reports)
    for r in reports:
        status = "FAIL" if r.errors else "ok"
        out.append("[%s] %s  (minos %s, %d imports)" % (status, r.name, fmt_version(r.minos), r.import_count))
        errors, notes = r.errors, r.notes
        for kind in ("minos", "platform", "library"):
            for f in errors:
                if f.kind == kind:
                    out.append("    ERROR " + format_finding(f))
        sym_by_lib: Dict[str, List[str]] = {}
        for f in errors:
            if f.kind == "symbol":
                sym_by_lib.setdefault(f.lib or "(flat lookup)", []).append(f.symbol or "")
        for lib in sorted(sym_by_lib, key=lambda k: -len(sym_by_lib[k])):
            syms = sorted(sym_by_lib[lib])
            out.append("    ERROR %d symbol%s missing from %s (Symbol not found on 14.3):" % (
                len(syms), "" if len(syms) == 1 else "s", lib))
            for s in syms if verbose else syms[:limit]:
                out.append("        " + s)
            if not verbose and len(syms) > limit:
                out.append("        ... %d more (--verbose to list all)" % (len(syms) - limit))
        weak_by_lib: Dict[str, List[str]] = {}
        for f in notes:
            if f.kind == "weak-symbol":
                weak_by_lib.setdefault(f.lib or "(flat lookup)", []).append(f.symbol or "")
            else:
                out.append("    note  " + format_finding(f))
        for lib in sorted(weak_by_lib):
            syms = sorted(weak_by_lib[lib])
            out.append("    note  %d symbol%s from %s weak (nil at runtime on 14.3):" % (
                len(syms), "" if len(syms) == 1 else "s", lib))
            for s in syms if verbose else syms[:limit]:
                out.append("        " + s)
            if not verbose and len(syms) > limit:
                out.append("        ... %d more" % (len(syms) - limit))
    bad = [r for r in reports if r.errors]
    out.append("")
    out.append(
        "%d Mach-O file%s checked, %d with errors (%d total error%s), minos limit %s"
        % (len(reports), "" if len(reports) == 1 else "s", len(bad), n_err, "" if n_err == 1 else "s",
           fmt_version(max_minos))
    )
    out.append("RESULT: " + ("FAIL" if n_err else "PASS"))
    return "\n".join(out)


def locate_app(path: str, scratch: str) -> str:
    if os.path.isdir(path):
        return path
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            z.extractall(scratch)
        payload = os.path.join(scratch, "Payload")
        apps = [d for d in os.listdir(payload) if d.endswith(".app")] if os.path.isdir(payload) else []
        if len(apps) != 1:
            raise ToolError("expected exactly one Payload/*.app in %s, found %d" % (path, len(apps)))
        return os.path.join(payload, apps[0])
    raise ToolError("%s is neither a directory (.app) nor a zip (.ipa)" % path)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("app", help="path to an .app directory or an .ipa")
    ap.add_argument("sdk", help="path to an iPhoneOS SDK root (e.g. iPhoneOS14.3.sdk)")
    ap.add_argument("--max-minos", default=DEFAULT_MAX_MINOS)
    ap.add_argument("--arch", default=DEFAULT_ARCH)
    ap.add_argument("--limit", type=int, default=25, help="symbols listed per library group (default 25)")
    ap.add_argument("--verbose", action="store_true", help="list every symbol")
    ap.add_argument("--use-nm", action="store_true", help="force `nm -m -u` instead of `dyld_info -imports`")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.sdk):
        print("error: SDK path %s is not a directory" % args.sdk, file=sys.stderr)
        return 2
    max_minos = parse_version(args.max_minos)
    with tempfile.TemporaryDirectory(prefix="ios14check.") as scratch:
        try:
            app_dir = locate_app(args.app, scratch)
            checker = BundleChecker(app_dir, SdkIndex(args.sdk, args.arch), args.arch, max_minos)
            if args.use_nm:
                checker.dyld_info = None
            bins = find_binaries(checker.app_dir)
            if not bins:
                raise ToolError("no Mach-O files found in %s" % app_dir)
            reports = [checker.check(b) for b in bins]
        except (ToolError, OSError, zipfile.BadZipFile) as e:
            print("error: %s" % e, file=sys.stderr)
            return 2
        print(render(reports, args.limit, args.verbose, max_minos))
        return 1 if any(r.errors for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
