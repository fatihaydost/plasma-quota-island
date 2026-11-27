"""Standard-library unittest suite (unit + live integration) for Carbon-1-Backend."""

from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
from typing import Any
import unittest
from unittest import mock
import urllib.error
import urllib.request

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "package" / "contents" / "scripts" / "island_ctl.py"
EXEC_QML_PATH = REPO_ROOT / "package" / "contents" / "ui" / "Exec.qml"
BACKEND_QML_PATH = REPO_ROOT / "package" / "contents" / "ui" / "Backend.qml"
SYSTEM_PYTHON = "/usr/bin/python3" if Path("/usr/bin/python3").exists() else "python3"
QMLLINT_BIN = Path("/usr/lib/qt6/bin/qmllint")


def _load_island_ctl():
    spec = importlib.util.spec_from_file_location("island_ctl", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ctl = _load_island_ctl()


class TestIslandBackend(unittest.TestCase):
    def test_clamp_int_art_url_and_strict_input_validation(self) -> None:
        self.assertEqual(ctl.clamp_int(-12, 0, 150), 0)
        self.assertEqual(ctl.clamp_int(175.6, 0, 150), 150)
        self.assertEqual(ctl.clamp_int(42.6, 0, 100), 43)

        # Only local file:/// and encrypted https:// allowed; cleartext http:// and remote file://host dropped
        self.assertEqual(ctl.sanitize_art_url("file:///tmp/cover.png"), "file:///tmp/cover.png")
        self.assertEqual(ctl.sanitize_art_url("https://cdn.example/art.jpg"), "https://cdn.example/art.jpg")
        self.assertEqual(ctl.sanitize_art_url("http://insecure.example/art.jpg"), "")
        self.assertEqual(ctl.sanitize_art_url("file://remote-host/share/art.jpg"), "")
        self.assertEqual(ctl.sanitize_art_url("javascript:alert(1)"), "")
        self.assertEqual(ctl.sanitize_art_url("data:text/html,<script>"), "")
        self.assertEqual(ctl.sanitize_art_url(None), "")

        # MPRIS busName validation
        self.assertEqual(
            ctl.validate_bus_name("org.mpris.MediaPlayer2.brave.instance2793"),
            "org.mpris.MediaPlayer2.brave.instance2793",
        )
        for bad_bus in ("", "org.freedesktop.DBus", "--help", "-player", "org.mpris.MediaPlayer2.bad space"):
            with self.assertRaises(ValueError):
                ctl.validate_bus_name(bad_bus)

        # sinkId / streamId validation (reject leading '-' option injection)
        self.assertEqual(ctl.validate_audio_id("60", "sinkId"), "60")
        self.assertEqual(ctl.validate_audio_id("alsa_output.pci-0000_00_1f.3.hdmi-stereo", "sinkId"),
                         "alsa_output.pci-0000_00_1f.3.hdmi-stereo")
        for bad_id in ("", "-5", "--version", "-h", "bad id"):
            with self.assertRaises(ValueError):
                ctl.validate_audio_id(bad_id, "sinkId")

    def test_iso_parsing_and_turkish_reset_formatting(self) -> None:
        ref = datetime(2026, 11, 14, 20, 30, 0, tzinfo=timezone.utc)

        self.assertEqual(ctl.normalize_iso_utc("2026-11-14T20:50:00.123456+00:00"), "2026-11-14T20:50:00Z")
        self.assertEqual(ctl.normalize_iso_utc("2026-11-14T23:50:00+03:00"), "2026-11-14T20:50:00Z")
        self.assertEqual(ctl.normalize_iso_utc(""), "")

        self.assertEqual(ctl.format_reset_in("2026-11-14T20:50:00Z", now_utc=ref), "20m")
        self.assertEqual(ctl.format_reset_in("2026-11-14T21:51:04Z", now_utc=ref), "1h 21m")
        self.assertEqual(ctl.format_reset_in("2026-11-17T18:00:00Z", now_utc=ref), "2d 21h")
        self.assertEqual(ctl.format_reset_in("2026-11-14T20:00:00Z", now_utc=ref), "0m")
        self.assertEqual(ctl.format_reset_in(None, now_utc=ref), "—")

    def test_mpris_normalize_and_plasma_browser_dedup(self) -> None:
        brave_snap = ctl._normalize_player_snapshot(
            "org.mpris.MediaPlayer2.brave.instance2793",
            {"Identity": "Brave"},
            {
                "PlaybackStatus": "Playing",
                "Position": 42_500_000,
                "CanPlay": True,
                "CanPause": True,
                "CanGoNext": True,
                "CanGoPrevious": False,
                "CanSeek": True,
                "Metadata": {
                    "mpris:trackid": "/com/brave/Track1",
                    "mpris:length": 215_000_000,
                    "mpris:artUrl": "http://cleartext.example/drop.jpg",
                    "xesam:title": "Gruvbox Beats",
                    "xesam:artist": [""],
                    "xesam:album": "",
                },
            },
        )
        self.assertEqual(brave_snap["artUrl"], "")

        pbi_snap = ctl._normalize_player_snapshot(
            "org.mpris.MediaPlayer2.plasma-browser-integration",
            {"Identity": "Brave"},
            {
                "PlaybackStatus": "Playing",
                "Position": 42_500_000,
                "Metadata": {
                    "kde:pid": 2793,
                    "mpris:artUrl": "file:///tmp/art.png",
                    "xesam:title": "Gruvbox Beats",
                    "xesam:artist": ["Chill Synth"],
                    "xesam:album": "Late Night Coding",
                },
            },
        )
        spotify_snap = ctl._normalize_player_snapshot(
            "org.mpris.MediaPlayer2.spotify",
            {"Identity": "Spotify"},
            {
                "PlaybackStatus": "Paused",
                "Position": 10_000_000,
                "Metadata": {"xesam:title": "Paused Song", "xesam:artist": "Artist B"},
            },
        )

        merged = ctl.select_and_merge_players([spotify_snap, brave_snap, pbi_snap], selected_bus="")
        self.assertTrue(merged["available"])
        self.assertEqual(merged["activePlayer"], "org.mpris.MediaPlayer2.brave.instance2793")
        self.assertEqual(merged["playbackStatus"], "Playing")
        self.assertEqual(merged["artist"], "Chill Synth")
        self.assertEqual(merged["album"], "Late Night Coding")
        self.assertEqual(merged["artUrl"], "file:///tmp/art.png")
        self.assertEqual(merged["lengthSec"], 215.0)
        self.assertEqual(merged["positionSec"], 42.5)
        self.assertEqual(
            [p["busName"] for p in merged["players"]],
            ["org.mpris.MediaPlayer2.spotify", "org.mpris.MediaPlayer2.brave.instance2793"],
        )

        selected = ctl.select_and_merge_players(
            [spotify_snap, brave_snap, pbi_snap],
            selected_bus="org.mpris.MediaPlayer2.spotify",
        )
        self.assertEqual(selected["activePlayer"], "org.mpris.MediaPlayer2.spotify")
        self.assertEqual(selected["identity"], "Spotify")

    @unittest.skipUnless(importlib.util.find_spec("gi") is not None, "PyGObject (gi) yok")
    def test_mpris_shuffle_and_loop(self) -> None:
        snap = ctl._normalize_player_snapshot(
            "org.mpris.MediaPlayer2.spotify",
            {"Identity": "Spotify"},
            {"PlaybackStatus": "Playing", "Shuffle": True, "LoopStatus": "Track", "Metadata": {}},
        )
        self.assertTrue(snap["canShuffle"])
        self.assertTrue(snap["shuffle"])
        self.assertTrue(snap["canLoop"])
        self.assertEqual(snap["loopStatus"], "Track")
        bare = ctl._normalize_player_snapshot("org.mpris.MediaPlayer2.mpv", {}, {"PlaybackStatus": "Paused"})
        self.assertFalse(bare["canShuffle"])
        self.assertFalse(bare["canLoop"])
        merged = ctl.select_and_merge_players([snap])
        self.assertTrue(merged["canShuffle"] and merged["canLoop"])
        self.assertEqual([ctl.next_loop_status(x) for x in ("None", "Playlist", "Track", "bogus")],
                         ["Playlist", "Track", "None", "None"])

        from gi.repository import GLib  # type: ignore[import-untyped]

        fake_bus = mock.MagicMock()
        with mock.patch.object(ctl, "_get_session_bus", return_value=(fake_bus, mock.MagicMock(), GLib)), \
                mock.patch.object(ctl, "_dbus_get_prop", return_value="Playlist"):
            res = ctl.run_media_action("loop", ["org.mpris.MediaPlayer2.spotify"])
        self.assertEqual(res, {"ok": True, "loopStatus": "Track"})
        sent = fake_bus.call_sync.call_args.args
        self.assertEqual(sent[3], "Set")
        self.assertEqual(sent[4].unpack(), ("org.mpris.MediaPlayer2.Player", "LoopStatus", "Track"))

        with mock.patch.object(ctl, "_get_session_bus", return_value=(fake_bus, mock.MagicMock(), GLib)), \
                mock.patch.object(ctl, "_dbus_get_prop", return_value=True):
            res = ctl.run_media_action("shuffle", ["org.mpris.MediaPlayer2.spotify"])
        self.assertEqual(res, {"ok": True, "shuffle": False})

    def test_mpris_select_player_seek_and_transport(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(
            os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
        ):
            res = ctl.run_media_action("select-player", ["org.mpris.MediaPlayer2.mpv"])
            self.assertTrue(res["ok"])
            self.assertEqual(ctl.read_selected_player(), "org.mpris.MediaPlayer2.mpv")

            with self.assertRaises(ValueError):
                ctl.run_media_action("select-player", ["invalid.bus.name"])

            calls: list[tuple[str, Any]] = []

            class FakeBus:
                def __init__(self, fail_set_pos: bool = False):
                    self.fail_set_pos = fail_set_pos

                def call_sync(self, bus_name, obj_path, iface, method, params, reply_type, flags, timeout, cancellable):
                    if iface == "org.freedesktop.DBus.Properties" and method == "GetAll":
                        class Reply:
                            def unpack(self_inner):
                                return ({"Metadata": {"mpris:trackid": "/org/mpv/track/1"}, "Position": 10_000_000},)
                        return Reply()
                    if method == "SetPosition" and self.fail_set_pos:
                        raise RuntimeError("SetPosition unsupported")
                    calls.append((method, params))
                    return None

            class FakeGio:
                class DBusCallFlags:
                    NONE = 0

            class FakeGLib:
                @staticmethod
                def Variant(sig, val):
                    return (sig, val)

                @staticmethod
                def VariantType(sig):
                    return sig

            with mock.patch.object(ctl, "_get_session_bus", return_value=(FakeBus(False), FakeGio, FakeGLib)):
                out1 = ctl.run_media_action("seek", ["30.5", "org.mpris.MediaPlayer2.mpv"])
                self.assertTrue(out1["ok"])
                self.assertEqual(calls[-1], ("SetPosition", ("(ox)", ("/org/mpv/track/1", 30_500_000))))

                for cmd_name, expected_dbus in (("play-pause", "PlayPause"), ("next", "Next"), ("prev", "Previous")):
                    t_out = ctl.run_media_action(cmd_name, ["org.mpris.MediaPlayer2.mpv"])
                    self.assertTrue(t_out["ok"])
                    self.assertEqual(calls[-1][0], expected_dbus)

            with mock.patch.object(ctl, "_get_session_bus", return_value=(FakeBus(True), FakeGio, FakeGLib)):
                out2 = ctl.run_media_action("seek", ["30.5", "org.mpris.MediaPlayer2.mpv"])
                self.assertTrue(out2["ok"])
                self.assertEqual(calls[-1], ("Seek", ("(x)", (20_500_000,))))

    def test_audio_parsing_actions_and_option_injection_guard(self) -> None:
        self.assertEqual(ctl.parse_wpctl_volume_line("Volume: 0.25"), (25, False))
        self.assertEqual(ctl.parse_wpctl_volume_line("Volume: 1,35 [MUTED]"), (135, True))

        audio = ctl.build_audio_status_from_pactl(
            info_data={"default_sink_name": "alsa_output.hdmi", "default_source_name": "alsa_input.mic"},
            sinks_data=[
                {
                    "index": 221,
                    "name": "alsa_output.hdmi",
                    "description": "MSI HDMI",
                    "mute": False,
                    "volume": {
                        "front-left": {"value_percent": "25%"},
                        "front-right": {"value_percent": "25%"},
                    },
                    "properties": {"object.id": "60"},
                }
            ],
            sources_data=[
                {
                    "index": 10,
                    "name": "alsa_output.hdmi.monitor",
                    "mute": True,
                    "volume": {"front-left": {"value_percent": "100%"}},
                },
                {
                    "index": 11,
                    "name": "alsa_input.mic",
                    "mute": False,
                    "volume": {"front-left": {"value_percent": "85%"}},
                },
            ],
            sink_inputs_data=[
                {
                    "index": 301,
                    "mute": False,
                    "volume": {"front-left": {"value_percent": "100%"}},
                    "properties": {"object.id": "76", "application.name": "Brave", "media.name": "Playback"},
                },
                {
                    "index": 302,
                    "mute": False,
                    "volume": {"front-left": {"value_percent": "100%"}},
                    "properties": {"object.id": "77", "media.role": "event"},
                },
            ],
        )

        self.assertEqual(audio["volume"], 25)
        self.assertFalse(audio["muted"])
        self.assertEqual(audio["sinkId"], "60")
        self.assertEqual(audio["sinkName"], "MSI HDMI")
        self.assertEqual(audio["sourceVolume"], 85)
        self.assertEqual(len(audio["streams"]), 1)
        self.assertEqual(audio["streams"][0]["id"], "76")

        executed: list[list[str]] = []

        def fake_run_cmd(cmd: list[str], timeout: float = 2.0):
            executed.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        def fake_pactl_json(subargs: list[str]):
            if subargs == ["list", "sinks"]:
                return [{"index": 221, "name": "alsa_output.hdmi", "properties": {"object.id": "60"}}]
            if subargs == ["list", "sink-inputs"]:
                return [{"index": 301, "properties": {"object.id": "76"}}]
            return None

        with (
            mock.patch.object(ctl, "_run_cmd", side_effect=fake_run_cmd),
            mock.patch.object(ctl, "get_audio_status", return_value={"volume": 25}),
            mock.patch.object(ctl, "_pactl_json", side_effect=fake_pactl_json),
            mock.patch.object(ctl.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"),
        ):
            with io.StringIO() as buf, mock.patch("sys.stdout", buf):
                rc = ctl.main(["audio", "change-volume", "-5"])
            self.assertEqual(rc, 0)
            self.assertEqual(executed[-1], ["wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", "0.20"])

            ctl.run_audio_action("set-volume", ["180"])
            self.assertEqual(executed[-1], ["wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", "1.50"])

            self.assertTrue(ctl.run_audio_action("toggle-mute", [])["ok"])
            self.assertTrue(ctl.run_audio_action("toggle-mic", [])["ok"])

            self.assertTrue(ctl.run_audio_action("set-sink", ["60"])["ok"])
            self.assertIn(["wpctl", "set-default", "60"], executed)
            self.assertIn(["pactl", "set-default-sink", "alsa_output.hdmi"], executed)
            self.assertIn(["pactl", "move-sink-input", "301", "alsa_output.hdmi"], executed)

            self.assertTrue(ctl.run_audio_action("set-stream-volume", ["76", "125"])["ok"])
            self.assertEqual(executed[-1], ["pactl", "set-sink-input-volume", "301", "125%"])

            self.assertTrue(ctl.run_audio_action("toggle-stream-mute", ["76"])["ok"])
            self.assertEqual(executed[-1], ["pactl", "set-sink-input-mute", "301", "toggle"])

            with self.assertRaises(ValueError):
                ctl.run_audio_action("set-sink", ["--bad-flag"])
            with self.assertRaises(ValueError):
                ctl.run_audio_action("set-stream-volume", ["-76", "50"])

    def test_claude_quota_live_fallback_and_secret_redaction(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            ephemeral_secret = secrets.token_hex(16)
            cred_file = tmp_path / "creds.json"
            cred_file.write_text(
                json.dumps({"claudeAiOauth": {"accessToken": ephemeral_secret}}),
                encoding="utf-8",
            )
            fallback_file = tmp_path / "claude_cfg.json"
            fallback_file.write_text(
                json.dumps(
                    {
                        "cachedUsageUtilization": {
                            "utilization": {
                                "five_hour": {"utilization": 12, "resets_at": "2026-11-14T21:00:00Z"},
                                "seven_day": {"utilization": 42, "resets_at": "2026-11-17T18:00:00Z"},
                                "limits": [
                                    {
                                        "kind": "weekly_scoped",
                                        "percent": 70,
                                        "resets_at": "2026-11-17T18:00:00Z",
                                        "scope": {"model": {"display_name": "Fable"}},
                                    }
                                ],
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )

            seen_headers: dict[str, str] = {}

            class FakeResp(io.BytesIO):
                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    self.close()

            def fake_urlopen_ok(req, timeout=6.0):
                for k, v in req.header_items():
                    seen_headers[k.lower()] = v
                payload = {
                    "five_hour": {"utilization": 5.0, "resets_at": "2026-11-14T20:50:00Z"},
                    "seven_day": {"utilization": 27.0, "resets_at": "2026-11-17T18:00:00Z"},
                    "limits": [
                        {
                            "kind": "weekly_scoped",
                            "percent": 26,
                            "resets_at": "2026-11-17T18:00:00Z",
                            "scope": {"model": {"display_name": "Fable"}},
                        }
                    ],
                }
                return FakeResp(json.dumps(payload).encode("utf-8"))

            ref = datetime(2026, 11, 14, 20, 30, 0, tzinfo=timezone.utc)
            env_patch = {
                "PLASMA_QUOTA_ISLAND_CACHE_DIR": str(tmp_path / "cache"),
                "CLAUDE_CREDENTIALS_PATH": str(cred_file),
                "CLAUDE_CONFIG_PATH": str(fallback_file),
            }
            with mock.patch.dict(os.environ, env_patch):
                with mock.patch.object(urllib.request, "urlopen", side_effect=fake_urlopen_ok):
                    live = ctl.fetch_claude_quota(now_utc=ref)
                self.assertEqual(seen_headers["authorization"], f"Bearer {ephemeral_secret}")
                self.assertEqual(seen_headers["anthropic-beta"], "oauth-2025-04-20")
                self.assertEqual(seen_headers["user-agent"], ctl.QUOTA_USER_AGENT)
                self.assertTrue(live["available"])
                self.assertEqual(live["source"], "live")
                self.assertEqual(live["fiveHour"]["usedPct"], 5)
                self.assertEqual(live["sevenDay"]["usedPct"], 27)
                self.assertEqual(live["fableWeekly"]["usedPct"], 26)
                self.assertNotIn(ephemeral_secret, json.dumps(live))

                def fake_urlopen_fail(req, timeout=6.0):
                    raise urllib.error.URLError("offline")

                with mock.patch.object(urllib.request, "urlopen", side_effect=fake_urlopen_fail):
                    fb = ctl.fetch_claude_quota(now_utc=ref)
                self.assertTrue(fb["available"])
                self.assertEqual(fb["source"], "cache")
                self.assertEqual(fb["fiveHour"]["usedPct"], 12)
                self.assertEqual(fb["sevenDay"]["usedPct"], 42)
                self.assertEqual(fb["fableWeekly"]["usedPct"], 70)
                self.assertNotIn(ephemeral_secret, json.dumps(fb))

    def test_agy_statusline_record_merge_and_overlay(self) -> None:
        ref = datetime(2026, 11, 27, 11, 0, 0, tzinfo=timezone.utc)
        turn = {"quota": {
            "gemini-5h": {"remaining_fraction": 1, "reset_time": "2026-11-27T15:42:48Z"},
            "gemini-weekly": {"remaining_fraction": 0.612, "reset_time": "2026-12-03T07:02:26Z"},
            "3p-5h": {"remaining_fraction": 0.8, "reset_time": "2026-11-27T16:00:00Z"},
            "3p-weekly": {"remaining_fraction": 0.9, "reset_time": "2026-12-04T11:00:00Z"},
        }, "plan_tier": "Google AI Ultra", "model": {"display_name": "Gemini 4 Neon"}}
        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(
            os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
        ):
            ctl.record_agy_statusline(json.dumps(turn))
            # An older session reporting less use in the same window does not overwrite.
            older = {"quota": {"gemini-weekly": {"remaining_fraction": 0.95, "reset_time": "2026-12-03T07:02:26Z"}}}
            ctl.record_agy_statusline(json.dumps(older))
            ctl.record_agy_statusline("not json")
            saved = ctl._read_agy_statusline()
            self.assertEqual(saved["quota"]["gemini-weekly"]["remaining_fraction"], 0.612)
            self.assertEqual(set(saved["quota"]), set(ctl.AGY_STATUSLINE_KEYS))
            self.assertNotIn("plan_tier", json.dumps(saved))  # only the buckets are kept

            # API unavailable (token expired): the status line makes AGY available.
            down = ctl._with_reason(ctl._unavailable_agy_quota(), "auth_expired", 401)
            q = ctl.apply_agy_statusline(down, dict(saved, at=int(ref.timestamp())), ref)
            self.assertTrue(q["available"])
            self.assertEqual(q["source"], "statusline")
            self.assertNotIn("reason", q)
            self.assertEqual(q["geminiPool"]["usedPct"], 0)
            self.assertEqual(q["claudePool"]["usedPct"], 20)
            self.assertEqual(q["weekly"]["usedPct"], 39)  # the more used group's week
            self.assertEqual(q["weekly"]["resetsAt"], "2026-12-03T07:02:26Z")

            # A window that has reset since the last report counts as unused.
            later = datetime(2026, 11, 27, 16, 30, 0, tzinfo=timezone.utc)
            q2 = ctl.apply_agy_statusline(down, dict(saved, at=int(ref.timestamp())), later)
            self.assertEqual(q2["claudePool"]["usedPct"], 0)
            self.assertEqual(q2["claudePool"]["resetsAt"], "")

            # Too old a report is ignored; a live API result keeps its source.
            stale = dict(saved, at=int(ref.timestamp()) - ctl.AGY_STATUSLINE_MAX_AGE_SEC - 1)
            self.assertFalse(ctl.apply_agy_statusline(down, stale, ref)["available"])
            live = {**ctl._unavailable_agy_quota(), "available": True, "source": "live"}
            self.assertEqual(ctl.apply_agy_statusline(live, dict(saved, at=int(ref.timestamp())), ref)["source"], "live")
        self.assertIsNone(ctl.merge_agy_statusline({"quota": {}}, {}))

    def test_agy_statusline_command_prints_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            env = {**os.environ, "PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
            payload = json.dumps({"quota": {"gemini-5h": {"remaining_fraction": 0.5, "reset_time": "2026-11-27T15:00:00Z"}}})
            res = subprocess.run(["python3", str(SCRIPT_PATH), "agy-statusline"], input=payload,
                                 capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual(res.returncode, 0)
            self.assertEqual(res.stdout, "")  # agy shows whatever the status line prints
            self.assertEqual(oct(os.stat(Path(tmpdir) / ctl.AGY_STATUSLINE_FILE).st_mode & 0o777), "0o600")

    def test_agy_models_parser_and_quotas_ttl(self) -> None:
        ref = datetime(2026, 11, 14, 20, 30, 0, tzinfo=timezone.utc)
        sample_5h = {
            "models": {
                "tab_flash_lite_preview": {"quotaInfo": {"remainingFraction": 1}},
                "gemini-3.8-flash-tiered": {
                    "displayName": "Gemini 4 Carbon",
                    "quotaInfo": {"remainingFraction": 0.94, "resetTime": "2026-11-14T21:51:04Z"},
                },
                # Protobuf3 omits remainingFraction when 0.0 (100% exhausted)
                "claude-opus-5-5-high": {
                    "displayName": "Claude Opus 5.5",
                    "quotaInfo": {"resetTime": "2026-11-14T22:30:00Z"},
                },
            }
        }
        parsed = ctl.parse_agy_models_payload(sample_5h, source="live", now_utc=ref)
        self.assertTrue(parsed["available"])
        self.assertEqual(parsed["geminiPool"]["usedPct"], 6)
        self.assertEqual(parsed["claudePool"]["usedPct"], 100)
        self.assertEqual(parsed["weekly"]["usedPct"], -1)

        # When >6h weekly reset cap is active, weekly reports real cap percentage
        sample_7d = {
            "models": {
                "gemini-3.8-flash-tiered": {
                    "displayName": "Gemini 4 Carbon",
                    "quotaInfo": {"remainingFraction": 0.20, "resetTime": "2026-11-17T18:00:00Z"},
                }
            }
        }
        parsed_7d = ctl.parse_agy_models_payload(sample_7d, source="live", now_utc=ref)
        self.assertEqual(parsed_7d["weekly"]["usedPct"], 80)
        self.assertEqual(parsed_7d["weekly"]["resetInHuman"], "2d 21h")

        # When retrieveUserQuotaSummary provides a 3p-weekly bucket, weekly reports its usedPct and resetTime
        sample_summary = {
            "groups": [
                {
                    "buckets": [
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "resetTime": "2026-11-21T19:44:18Z",
                            "remainingFraction": 0.85,
                        },
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "resetTime": "2026-11-15T00:44:18Z",
                            "remainingFraction": 1,
                        },
                    ]
                }
            ]
        }
        parsed_with_summary = ctl.parse_agy_models_payload(
            sample_5h,
            source="live",
            now_utc=ref,
            summary_payload=sample_summary,
        )
        self.assertEqual(parsed_with_summary["weekly"]["usedPct"], 15)
        self.assertEqual(parsed_with_summary["weekly"]["remainingPct"], 85)
        self.assertEqual(parsed_with_summary["weekly"]["resetsAt"], "2026-11-21T19:44:18Z")
        self.assertEqual(parsed_with_summary["weekly"]["resetInHuman"], "6d 23h")

        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(
            os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
        ):
            calls = {"count": 0}

            def fake_claude(_now=None):
                calls["count"] += 1
                return {
                    "available": True,
                    "source": "live",
                    "fiveHour": {"usedPct": calls["count"], "remainingPct": 100 - calls["count"], "resetsAt": "", "resetInHuman": "—"},
                    "sevenDay": {"usedPct": 10, "remainingPct": 90, "resetsAt": "", "resetInHuman": "—"},
                    "fableWeekly": None,
                }

            with (
                mock.patch.object(ctl, "fetch_claude_quota", side_effect=fake_claude),
                mock.patch.object(ctl, "fetch_agy_quota", return_value=ctl._unavailable_agy_quota()),
                mock.patch.object(ctl, "fetch_codex_quota", return_value=ctl._unavailable_codex_quota(configured=False)),
            ):
                first = ctl.get_quotas(force=False)
                self.assertEqual(first["claude"]["fiveHour"]["usedPct"], 1)
                first["fetchedAtEpoch"] = int(ctl.time.time()) - 5
                ctl._write_quotas_cache(first)

                cached_hit = ctl.get_quotas(force=False)
                self.assertEqual(cached_hit["claude"]["fiveHour"]["usedPct"], 1)
                self.assertEqual(calls["count"], 1)

                forced = ctl.get_quotas(force=True)
                self.assertEqual(forced["claude"]["fiveHour"]["usedPct"], 2)
                self.assertEqual(calls["count"], 2)

    def test_quota_429_keeps_last_good_value_and_reports_reason(self) -> None:
        now = int(ctl.time.time())
        good = {
            "available": True, "configured": True, "source": "live", "dataAt": now - 600,
            "fiveHour": {"usedPct": 16, "remainingPct": 84, "resetsAt": "", "resetInHuman": "—"},
            "sevenDay": {"usedPct": 94, "remainingPct": 6, "resetsAt": "", "resetInHuman": "—"},
            "fableWeekly": None,
        }
        # Canlı ucun 429'u sonrası fetch_claude_quota'nın döndürdüğü bayat yerel yedek (asıl hata yolu)
        stale_local = {**good, "source": "cache", "dataAt": now - 5300, "reason": "rate_limited", "httpStatus": 429}
        rate_limited = ctl._with_reason(ctl._unavailable_claude_quota(), "rate_limited", 429)
        others = {
            "fetch_agy_quota": ctl._unavailable_agy_quota(configured=False),
            "fetch_codex_quota": ctl._unavailable_codex_quota(configured=False),
        }
        for failing in (stale_local, rate_limited):
            with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}), \
                    mock.patch.object(ctl, "fetch_claude_quota", return_value=dict(failing)), \
                    mock.patch.object(ctl, "fetch_agy_quota", return_value=others["fetch_agy_quota"]), \
                    mock.patch.object(ctl, "fetch_codex_quota", return_value=others["fetch_codex_quota"]):
                ctl._write_quotas_cache({"claude": good, "fetchedAt": {"claude": now - 600}})
                res = ctl.get_quotas(force=True)
                self.assertTrue(res["claude"]["available"])
                self.assertEqual(res["claude"]["source"], "cache")
                self.assertEqual(res["claude"]["fiveHour"]["usedPct"], 16)
                self.assertEqual((res["claude"]["reason"], res["claude"]["httpStatus"]), ("rate_limited", 429))
                # İkinci başarısız çağrı da son iyi değeri görür (önbellek ezilmedi).
                again = ctl.get_quotas(force=True)
                self.assertTrue(again["claude"]["available"])
                stored = ctl._read_quotas_cache()["claude"]
                self.assertTrue(stored["available"])
                self.assertEqual(stored["dataAt"], now - 600)
                # 30 dk'yı aşınca unavailable + neden.
                with mock.patch.object(ctl.time, "time", return_value=now + 31 * 60):
                    late = ctl.get_quotas(force=True)
                self.assertFalse(late["claude"]["available"])
                self.assertEqual(late["claude"]["reason"], "rate_limited")
                # TTL kısa yolu bayat önbellek değerini "taze" diye döndürmez.
                with mock.patch.object(ctl.time, "time", return_value=now + 31 * 60):
                    ttl = ctl.get_quotas(force=False)
                self.assertFalse(ttl["claude"]["available"])

    def test_removed_credentials_hide_quota_within_ttl(self) -> None:
        live = {
            "available": True, "configured": True, "source": "live",
            "fiveHour": {"usedPct": 16, "remainingPct": 84, "resetsAt": "", "resetInHuman": "—"},
            "sevenDay": {"usedPct": 94, "remainingPct": 6, "resetsAt": "", "resetInHuman": "—"},
            "fableWeekly": None,
        }
        gone = ctl._with_reason(ctl._unavailable_claude_quota(configured=False), "no_credentials")
        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}), \
                mock.patch.object(ctl, "fetch_claude_quota", side_effect=[dict(live), dict(gone), dict(gone)]) as fetch, \
                mock.patch.object(ctl, "fetch_agy_quota", return_value=ctl._unavailable_agy_quota(configured=False)), \
                mock.patch.object(ctl, "fetch_codex_quota", return_value=ctl._unavailable_codex_quota(configured=False)):
            self.assertTrue(ctl.get_quotas(force=True)["claude"]["available"])
            removed = ctl.get_quotas(force=True)
            self.assertFalse(removed["claude"]["available"])
            # 90 sn TTL içinde eski iyi değer geri gelmez.
            within_ttl = ctl.get_quotas(force=False)
            self.assertFalse(within_ttl["claude"]["available"])
            self.assertFalse(ctl._read_quotas_cache()["claude"]["available"])
            self.assertEqual(fetch.call_count, 3)  # unavailable sonuç TTL ile saklanmaz

    def test_quota_failure_reason_mapping(self) -> None:
        def http(code: int) -> urllib.error.HTTPError:
            return urllib.error.HTTPError("https://example.invalid", code, "x", {}, io.BytesIO(b""))  # type: ignore[arg-type]

        self.assertEqual(ctl._failure_reason(http(429)), ("rate_limited", 429))
        self.assertEqual(ctl._failure_reason(http(401)), ("auth_expired", 401))
        self.assertEqual(ctl._failure_reason(http(503)), ("server_error", 503))
        self.assertEqual(ctl._failure_reason(urllib.error.URLError("offline")), ("network", 0))
        self.assertEqual(ctl._failure_reason(json.JSONDecodeError("x", "", 0)), ("bad_response", 0))
        with tempfile.TemporaryDirectory() as tmpdir:
            cred = Path(tmpdir) / "c.json"
            cred.write_text(json.dumps({"claudeAiOauth": {"accessToken": "tok-SECRET"}}), encoding="utf-8")
            env = {"CLAUDE_CREDENTIALS_PATH": str(cred), "CLAUDE_CONFIG_PATH": str(Path(tmpdir) / "none.json")}
            with mock.patch.dict(os.environ, env), mock.patch.object(urllib.request, "urlopen", side_effect=http(429)):
                q = ctl.fetch_claude_quota()
            self.assertFalse(q["available"])
            self.assertEqual((q["reason"], q["httpStatus"]), ("rate_limited", 429))
            self.assertNotIn("SECRET", json.dumps(q))
            with mock.patch.dict(os.environ, {"CODEX_HOME": tmpdir}):
                self.assertEqual(ctl.fetch_codex_quota()["reason"], "no_credentials")

    def test_codex_usage_parser_and_credentials(self) -> None:
        ref = datetime(2026, 11, 14, 20, 30, 0, tzinfo=timezone.utc)
        reset_5h = int(datetime(2026, 11, 14, 22, 0, 0, tzinfo=timezone.utc).timestamp())
        reset_7d = int(datetime(2026, 11, 17, 18, 0, 0, tzinfo=timezone.utc).timestamp())
        # openai/codex RateLimitStatusPayload biçimi (pencereler ters sırada da gelse süreye göre eşlenir)
        payload = {
            "plan_type": "plus",
            "rate_limit": {
                "allowed": True,
                "limit_reached": False,
                "primary_window": {"used_percent": 40, "limit_window_seconds": 604800,
                                   "reset_after_seconds": 1, "reset_at": reset_7d},
                "secondary_window": {"used_percent": 12, "limit_window_seconds": 18000,
                                     "reset_after_seconds": 1, "reset_at": reset_5h},
            },
        }
        parsed = ctl.parse_codex_usage_payload(payload, source="live", now_utc=ref)
        self.assertTrue(parsed["available"])
        self.assertTrue(parsed["configured"])
        self.assertEqual(parsed["fiveHour"]["usedPct"], 12)
        self.assertEqual(parsed["fiveHour"]["resetsAt"], "2026-11-14T22:00:00Z")
        self.assertEqual(parsed["fiveHour"]["resetInHuman"], "1h 30m")
        self.assertEqual(parsed["sevenDay"]["usedPct"], 40)
        self.assertEqual(parsed["sevenDay"]["remainingPct"], 60)
        self.assertNotIn("windowSec", json.dumps(parsed))

        # Yalnız primary (süresiz) -> 5sa; haftalık eksik -1
        only_primary = ctl.parse_codex_usage_payload(
            {"rate_limit": {"primary_window": {"used_percent": 7, "reset_at": reset_5h}}}, now_utc=ref)
        self.assertEqual(only_primary["fiveHour"]["usedPct"], 7)
        self.assertEqual(only_primary["sevenDay"]["usedPct"], -1)

        # Tanınmayan biçim -> uydurma yok, unavailable
        for bad in ({}, {"rate_limit": None}, {"rate_limit": {"primary_window": {"foo": 1}}}):
            self.assertFalse(ctl.parse_codex_usage_payload(bad, now_utc=ref)["available"])

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            ephemeral_secret = secrets.token_hex(16)
            account = secrets.token_hex(6)
            seen_headers: dict[str, str] = {}

            class FakeResp(io.BytesIO):
                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    self.close()

            def fake_urlopen(req, timeout=6.0):
                seen_headers["url"] = req.full_url
                for k, v in req.header_items():
                    seen_headers[k.lower()] = v
                return FakeResp(json.dumps(payload).encode("utf-8"))

            # Kimlik yok -> configured False ve ağ isteği yapılmaz
            with mock.patch.dict(os.environ, {"CODEX_HOME": str(tmp_path)}), \
                    mock.patch.object(urllib.request, "urlopen", side_effect=AssertionError("ağ isteği olmamalı")):
                missing = ctl.fetch_codex_quota(now_utc=ref)
            self.assertFalse(missing["available"])
            self.assertFalse(missing["configured"])

            (tmp_path / "auth.json").write_text(json.dumps(
                {"tokens": {"access_token": ephemeral_secret, "account_id": account}}), encoding="utf-8")
            with mock.patch.dict(os.environ, {"CODEX_HOME": str(tmp_path)}), \
                    mock.patch.object(urllib.request, "urlopen", side_effect=fake_urlopen):
                live = ctl.fetch_codex_quota(now_utc=ref)
            self.assertEqual(seen_headers["url"], ctl.CODEX_USAGE_URL)
            self.assertEqual(seen_headers["authorization"], f"Bearer {ephemeral_secret}")
            self.assertEqual(seen_headers["chatgpt-account-id"], account)
            self.assertTrue(live["available"])
            self.assertEqual(live["fiveHour"]["usedPct"], 12)
            self.assertNotIn(ephemeral_secret, json.dumps(live))
            self.assertNotIn(account, json.dumps(live))

            def fail(req, timeout=6.0):
                raise urllib.error.URLError("offline")

            with mock.patch.dict(os.environ, {"CODEX_HOME": str(tmp_path)}), \
                    mock.patch.object(urllib.request, "urlopen", side_effect=fail):
                offline = ctl.fetch_codex_quota(now_utc=ref)
            self.assertFalse(offline["available"])
            self.assertTrue(offline["configured"])

    def test_quotas_disabled_and_unconfigured_providers(self) -> None:
        def win(pct):
            return {"usedPct": pct, "remainingPct": 100 - pct, "resetsAt": "", "resetInHuman": "—"}

        live_codex = {"available": True, "configured": True, "source": "live",
                      "fiveHour": win(3), "sevenDay": win(9)}
        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(
            os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
        ):
            never = mock.Mock(side_effect=AssertionError("kapalı sağlayıcı sorgulanmamalı"))
            with (
                mock.patch.object(ctl, "fetch_claude_quota", never),
                mock.patch.object(ctl, "fetch_agy_quota", return_value=ctl._unavailable_agy_quota(configured=False)),
                mock.patch.object(ctl, "fetch_codex_quota", return_value=live_codex) as codex_mock,
            ):
                out = ctl.get_quotas(force=True, providers=["agy", "codex"])
                self.assertEqual(out["providers"], ["agy", "codex"])
                self.assertNotIn("claude", out)
                self.assertFalse(out["agy"]["configured"])
                self.assertEqual(out["codex"]["fiveHour"]["usedPct"], 3)

                # Sağlayıcı başına TTL: codex taze -> tekrar sorgulanmaz
                again = ctl.get_quotas(force=False, providers=["codex"])
                self.assertEqual(again["codex"]["fiveHour"]["usedPct"], 3)
                self.assertEqual(codex_mock.call_count, 1)

                # Hiç sağlayıcı yok -> hiçbir fetch yok
                self.assertEqual(ctl.get_quotas(force=True, providers=[])["providers"], [])

            cache_file = Path(tmpdir) / "quotas_cache.json"
            self.assertEqual(cache_file.stat().st_mode & 0o777, 0o600)
            cached = json.loads(cache_file.read_text(encoding="utf-8"))
            self.assertIn("codex", cached["fetchedAt"])

            # Uç nokta düşünce önceki veri kullanılır; kimlik silinmişse kullanılmaz
            with mock.patch.object(ctl, "fetch_codex_quota", return_value=ctl._unavailable_codex_quota()):
                fb = ctl.get_quotas(force=True, providers=["codex"])
            self.assertEqual(fb["codex"]["source"], "cache")
            self.assertEqual(fb["codex"]["fiveHour"]["usedPct"], 3)
            with mock.patch.object(ctl, "fetch_codex_quota",
                                   return_value=ctl._unavailable_codex_quota(configured=False)):
                gone = ctl.get_quotas(force=True, providers=["codex"])
            self.assertFalse(gone["codex"]["available"])
            self.assertFalse(gone["codex"]["configured"])

        # CLI: bilinmeyen sağlayıcı adı yok sayılır
        with mock.patch.object(ctl, "get_quotas", return_value={}) as gq, \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            ctl.main(["quotas", "--providers", "codex,evil;rm", "--force"])
        gq.assert_called_once_with(force=True, providers=["codex"])

    def test_stale_quota_cache_is_bounded(self) -> None:
        def win(pct, reset=""):
            return {"usedPct": pct, "remainingPct": 100 - pct, "resetsAt": reset, "resetInHuman": "—"}

        live = {"available": True, "configured": True, "source": "live", "fiveHour": win(3), "sevenDay": win(9)}
        down = ctl._unavailable_codex_quota()
        with tempfile.TemporaryDirectory() as tmpdir, mock.patch.dict(
            os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir}
        ):
            t0 = 1_800_000_000
            with mock.patch.object(ctl.time, "time", return_value=t0), \
                    mock.patch.object(ctl, "fetch_codex_quota", return_value=dict(live)):
                first = ctl.get_quotas(force=True, providers=["codex"])
            self.assertEqual(first["codex"]["dataAt"], t0)

            # Uç düştü, veri 10 dk eski: önbellek kullanılır, dataAt korunur (UI bayat çizer)
            with mock.patch.object(ctl.time, "time", return_value=t0 + 600), \
                    mock.patch.object(ctl, "fetch_codex_quota", return_value=dict(down)):
                fb = ctl.get_quotas(force=True, providers=["codex"])
            self.assertTrue(fb["codex"]["available"])
            self.assertEqual(fb["codex"]["source"], "cache")
            self.assertEqual(fb["codex"]["dataAt"], t0)

            # 31 dk sonra hâlâ kapalı: bayat veri gösterilmez (yeniden yedeklemek dataAt'i tazelemez)
            with mock.patch.object(ctl.time, "time", return_value=t0 + 31 * 60), \
                    mock.patch.object(ctl, "fetch_codex_quota", return_value=dict(down)):
                old = ctl.get_quotas(force=True, providers=["codex"])
            self.assertFalse(old["codex"]["available"])
            self.assertTrue(old["codex"]["configured"])

        now = 1_800_000_000
        fresh = {**live, "dataAt": now - 60}
        self.assertTrue(ctl._cached_quota_usable(fresh, now))
        self.assertFalse(ctl._cached_quota_usable({**live, "dataAt": 0}, now))
        past = datetime.fromtimestamp(now - 1, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertFalse(ctl._cached_quota_usable({**fresh, "fiveHour": win(3, past)}, now))

        # ~/.claude.json yedeği: fetchedAtMs yoksa ya da eskiyse gösterilmez
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Path(tmpdir) / "claude.json"
            env = {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmpdir, "CLAUDE_CREDENTIALS_PATH": str(Path(tmpdir) / "none.json"),
                   "CLAUDE_CONFIG_PATH": str(cfg)}
            util = {"five_hour": {"utilization": 12}, "seven_day": {"utilization": 42}}
            with mock.patch.dict(os.environ, env):
                for fetched_ms, expect in ((None, False), ((now - 3600) * 1000, False), ((now - 60) * 1000, True)):
                    body = {"utilization": util}
                    if fetched_ms is not None:
                        body["fetchedAtMs"] = fetched_ms
                    cfg.write_text(json.dumps({"cachedUsageUtilization": body}), encoding="utf-8")
                    with mock.patch.object(ctl.time, "time", return_value=now):
                        res = ctl.get_quotas(force=True, providers=["claude"])
                    self.assertEqual(res["claude"]["available"], expect, fetched_ms)

    def test_qml_contracts_and_qmllint(self) -> None:
        exec_src = EXEC_QML_PATH.read_text(encoding="utf-8")
        self.assertIn('engine: "executable"', exec_src)
        self.assertIn("disconnectSource(", exec_src)
        self.assertIn("#seq-", exec_src)
        self.assertIn("_seq", exec_src)
        self.assertNotIn("createQmlObject", exec_src)
        self.assertNotIn("createObject", exec_src)

        backend_src = BACKEND_QML_PATH.read_text(encoding="utf-8")
        self.assertRegex(
            backend_src,
            r"if \(providers\.length === 0\) \{\s*root\.quotasLoaded = true;",
            "Sağlayıcı yokken quotasLoaded true olmalı (Kotalar sekmesi gizlenebilsin)",
        )
        required_props = [
            "expanded",
            "mediaAvailable", "activePlayer", "playerIdentity", "playbackStatus",
            "trackTitle", "trackArtist", "trackAlbum", "artUrl", "lengthSec", "positionSec",
            "canPlay", "canPause", "canGoNext", "canGoPrevious", "canSeek", "players",
            "volume", "muted", "sinkId", "sinkName", "sourceVolume", "sourceMuted",
            "sinks", "streams", "claudeQuota", "agyQuota", "quotasUpdatedAt", "quotasLoading",
            "claude5hUsed", "claude7dUsed", "claudeFable7dUsed",
            "agyGemini5hUsed", "agyClaude5hUsed", "agy7dUsed",
            "codexQuota", "codex5hUsed", "codex7dUsed",
            "claudeEnabled", "agyEnabled", "codexEnabled",
            "claudeShown", "agyShown", "codexShown", "anyQuotaShown",
            "liveData", "herdrWorkingCount", "herdrBlockedCount", "herdrDoneCount", "herdrAgents",
            "houraData", "powerProfile", "batteryData", "bluetoothData",
            "shelfItems", "shelfCount",
            "_busyStatus", "_busyQuotas", "_busyLive",
        ]
        for prop in required_props:
            self.assertIn(prop, backend_src, f"Missing property in Backend.qml: {prop}")

        required_funcs = [
            "function playPause(", "function next(", "function previous(", "function seek(",
            "function selectPlayer(", "function setVolume(", "function changeVolume(",
            "function toggleMute(", "function toggleMic(", "function setSink(",
            "function setStreamVolume(", "function toggleStreamMute(",
            "function refreshStatus(", "function refreshQuotas(",
            "function refreshLive(", "function focusAgent(", "function setPowerProfile(",
            "function shelfAdd(", "function shelfRemove(", "function shelfClear(", "function shelfOpen(",
        ]
        for fn in required_funcs:
            self.assertIn(fn, backend_src, f"Missing function in Backend.qml: {fn}")

        self.assertIn("3000", backend_src)
        if not QMLLINT_BIN.exists():
            self.skipTest("Qt 6 qmllint yok (/usr/lib/qt6/bin/qmllint)")
        lint = subprocess.run(
            [str(QMLLINT_BIN), "-I", "/usr/lib/qt6/qml", str(EXEC_QML_PATH), str(BACKEND_QML_PATH)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(lint.returncode, 0, f"qmllint failed:\n{lint.stdout}\n{lint.stderr}")
        self.assertEqual(lint.stdout.strip(), "")
        self.assertEqual(lint.stderr.strip(), "")

    def test_no_secrets_emails_or_uuids_in_owned_files(self) -> None:
        uuid_re = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
        token_re = re.compile(r"(sk-ant-[A-Za-z0-9_-]+|ya29\.[A-Za-z0-9._-]+)")
        email_re = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

        self.assertTrue(os.access(SCRIPT_PATH, os.X_OK), "island_ctl.py must be executable (chmod +x)")
        for path in (SCRIPT_PATH, EXEC_QML_PATH, BACKEND_QML_PATH, Path(__file__).resolve()):
            content = path.read_text(encoding="utf-8")
            self.assertIsNone(uuid_re.search(content), f"UUID literal found in {path.name}")
            self.assertIsNone(token_re.search(content), f"Token prefix found in {path.name}")
            self.assertIsNone(email_re.search(content), f"Email literal found in {path.name}")

    def test_live_status_and_quotas_integration(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            env = os.environ.copy()
            env["PLASMA_QUOTA_ISLAND_CACHE_DIR"] = tmpdir

            r_status = subprocess.run(
                [SYSTEM_PYTHON, str(SCRIPT_PATH), "status"],
                capture_output=True,
                text=True,
                env=env,
                timeout=10,
                check=True,
            )
            status = json.loads(r_status.stdout)
            self.assertIn("media", status)
            self.assertIn("audio", status)
            self.assertIsInstance(status["media"]["available"], bool)
            self.assertIsInstance(status["media"]["players"], list)
            self.assertTrue(0 <= status["audio"]["volume"] <= 150)

            r_quotas = subprocess.run(
                [SYSTEM_PYTHON, str(SCRIPT_PATH), "quotas", "--force"],
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
                check=True,
            )
            quotas = json.loads(r_quotas.stdout)
            self.assertIn("updatedAt", quotas)
            self.assertIn("fetchedAtEpoch", quotas)
            self.assertIn("claude", quotas)
            self.assertIn("agy", quotas)
            self.assertIn("codex", quotas)

            if quotas["claude"]["available"]:
                self.assertTrue(-1 <= quotas["claude"]["fiveHour"]["usedPct"] <= 100)
                self.assertTrue(-1 <= quotas["claude"]["sevenDay"]["usedPct"] <= 100)

            if quotas["agy"]["available"]:
                self.assertTrue(0 <= quotas["agy"]["geminiPool"]["usedPct"] <= 100)
                self.assertTrue(0 <= quotas["agy"]["claudePool"]["usedPct"] <= 100)
                self.assertTrue(-1 <= quotas["agy"]["weekly"]["usedPct"] <= 100)

            raw_out = r_quotas.stdout + (Path(tmpdir) / "quotas_cache.json").read_text(encoding="utf-8")
            self.assertNotIn("sk-ant-", raw_out)
            self.assertNotIn("ya29.", raw_out)
            self.assertNotIn("@", raw_out)


if __name__ == "__main__":
    unittest.main()
