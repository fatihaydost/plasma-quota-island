#!/usr/bin/env python3
"""Quota Island — Live Activities & File Shelf controller.

Provides read-only status aggregation and safe actions for:
- Herdr live agents (`hc ls --json`, `herdr-app do agent.focus --terminal <id>`)
- Houra focus summary (`~/.local/share/houra/houra.sqlite` in read-only URI mode)
- CachyOS power profiles (`powerprofilesctl get` / `powerprofilesctl set`)
- Battery & Bluetooth audio/device status (`upower`, `bluetoothctl`)
- NotchNook-style File & Text Shelf (`~/.cache/plasma-quota-island/shelf.json`, `xdg-open`)
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from typing import Any
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, pathname2url, urlopen
import signal
import uuid

VALID_POWER_PROFILES: tuple[str, ...] = ("performance", "balanced", "power-saver")
VALID_POWER_ACTIONS: tuple[str, ...] = ("sleep", "lock", "logout", "reboot", "poweroff")
TERMINAL_ID_RE = re.compile(r"^[A-Za-z0-9_.:@-]{1,64}$")
SHELF_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PLAIN_SHELL_AGENTS = frozenset({
    "",
    "sh",
    "bash",
    "zsh",
    "fish",
    "nu",
    "dash",
    "ksh",
    "tcsh",
    "csh",
})
MAX_SHELF_ITEMS = 50
MAX_TEXT_LENGTH = 8192


def _augmented_env() -> dict[str, str]:
    """Ensure ~/.local/bin and standard system dirs are on PATH inside plasmashell."""
    env = os.environ.copy()
    extra_dirs = [
        str(Path.home() / ".local" / "bin"),
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]
    current_parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
    for d in extra_dirs:
        if d not in current_parts:
            current_parts.append(d)
    env["PATH"] = os.pathsep.join(current_parts)
    return env


def _which(cmd: str, env: dict[str, str] | None = None) -> str | None:
    search_path = (env or _augmented_env()).get("PATH")
    return shutil.which(cmd, path=search_path)


def _run_cmd(
    argv: list[str],
    timeout: float = 2.5,
) -> tuple[int, str, str]:
    """Run an external command safely without a shell."""
    env = _augmented_env()
    resolved = _which(argv[0], env=env)
    if not resolved:
        return 127, "", f"{argv[0]} not found"
    full_argv = [resolved, *argv[1:]]
    try:
        proc = subprocess.run(
            full_argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"{argv[0]} timed out"
    except OSError as exc:
        return 126, "", str(exc)


def _spawn_detached(argv: list[str]) -> tuple[bool, str]:
    """Spawn a detached GUI helper (such as xdg-open) without blocking plasmashell."""
    env = _augmented_env()
    resolved = _which(argv[0], env=env)
    if not resolved:
        return False, f"{argv[0]} not found"
    try:
        subprocess.Popen(
            [resolved, *argv[1:]],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
        return True, ""
    except OSError as exc:
        return False, str(exc)


# ---------------------------------------------------------------------------
# 1. Herdr Live Agents (`hc ls --json`)
# ---------------------------------------------------------------------------

def _normalize_agent_status(raw_status: Any) -> tuple[str, str, str]:
    """Normalize Herdr terminal status record or string to (bucket, msg, kind).

    Buckets: 'working' | 'blocked' | 'done' | '' (not an agent status).
    """
    msg = ""
    kind = ""
    state_str = ""
    if isinstance(raw_status, dict):
        state_str = str(raw_status.get("state") or "").strip().lower()
        msg = str(raw_status.get("msg") or raw_status.get("title") or "").strip()
        kind = str(raw_status.get("kind") or "").strip()
    elif isinstance(raw_status, str):
        state_str = raw_status.strip().lower()

    if state_str in ("blocked", "error", "permission", "question", "auth", "waiting_approval"):
        return "blocked", msg, kind or (state_str if state_str != "blocked" else "")
    if state_str in ("working", "running", "busy"):
        return "working", msg, kind
    if state_str in ("done", "idle", "completed", "finished"):
        return "done", msg, kind
    return "", msg, kind


def get_herdr_status() -> dict[str, Any]:
    # installed=False iken arayüz Herdr kartını ve Sneak Peek tetikleyicisini tamamen gizler.
    installed = _which("hc") is not None
    rc, stdout, _stderr = _run_cmd(["hc", "ls", "--json"], timeout=2.5) if installed else (127, "", "")
    if rc != 0 or not stdout.strip():
        return {
            "installed": installed,
            "available": False,
            "workingCount": 0,
            "blockedCount": 0,
            "doneCount": 0,
            "totalCount": 0,
            "agents": [],
        }

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return {
            "installed": True,
            "available": False,
            "workingCount": 0,
            "blockedCount": 0,
            "doneCount": 0,
            "totalCount": 0,
            "agents": [],
        }

    raw_terminals = payload.get("terminals") if isinstance(payload, dict) else payload
    if not isinstance(raw_terminals, list):
        raw_terminals = []

    agents: list[dict[str, Any]] = []
    working_count = 0
    blocked_count = 0
    done_count = 0

    for entry in raw_terminals:
        if not isinstance(entry, dict):
            continue
        term_state = str(entry.get("state") or "live").strip().lower()
        if term_state not in ("live", ""):
            continue

        address = str(entry.get("address") or entry.get("id") or "").strip()
        if not address:
            continue

        agent_name = str(
            entry.get("agent")
            or entry.get("template")
            or (entry.get("status", {}).get("app") if isinstance(entry.get("status"), dict) else "")
            or ""
        ).strip()
        bucket, msg, kind = _normalize_agent_status(entry.get("status"))

        # Filter out plain interactive shells unless they actively reported an OSC 7501 status.
        if not bucket:
            if agent_name.lower() in PLAIN_SHELL_AGENTS:
                continue
            bucket = "done"

        if bucket == "working":
            working_count += 1
        elif bucket == "blocked":
            blocked_count += 1
        else:
            done_count += 1

        where = str(entry.get("where") or entry.get("name") or entry.get("title") or "").strip()
        cwd = str(entry.get("cwd") or "").strip()
        if not where:
            where = Path(cwd).name if cwd else address

        turn_val = entry.get("turn", 0)
        try:
            turn_int = int(turn_val)
        except (TypeError, ValueError):
            turn_int = 0

        agents.append({
            "id": address,
            "address": address,
            "agent": agent_name or "agent",
            "where": where,
            "cwd": cwd,
            "status": bucket,
            "turn": turn_int,
            "msg": msg,
            "kind": kind,
        })

    # Prioritize blocked first, then working, then done so urgent approvals stay on top.
    priority = {"blocked": 0, "working": 1, "done": 2}
    agents.sort(key=lambda item: (priority.get(item["status"], 3), item["where"].lower(), item["id"]))

    return {
        "installed": True,
        "available": True,
        "workingCount": working_count,
        "blockedCount": blocked_count,
        "doneCount": done_count,
        "totalCount": len(agents),
        "agents": agents,
    }


def focus_herdr_agent(terminal_id: str) -> dict[str, Any]:
    tid = (terminal_id or "").strip()
    if not tid or tid.startswith("-") or not TERMINAL_ID_RE.match(tid):
        return {"ok": False, "error": "invalid_terminal_id"}

    rc, _stdout, stderr = _run_cmd(
        ["herdr-app", "do", "agent.focus", "--terminal", tid],
        timeout=3.0,
    )
    if rc != 0:
        return {"ok": False, "terminal": tid, "error": stderr.strip() or f"exit_{rc}"}
    return {"ok": True, "terminal": tid}


# ---------------------------------------------------------------------------
# 2. Houra Read-Only Focus Summary (`~/.local/share/houra/houra.sqlite`)
# ---------------------------------------------------------------------------

def _houra_db_path() -> Path:
    override = os.environ.get("HOURA_DB_PATH", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local" / "share" / "houra" / "houra.sqlite"


def _day_bounds_epoch(ref_date: dt.date) -> tuple[float, float]:
    start_dt = dt.datetime.combine(ref_date, dt.time.min)
    end_dt = dt.datetime.combine(ref_date + dt.timedelta(days=1), dt.time.min)
    return start_dt.timestamp(), end_dt.timestamp()


def get_houra_summary(
    db_path: Path | None = None,
    ref_date: dt.date | None = None,
) -> dict[str, Any]:
    target_db = db_path if db_path is not None else _houra_db_path()
    empty_result: dict[str, Any] = {
        "installed": target_db.is_file(),
        "available": False,
        "completedSessions": 0,
        "focusMinutes": 0,
        "focusSeconds": 0,
        "pendingTodos": 0,
        "completedTodos": 0,
        "activeSession": None,
        "topTodos": [],
    }
    if not empty_result["installed"]:
        return empty_result

    today = ref_date or dt.date.today()
    today_iso = today.isoformat()
    t_start, t_end = _day_bounds_epoch(today)

    uri = f"file:{pathname2url(str(target_db.resolve()))}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=1.5)
        conn.row_factory = sqlite3.Row
    except sqlite3.Error:
        return empty_result

    try:
        conn.execute("PRAGMA query_only = ON")
        tables = {
            str(r["name"])
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
        }

        completed_sessions = 0
        total_focus_sec = 0
        active_session: dict[str, Any] | None = None

        if "sessions" in tables:
            session_rows = conn.execute(
                """
                SELECT id, goal, work_min, start, end, focus_sec
                FROM sessions
                WHERE start >= ? AND start < ?
                ORDER BY start ASC
                """,
                (t_start, t_end),
            ).fetchall()

            for row in session_rows:
                fsec = max(0, int(row["focus_sec"] or 0))
                if row["end"] is not None:
                    completed_sessions += 1
                    total_focus_sec += fsec
                else:
                    total_focus_sec += fsec
                    active_session = {
                        "id": int(row["id"]),
                        "goal": str(row["goal"] or "").strip() or "Odak",
                        "workMinutes": max(0, int(row["work_min"] or 0)),
                        "focusMinutes": int(fsec // 60),
                    }

        pending_todos = 0
        completed_todos = 0
        top_todos: list[dict[str, Any]] = []

        if "todos" in tables:
            todo_cols = {
                str(r["name"])
                for r in conn.execute("PRAGMA table_info(todos)").fetchall()
            }
            if {"scope", "end_day", "priority", "position"}.issubset(todo_cols):
                todo_rows = conn.execute(
                    """
                    SELECT id, day, title, state, scope, end_day, priority, position
                    FROM todos
                    WHERE (scope = 'day' AND day = ?)
                       OR (scope = 'range' AND day <= ? AND (CASE WHEN end_day = '' THEN day ELSE end_day END) >= ?)
                       OR (state != 2 AND scope IN ('day', 'range') AND (CASE WHEN end_day = '' THEN day ELSE end_day END) < ?)
                    ORDER BY priority DESC, position ASC, id ASC
                    """,
                    (today_iso, today_iso, today_iso, today_iso),
                ).fetchall()
            else:
                todo_rows = conn.execute(
                    "SELECT id, day, title, state FROM todos WHERE day = ? ORDER BY id ASC",
                    (today_iso,),
                ).fetchall()

            for trow in todo_rows:
                state_int = int(trow["state"] or 0)
                if state_int == 2:
                    completed_todos += 1
                else:
                    pending_todos += 1
                    if len(top_todos) < 4:
                        top_todos.append({
                            "id": int(trow["id"]),
                            "title": str(trow["title"] or "").strip(),
                            "state": state_int,
                        })

        return {
            "installed": True,
            "available": True,
            "completedSessions": completed_sessions,
            "focusMinutes": int(total_focus_sec // 60),
            "focusSeconds": total_focus_sec,
            "pendingTodos": pending_todos,
            "completedTodos": completed_todos,
            "activeSession": active_session,
            "topTodos": top_todos,
        }
    except sqlite3.Error:
        return empty_result
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 3. CachyOS Power Profile, Battery & Bluetooth
# ---------------------------------------------------------------------------

def get_power_status() -> dict[str, Any]:
    rc, stdout, _stderr = _run_cmd(["powerprofilesctl", "get"], timeout=2.0)
    profile = stdout.strip().lower() if rc == 0 else ""
    if profile not in VALID_POWER_PROFILES:
        return {
            "available": False,
            "profile": "balanced",
            "profiles": list(VALID_POWER_PROFILES),
        }
    return {
        "available": True,
        "profile": profile,
        "profiles": list(VALID_POWER_PROFILES),
    }


def set_power_profile(profile: str) -> dict[str, Any]:
    target = (profile or "").strip().lower()
    if target not in VALID_POWER_PROFILES:
        return {"ok": False, "error": "invalid_profile"}
    rc, _stdout, stderr = _run_cmd(["powerprofilesctl", "set", target], timeout=3.0)
    if rc != 0:
        return {"ok": False, "profile": target, "error": stderr.strip() or f"exit_{rc}"}
    return {"ok": True, "profile": target}


def _parse_upower_info(text: str) -> dict[str, Any]:
    present: bool | None = None
    percentage = -1
    state = ""
    time_rem = ""

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if ":" not in line:
            continue
        key, val = [part.strip() for part in line.split(":", 1)]
        key_low = key.lower()
        if key_low == "present":
            present = val.lower() in ("yes", "true", "1")
        elif key_low == "percentage":
            num_str = val.rstrip("%").strip().replace(",", ".")
            try:
                percentage = max(0, min(100, int(round(float(num_str)))))
            except ValueError:
                pass
        elif key_low == "state":
            state = val.lower()
        elif key_low in ("time to empty", "time to full"):
            time_rem = val

    available = bool(present) and percentage >= 0
    charging = state in ("charging", "pending-charge")
    plugged_in = charging or state == "fully-charged"
    return {
        "available": available,
        "percentage": percentage if available else -1,
        "state": state if available else "",
        "charging": charging if available else False,
        "pluggedIn": plugged_in if available else False,
        "timeRemaining": time_rem if available else "",
    }


def get_battery_status() -> dict[str, Any]:
    rc, stdout, _stderr = _run_cmd(
        ["upower", "-i", "/org/freedesktop/UPower/devices/DisplayDevice"],
        timeout=2.0,
    )
    if rc == 0 and stdout.strip():
        parsed = _parse_upower_info(stdout)
        if parsed["available"]:
            return parsed

    rc_enum, enum_out, _ = _run_cmd(["upower", "-e"], timeout=2.0)
    if rc_enum == 0:
        for dev_line in enum_out.splitlines():
            dev = dev_line.strip()
            if "/battery_" in dev:
                rc_b, b_out, _ = _run_cmd(["upower", "-i", dev], timeout=2.0)
                if rc_b == 0 and b_out.strip():
                    parsed = _parse_upower_info(b_out)
                    if parsed["available"]:
                        return parsed

    return {
        "available": False,
        "percentage": -1,
        "state": "",
        "charging": False,
        "pluggedIn": False,
        "timeRemaining": "",
    }


def _parse_bt_device_info(info_text: str, fallback_name: str) -> dict[str, Any]:
    alias = fallback_name
    is_audio = False
    battery = -1
    connected: bool | None = None

    for raw_line in info_text.splitlines():
        line = raw_line.strip()
        if line.startswith("Alias:"):
            val = line.split(":", 1)[1].strip()
            if val:
                alias = val
        elif line.startswith("Name:") and not alias:
            alias = line.split(":", 1)[1].strip()
        elif line.startswith("Connected:"):
            connected = line.split(":", 1)[1].strip().lower() == "yes"
        elif line.startswith("Icon:"):
            icon_val = line.split(":", 1)[1].strip().lower()
            if "audio" in icon_val or "headset" in icon_val or "headphone" in icon_val:
                is_audio = True
        elif line.startswith("UUID:"):
            uuid_low = line.lower()
            if any(tok in uuid_low for tok in ("audio sink", "handsfree", "headset", "0000110b", "0000111e")):
                is_audio = True
        elif "Battery Percentage:" in line:
            m = re.search(r"\((\d{1,3})\)", line)
            if m:
                battery = max(0, min(100, int(m.group(1))))
            else:
                m_hex = re.search(r"0x([0-9a-fA-F]+)", line)
                if m_hex:
                    battery = max(0, min(100, int(m_hex.group(1), 16)))

    return {
        "name": alias,
        "isAudio": is_audio,
        "battery": battery,
        "connected": True if connected is None else connected,
    }


def get_bluetooth_status() -> dict[str, Any]:
    rc, stdout, _stderr = _run_cmd(["bluetoothctl", "devices", "Connected"], timeout=2.0)
    if rc != 0:
        return {
            "available": False,
            "connected": False,
            "name": "",
            "mac": "",
            "isAudio": False,
            "battery": -1,
            "devices": [],
        }

    candidates: list[tuple[str, str]] = []
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        if not line.startswith("Device "):
            continue
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        mac = parts[1].strip()
        initial_name = parts[2].strip() if len(parts) >= 3 else mac
        candidates.append((mac, initial_name))

    def _probe_bt_device(pair: tuple[str, str]) -> dict[str, Any] | None:
        mac, initial_name = pair
        rc_info, info_out, _ = _run_cmd(["bluetoothctl", "info", mac], timeout=1.5)
        if rc_info == 0 and info_out.strip():
            meta = _parse_bt_device_info(info_out, initial_name)
            if not meta["connected"]:
                return None
        else:
            meta = {
                "name": initial_name,
                "isAudio": False,
                "battery": -1,
                "connected": True,
            }
        return {
            "mac": mac,
            "name": meta["name"],
            "isAudio": meta["isAudio"],
            "battery": meta["battery"],
        }

    devices: list[dict[str, Any]] = []
    if len(candidates) == 1:
        one = _probe_bt_device(candidates[0])
        if one is not None:
            devices.append(one)
    elif len(candidates) > 1:
        with ThreadPoolExecutor(max_workers=min(4, len(candidates))) as bt_pool:
            for probed in bt_pool.map(_probe_bt_device, candidates):
                if probed is not None:
                    devices.append(probed)

    if not devices:
        return {
            "available": True,
            "connected": False,
            "name": "",
            "mac": "",
            "isAudio": False,
            "battery": -1,
            "devices": [],
        }

    # Prefer connected Bluetooth audio devices (headphones/headset/speaker) first.
    devices.sort(key=lambda d: (0 if d["isAudio"] else 1, d["name"].lower()))
    primary = devices[0]
    return {
        "available": True,
        "connected": True,
        "name": primary["name"],
        "mac": primary["mac"],
        "isAudio": primary["isAudio"],
        "battery": primary["battery"],
        "devices": devices,
    }


# ---------------------------------------------------------------------------
# 4. File & Text Shelf (`~/.cache/plasma-quota-island/shelf.json`)
# ---------------------------------------------------------------------------

CACHE_DIR_NAME = "plasma-quota-island"
LEGACY_CACHE_DIR_NAME = "gruvbox-island"


def _default_cache_dir(base: Path) -> Path:
    """island_ctl.py ile aynı kural. Varsayılan önbellek dizini; eski ~/.cache/gruvbox-island bir kez yeni ada taşınır (raf korunur)."""
    new = base / CACHE_DIR_NAME
    old = base / LEGACY_CACHE_DIR_NAME
    if not new.exists() and old.is_dir():
        try:
            os.rename(old, new)
            # Eski dizin daha geniş izinli olabilir.
            for d in (new, new / "notes"):
                if d.is_dir():
                    d.chmod(0o700)
        except OSError:
            # Eşzamanlı başka süreç taşımış olabilir; taşınamadıysa veri kaybolmasın diye eskisi kullanılır.
            return new if new.exists() else old
    return new


def _shelf_path() -> Path:
    explicit = os.environ.get("PLASMA_QUOTA_ISLAND_SHELF_PATH", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    cache_override = os.environ.get("PLASMA_QUOTA_ISLAND_CACHE_DIR", "").strip()
    if cache_override:
        return Path(cache_override).expanduser() / "shelf.json"
    xdg_cache = os.environ.get("XDG_CACHE_HOME", "").strip()
    base = Path(xdg_cache).expanduser() if xdg_cache else (Path.home() / ".cache")
    return _default_cache_dir(base) / "shelf.json"


def _notes_dir(shelf_file: Path) -> Path:
    return shelf_file.parent / "notes"


def _shorten_home(path_str: str) -> str:
    home = str(Path.home())
    if path_str == home:
        return "~"
    if path_str.startswith(home + os.sep):
        return "~" + path_str[len(home):]
    return path_str


def _classify_shelf_input(raw: str) -> dict[str, Any] | None:
    cleaned = raw.replace("\x00", "").strip()
    if not cleaned:
        return None
    if len(cleaned) > MAX_TEXT_LENGTH:
        cleaned = cleaned[:MAX_TEXT_LENGTH]

    # 1. Handle file:// URIs (e.g. from Qt DropArea drop.urls; accept only empty or localhost host)
    if cleaned.startswith("file://"):
        parsed = urlparse(cleaned)
        if parsed.netloc.lower() not in ("", "localhost"):
            return None
        local_path = unquote(parsed.path or "")
        if not local_path or not local_path.startswith("/"):
            return None
        p = Path(local_path).expanduser()
        resolved_str = str(p)
        is_dir = p.is_dir()
        kind = "dir" if is_dir else "file"
        label = p.name or resolved_str
        return {
            "kind": kind,
            "label": label,
            "value": resolved_str,
            "subtitle": _shorten_home(resolved_str),
            "exists": p.exists(),
        }

    # 2. Handle http:// and https:// URLs
    if cleaned.startswith(("http://", "https://")) and "\n" not in cleaned and " " not in cleaned:
        parsed = urlparse(cleaned)
        host = parsed.netloc or cleaned
        tail = parsed.path.rstrip("/")
        short_tail = ("/" + tail.split("/")[-1]) if tail and tail != "/" else ""
        label = (host + short_tail)[:64]
        return {
            "kind": "url",
            "label": label,
            "value": cleaned,
            "subtitle": cleaned[:120],
            "exists": True,
        }

    # 3. Handle local absolute or ~/ paths when single-line
    if "\n" not in cleaned and (cleaned.startswith("/") or cleaned.startswith("~/")):
        p = Path(cleaned).expanduser()
        if p.exists():
            resolved_str = str(p)
            kind = "dir" if p.is_dir() else "file"
            return {
                "kind": kind,
                "label": p.name or resolved_str,
                "value": resolved_str,
                "subtitle": _shorten_home(resolved_str),
                "exists": True,
            }

    # 4. Treat everything else as a pinned text snippet
    lines = [ln.strip() for ln in cleaned.splitlines() if ln.strip()]
    first_line = lines[0] if lines else cleaned
    label = first_line[:64] + ("…" if len(first_line) > 64 else "")
    # subtitle arayüzde gösterilmez; yalnız raf JSON'unda dil bağımsız özet olarak tutulur.
    line_info = f"{len(cleaned)} chars" if len(lines) <= 1 else f"{len(lines)} lines · {len(cleaned)} chars"
    return {
        "kind": "text",
        "label": label,
        "value": cleaned,
        "subtitle": f"Text · {line_info}",
        "exists": True,
    }


def _read_shelf_unlocked(shelf_file: Path) -> list[dict[str, Any]]:
    if not shelf_file.is_file():
        return []
    try:
        raw_data = json.loads(shelf_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []

    raw_items = raw_data.get("items") if isinstance(raw_data, dict) else raw_data
    if not isinstance(raw_items, list):
        return []

    valid_items: list[dict[str, Any]] = []
    for item in raw_items:
        if not isinstance(item, dict):
            continue
        item_id = str(item.get("id") or "").strip()
        kind = str(item.get("kind") or "text").strip()
        value = str(item.get("value") or "")
        if not item_id or not SHELF_ID_RE.match(item_id) or not value:
            continue
        exists = True
        if kind in ("file", "dir"):
            exists = Path(value).exists()
        valid_items.append({
            "id": item_id,
            "kind": kind if kind in ("file", "dir", "url", "text") else "text",
            "label": str(item.get("label") or value[:64]),
            "value": value,
            "subtitle": str(item.get("subtitle") or ""),
            "exists": exists,
            "addedAt": str(item.get("addedAt") or ""),
            "addedEpoch": int(item.get("addedEpoch") or 0),
        })
    return valid_items


def _write_shelf_unlocked(shelf_file: Path, items: list[dict[str, Any]]) -> None:
    shelf_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp_path = shelf_file.with_suffix(".json.tmp")
    payload = json.dumps(items, ensure_ascii=False, indent=2)
    fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.write("\n")
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    os.replace(str(tmp_path), str(shelf_file))


class _ShelfLock:
    def __init__(self, shelf_file: Path) -> None:
        self._lock_path = shelf_file.with_suffix(".lock")
        self._fd: int | None = None

    def __enter__(self) -> "_ShelfLock":
        self._lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(str(self._lock_path), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self._fd = fd
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None


def get_shelf_status(shelf_file: Path | None = None) -> dict[str, Any]:
    target = shelf_file if shelf_file is not None else _shelf_path()
    items = _read_shelf_unlocked(target)
    return {
        "count": len(items),
        "items": items,
    }


def shelf_add_many(raw_inputs: list[str], shelf_file: Path | None = None) -> dict[str, Any]:
    target = shelf_file if shelf_file is not None else _shelf_path()
    classified_list = []
    for raw in raw_inputs:
        c = _classify_shelf_input(raw)
        if c is not None:
            classified_list.append(c)

    if not classified_list:
        return {"ok": False, "error": "empty_input"}

    now_epoch = int(time.time())
    now_hm = dt.datetime.now().strftime("%H:%M")

    with _ShelfLock(target):
        items = _read_shelf_unlocked(target)
        last_added: dict[str, Any] | None = None

        for classified in classified_list:
            existing_id = ""
            filtered: list[dict[str, Any]] = []
            for existing in items:
                if existing["kind"] == classified["kind"] and existing["value"] == classified["value"]:
                    existing_id = existing["id"]
                else:
                    filtered.append(existing)

            item_id = existing_id or f"s_{uuid.uuid4().hex[:10]}"
            new_entry = {
                "id": item_id,
                "kind": classified["kind"],
                "label": classified["label"],
                "value": classified["value"],
                "subtitle": classified["subtitle"],
                "exists": classified["exists"],
                "addedAt": now_hm,
                "addedEpoch": now_epoch,
            }
            items = [new_entry, *filtered][:MAX_SHELF_ITEMS]
            last_added = new_entry

        _write_shelf_unlocked(target, items)

    return {
        "ok": True,
        "item": last_added,
        "count": len(items),
        "items": items,
    }


def shelf_add(raw_input: str, shelf_file: Path | None = None) -> dict[str, Any]:
    return shelf_add_many([raw_input], shelf_file=shelf_file)


def _cleanup_note_file(shelf_file: Path, item_id: str) -> None:
    if not SHELF_ID_RE.match(item_id):
        return
    note_file = _notes_dir(shelf_file) / f"{item_id}.txt"
    try:
        note_file.unlink(missing_ok=True)
    except OSError:
        pass


def shelf_remove(item_id: str, shelf_file: Path | None = None) -> dict[str, Any]:
    sid = (item_id or "").strip()
    if not sid or not SHELF_ID_RE.match(sid):
        return {"ok": False, "error": "invalid_id"}

    target = shelf_file if shelf_file is not None else _shelf_path()
    with _ShelfLock(target):
        items = _read_shelf_unlocked(target)
        remaining = [it for it in items if it["id"] != sid]
        removed = len(remaining) != len(items)
        if removed:
            _write_shelf_unlocked(target, remaining)
            _cleanup_note_file(target, sid)

    return {
        "ok": True,
        "removedId": sid,
        "removed": removed,
        "count": len(remaining),
        "items": remaining,
    }


def shelf_clear(shelf_file: Path | None = None) -> dict[str, Any]:
    target = shelf_file if shelf_file is not None else _shelf_path()
    with _ShelfLock(target):
        _write_shelf_unlocked(target, [])
        ndir = _notes_dir(target)
        if ndir.is_dir():
            for child in ndir.glob("*.txt"):
                try:
                    child.unlink(missing_ok=True)
                except OSError:
                    pass

    return {
        "ok": True,
        "count": 0,
        "items": [],
    }


def shelf_open(item_id: str, shelf_file: Path | None = None) -> dict[str, Any]:
    sid = (item_id or "").strip()
    if not sid or not SHELF_ID_RE.match(sid):
        return {"ok": False, "error": "invalid_id"}

    target_shelf = shelf_file if shelf_file is not None else _shelf_path()
    items = _read_shelf_unlocked(target_shelf)
    found = next((it for it in items if it["id"] == sid), None)
    if found is None:
        return {"ok": False, "error": "not_found"}

    kind = found["kind"]
    val = found["value"]
    open_target = ""

    if kind in ("file", "dir"):
        p = Path(val).expanduser()
        if not p.exists():
            return {"ok": False, "error": "file_missing", "path": str(p)}
        open_target = str(p.resolve())
    elif kind == "url":
        parsed = urlparse(val)
        if parsed.scheme not in ("http", "https"):
            return {"ok": False, "error": "unsupported_scheme"}
        open_target = val
    else:
        # Text snippet: if it is a safe http(s) URL, open directly; otherwise open via temp .txt file.
        if val.startswith(("http://", "https://")) and "\n" not in val and " " not in val:
            open_target = val
        else:
            ndir = _notes_dir(target_shelf)
            ndir.mkdir(parents=True, exist_ok=True, mode=0o700)
            note_path = ndir / f"{sid}.txt"
            fd = os.open(str(note_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(val)
            open_target = str(note_path.resolve())

    ok, err = _spawn_detached(["xdg-open", open_target])
    if not ok:
        return {"ok": False, "id": sid, "error": err}
    return {"ok": True, "id": sid, "target": open_target}


def shelf_copy(item_id: str, shelf_file: Path | None = None) -> dict[str, Any]:
    sid = (item_id or "").strip()
    if not sid or not SHELF_ID_RE.match(sid):
        return {"ok": False, "error": "invalid_id"}

    target_shelf = shelf_file if shelf_file is not None else _shelf_path()
    items = _read_shelf_unlocked(target_shelf)
    found = next((it for it in items if it["id"] == sid), None)
    if found is None:
        return {"ok": False, "error": "not_found"}

    text_val = found["value"]
    env = _augmented_env()

    if _which("qdbus6", env=env):
        rc, _, _ = _run_cmd(
            [
                "qdbus6",
                "--",
                "org.kde.klipper",
                "/klipper",
                "org.kde.klipper.klipper.setClipboardContents",
                text_val,
            ],
            timeout=2.0,
        )
        if rc == 0:
            return {"ok": True, "id": sid, "backend": "klipper"}

    if _which("wl-copy", env=env):
        try:
            subprocess.run(
                [_which("wl-copy", env=env) or "wl-copy"],
                input=text_val,
                text=True,
                timeout=2.0,
                env=env,
                check=True,
            )
            return {"ok": True, "id": sid, "backend": "wl-copy"}
        except (OSError, subprocess.SubprocessError):
            pass

    if _which("xclip", env=env):
        try:
            subprocess.run(
                [_which("xclip", env=env) or "xclip", "-selection", "clipboard"],
                input=text_val,
                text=True,
                timeout=2.0,
                env=env,
                check=True,
            )
            return {"ok": True, "id": sid, "backend": "xclip"}
        except (OSError, subprocess.SubprocessError):
            pass

    return {"ok": False, "id": sid, "error": "no_clipboard_backend"}


# ---------------------------------------------------------------------------
# 5. System Load (CPU %, CPU °C, RAM %, GPU %, GPU °C, Disk %)
# ---------------------------------------------------------------------------

def _cache_dir() -> Path:
    cache_override = os.environ.get("PLASMA_QUOTA_ISLAND_CACHE_DIR", "").strip()
    if cache_override:
        return Path(cache_override).expanduser()
    xdg_cache = os.environ.get("XDG_CACHE_HOME", "").strip()
    base = Path(xdg_cache).expanduser() if xdg_cache else (Path.home() / ".cache")
    return _default_cache_dir(base)


def _read_json_cache(filename: str) -> dict[str, Any] | None:
    path = _cache_dir() / filename
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _write_json_cache(filename: str, payload: dict[str, Any]) -> None:
    cdir = _cache_dir()
    try:
        cdir.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = cdir / filename
        # Arka plan yenileyicileri eşzamanlı yazabilir; süreç başına ayrı geçici dosya.
        tmp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, ensure_ascii=False))
        os.replace(str(tmp), str(target))
    except OSError:
        pass


def _read_cpu_jiffies() -> tuple[int, int] | None:
    try:
        first_line = Path("/proc/stat").read_text(encoding="utf-8").splitlines()[0]
        parts = [int(x) for x in first_line.split()[1:9]]
        if len(parts) < 4:
            return None
        idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
        total = sum(parts)
        return total, idle
    except (OSError, ValueError, IndexError):
        return None


def _read_cpu_temp() -> int:
    hwmon_root = Path("/sys/class/hwmon")
    if hwmon_root.is_dir():
        for hw in sorted(hwmon_root.iterdir()):
            try:
                name = (hw / "name").read_text(encoding="utf-8").strip().lower()
            except OSError:
                continue
            if name in ("k10temp", "coretemp", "zenpower", "cpu_thermal", "acpitz"):
                for tin in sorted(hw.glob("temp*_input")):
                    try:
                        milli = int(tin.read_text(encoding="utf-8").strip())
                        if milli > 1000:
                            return max(0, min(130, milli // 1000))
                    except (OSError, ValueError):
                        continue
    return -1


def refresh_gpu_cache() -> dict[str, Any]:
    gpu_pct = -1
    gpu_temp = -1
    gpu_name = ""

    drm_root = Path("/sys/class/drm")
    if drm_root.is_dir():
        for busy_file in sorted(drm_root.glob("card*/device/gpu_busy_percent")):
            try:
                gpu_pct = max(0, min(100, int(busy_file.read_text(encoding="utf-8").strip())))
                break
            except (OSError, ValueError):
                continue

    hwmon_root = Path("/sys/class/hwmon")
    if hwmon_root.is_dir():
        for hw in sorted(hwmon_root.iterdir()):
            try:
                name = (hw / "name").read_text(encoding="utf-8").strip().lower()
            except OSError:
                continue
            if name in ("amdgpu", "nvidia"):
                for tin in sorted(hw.glob("temp*_input")):
                    try:
                        milli = int(tin.read_text(encoding="utf-8").strip())
                        if milli > 1000:
                            gpu_temp = max(0, min(130, milli // 1000))
                            break
                    except (OSError, ValueError):
                        continue

    if gpu_pct < 0 and _which("nvidia-smi"):
        rc, stdout, _ = _run_cmd(
            [
                "nvidia-smi",
                "--query-gpu=utilization.gpu,temperature.gpu,name",
                "--format=csv,noheader,nounits",
            ],
            timeout=3.0,
        )
        if rc == 0 and stdout.strip():
            first = stdout.splitlines()[0]
            cols = [c.strip() for c in first.split(",")]
            if len(cols) >= 1:
                try:
                    gpu_pct = max(0, min(100, int(round(float(cols[0])))))
                except ValueError:
                    pass
            if len(cols) >= 2:
                try:
                    gpu_temp = max(0, min(130, int(round(float(cols[1])))))
                except ValueError:
                    pass
            if len(cols) >= 3:
                gpu_name = cols[2]

    payload = {
        "updatedEpoch": time.time(),
        "gpuPct": gpu_pct,
        "gpuTemp": gpu_temp,
        "gpuName": gpu_name,
    }
    _write_json_cache("gpu_cache.json", payload)
    return payload


def get_sysload_status() -> dict[str, Any]:
    # 1. CPU % via cached /proc/stat delta (zero sleep in fast path)
    cpu_pct = 0
    jiffies = _read_cpu_jiffies()
    now_ts = time.time()
    if jiffies is not None:
        total, idle = jiffies
        prev = _read_json_cache("cpu_stat.json")
        _write_json_cache("cpu_stat.json", {"ts": now_ts, "total": total, "idle": idle})
        if prev and isinstance(prev.get("total"), int) and isinstance(prev.get("idle"), int):
            dt_total = total - int(prev["total"])
            dt_idle = idle - int(prev["idle"])
            if dt_total > 0:
                cpu_pct = max(0, min(100, int(round((dt_total - dt_idle) * 100.0 / dt_total))))

    cpu_temp = _read_cpu_temp()

    # 2. RAM % and GB from /proc/meminfo
    ram_pct = 0
    ram_used_gb = 0.0
    ram_total_gb = 0.0
    try:
        mem_kb: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            num = v.strip().split()[0]
            mem_kb[k.strip()] = int(num)
        total_kb = mem_kb.get("MemTotal", 0)
        avail_kb = mem_kb.get("MemAvailable", mem_kb.get("MemFree", 0))
        if total_kb > 0:
            used_kb = max(0, total_kb - avail_kb)
            ram_pct = max(0, min(100, int(round(used_kb * 100.0 / total_kb))))
            ram_used_gb = round(used_kb / (1024.0 * 1024.0), 1)
            ram_total_gb = round(total_kb / (1024.0 * 1024.0), 1)
    except (OSError, ValueError, IndexError):
        pass

    # 3. GPU % & °C (fast sysfs first, or cached nvidia-smi with detached refresh)
    gpu_pct = -1
    gpu_temp = -1
    gpu_name = ""
    drm_root = Path("/sys/class/drm")
    if drm_root.is_dir():
        for busy_file in sorted(drm_root.glob("card*/device/gpu_busy_percent")):
            try:
                gpu_pct = max(0, min(100, int(busy_file.read_text(encoding="utf-8").strip())))
                break
            except (OSError, ValueError):
                continue

    gpu_cached = _read_json_cache("gpu_cache.json")
    if gpu_cached is not None:
        if gpu_pct < 0 and isinstance(gpu_cached.get("gpuPct"), int):
            gpu_pct = int(gpu_cached["gpuPct"])
        if isinstance(gpu_cached.get("gpuTemp"), int):
            gpu_temp = int(gpu_cached["gpuTemp"])
        if isinstance(gpu_cached.get("gpuName"), str):
            gpu_name = str(gpu_cached["gpuName"])
        age = now_ts - float(gpu_cached.get("updatedEpoch") or 0.0)
        if age > 5.0:
            _spawn_detached([sys.executable, str(Path(__file__).resolve()), "gpu-refresh"])
    else:
        _spawn_detached([sys.executable, str(Path(__file__).resolve()), "gpu-refresh"])

    # 4. Disk / %
    disk_pct = 0
    disk_used_gb = 0.0
    disk_total_gb = 0.0
    try:
        st = os.statvfs("/")
        total_b = st.f_blocks * st.f_frsize
        avail_b = st.f_bavail * st.f_frsize
        if total_b > 0:
            used_b = max(0, total_b - avail_b)
            disk_pct = max(0, min(100, int(round(used_b * 100.0 / total_b))))
            disk_used_gb = round(used_b / (1024.0 ** 3), 1)
            disk_total_gb = round(total_b / (1024.0 ** 3), 1)
    except OSError:
        pass

    return {
        "available": True,
        "cpuPct": cpu_pct,
        "cpuTemp": cpu_temp,
        "ramPct": ram_pct,
        "ramUsedGb": ram_used_gb,
        "ramTotalGb": ram_total_gb,
        "gpuPct": gpu_pct,
        "gpuTemp": gpu_temp,
        "gpuName": gpu_name,
        "diskPct": disk_pct,
        "diskUsedGb": disk_used_gb,
        "diskTotalGb": disk_total_gb,
    }


# ---------------------------------------------------------------------------
# 6. Weather (Open-Meteo Current + 7-Day Forecast)
# ---------------------------------------------------------------------------

def _wmo_to_key_and_icon(code: int, is_day: bool = True) -> tuple[str, str]:
    # Açıklama çevrilebilir anahtar olarak döner; metni QML (DashClock.weatherText) i18n ile üretir.
    if code == 0:
        return "clear", ("weather-clear-symbolic" if is_day else "weather-clear-night-symbolic")
    if code in (1, 2):
        return "partly_cloudy", ("weather-few-clouds-symbolic" if is_day else "weather-few-clouds-night-symbolic")
    if code == 3:
        return "cloudy", "weather-overcast-symbolic"
    if code in (45, 48):
        return "fog", "weather-fog-symbolic"
    if code in (51, 53, 55, 56, 57):
        return "drizzle", "weather-showers-scattered-symbolic"
    if code in (61, 63, 65, 66, 67, 80, 81, 82):
        return "rain", "weather-showers-symbolic"
    if code in (71, 73, 75, 77, 85, 86):
        return "snow", "weather-snow-symbolic"
    if code in (95, 96, 99):
        return "storm", "weather-storm-symbolic"
    return "cloudy", "weather-few-clouds-symbolic"


WEATHER_MODES: tuple[str, ...] = ("off", "manual", "ip")


def parse_weather_opts(args: list[str]) -> dict[str, Any]:
    """`--weather off|manual|ip --city X --lat Y --lon Z` bayraklarını ayrıştırır (varsayılan: kapalı)."""
    opts: dict[str, Any] = {"mode": "off", "city": "", "lat": None, "lon": None}
    i = 0
    while i < len(args) - 1:
        key, val = args[i], args[i + 1]
        if key == "--weather" and val in WEATHER_MODES:
            opts["mode"] = val
        elif key == "--city":
            opts["city"] = val.strip()[:80]
        elif key in ("--lat", "--lon"):
            try:
                num = float(val)
            except ValueError:
                num = None
            limit = 90.0 if key == "--lat" else 180.0
            if num is not None and -limit <= num <= limit:
                opts[key[2:]] = num
        else:
            i += 1
            continue
        i += 2
    return opts


def _weather_loc_key(opts: dict[str, Any]) -> str:
    if opts["mode"] == "ip":
        return "ip"
    if opts["lat"] is not None and opts["lon"] is not None:
        return f"coord:{opts['lat']:.4f},{opts['lon']:.4f}"
    return "city:" + opts["city"].lower()


def _empty_weather(desc: str, city: str = "", enabled: bool = True) -> dict[str, Any]:
    return {
        "enabled": enabled,
        "available": False,
        "city": city,
        "temp": 0,
        "feelsLike": 0,
        "humidity": 0,
        "wind": 0,
        "pressure": 0,
        "code": 0,
        "isDay": True,
        "desc": desc,
        "icon": "weather-few-clouds-symbolic",
        "daily": [],
    }


def _resolve_weather_location(opts: dict[str, Any]) -> tuple[float, float, str] | None:
    """Konumu yalnız kullanıcı ayarından çözer; IP konumu (ipwho.is) yalnız mode == 'ip' iken."""
    city = opts["city"]
    if opts["mode"] == "manual" and opts["lat"] is not None and opts["lon"] is not None:
        return float(opts["lat"]), float(opts["lon"]), city

    key = _weather_loc_key(opts)
    loc_cache = _read_json_cache("weather_loc.json")
    cached_ok = bool(
        loc_cache
        and loc_cache.get("key") == key
        and isinstance(loc_cache.get("lat"), (int, float))
        and isinstance(loc_cache.get("lon"), (int, float))
    )
    if cached_ok and (time.time() - float(loc_cache.get("ts") or 0)) < 43200:
        return float(loc_cache["lat"]), float(loc_cache["lon"]), str(loc_cache.get("city") or city)

    try:
        if opts["mode"] == "ip":
            req = Request("https://ipwho.is/", headers={"User-Agent": "plasma-quota-island/1.0"})
            with urlopen(req, timeout=2.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            if data.get("success") is not False and data.get("latitude") is not None and data.get("longitude") is not None:
                found = (float(data["latitude"]), float(data["longitude"]), str(data.get("city") or "").strip())
            else:
                found = None
        elif city:
            # Şehir adı Open-Meteo geocoding ile koordinata çevrilir (hava durumu da aynı sağlayıcıdan).
            url = "https://geocoding-api.open-meteo.com/v1/search?count=1&format=json&name=" + quote(city)
            req = Request(url, headers={"User-Agent": "plasma-quota-island/1.0"})
            with urlopen(req, timeout=3.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            hits = data.get("results") if isinstance(data, dict) else None
            if isinstance(hits, list) and hits and isinstance(hits[0], dict):
                hit = hits[0]
                found = (float(hit["latitude"]), float(hit["longitude"]), str(hit.get("name") or city))
            else:
                found = None
        else:
            found = None
        if found is not None:
            _write_json_cache("weather_loc.json", {"key": key, "ts": time.time(), "lat": found[0], "lon": found[1], "city": found[2]})
            return found
    except Exception:
        pass

    if cached_ok:
        return float(loc_cache["lat"]), float(loc_cache["lon"]), str(loc_cache.get("city") or city)
    return None


def fetch_weather_live(opts: dict[str, Any]) -> dict[str, Any]:
    if opts["mode"] == "off":
        return _empty_weather("", enabled=False)
    loc = _resolve_weather_location(opts)
    if loc is None:
        return _empty_weather("no_location", opts["city"])
    lat, lon, city = loc
    url = (
        f"https://api.open-meteo.com/v1/forecast?latitude={lat:.4f}&longitude={lon:.4f}"
        "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,surface_pressure,is_day"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        "&timezone=auto&wind_speed_unit=kmh"
    )
    try:
        req = Request(url, headers={"User-Agent": "plasma-quota-island/1.0"})
        with urlopen(req, timeout=3.5) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except Exception:
        cached = _read_json_cache("weather_cache.json")
        if cached and cached.get("available") and cached.get("locKey") == _weather_loc_key(opts):
            return cached
        return _empty_weather("offline", city)

    cur = raw.get("current") if isinstance(raw, dict) else {}
    if not isinstance(cur, dict):
        cur = {}

    temp = int(round(float(cur.get("temperature_2m") or 0.0)))
    feels = int(round(float(cur.get("apparent_temperature") or temp)))
    humidity = int(round(float(cur.get("relative_humidity_2m") or 0.0)))
    wind = int(round(float(cur.get("wind_speed_10m") or 0.0)))
    pressure = int(round(float(cur.get("surface_pressure") or 1013.0)))
    wcode = int(cur.get("weather_code") or 0)
    is_day = bool(int(cur.get("is_day", 1)))
    desc, icon = _wmo_to_key_and_icon(wcode, is_day=is_day)

    daily_raw = raw.get("daily") if isinstance(raw, dict) else {}
    daily_list: list[dict[str, Any]] = []
    if isinstance(daily_raw, dict):
        times = daily_raw.get("time") or []
        codes = daily_raw.get("weather_code") or []
        maxs = daily_raw.get("temperature_2m_max") or []
        mins = daily_raw.get("temperature_2m_min") or []
        count = min(7, len(times), len(codes), len(maxs), len(mins))
        for idx in range(count):
            t_str = str(times[idx])
            try:
                d_obj = dt.date.fromisoformat(t_str)
                # Gün adı QML'de yerel ayara göre üretilir; dow Qt düzeninde (0 = Pazar).
                day_label = "today" if idx == 0 else ""
                dow = (d_obj.weekday() + 1) % 7
                date_short = d_obj.strftime("%d.%m")
            except ValueError:
                day_label = t_str[-5:]
                date_short = t_str[-5:]
                dow = None
            c_int = int(codes[idx] or 0)
            d_desc, d_icon = _wmo_to_key_and_icon(c_int, is_day=True)
            daily_list.append({
                "day": day_label,
                "dow": dow,
                "date": date_short,
                "min": int(round(float(mins[idx] or 0.0))),
                "max": int(round(float(maxs[idx] or 0.0))),
                "code": c_int,
                "desc": d_desc,
                "icon": d_icon,
            })

    payload: dict[str, Any] = {
        "enabled": True,
        "locKey": _weather_loc_key(opts),
        "available": True,
        "updatedEpoch": time.time(),
        "city": city,
        "temp": temp,
        "feelsLike": feels,
        "humidity": humidity,
        "wind": wind,
        "pressure": pressure,
        "code": wcode,
        "isDay": is_day,
        "desc": desc,
        "icon": icon,
        "daily": daily_list,
    }
    _write_json_cache("weather_cache.json", payload)
    return payload


def _weather_refresh_argv(opts: dict[str, Any]) -> list[str]:
    argv = [sys.executable, str(Path(__file__).resolve()), "weather-refresh", "--weather", opts["mode"], "--city", opts["city"]]
    if opts["lat"] is not None and opts["lon"] is not None:
        argv += ["--lat", str(opts["lat"]), "--lon", str(opts["lon"])]
    return argv


def get_weather_status(opts: dict[str, Any] | None = None) -> dict[str, Any]:
    opts = opts or parse_weather_opts([])
    if opts["mode"] == "off":
        # Kapalıyken hiçbir ağ isteği yapılmaz.
        return _empty_weather("", enabled=False)
    cached = _read_json_cache("weather_cache.json")
    if cached is not None and cached.get("available") and cached.get("locKey") == _weather_loc_key(opts):
        age = time.time() - float(cached.get("updatedEpoch") or 0.0)
        if age > 900.0:
            _spawn_detached(_weather_refresh_argv(opts))
        return cached

    _spawn_detached(_weather_refresh_argv(opts))
    return _empty_weather("loading", opts["city"])


# ---------------------------------------------------------------------------
# 7. Network (Wi-Fi / Wired Ethernet) & Bluetooth Toggle
# ---------------------------------------------------------------------------

def refresh_network_cache() -> dict[str, Any]:
    wired_on = False
    wired_name = ""
    wifi_on = False
    wifi_ssid = ""
    wifi_quality = 0

    net_root = Path("/sys/class/net")
    if net_root.is_dir():
        for iface_dir in sorted(net_root.iterdir()):
            iname = iface_dir.name
            if iname == "lo" or iname.startswith(("docker", "br-", "veth", "virbr", "tailscale", "tun", "wg", "p2p")):
                continue
            is_wireless = (iface_dir / "wireless").is_dir() or (iface_dir / "phy80211").is_dir()
            if not is_wireless:
                try:
                    carrier = (iface_dir / "carrier").read_text(encoding="utf-8").strip()
                    if carrier == "1":
                        wired_on = True
                        wired_name = iname
                except OSError:
                    pass

    try:
        for line in Path("/proc/net/wireless").read_text(encoding="utf-8").splitlines()[2:]:
            if ":" not in line:
                continue
            _, rest = line.split(":", 1)
            cols = rest.split()
            if len(cols) >= 2:
                link_val = float(cols[1].rstrip("."))
                wifi_quality = max(0, min(100, int(round(link_val * 100.0 / 70.0)) if link_val <= 70 else int(round(link_val))))
                break
    except (OSError, ValueError):
        pass

    if _which("nmcli"):
        rc_w, out_w, _ = _run_cmd(["nmcli", "-t", "-f", "WIFI", "general"], timeout=1.5)
        if rc_w == 0:
            wifi_on = out_w.strip().lower() == "enabled"

        rc_d, out_d, _ = _run_cmd(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev", "status"], timeout=1.5)
        if rc_d == 0:
            for raw_line in out_d.splitlines():
                parts = raw_line.split(":", 3)
                if len(parts) < 4:
                    continue
                _dev, dev_type, state, conn = parts
                if dev_type == "wifi" and state == "connected" and conn:
                    wifi_ssid = conn.strip()
                    wifi_on = True
                elif dev_type == "ethernet" and state == "connected":
                    wired_on = True
                    if conn.strip():
                        wired_name = conn.strip()

    payload = {
        "updatedEpoch": time.time(),
        "nmcli": _which("nmcli") is not None,
        "wiredOn": wired_on,
        "wiredName": wired_name,
        "wifiOn": wifi_on,
        "wifiSsid": wifi_ssid,
        "wifiQuality": wifi_quality if wifi_ssid else 0,
    }
    _write_json_cache("net_cache.json", payload)
    return payload


def get_network_status() -> dict[str, Any]:
    cached = _read_json_cache("net_cache.json")
    now_ts = time.time()
    if cached is not None and "wifiOn" in cached:
        age = now_ts - float(cached.get("updatedEpoch") or 0.0)
        if age > 4.0:
            _spawn_detached([sys.executable, str(Path(__file__).resolve()), "net-refresh"])
        return cached

    _spawn_detached([sys.executable, str(Path(__file__).resolve()), "net-refresh"])
    # Fast synchronous sysfs fallback when cache is cold
    wired_on = False
    wifi_quality = 0
    try:
        for line in Path("/proc/net/wireless").read_text(encoding="utf-8").splitlines()[2:]:
            if ":" in line:
                cols = line.split(":", 1)[1].split()
                if len(cols) >= 2:
                    link_val = float(cols[1].rstrip("."))
                    wifi_quality = max(0, min(100, int(round(link_val * 100.0 / 70.0))))
                    break
    except (OSError, ValueError):
        pass
    return {
        "nmcli": _which("nmcli") is not None,
        "wiredOn": wired_on,
        "wiredName": "",
        "wifiOn": wifi_quality > 0,
        "wifiSsid": "Wi-Fi" if wifi_quality > 0 else "",
        "wifiQuality": wifi_quality,
    }


def toggle_wifi(state: str = "") -> dict[str, Any]:
    target = state.strip().lower()
    if target not in ("on", "off"):
        cur = refresh_network_cache()
        target = "off" if cur.get("wifiOn") else "on"
    rc, _, stderr = _run_cmd(["nmcli", "radio", "wifi", target], timeout=3.0)
    if rc != 0:
        return {"ok": False, "wifiOn": target == "on", "error": stderr.strip() or f"exit_{rc}"}
    updated = refresh_network_cache()
    updated["wifiOn"] = target == "on"
    if target == "off":
        updated["wifiSsid"] = ""
        updated["wifiQuality"] = 0
    _write_json_cache("net_cache.json", updated)
    return {"ok": True, **updated}


def toggle_bluetooth(state: str = "") -> dict[str, Any]:
    target = state.strip().lower()
    if target not in ("on", "off"):
        rc_s, out_s, _ = _run_cmd(["bluetoothctl", "show"], timeout=2.0)
        powered = "powered: yes" in out_s.lower() if rc_s == 0 else False
        target = "off" if powered else "on"
    rc, _, stderr = _run_cmd(["bluetoothctl", "power", target], timeout=3.0)
    if rc != 0:
        return {"ok": False, "powered": target == "on", "error": stderr.strip() or f"exit_{rc}"}
    return {"ok": True, "powered": target == "on"}


# ---------------------------------------------------------------------------
# 8. DND (Rahatsız Etme), Coffee Mode (Uyanık Tut) & Power Menu
# ---------------------------------------------------------------------------

def _pid_file(name: str) -> Path:
    return _cache_dir() / f"{name}.pid"


def _is_pid_alive(pid_path: Path) -> int | None:
    if not pid_path.is_file():
        return None
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
        if pid <= 1:
            return None
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        try:
            pid_path.unlink(missing_ok=True)
        except OSError:
            pass
        return None


def _kill_pid_file(pid_path: Path) -> bool:
    pid = _is_pid_alive(pid_path)
    if pid is None:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        pid_path.unlink(missing_ok=True)
    except OSError:
        pass
    return True


def _run_dnd_hold_daemon() -> int:
    pid_path = _pid_file("dnd_inhibit")
    pid_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    pid_path.write_text(str(os.getpid()), encoding="utf-8")
    try:
        from gi.repository import Gio, GLib  # type: ignore

        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        res = bus.call_sync(
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "Inhibit",
            GLib.Variant("(ssa{sv})", ("org.kde.plasmashell", "Quota Island Do Not Disturb", {})),
            GLib.VariantType("(u)"),
            Gio.DBusCallFlags.NONE,
            2500,
            None,
        )
        cookie = res.unpack()[0]

        def _cleanup(*_args: Any) -> None:
            try:
                bus.call_sync(
                    "org.freedesktop.Notifications",
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                    "UnInhibit",
                    GLib.Variant("(u)", (cookie,)),
                    None,
                    Gio.DBusCallFlags.NONE,
                    1500,
                    None,
                )
            except Exception:
                pass
            try:
                pid_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, _cleanup)
        signal.signal(signal.SIGINT, _cleanup)
        while True:
            time.sleep(3600)
    except Exception:
        try:
            pid_path.unlink(missing_ok=True)
        except OSError:
            pass
        return 1


def _run_coffee_hold_daemon() -> int:
    pid_path = _pid_file("coffee_inhibit")
    pid_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    pid_path.write_text(str(os.getpid()), encoding="utf-8")
    try:
        from gi.repository import Gio, GLib  # type: ignore

        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        res = bus.call_sync(
            "org.freedesktop.ScreenSaver",
            "/ScreenSaver",
            "org.freedesktop.ScreenSaver",
            "Inhibit",
            GLib.Variant("(ss)", ("Quota Island", "Keep Awake (Coffee Mode)")),
            GLib.VariantType("(u)"),
            Gio.DBusCallFlags.NONE,
            2500,
            None,
        )
        cookie = res.unpack()[0]

        def _cleanup(*_args: Any) -> None:
            try:
                bus.call_sync(
                    "org.freedesktop.ScreenSaver",
                    "/ScreenSaver",
                    "org.freedesktop.ScreenSaver",
                    "UnInhibit",
                    GLib.Variant("(u)", (cookie,)),
                    None,
                    Gio.DBusCallFlags.NONE,
                    1500,
                    None,
                )
            except Exception:
                pass
            try:
                pid_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, _cleanup)
        signal.signal(signal.SIGINT, _cleanup)
        while True:
            time.sleep(3600)
    except Exception:
        try:
            pid_path.unlink(missing_ok=True)
        except OSError:
            pass
        return 1


def get_toggles_status() -> dict[str, Any]:
    dnd_on = _is_pid_alive(_pid_file("dnd_inhibit")) is not None
    coffee_on = _is_pid_alive(_pid_file("coffee_inhibit")) is not None
    return {
        "dndActive": dnd_on,
        "coffeeActive": coffee_on,
    }


def toggle_dnd(state: str = "") -> dict[str, Any]:
    pid_path = _pid_file("dnd_inhibit")
    currently_on = _is_pid_alive(pid_path) is not None
    want_on = (state.strip().lower() == "on") if state.strip().lower() in ("on", "off") else (not currently_on)
    if not want_on:
        _kill_pid_file(pid_path)
        return {"ok": True, "dndActive": False}
    if not currently_on:
        _spawn_detached([sys.executable, str(Path(__file__).resolve()), "_dnd-daemon"])
        time.sleep(0.08)
    return {"ok": True, "dndActive": True}


def toggle_coffee(state: str = "") -> dict[str, Any]:
    pid_path = _pid_file("coffee_inhibit")
    currently_on = _is_pid_alive(pid_path) is not None
    want_on = (state.strip().lower() == "on") if state.strip().lower() in ("on", "off") else (not currently_on)
    if not want_on:
        _kill_pid_file(pid_path)
        return {"ok": True, "coffeeActive": False}
    if not currently_on:
        _spawn_detached([sys.executable, str(Path(__file__).resolve()), "_coffee-daemon"])
        time.sleep(0.08)
    return {"ok": True, "coffeeActive": True}


def run_power_action(action: str) -> dict[str, Any]:
    act = (action or "").strip().lower()
    if act not in VALID_POWER_ACTIONS:
        return {"ok": False, "error": "invalid_power_action"}

    if act == "lock":
        rc, _, stderr = _run_cmd(["loginctl", "lock-session"], timeout=3.0)
        if rc != 0:
            rc, _, stderr = _run_cmd(
                ["qdbus6", "org.freedesktop.ScreenSaver", "/ScreenSaver", "Lock"],
                timeout=3.0,
            )
        return {"ok": rc == 0, "action": act, "error": "" if rc == 0 else (stderr.strip() or f"exit_{rc}")}

    if act == "sleep":
        rc, _, stderr = _run_cmd(["systemctl", "suspend"], timeout=3.0)
        return {"ok": rc == 0, "action": act, "error": "" if rc == 0 else (stderr.strip() or f"exit_{rc}")}

    if act == "logout":
        rc, _, stderr = _run_cmd(["qdbus6", "org.kde.Shutdown", "/Shutdown", "logout"], timeout=3.0)
        if rc != 0:
            user = os.environ.get("USER", "").strip()
            if user:
                rc, _, stderr = _run_cmd(["loginctl", "terminate-user", user], timeout=3.0)
        return {"ok": rc == 0, "action": act, "error": "" if rc == 0 else (stderr.strip() or f"exit_{rc}")}

    if act == "reboot":
        rc, _, stderr = _run_cmd(["systemctl", "reboot"], timeout=3.0)
        return {"ok": rc == 0, "action": act, "error": "" if rc == 0 else (stderr.strip() or f"exit_{rc}")}

    if act == "poweroff":
        rc, _, stderr = _run_cmd(["systemctl", "poweroff"], timeout=3.0)
        return {"ok": rc == 0, "action": act, "error": "" if rc == 0 else (stderr.strip() or f"exit_{rc}")}

    return {"ok": False, "error": "invalid_power_action"}


# ---------------------------------------------------------------------------
# Aggregated Status & CLI Entrypoint
# ---------------------------------------------------------------------------

def build_full_status(args: list[str] | None = None) -> dict[str, Any]:
    """args: status bayrakları (--no-herdr, --no-houra, --weather ... )."""
    args = list(args or [])
    defaults: dict[str, dict[str, Any]] = {
        "herdr": {
            "installed": False,
            "available": False,
            "workingCount": 0,
            "blockedCount": 0,
            "doneCount": 0,
            "totalCount": 0,
            "agents": [],
        },
        "houra": {
            "installed": False,
            "available": False,
            "completedSessions": 0,
            "focusMinutes": 0,
            "focusSeconds": 0,
            "pendingTodos": 0,
            "completedTodos": 0,
            "activeSession": None,
            "topTodos": [],
        },
        "power": {
            "available": False,
            "profile": "balanced",
            "profiles": list(VALID_POWER_PROFILES),
        },
        "battery": {
            "available": False,
            "percentage": -1,
            "state": "",
            "charging": False,
            "pluggedIn": False,
            "timeRemaining": "",
        },
        "bluetooth": {
            "available": False,
            "connected": False,
            "name": "",
            "mac": "",
            "isAudio": False,
            "battery": -1,
            "devices": [],
        },
        "shelf": {
            "count": 0,
            "items": [],
        },
        "sysload": {
            "available": False,
            "cpuPct": 0,
            "cpuTemp": -1,
            "ramPct": 0,
            "ramUsedGb": 0.0,
            "ramTotalGb": 0.0,
            "gpuPct": -1,
            "gpuTemp": -1,
            "gpuName": "",
            "diskPct": 0,
            "diskUsedGb": 0.0,
            "diskTotalGb": 0.0,
        },
        "weather": _empty_weather("", enabled=False),
        "network": {
            "nmcli": False,
            "wiredOn": False,
            "wiredName": "",
            "wifiOn": False,
            "wifiSsid": "",
            "wifiQuality": 0,
        },
        "toggles": {
            "dndActive": False,
            "coffeeActive": False,
        },
    }
    weather_opts = parse_weather_opts(args)
    probes = {
        "herdr": get_herdr_status,
        "houra": get_houra_summary,
        "power": get_power_status,
        "battery": get_battery_status,
        "bluetooth": get_bluetooth_status,
        "shelf": get_shelf_status,
        "sysload": get_sysload_status,
        "weather": lambda: get_weather_status(weather_opts),
        "network": get_network_status,
        "toggles": get_toggles_status,
    }
    # Ayarlarda kapatılan entegrasyonlar hiç yoklanmaz (komut/DB erişimi yok).
    if "--no-herdr" in args:
        probes.pop("herdr")
    if "--no-houra" in args:
        probes.pop("houra")
    results: dict[str, Any] = {key: defaults[key] for key in ("herdr", "houra") if key not in probes}
    with ThreadPoolExecutor(max_workers=len(probes)) as pool:
        futures = {key: pool.submit(fn) for key, fn in probes.items()}
        for key, fut in futures.items():
            try:
                results[key] = fut.result()
            except Exception:
                results[key] = defaults[key]

    return {
        "updatedAt": dt.datetime.now().strftime("%H:%M"),
        "herdr": results["herdr"],
        "houra": results["houra"],
        "power": results["power"],
        "battery": results["battery"],
        "bluetooth": results["bluetooth"],
        "shelf": results["shelf"],
        "sysload": results["sysload"],
        "weather": results["weather"],
        "network": results["network"],
        "toggles": results["toggles"],
    }


def _emit(payload: dict[str, Any]) -> int:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    if payload.get("ok") is False:
        return 1
    return 0


DIAG_TOOLS: tuple[str, ...] = ("wpctl", "pactl", "hc", "herdr-app", "powerprofilesctl", "upower", "bluetoothctl", "nmcli")


def get_diagnostics() -> dict[str, Any]:
    """İsteğe bağlı araç ve kimliklerin yalnız var/yok durumu; yol, belirteç veya içerik dönmez."""
    env = _augmented_env()
    creds: dict[str, bool] = {}
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import island_ctl  # kimlik okuyucuları tek kaynakta kalsın diye

        creds["claude"] = bool(island_ctl._read_claude_access_token())
        creds["agy"] = bool(island_ctl._lookup_agy_access_token())
        creds["codex"] = bool(island_ctl._read_codex_credentials()[0])
    except Exception:
        creds = {"claude": False, "agy": False, "codex": False}
    return {
        "ok": True,
        "tools": {name: _which(name, env=env) is not None for name in DIAG_TOOLS},
        "files": {"houraDb": _houra_db_path().is_file()},
        "credentials": creds,
    }


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    cmd = args[0] if args else "status"
    rest = args[1:]

    if cmd == "status":
        return _emit(build_full_status(rest))

    if cmd == "focus-agent":
        if not rest:
            return _emit({"ok": False, "error": "missing_terminal_id"})
        return _emit(focus_herdr_agent(rest[0]))

    if cmd == "set-power":
        if not rest:
            return _emit({"ok": False, "error": "missing_profile"})
        return _emit(set_power_profile(rest[0]))

    if cmd == "diagnostics":
        return _emit(get_diagnostics())

    if cmd == "gpu-refresh":
        return _emit({"ok": True, **refresh_gpu_cache()})

    if cmd == "weather-refresh":
        return _emit({"ok": True, **fetch_weather_live(parse_weather_opts(rest))})

    if cmd == "net-refresh":
        return _emit({"ok": True, **refresh_network_cache()})

    if cmd == "wifi-toggle":
        return _emit(toggle_wifi(rest[0] if rest else ""))

    if cmd == "bt-toggle":
        return _emit(toggle_bluetooth(rest[0] if rest else ""))

    if cmd == "dnd-toggle":
        return _emit(toggle_dnd(rest[0] if rest else ""))

    if cmd == "coffee-toggle":
        return _emit(toggle_coffee(rest[0] if rest else ""))

    if cmd == "_dnd-daemon":
        return _run_dnd_hold_daemon()

    if cmd == "_coffee-daemon":
        return _run_coffee_hold_daemon()

    if cmd == "power-action":
        if not rest:
            return _emit({"ok": False, "error": "missing_action"})
        return _emit(run_power_action(rest[0]))

    if cmd == "shelf-list":
        shelf = get_shelf_status()
        return _emit({"ok": True, **shelf})

    if cmd == "shelf-add":
        if not rest:
            return _emit({"ok": False, "error": "missing_value"})
        if rest[0] == "--":
            if len(rest) < 2:
                return _emit({"ok": False, "error": "missing_value"})
            literal_val = rest[1] if len(rest) == 2 else " ".join(rest[1:])
            return _emit(shelf_add(literal_val))
        if rest[0] == "--batch" and len(rest) > 1:
            return _emit(shelf_add_many(rest[1:]))
        value = rest[0] if len(rest) == 1 else " ".join(rest)
        return _emit(shelf_add(value))

    if cmd == "shelf-remove":
        if not rest:
            return _emit({"ok": False, "error": "missing_id"})
        return _emit(shelf_remove(rest[0]))

    if cmd == "shelf-clear":
        return _emit(shelf_clear())

    if cmd == "shelf-open":
        if not rest:
            return _emit({"ok": False, "error": "missing_id"})
        return _emit(shelf_open(rest[0]))

    if cmd == "shelf-copy":
        if not rest:
            return _emit({"ok": False, "error": "missing_id"})
        return _emit(shelf_copy(rest[0]))

    return _emit({"ok": False, "error": f"unknown_command:{cmd}"})


if __name__ == "__main__":
    raise SystemExit(main())
