#!/usr/bin/env python3
"""Quota Island backend controller (MPRIS2, PipeWire/PulseAudio, Claude/AGY/Codex quotas).

Security policy:
- Never hardcode, log, print, or cache OAuth tokens, emails, or account/organization UUIDs.
- Credentials are read strictly in-memory at runtime from ~/.claude/.credentials.json,
  $CODEX_HOME/auth.json (default ~/.codex) and libsecret.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any
import urllib.error
import urllib.request

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
AGY_MODELS_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
AGY_QUOTA_SUMMARY_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
# openai/codex backend-client: DEFAULT_CHATGPT_BASE_URL + "/wham/usage" (rate_limit_status_url)
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
QUOTA_PROVIDERS = ("claude", "agy", "codex")
# Kendi dürüst istemci kimliğimiz. Claude ucu kabul ediyor (17.11 canlı deneme: HTTP 200).
# AGY ve Codex ucunda denenemedi (AGY kimliği geçersizdi, Codex kimliği yok); orada eski UA kaldı.
QUOTA_USER_AGENT = "plasma-quota-island/1.0"
QUOTA_CACHE_TTL_SEC = 90
# Yedek/önbellek kota verisi en fazla bu kadar eski olabilir; daha eskisi gösterilmez.
QUOTA_STALE_MAX_SEC = 30 * 60
ALLOWED_ART_SCHEMES = ("file://", "https://")
_DBUS_OBJ_PATH_RE = re.compile(r"^/(?:[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*)?$")
_BUS_NAME_RE = re.compile(r"^org\.mpris\.MediaPlayer2\.[A-Za-z0-9_.-]{1,180}$")
_AUDIO_ID_RE = re.compile(r"^[A-Za-z0-9_.:@][A-Za-z0-9_.:@/-]{0,199}$")


CACHE_DIR_NAME = "plasma-quota-island"
LEGACY_CACHE_DIR_NAME = "gruvbox-island"


def _default_cache_dir(base: Path) -> Path:
    """Varsayılan önbellek dizini; eski ~/.cache/gruvbox-island bir kez yeni ada taşınır (raf korunur)."""
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


def get_cache_dir() -> Path:
    override = os.environ.get("PLASMA_QUOTA_ISLAND_CACHE_DIR", "").strip()
    if override:
        path = Path(override).expanduser()
    else:
        xdg = os.environ.get("XDG_CACHE_HOME", "").strip()
        base = Path(xdg).expanduser() if xdg else (Path.home() / ".cache")
        path = _default_cache_dir(base)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def _atomic_write_text(target: Path, content: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    try:
        os.chmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def clamp_int(value: float | int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, int(round(float(value)))))


def sanitize_art_url(raw: Any) -> str:
    if not isinstance(raw, str):
        return ""
    url = raw.strip()
    if url.startswith("https://"):
        return url
    if url.startswith("file:///"):
        return url
    return ""


def validate_bus_name(raw: Any) -> str:
    cleaned = str(raw or "").strip()
    if not cleaned or not _BUS_NAME_RE.match(cleaned):
        raise ValueError("invalid MPRIS2 busName (must start with org.mpris.MediaPlayer2.)")
    return cleaned


def validate_audio_id(raw: Any, label: str = "audioId") -> str:
    cleaned = str(raw or "").strip()
    if not cleaned or cleaned.startswith("-") or not _AUDIO_ID_RE.match(cleaned):
        raise ValueError(f"invalid {label}")
    return cleaned


def parse_iso_utc(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def normalize_iso_utc(raw: Any) -> str:
    dt = parse_iso_utc(raw)
    if dt is None:
        return ""
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def format_reset_in(raw_resets_at: Any, now_utc: datetime | None = None, default_empty: str = "—") -> str:
    dt = parse_iso_utc(raw_resets_at)
    if dt is None:
        return default_empty
    ref = now_utc.astimezone(timezone.utc) if now_utc is not None else datetime.now(timezone.utc)
    delta_sec = max(0, int(round((dt - ref).total_seconds())))
    if delta_sec <= 0:
        return "0m"
    if delta_sec >= 86400:
        days = delta_sec // 86400
        hours = (delta_sec % 86400) // 3600
        return f"{days}d {hours}h"
    if delta_sec >= 3600:
        hours = delta_sec // 3600
        mins = (delta_sec % 3600) // 60
        return f"{hours}h {mins}m"
    mins = max(1, math.ceil(delta_sec / 60))
    return f"{mins}m"


# ---------------------------------------------------------------------------
# MPRIS2 Media Subsystem
# ---------------------------------------------------------------------------

# Tekrar düğmesi döngüsü: kapalı -> liste -> parça -> kapalı.
MPRIS_LOOP_CYCLE: tuple[str, ...] = ("None", "Playlist", "Track")


def next_loop_status(current: str) -> str:
    if current not in MPRIS_LOOP_CYCLE:
        return "None"
    return MPRIS_LOOP_CYCLE[(MPRIS_LOOP_CYCLE.index(current) + 1) % len(MPRIS_LOOP_CYCLE)]


def _empty_media_state() -> dict[str, Any]:
    return {
        "available": False,
        "activePlayer": "",
        "identity": "",
        "playbackStatus": "Stopped",
        "title": "",
        "artist": "",
        "album": "",
        "artUrl": "",
        "lengthSec": 0.0,
        "positionSec": 0.0,
        "canPlay": False,
        "canPause": False,
        "canGoNext": False,
        "canGoPrevious": False,
        "canSeek": False,
        "shuffle": False,
        "loopStatus": "",
        "canShuffle": False,
        "canLoop": False,
        "players": [],
    }


def read_selected_player() -> str:
    sel_file = get_cache_dir() / "selected_player.txt"
    try:
        raw = sel_file.read_text(encoding="utf-8").strip()
        return validate_bus_name(raw) if raw else ""
    except (OSError, ValueError):
        return ""


def write_selected_player(bus_name: str) -> None:
    cleaned = validate_bus_name(bus_name)
    _atomic_write_text(get_cache_dir() / "selected_player.txt", cleaned + "\n")


def _get_session_bus() -> tuple[Any, Any, Any] | None:
    try:
        from gi.repository import Gio, GLib  # type: ignore[import-untyped]
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        return bus, Gio, GLib
    except Exception:
        return None


def _dbus_get_all_props(bus: Any, Gio: Any, GLib: Any, bus_name: str, iface: str) -> dict[str, Any]:
    res = bus.call_sync(
        bus_name,
        "/org/mpris/MediaPlayer2",
        "org.freedesktop.DBus.Properties",
        "GetAll",
        GLib.Variant("(s)", (iface,)),
        GLib.VariantType("(a{sv})"),
        Gio.DBusCallFlags.NONE,
        800,
        None,
    )
    unpacked = res.unpack()
    return dict(unpacked[0]) if unpacked else {}


def _dbus_get_prop(bus: Any, Gio: Any, GLib: Any, bus_name: str, iface: str, prop: str) -> Any:
    res = bus.call_sync(
        bus_name,
        "/org/mpris/MediaPlayer2",
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", (iface, prop)),
        GLib.VariantType("(v)"),
        Gio.DBusCallFlags.NONE,
        800,
        None,
    )
    unpacked = res.unpack()
    return unpacked[0] if unpacked else None


def _humanize_bus_identity(bus_name: str) -> str:
    suffix = bus_name.removeprefix("org.mpris.MediaPlayer2.")
    base = suffix.split(".")[0].replace("_", " ").replace("-", " ").strip()
    return base.capitalize() if base else "Media"


def _extract_artist(meta: dict[str, Any]) -> str:
    for key in ("xesam:artist", "xesam:albumArtist"):
        raw = meta.get(key)
        if isinstance(raw, list):
            joined = ", ".join(str(x).strip() for x in raw if str(x).strip())
            if joined:
                return joined
        elif isinstance(raw, str) and raw.strip():
            return raw.strip()
    return ""


def _normalize_player_snapshot(bus_name: str, root_props: dict[str, Any], player_props: dict[str, Any]) -> dict[str, Any]:
    meta_raw = player_props.get("Metadata")
    meta: dict[str, Any] = dict(meta_raw) if isinstance(meta_raw, dict) else {}

    identity = str(root_props.get("Identity") or "").strip() or _humanize_bus_identity(bus_name)
    playback_status = str(player_props.get("PlaybackStatus") or "Stopped").strip()
    if playback_status not in ("Playing", "Paused", "Stopped"):
        playback_status = "Stopped"

    length_us = meta.get("mpris:length", 0)
    try:
        length_sec = round(max(0.0, float(length_us) / 1_000_000.0), 2)
    except (TypeError, ValueError):
        length_sec = 0.0

    pos_us = player_props.get("Position", 0)
    try:
        position_sec = round(max(0.0, float(pos_us) / 1_000_000.0), 2)
    except (TypeError, ValueError):
        position_sec = 0.0
    if length_sec > 0.0 and position_sec > length_sec:
        position_sec = length_sec

    kde_pid = meta.get("kde:pid")
    pid_str = str(int(kde_pid)) if isinstance(kde_pid, (int, float)) and kde_pid > 0 else ""

    return {
        "busName": bus_name,
        "identity": identity,
        "playbackStatus": playback_status,
        "title": str(meta.get("xesam:title") or "").strip(),
        "artist": _extract_artist(meta),
        "album": str(meta.get("xesam:album") or "").strip(),
        "artUrl": sanitize_art_url(meta.get("mpris:artUrl")),
        "trackId": str(meta.get("mpris:trackid") or "").strip(),
        "lengthSec": length_sec,
        "positionSec": position_sec,
        "canPlay": bool(player_props.get("CanPlay", False)),
        "canPause": bool(player_props.get("CanPause", False)),
        "canGoNext": bool(player_props.get("CanGoNext", False)),
        "canGoPrevious": bool(player_props.get("CanGoPrevious", False)),
        "canSeek": bool(player_props.get("CanSeek", False)),
        # İsteğe bağlı MPRIS özellikleri: oynatıcı sunmuyorsa arayüz düğmeyi gizler.
        "canShuffle": "Shuffle" in player_props,
        "shuffle": bool(player_props.get("Shuffle", False)),
        "canLoop": str(player_props.get("LoopStatus") or "") in MPRIS_LOOP_CYCLE,
        "loopStatus": str(player_props.get("LoopStatus") or ""),
        "kdePid": pid_str,
    }


def select_and_merge_players(snapshots: list[dict[str, Any]], selected_bus: str = "") -> dict[str, Any]:
    if not snapshots:
        return _empty_media_state()

    by_bus = {s["busName"]: dict(s) for s in snapshots}

    # Backfill Chromium/Brave missing artist/album from KDE plasma-browser-integration when same PID,
    # and hide duplicate plasma-browser-integration entry unless explicitly selected.
    pbi_name = "org.mpris.MediaPlayer2.plasma-browser-integration"
    pbi = by_bus.get(pbi_name)
    if pbi and pbi.get("kdePid"):
        pid_suffix = f".instance{pbi['kdePid']}"
        matching = [b for b in by_bus if b != pbi_name and b.endswith(pid_suffix)]
        if matching:
            for target_bus in matching:
                target = by_bus[target_bus]
                if not target["artist"] and pbi["artist"]:
                    target["artist"] = pbi["artist"]
                if not target["album"] and pbi["album"]:
                    target["album"] = pbi["album"]
                if not target["artUrl"] and pbi["artUrl"]:
                    target["artUrl"] = pbi["artUrl"]
            if selected_bus != pbi_name:
                del by_bus[pbi_name]

    deduped = list(by_bus.values())
    if not deduped:
        return _empty_media_state()

    chosen: dict[str, Any] | None = None
    if selected_bus and selected_bus in by_bus:
        chosen = by_bus[selected_bus]
    if chosen is None:
        for status_pref in ("Playing", "Paused"):
            for snap in deduped:
                if snap["playbackStatus"] == status_pref:
                    chosen = snap
                    break
            if chosen is not None:
                break
    if chosen is None:
        chosen = deduped[0]

    return {
        "available": True,
        "activePlayer": chosen["busName"],
        "identity": chosen["identity"],
        "playbackStatus": chosen["playbackStatus"],
        "title": chosen["title"],
        "artist": chosen["artist"],
        "album": chosen["album"],
        "artUrl": chosen["artUrl"],
        "lengthSec": chosen["lengthSec"],
        "positionSec": chosen["positionSec"],
        "canPlay": chosen["canPlay"],
        "canPause": chosen["canPause"],
        "canGoNext": chosen["canGoNext"],
        "canGoPrevious": chosen["canGoPrevious"],
        "canSeek": chosen["canSeek"],
        "shuffle": chosen["shuffle"],
        "loopStatus": chosen["loopStatus"],
        "canShuffle": chosen["canShuffle"],
        "canLoop": chosen["canLoop"],
        "players": [
            {
                "busName": s["busName"],
                "identity": s["identity"],
                "playbackStatus": s["playbackStatus"],
            }
            for s in deduped
        ],
    }


def _collect_mpris_snapshots() -> list[dict[str, Any]]:
    ctx = _get_session_bus()
    if ctx is None:
        return []
    bus, Gio, GLib = ctx
    try:
        res = bus.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            None,
            GLib.VariantType("(as)"),
            Gio.DBusCallFlags.NONE,
            1000,
            None,
        )
        bus_names = sorted(n for n in res.unpack()[0] if n.startswith("org.mpris.MediaPlayer2."))
    except Exception:
        return []

    snapshots: list[dict[str, Any]] = []
    for name in bus_names:
        try:
            root_props = _dbus_get_all_props(bus, Gio, GLib, name, "org.mpris.MediaPlayer2")
            player_props = _dbus_get_all_props(bus, Gio, GLib, name, "org.mpris.MediaPlayer2.Player")
            if "Position" not in player_props:
                try:
                    pos_val = _dbus_get_prop(bus, Gio, GLib, name, "org.mpris.MediaPlayer2.Player", "Position")
                    if pos_val is not None:
                        player_props["Position"] = pos_val
                except Exception:
                    pass
            snapshots.append(_normalize_player_snapshot(name, root_props, player_props))
        except Exception:
            continue
    return snapshots


def get_media_status() -> dict[str, Any]:
    snapshots = _collect_mpris_snapshots()
    selected = read_selected_player()
    return select_and_merge_players(snapshots, selected)


def _resolve_target_player(explicit_bus: str = "") -> str:
    if explicit_bus.strip():
        return validate_bus_name(explicit_bus)
    media = get_media_status()
    active = str(media.get("activePlayer") or "").strip()
    return validate_bus_name(active) if active else ""


def run_media_action(action: str, args: list[str]) -> dict[str, Any]:
    if action == "select-player":
        if not args:
            raise ValueError("media select-player requires <busName>")
        write_selected_player(args[0])
        return {"ok": True, "selectedPlayer": args[0].strip()}

    if action == "seek":
        if not args:
            raise ValueError("media seek requires <positionSec> [busName]")
        target_sec = max(0.0, float(args[0]))
        explicit_bus = args[1] if len(args) > 1 else ""
        bus_name = _resolve_target_player(explicit_bus)
        if not bus_name:
            return {"ok": False, "error": "no active media player"}
        ctx = _get_session_bus()
        if ctx is None:
            return {"ok": False, "error": "session bus unavailable"}
        bus, Gio, GLib = ctx
        target_us = int(round(target_sec * 1_000_000.0))

        player_props = _dbus_get_all_props(bus, Gio, GLib, bus_name, "org.mpris.MediaPlayer2.Player")
        meta = player_props.get("Metadata") if isinstance(player_props.get("Metadata"), dict) else {}
        track_id = str((meta or {}).get("mpris:trackid") or "").strip()

        if track_id and _DBUS_OBJ_PATH_RE.match(track_id):
            try:
                bus.call_sync(
                    bus_name,
                    "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player",
                    "SetPosition",
                    GLib.Variant("(ox)", (track_id, target_us)),
                    None,
                    Gio.DBusCallFlags.NONE,
                    1000,
                    None,
                )
                return {"ok": True}
            except Exception:
                pass

        cur_us = int(player_props.get("Position", 0) or 0)
        offset_us = target_us - cur_us
        bus.call_sync(
            bus_name,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            "Seek",
            GLib.Variant("(x)", (offset_us,)),
            None,
            Gio.DBusCallFlags.NONE,
            1000,
            None,
        )
        return {"ok": True}

    if action in ("shuffle", "loop"):
        bus_name = _resolve_target_player(args[0] if args else "")
        if not bus_name:
            return {"ok": False, "error": "no active media player"}
        ctx = _get_session_bus()
        if ctx is None:
            return {"ok": False, "error": "session bus unavailable"}
        bus, Gio, GLib = ctx
        iface = "org.mpris.MediaPlayer2.Player"
        if action == "shuffle":
            prop, value = "Shuffle", GLib.Variant("b", not bool(_dbus_get_prop(bus, Gio, GLib, bus_name, iface, "Shuffle")))
        else:
            current = str(_dbus_get_prop(bus, Gio, GLib, bus_name, iface, "LoopStatus") or "")
            prop, value = "LoopStatus", GLib.Variant("s", next_loop_status(current))
        bus.call_sync(
            bus_name,
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "Set",
            GLib.Variant("(ssv)", (iface, prop, value)),
            None,
            Gio.DBusCallFlags.NONE,
            1000,
            None,
        )
        return {"ok": True, prop[0].lower() + prop[1:]: value.unpack()}

    method_map = {
        "play-pause": "PlayPause",
        "next": "Next",
        "prev": "Previous",
        "previous": "Previous",
    }
    if action not in method_map:
        raise ValueError(f"Unsupported media action: {action}")

    explicit_bus = args[0] if args else ""
    bus_name = _resolve_target_player(explicit_bus)
    if not bus_name:
        return {"ok": False, "error": "no active media player"}

    ctx = _get_session_bus()
    if ctx is None:
        return {"ok": False, "error": "session bus unavailable"}
    bus, Gio, _GLib = ctx
    bus.call_sync(
        bus_name,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        method_map[action],
        None,
        None,
        Gio.DBusCallFlags.NONE,
        1000,
        None,
    )
    return {"ok": True}


# ---------------------------------------------------------------------------
# PipeWire / PulseAudio Subsystem (wpctl + pactl)
# ---------------------------------------------------------------------------

def _run_cmd(cmd: list[str], timeout: float = 2.0) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["LC_NUMERIC"] = "C"
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, check=False)


def parse_pactl_volume_pct(vol_obj: Any) -> int:
    if not isinstance(vol_obj, dict) or not vol_obj:
        return 0
    values: list[float] = []
    for ch in vol_obj.values():
        if not isinstance(ch, dict):
            continue
        pct_str = str(ch.get("value_percent") or "").strip().rstrip("%").strip()
        if pct_str:
            try:
                values.append(float(pct_str))
                continue
            except ValueError:
                pass
        if "value" in ch:
            try:
                values.append(float(ch["value"]) * 100.0 / 65536.0)
            except (TypeError, ValueError):
                pass
    if not values:
        return 0
    return clamp_int(sum(values) / len(values), 0, 150)


def parse_wpctl_volume_line(line: str) -> tuple[int, bool]:
    # Example: "Volume: 0.25" or "Volume: 0.45 [MUTED]"
    muted = "[MUTED]" in line.upper()
    m = re.search(r"([0-9]+(?:[.,][0-9]+)?)", line)
    if not m:
        return 0, muted
    val = float(m.group(1).replace(",", "."))
    return clamp_int(val * 100.0, 0, 150), muted


def build_audio_status_from_pactl(
    info_data: dict[str, Any],
    sinks_data: list[dict[str, Any]],
    sources_data: list[dict[str, Any]],
    sink_inputs_data: list[dict[str, Any]],
) -> dict[str, Any]:
    default_sink_name = str(info_data.get("default_sink_name") or "").strip()
    default_source_name = str(info_data.get("default_source_name") or "").strip()

    sinks: list[dict[str, Any]] = []
    default_sink_entry: dict[str, Any] | None = None

    for sink in sinks_data:
        if not isinstance(sink, dict):
            continue
        props = sink.get("properties") if isinstance(sink.get("properties"), dict) else {}
        sink_id = str((props or {}).get("object.id") or sink.get("index") or "").strip()
        name = str(sink.get("name") or "").strip()
        desc = str(
            sink.get("description")
            or (props or {}).get("node.description")
            or (props or {}).get("device.description")
            or name
        ).strip()
        vol = parse_pactl_volume_pct(sink.get("volume"))
        muted = bool(sink.get("mute", False))
        is_default = bool(name and name == default_sink_name)
        entry = {
            "id": sink_id,
            "name": name,
            "description": desc,
            "volume": vol,
            "muted": muted,
            "isDefault": is_default,
        }
        sinks.append(entry)
        if is_default:
            default_sink_entry = entry

    if default_sink_entry is None and sinks:
        sinks[0]["isDefault"] = True
        default_sink_entry = sinks[0]

    source_volume = 100
    source_muted = False
    chosen_source: dict[str, Any] | None = None
    for src in sources_data:
        if not isinstance(src, dict):
            continue
        src_name = str(src.get("name") or "").strip()
        if default_source_name and src_name == default_source_name:
            chosen_source = src
            break
    if chosen_source is None:
        for src in sources_data:
            if isinstance(src, dict) and not str(src.get("name") or "").endswith(".monitor"):
                chosen_source = src
                break
    if chosen_source is not None:
        source_volume = parse_pactl_volume_pct(chosen_source.get("volume"))
        source_muted = bool(chosen_source.get("mute", False))

    streams: list[dict[str, Any]] = []
    for si in sink_inputs_data:
        if not isinstance(si, dict):
            continue
        props = si.get("properties") if isinstance(si.get("properties"), dict) else {}
        role = str((props or {}).get("media.role") or "").strip().lower()
        if role in ("event", "filter"):
            continue
        stream_id = str((props or {}).get("object.id") or si.get("index") or "").strip()
        if not stream_id:
            continue
        app_name = str(
            (props or {}).get("application.name")
            or (props or {}).get("node.name")
            or (props or {}).get("application.process.binary")
            or "Playback"
        ).strip()
        media_name = str((props or {}).get("media.name") or "Playback").strip()
        streams.append(
            {
                "id": stream_id,
                "appName": app_name,
                "mediaName": media_name,
                "volume": parse_pactl_volume_pct(si.get("volume")),
                "muted": bool(si.get("mute", False)),
            }
        )

    return {
        "volume": default_sink_entry["volume"] if default_sink_entry else 0,
        "muted": default_sink_entry["muted"] if default_sink_entry else False,
        "sinkId": default_sink_entry["id"] if default_sink_entry else "",
        "sinkName": default_sink_entry["description"] if default_sink_entry else "",
        "sourceVolume": source_volume,
        "sourceMuted": source_muted,
        "sinks": sinks,
        "streams": streams,
    }


def _pactl_json(subargs: list[str]) -> Any:
    res = _run_cmd(["pactl", "-f", "json", *subargs], timeout=2.0)
    if res.returncode != 0 or not res.stdout.strip():
        return None
    try:
        return json.loads(res.stdout)
    except json.JSONDecodeError:
        return None


def get_audio_status() -> dict[str, Any]:
    if shutil.which("pactl"):
        with ThreadPoolExecutor(max_workers=4) as pool:
            f_info = pool.submit(_pactl_json, ["info"])
            f_sinks = pool.submit(_pactl_json, ["list", "sinks"])
            f_sources = pool.submit(_pactl_json, ["list", "sources"])
            f_inputs = pool.submit(_pactl_json, ["list", "sink-inputs"])
            info_data = f_info.result()
            sinks_data = f_sinks.result()
            sources_data = f_sources.result()
            inputs_data = f_inputs.result()

        if isinstance(info_data, dict) and isinstance(sinks_data, list):
            return build_audio_status_from_pactl(
                info_data,
                sinks_data,
                sources_data if isinstance(sources_data, list) else [],
                inputs_data if isinstance(inputs_data, list) else [],
            )

    # Fallback to wpctl if pactl is unavailable
    vol, muted = 0, False
    src_vol, src_muted = 100, False
    if shutil.which("wpctl"):
        r_sink = _run_cmd(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
        if r_sink.returncode == 0:
            vol, muted = parse_wpctl_volume_line(r_sink.stdout)
        r_src = _run_cmd(["wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@"])
        if r_src.returncode == 0:
            src_vol, src_muted = parse_wpctl_volume_line(r_src.stdout)

    return {
        "volume": vol,
        "muted": muted,
        "sinkId": "",
        "sinkName": "",
        "sourceVolume": src_vol,
        "sourceMuted": src_muted,
        "sinks": [],
        "streams": [],
    }


def _resolve_sink_input_index(stream_id: str) -> tuple[str | None, str | None]:
    """Return (pactl_index, pipewire_object_id) for a streamId."""
    target = stream_id.strip()
    inputs = _pactl_json(["list", "sink-inputs"]) if shutil.which("pactl") else None
    if isinstance(inputs, list):
        for si in inputs:
            if not isinstance(si, dict):
                continue
            idx = str(si.get("index") or "").strip()
            props = si.get("properties") if isinstance(si.get("properties"), dict) else {}
            obj_id = str((props or {}).get("object.id") or "").strip()
            if target in (idx, obj_id):
                return (idx or None), (obj_id or None)
    return (target if target else None), (target if target.isdigit() else None)


def run_audio_action(action: str, args: list[str]) -> dict[str, Any]:
    if action == "set-volume":
        if not args:
            raise ValueError("audio set-volume requires <0-150>")
        pct = clamp_int(float(args[0].rstrip("%")), 0, 150)
        if shutil.which("wpctl"):
            res = _run_cmd(["wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", f"{pct / 100.0:.2f}"])
            if res.returncode == 0:
                return {"ok": True, "volume": pct}
        res = _run_cmd(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{pct}%"])
        return {"ok": res.returncode == 0, "volume": pct}

    if action == "change-volume":
        if not args:
            raise ValueError("audio change-volume requires <delta>")
        raw_delta = args[0].strip().rstrip("%")
        delta = float(raw_delta)
        current = get_audio_status().get("volume", 0)
        target_pct = clamp_int(float(current) + delta, 0, 150)
        return run_audio_action("set-volume", [str(target_pct)])

    if action == "toggle-mute":
        if shutil.which("wpctl"):
            res = _run_cmd(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
            if res.returncode == 0:
                return {"ok": True}
        res = _run_cmd(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle"])
        return {"ok": res.returncode == 0}

    if action == "toggle-mic":
        if shutil.which("wpctl"):
            res = _run_cmd(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
            if res.returncode == 0:
                return {"ok": True}
        res = _run_cmd(["pactl", "set-source-mute", "@DEFAULT_SOURCE@", "toggle"])
        return {"ok": res.returncode == 0}

    if action == "set-sink":
        if not args or not args[0].strip():
            raise ValueError("audio set-sink requires <sinkId>")
        sink_id = validate_audio_id(args[0], "sinkId")
        matched_name = ""
        matched_obj_id = ""
        sinks = _pactl_json(["list", "sinks"]) if shutil.which("pactl") else None
        if isinstance(sinks, list):
            for sink in sinks:
                if not isinstance(sink, dict):
                    continue
                idx = str(sink.get("index") or "").strip()
                name = str(sink.get("name") or "").strip()
                props = sink.get("properties") if isinstance(sink.get("properties"), dict) else {}
                obj_id = str((props or {}).get("object.id") or "").strip()
                if sink_id in (obj_id, idx, name):
                    matched_name = name
                    matched_obj_id = obj_id
                    break

        ok = False
        if shutil.which("wpctl") and (matched_obj_id or sink_id.isdigit()):
            r_wp = _run_cmd(["wpctl", "set-default", matched_obj_id or sink_id])
            ok = ok or (r_wp.returncode == 0)
        if shutil.which("pactl"):
            target_sink = validate_audio_id(matched_name or sink_id, "sinkId")
            r_pa = _run_cmd(["pactl", "set-default-sink", target_sink])
            ok = ok or (r_pa.returncode == 0)
            inputs = _pactl_json(["list", "sink-inputs"])
            if isinstance(inputs, list):
                for si in inputs:
                    if isinstance(si, dict) and si.get("index") is not None:
                        _run_cmd(["pactl", "move-sink-input", str(si["index"]), target_sink])
        return {"ok": ok}

    if action == "set-stream-volume":
        if len(args) < 2:
            raise ValueError("audio set-stream-volume requires <streamId> <0-150>")
        stream_id = validate_audio_id(args[0], "streamId")
        pct = clamp_int(float(args[1].rstrip("%")), 0, 150)
        pa_idx, pw_id = _resolve_sink_input_index(stream_id)
        if shutil.which("pactl") and pa_idx:
            res = _run_cmd(["pactl", "set-sink-input-volume", validate_audio_id(pa_idx, "streamId"), f"{pct}%"])
            if res.returncode == 0:
                return {"ok": True, "volume": pct}
        if shutil.which("wpctl") and pw_id:
            res = _run_cmd(["wpctl", "set-volume", "-l", "1.5", validate_audio_id(pw_id, "streamId"), f"{pct / 100.0:.2f}"])
            if res.returncode == 0:
                return {"ok": True, "volume": pct}
        return {"ok": False}

    if action == "toggle-stream-mute":
        if not args or not args[0].strip():
            raise ValueError("audio toggle-stream-mute requires <streamId>")
        stream_id = validate_audio_id(args[0], "streamId")
        pa_idx, pw_id = _resolve_sink_input_index(stream_id)
        if shutil.which("pactl") and pa_idx:
            res = _run_cmd(["pactl", "set-sink-input-mute", validate_audio_id(pa_idx, "streamId"), "toggle"])
            if res.returncode == 0:
                return {"ok": True}
        if shutil.which("wpctl") and pw_id:
            res = _run_cmd(["wpctl", "set-mute", validate_audio_id(pw_id, "streamId"), "toggle"])
            if res.returncode == 0:
                return {"ok": True}
        return {"ok": False}

    raise ValueError(f"Unsupported audio action: {action}")


# ---------------------------------------------------------------------------
# Claude / AGY / Codex Subscription Quotas Subsystem
# ---------------------------------------------------------------------------

def _empty_window(default_human: str = "—") -> dict[str, Any]:
    return {
        "usedPct": 0,
        "remainingPct": 100,
        "resetsAt": "",
        "resetInHuman": default_human,
    }


def _failure_reason(exc: BaseException) -> tuple[str, int]:
    """Kota isteği hatasını arayüz/teşhis için kısa bir nedene çevirir: (reason, httpStatus)."""
    if isinstance(exc, urllib.error.HTTPError):
        code = int(exc.code)
        if code == 429:
            return "rate_limited", code
        if code in (401, 403):
            return "auth_expired", code
        return ("server_error" if code >= 500 else "http_error"), code
    if isinstance(exc, ValueError):  # JSONDecodeError dahil
        return "bad_response", 0
    if isinstance(exc, OSError):  # URLError, zaman aşımı
        return "network", 0
    return "error", 0


def _with_reason(q: dict[str, Any], reason: str, http_status: int = 0) -> dict[str, Any]:
    q["reason"] = reason
    q["httpStatus"] = http_status
    return q


def _unavailable_claude_quota(configured: bool = True) -> dict[str, Any]:
    return {
        "available": False,
        "configured": configured,
        "source": "unavailable",
        "fiveHour": _empty_window(),
        "sevenDay": _empty_window(),
        "fableWeekly": None,
    }


def _unavailable_agy_quota(configured: bool = True) -> dict[str, Any]:
    return {
        "available": False,
        "configured": configured,
        "source": "unavailable",
        "geminiPool": {"label": "Gemini 4 (Carbon/Argon)", **_empty_window()},
        "claudePool": {"label": "Claude 5.5 (AGY)", **_empty_window()},
        "weekly": {"label": "Weekly (7d)", **_empty_window("7d window")},
    }


def _parse_claude_bucket(
    bucket: Any,
    fallback_limit: dict[str, Any] | None = None,
    now_utc: datetime | None = None,
) -> dict[str, Any]:
    raw_pct: Any = None
    raw_reset: Any = None
    if isinstance(bucket, dict):
        raw_pct = bucket.get("utilization")
        if raw_pct is None:
            raw_pct = bucket.get("percent")
        raw_reset = bucket.get("resets_at") or bucket.get("resetsAt")
    if raw_pct is None and isinstance(fallback_limit, dict):
        raw_pct = fallback_limit.get("percent")
    if not raw_reset and isinstance(fallback_limit, dict):
        raw_reset = fallback_limit.get("resets_at") or fallback_limit.get("resetsAt")

    if raw_pct is None:
        return {
            "usedPct": -1,
            "remainingPct": -1,
            "resetsAt": normalize_iso_utc(raw_reset),
            "resetInHuman": format_reset_in(raw_reset, now_utc=now_utc),
        }

    used = clamp_int(float(raw_pct), 0, 100)
    return {
        "usedPct": used,
        "remainingPct": 100 - used,
        "resetsAt": normalize_iso_utc(raw_reset),
        "resetInHuman": format_reset_in(raw_reset, now_utc=now_utc),
    }


def parse_claude_usage_payload(
    payload: dict[str, Any],
    source: str = "live",
    now_utc: datetime | None = None,
) -> dict[str, Any]:
    limits = payload.get("limits") if isinstance(payload.get("limits"), list) else []
    session_limit: dict[str, Any] | None = None
    weekly_all_limit: dict[str, Any] | None = None
    fable_limit: dict[str, Any] | None = None

    for item in limits:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind") or "").strip()
        if kind == "session" and session_limit is None:
            session_limit = item
        elif kind == "weekly_all" and weekly_all_limit is None:
            weekly_all_limit = item
        elif kind == "weekly_scoped":
            scope = item.get("scope") if isinstance(item.get("scope"), dict) else {}
            model = (scope or {}).get("model") if isinstance((scope or {}).get("model"), dict) else {}
            model_label = f"{(model or {}).get('display_name') or ''} {(model or {}).get('id') or ''}".lower()
            if "fable" in model_label:
                fable_limit = item

    five_hour = _parse_claude_bucket(payload.get("five_hour"), session_limit, now_utc=now_utc)
    seven_day = _parse_claude_bucket(payload.get("seven_day"), weekly_all_limit, now_utc=now_utc)

    fable_bucket = (
        payload.get("seven_day_fable")
        or payload.get("fable_weekly")
        or payload.get("fableWeekly")
    )
    fable_weekly: dict[str, Any] | None = None
    if isinstance(fable_bucket, dict) or fable_limit is not None:
        fable_weekly = _parse_claude_bucket(fable_bucket, fable_limit, now_utc=now_utc)

    return {
        "available": True,
        "configured": True,
        "source": source,
        "fiveHour": five_hour,
        "sevenDay": seven_day,
        "fableWeekly": fable_weekly,
    }


def _read_claude_access_token() -> str:
    cred_path_str = os.environ.get("CLAUDE_CREDENTIALS_PATH", "").strip()
    cred_path = Path(cred_path_str).expanduser() if cred_path_str else (Path.home() / ".claude" / ".credentials.json")
    try:
        data = json.loads(cred_path.read_text(encoding="utf-8"))
    except Exception:
        return ""
    if not isinstance(data, dict):
        return ""
    oauth = data.get("claudeAiOauth")
    if isinstance(oauth, dict):
        tok = oauth.get("accessToken") or oauth.get("access_token")
        if isinstance(tok, str) and tok.strip():
            return tok.strip()
    for key in ("accessToken", "access_token", "oauthToken"):
        tok = data.get(key)
        if isinstance(tok, str) and tok.strip():
            return tok.strip()
    return ""


def _read_claude_fallback_json(now_utc: datetime | None = None) -> dict[str, Any] | None:
    cfg_path_str = os.environ.get("CLAUDE_CONFIG_PATH", "").strip()
    cfg_path = Path(cfg_path_str).expanduser() if cfg_path_str else (Path.home() / ".claude.json")
    try:
        data = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None

    cached = data.get("cachedUsageUtilization")
    if isinstance(cached, dict):
        util = cached.get("utilization")
        if isinstance(util, dict) and ("five_hour" in util or "seven_day" in util or "limits" in util):
            parsed = parse_claude_usage_payload(util, source="cache", now_utc=now_utc)
            fetched_ms = cached.get("fetchedAtMs")
            # Zaman damgası yoksa veri yaşı bilinmez: dataAt=0 -> get_quotas bunu bayat sayar.
            parsed["dataAt"] = int(fetched_ms // 1000) if isinstance(fetched_ms, (int, float)) and fetched_ms > 0 else 0
            return parsed

    if "five_hour" in data or "seven_day" in data:
        return {**parse_claude_usage_payload(data, source="cache", now_utc=now_utc), "dataAt": 0}

    return None


def fetch_claude_quota(now_utc: datetime | None = None) -> dict[str, Any]:
    token = _read_claude_access_token()
    has_token = bool(token)
    reason, http_status = ("no_credentials", 0) if not token else ("bad_response", 0)
    if token:
        req = urllib.request.Request(
            CLAUDE_USAGE_URL,
            method="GET",
            headers={
                "Authorization": f"Bearer {token}",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
                "User-Agent": QUOTA_USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=6.0) as resp:
                body = json.loads(resp.read().decode("utf-8"))
            if isinstance(body, dict) and ("five_hour" in body or "seven_day" in body or "limits" in body):
                return parse_claude_usage_payload(body, source="live", now_utc=now_utc)
        except Exception as exc:
            reason, http_status = _failure_reason(exc)
        finally:
            del token

    fallback = _read_claude_fallback_json(now_utc=now_utc)
    if fallback is not None:
        # Canlı istek neden başarısız oldu: yedek bayatsa get_quotas bu nedeni gösterir.
        return _with_reason(fallback, reason, http_status)

    return _with_reason(_unavailable_claude_quota(configured=has_token), reason, http_status)


def _extract_token_from_secret_raw(raw_secret: str) -> str:
    text = raw_secret.strip()
    if not text:
        return ""
    if text.startswith("{"):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            return ""
        if isinstance(parsed, dict):
            tok_obj = parsed.get("token")
            if isinstance(tok_obj, dict):
                val = tok_obj.get("access_token") or tok_obj.get("accessToken")
                if isinstance(val, str) and val.strip():
                    return val.strip()
            for k in ("access_token", "accessToken"):
                val = parsed.get(k)
                if isinstance(val, str) and val.strip():
                    return val.strip()
        return ""
    return text


def _lookup_agy_access_token() -> str:
    try:
        import gi  # type: ignore[import-untyped]
        gi.require_version("Secret", "1")
        from gi.repository import Secret  # type: ignore[import-untyped]

        schema = Secret.Schema.new(
            "org.freedesktop.Secret.Generic",
            Secret.SchemaFlags.NONE,
            {
                "service": Secret.SchemaAttributeType.STRING,
                "username": Secret.SchemaAttributeType.STRING,
            },
        )
        raw = Secret.password_lookup_sync(schema, {"service": "gemini", "username": "antigravity"}, None)
        if raw:
            return _extract_token_from_secret_raw(raw)

        service = Secret.Service.get_sync(Secret.ServiceFlags.LOAD_COLLECTIONS, None)
        for collection in service.get_collections():
            for item in collection.get_items():
                attrs = item.get_attributes() or {}
                if attrs.get("service") == "gemini" and attrs.get("username") == "antigravity":
                    item.load_secret_sync(None)
                    sec_val = item.get_secret()
                    if sec_val is not None:
                        return _extract_token_from_secret_raw(sec_val.get_text() or "")
    except Exception:
        pass
    return ""


def _pick_pool_window(
    candidates: list[dict[str, Any]],
    label: str,
    now_utc: datetime | None = None,
) -> dict[str, Any]:
    if not candidates:
        return {"label": label, **_empty_window()}

    with_reset = [c for c in candidates if c.get("resetTime")]
    pool = with_reset if with_reset else candidates

    best: dict[str, Any] | None = None
    best_used = -1.0
    for q in pool:
        has_reset = bool(q.get("resetTime"))
        # Protobuf3 omits remainingFraction when 0.0; if resetTime exists and remainingFraction is omitted, quota is 0.0.
        rem_raw = q.get("remainingFraction", 0.0 if has_reset else 1.0)
        try:
            rem_frac = max(0.0, min(1.0, float(rem_raw)))
        except (TypeError, ValueError):
            rem_frac = 1.0
        used_exact = (1.0 - rem_frac) * 100.0
        if used_exact > best_used:
            best_used = used_exact
            best = q

    assert best is not None
    used_pct = clamp_int(best_used, 0, 100)
    raw_reset = best.get("resetTime")
    return {
        "label": label,
        "usedPct": used_pct,
        "remainingPct": 100 - used_pct,
        "resetsAt": normalize_iso_utc(raw_reset),
        "resetInHuman": format_reset_in(raw_reset, now_utc=now_utc),
    }


def parse_agy_models_payload(
    payload: dict[str, Any],
    source: str = "live",
    now_utc: datetime | None = None,
    summary_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    models = payload.get("models")
    if not isinstance(models, dict) or not models:
        return _unavailable_agy_quota()

    ref = now_utc.astimezone(timezone.utc) if now_utc is not None else datetime.now(timezone.utc)
    gemini_quotas: list[dict[str, Any]] = []
    claude_quotas: list[dict[str, Any]] = []

    for model_id, info in models.items():
        if not isinstance(info, dict):
            continue
        qinfo = info.get("quotaInfo")
        if not isinstance(qinfo, dict):
            continue
        mid = str(model_id).lower()
        disp = str(info.get("displayName") or "").lower()
        combined = f"{mid} {disp}"
        if any(tag in combined for tag in ("gemini", "carbon", "argon", "hydrogen")):
            gemini_quotas.append(qinfo)
        elif "claude" in combined or "opus" in combined or "sonnet" in combined:
            claude_quotas.append(qinfo)

    weekly_reset = ""
    weekly_used = -1

    # Extract weekly (7d) and 5h buckets from retrieveUserQuotaSummary when available
    if isinstance(summary_payload, dict):
        groups = summary_payload.get("groups")
        if isinstance(groups, list):
            for grp in groups:
                if not isinstance(grp, dict):
                    continue
                buckets = grp.get("buckets")
                if not isinstance(buckets, list):
                    continue
                for b in buckets:
                    if not isinstance(b, dict):
                        continue
                    win = str(b.get("window") or "").strip().lower()
                    bid = str(b.get("bucketId") or "").strip().lower()
                    has_reset = bool(b.get("resetTime"))
                    rem_raw = b.get("remainingFraction", 0.0 if has_reset else 1.0)
                    try:
                        rem_frac = max(0.0, min(1.0, float(rem_raw)))
                    except (TypeError, ValueError):
                        rem_frac = 1.0
                    used_pct = clamp_int((1.0 - rem_frac) * 100.0, 0, 100)
                    norm_reset = normalize_iso_utc(b.get("resetTime"))

                    if win == "weekly" or "weekly" in bid:
                        if used_pct > weekly_used or weekly_used < 0:
                            weekly_used = used_pct
                            weekly_reset = norm_reset
                    elif (win == "5h" or "5h" in bid) and not claude_quotas:
                        claude_quotas.append(b)

    gemini_pool = _pick_pool_window(gemini_quotas, "Gemini 4 (Carbon/Argon)", now_utc=ref)
    claude_pool = _pick_pool_window(claude_quotas, "Claude 5.5 (AGY)", now_utc=ref)

    # Also check if any model pool directly reports a >6h weekly reset window
    for pool in (gemini_pool, claude_pool):
        dt = parse_iso_utc(pool["resetsAt"])
        if dt is not None and (dt - ref).total_seconds() > 6 * 3600:
            if pool["usedPct"] > weekly_used or weekly_used < 0:
                weekly_used = pool["usedPct"]
                weekly_reset = pool["resetsAt"]

    if weekly_used >= 0:
        weekly = {
            "label": "Weekly (7d)",
            "usedPct": weekly_used,
            "remainingPct": 100 - weekly_used,
            "resetsAt": weekly_reset,
            "resetInHuman": format_reset_in(weekly_reset, now_utc=ref),
        }
    else:
        weekly = {
            "label": "Weekly (7d)",
            "usedPct": -1,
            "remainingPct": -1,
            "resetsAt": "",
            "resetInHuman": "—",
        }

    return {
        "available": True,
        "configured": True,
        "source": source,
        "geminiPool": gemini_pool,
        "claudePool": claude_pool,
        "weekly": weekly,
    }


def _post_agy_endpoint(url: str, token: str) -> dict[str, Any] | None:
    req = urllib.request.Request(
        url,
        data=b"{}",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            # shortcut: taklit UA; dürüst UA denenemedi (kimlik 401), canlı deneme sonrası QUOTA_USER_AGENT yapılmalı.
            "User-Agent": "antigravity",
        },
    )
    with urllib.request.urlopen(req, timeout=6.0) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    return body if isinstance(body, dict) else None


def fetch_agy_quota(now_utc: datetime | None = None) -> dict[str, Any]:
    token = _lookup_agy_access_token()
    if not token:
        return _with_reason(_unavailable_agy_quota(configured=False), "no_credentials")

    reason, http_status = "bad_response", 0
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            f_models = pool.submit(_post_agy_endpoint, AGY_MODELS_URL, token)
            f_summary = pool.submit(_post_agy_endpoint, AGY_QUOTA_SUMMARY_URL, token)
            models_body = f_models.result()
            try:
                summary_body = f_summary.result()
            except Exception:
                summary_body = None  # haftalık özet isteğe bağlı
        if isinstance(models_body, dict):
            return parse_agy_models_payload(
                models_body,
                source="live",
                now_utc=now_utc,
                summary_payload=summary_body,
            )
    except Exception as exc:
        reason, http_status = _failure_reason(exc)
    finally:
        del token

    return _with_reason(_unavailable_agy_quota(), reason, http_status)


def _unavailable_codex_quota(configured: bool = True) -> dict[str, Any]:
    return {
        "available": False,
        "configured": configured,
        "source": "unavailable",
        "fiveHour": _empty_window(),
        "sevenDay": _empty_window(),
    }


def _parse_codex_window(window: Any, now_utc: datetime | None = None) -> dict[str, Any] | None:
    if not isinstance(window, dict) or window.get("used_percent") is None:
        return None
    try:
        used = clamp_int(float(window["used_percent"]), 0, 100)
    except (TypeError, ValueError):
        return None
    reset_iso = ""
    reset_at = window.get("reset_at")
    if isinstance(reset_at, (int, float)) and reset_at > 0:
        reset_iso = datetime.fromtimestamp(reset_at, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "usedPct": used,
        "remainingPct": 100 - used,
        "resetsAt": reset_iso,
        "resetInHuman": format_reset_in(reset_iso, now_utc=now_utc) if reset_iso else "—",
        "windowSec": int(window.get("limit_window_seconds") or 0),
    }


def parse_codex_usage_payload(
    payload: dict[str, Any],
    source: str = "live",
    now_utc: datetime | None = None,
) -> dict[str, Any]:
    rate = payload.get("rate_limit") if isinstance(payload, dict) else None
    if not isinstance(rate, dict):
        return _unavailable_codex_quota()
    windows = [
        w for w in (
            _parse_codex_window(rate.get("primary_window"), now_utc),
            _parse_codex_window(rate.get("secondary_window"), now_utc),
        ) if w is not None
    ]
    if not windows:
        return _unavailable_codex_quota()
    # Pencere süresiyle eşle: <=6sa ise 5 saatlik, daha uzunsa haftalık; süre yoksa primary=5sa, secondary=7g.
    five_hour: dict[str, Any] | None = None
    seven_day: dict[str, Any] | None = None
    for w in windows:
        sec = w.pop("windowSec")
        if sec and sec > 6 * 3600:
            seven_day = seven_day or w
        elif sec:
            five_hour = five_hour or w
        elif five_hour is None:
            five_hour = w
        else:
            seven_day = seven_day or w
    missing = {"usedPct": -1, "remainingPct": -1, "resetsAt": "", "resetInHuman": "—"}
    return {
        "available": True,
        "configured": True,
        "source": source,
        "fiveHour": five_hour or dict(missing),
        "sevenDay": seven_day or dict(missing),
    }


def _read_codex_credentials() -> tuple[str, str]:
    home = os.environ.get("CODEX_HOME", "").strip()
    auth_path = (Path(home).expanduser() if home else (Path.home() / ".codex")) / "auth.json"
    # shortcut: keyring'de ("Codex Auth") saklanan kimlik okunmaz; yalnız auth.json desteklenir.
    try:
        data = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception:
        return "", ""
    tokens = data.get("tokens") if isinstance(data, dict) else None
    if not isinstance(tokens, dict):
        return "", ""
    tok = tokens.get("access_token")
    acc = tokens.get("account_id")
    return (
        tok.strip() if isinstance(tok, str) else "",
        acc.strip() if isinstance(acc, str) else "",
    )


def fetch_codex_quota(now_utc: datetime | None = None) -> dict[str, Any]:
    token, account_id = _read_codex_credentials()
    if not token:
        return _with_reason(_unavailable_codex_quota(configured=False), "no_credentials")
    reason, http_status = "bad_response", 0
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        # shortcut: taklit UA; Codex kimliği olmadan denenemedi, canlı deneme sonrası QUOTA_USER_AGENT yapılmalı.
        "User-Agent": "codex-cli",
    }
    if account_id:
        headers["chatgpt-account-id"] = account_id
    req = urllib.request.Request(CODEX_USAGE_URL, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=6.0) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        if isinstance(body, dict):
            return parse_codex_usage_payload(body, source="live", now_utc=now_utc)
    except Exception as exc:
        reason, http_status = _failure_reason(exc)
    finally:
        del token, account_id, headers, req
    return _with_reason(_unavailable_codex_quota(), reason, http_status)


def _quota_fetcher(key: str):
    # Çağrı anında çözülür; testlerde mock.patch.object ile değiştirilebilir.
    return {"claude": fetch_claude_quota, "agy": fetch_agy_quota, "codex": fetch_codex_quota}[key]


def _unavailable_quota(key: str) -> dict[str, Any]:
    return {"claude": _unavailable_claude_quota, "agy": _unavailable_agy_quota,
            "codex": _unavailable_codex_quota}[key]()


def _cached_quota_usable(q: Any, now_epoch: int) -> bool:
    """Yedek veri yalnız taze (≤QUOTA_STALE_MAX_SEC) ve hiçbir penceresi sıfırlanmamışsa kullanılır."""
    if not isinstance(q, dict) or not q.get("available"):
        return False
    data_at = int(q.get("dataAt") or 0)
    if data_at <= 0 or not (0 <= now_epoch - data_at <= QUOTA_STALE_MAX_SEC):
        return False
    for bucket in q.values():
        if isinstance(bucket, dict) and bucket.get("resetsAt"):
            reset = parse_iso_utc(bucket["resetsAt"])
            if reset is not None and reset.timestamp() <= now_epoch:
                return False
    return True


def _read_quotas_cache() -> dict[str, Any] | None:
    cache_file = get_cache_dir() / "quotas_cache.json"
    try:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _write_quotas_cache(payload: dict[str, Any]) -> None:
    cache_file = get_cache_dir() / "quotas_cache.json"
    try:
        _atomic_write_text(cache_file, json.dumps(payload, ensure_ascii=False))
    except OSError:
        pass


def get_quotas(force: bool = False, providers: list[str] | tuple[str, ...] | None = None) -> dict[str, Any]:
    wanted = [p for p in QUOTA_PROVIDERS if providers is None or p in providers]
    now_epoch = int(time.time())
    cached = _read_quotas_cache() or {}
    stamps = dict(cached["fetchedAt"]) if isinstance(cached.get("fetchedAt"), dict) else {}
    legacy_stamp = int(cached.get("fetchedAtEpoch") or 0)

    out: dict[str, Any] = {}
    to_fetch: list[str] = []
    for key in wanted:
        prev = cached.get(key)
        stamp = int(stamps.get(key) or legacy_stamp)
        fresh_enough = isinstance(prev, dict) and (prev.get("source") == "live" or _cached_quota_usable(prev, now_epoch))
        if not force and fresh_enough and prev.get("available") and 0 <= (now_epoch - stamp) < QUOTA_CACHE_TTL_SEC and stamp > 0:
            out[key] = prev
        else:
            to_fetch.append(key)

    if to_fetch:
        now_utc = datetime.now(timezone.utc)
        with ThreadPoolExecutor(max_workers=len(to_fetch)) as pool:
            futures = {key: pool.submit(_quota_fetcher(key), now_utc) for key in to_fetch}
        for key, fut in futures.items():
            q = fut.result()
            prev = cached.get(key)
            reason, http_status = str(q.get("reason") or ""), int(q.get("httpStatus") or 0)
            if q.get("available") and q.get("source") == "live":
                q["dataAt"] = now_epoch
            elif q.get("available") and _cached_quota_usable(q, now_epoch):
                pass  # taze yerel yedek (ör. ~/.claude.json)
            elif q.get("configured", True) and _cached_quota_usable(prev, now_epoch):
                # Uç geçici erişilemez (429, ağ) ya da yerel yedek bayat: son iyi değer ≤30 dk "cache" olarak.
                q = {**prev, "source": "cache", "reason": reason, "httpStatus": http_status}
            elif q.get("available"):
                # Yerel yedek bayat ve kullanılabilir önbellek yok.
                q = _with_reason(_unavailable_quota(key), reason or "stale", http_status)
            out[key] = q
            stamps[key] = now_epoch

    result = {
        "updatedAt": datetime.now().strftime("%H:%M"),
        "fetchedAtEpoch": int(time.time()),
        "providers": wanted,
        **out,
    }
    # Önbellekte istenmeyen sağlayıcıların son verisi korunur (yeniden açılınca anında görünür).
    _write_quotas_cache({**cached, **result, "fetchedAt": stamps})
    return result


def get_full_status() -> dict[str, Any]:
    with ThreadPoolExecutor(max_workers=2) as pool:
        f_media = pool.submit(get_media_status)
        f_audio = pool.submit(get_audio_status)
        return {
            "media": f_media.result(),
            "audio": f_audio.result(),
        }


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print(json.dumps({"ok": False, "error": "missing command"}, ensure_ascii=False))
        return 2

    cmd = args[0]
    rest = args[1:]

    try:
        if cmd == "status":
            print(json.dumps(get_full_status(), ensure_ascii=False))
            return 0

        if cmd == "quotas":
            force = "--force" in rest or "-f" in rest
            providers: list[str] | None = None
            if "--providers" in rest:
                idx = rest.index("--providers")
                raw = rest[idx + 1] if idx + 1 < len(rest) else ""
                providers = [p for p in raw.split(",") if p in QUOTA_PROVIDERS]
            print(json.dumps(get_quotas(force=force, providers=providers), ensure_ascii=False))
            return 0

        if cmd == "media":
            if not rest:
                raise ValueError("media subcommand required")
            out = run_media_action(rest[0], rest[1:])
            print(json.dumps(out, ensure_ascii=False))
            return 0 if out.get("ok", True) else 1

        if cmd == "audio":
            if not rest:
                raise ValueError("audio subcommand required")
            out = run_audio_action(rest[0], rest[1:])
            print(json.dumps(out, ensure_ascii=False))
            return 0 if out.get("ok", True) else 1

        print(json.dumps({"ok": False, "error": f"unknown command: {cmd}"}, ensure_ascii=False))
        return 2
    except Exception as exc:
        # Never include raw payloads/headers; emit concise sanitized error message only.
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
