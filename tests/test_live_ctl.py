"""Unit, security, QML contract, and live integration tests for live_ctl.py.

Uses Python's standard library `unittest` so `python3 -m unittest discover -s tests`
runs directly without external test runner dependencies.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import threading
import time
from typing import Any
import unittest
from unittest import mock
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "package" / "contents" / "scripts" / "live_ctl.py"
LIVE_QML_PATH = REPO_ROOT / "package" / "contents" / "ui" / "LiveSection.qml"
SHELF_QML_PATH = REPO_ROOT / "package" / "contents" / "ui" / "ShelfSection.qml"
QMLLINT_BIN = Path("/usr/lib/qt6/bin/qmllint")


def _load_ctl_module():
    spec = importlib.util.spec_from_file_location("live_ctl", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ctl = _load_ctl_module()


def _init_sample_houra_db(db_file: Path, ref_date: dt.date) -> None:
    conn = sqlite3.connect(str(db_file))
    conn.executescript(
        """
        CREATE TABLE sessions (
            id INTEGER PRIMARY KEY,
            category_id INTEGER NOT NULL,
            goal TEXT NOT NULL,
            work_min INTEGER NOT NULL,
            rest_min INTEGER NOT NULL,
            start REAL NOT NULL,
            end REAL,
            focus_sec INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            emergency INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE todos (
            id INTEGER PRIMARY KEY,
            day TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            state INTEGER NOT NULL DEFAULT 0,
            session_id INTEGER,
            position INTEGER NOT NULL DEFAULT 0,
            priority INTEGER NOT NULL DEFAULT 1,
            scope TEXT NOT NULL DEFAULT 'day',
            end_day TEXT NOT NULL DEFAULT ''
        );
        """
    )
    day_start = dt.datetime.combine(ref_date, dt.time(9, 0)).timestamp()
    yesterday_start = dt.datetime.combine(ref_date - dt.timedelta(days=1), dt.time(14, 0)).timestamp()
    today_iso = ref_date.isoformat()
    yesterday_iso = (ref_date - dt.timedelta(days=1)).isoformat()

    # Yesterday completed session (must NOT count in today's summary)
    conn.execute(
        "INSERT INTO sessions (category_id, goal, work_min, rest_min, start, end, focus_sec) "
        "VALUES (1, 'Dün', 50, 10, ?, ?, 3000)",
        (yesterday_start, yesterday_start + 3000),
    )
    # Today: 2 completed sessions (25m + 50m = 75m) + 1 active session (10m) => 85m total
    conn.execute(
        "INSERT INTO sessions (category_id, goal, work_min, rest_min, start, end, focus_sec) "
        "VALUES (1, 'Derin Çalışma', 25, 5, ?, ?, 1500)",
        (day_start, day_start + 1500),
    )
    conn.execute(
        "INSERT INTO sessions (category_id, goal, work_min, rest_min, start, end, focus_sec) "
        "VALUES (1, 'Makale', 50, 10, ?, ?, 3000)",
        (day_start + 3600, day_start + 6600),
    )
    conn.execute(
        "INSERT INTO sessions (category_id, goal, work_min, rest_min, start, end, focus_sec) "
        "VALUES (1, 'Tez Yazımı', 50, 10, ?, NULL, 600)",
        (day_start + 7200,),
    )

    # Todos: 1 pending today, 1 in-progress today, 1 done today, 1 overdue from yesterday
    conn.execute(
        "INSERT INTO todos (day, title, state, priority, position, scope) VALUES (?, 'QML denetimi', 0, 2, 1, 'day')",
        (today_iso,),
    )
    conn.execute(
        "INSERT INTO todos (day, title, state, priority, position, scope) VALUES (?, 'Birim testleri', 1, 3, 2, 'day')",
        (today_iso,),
    )
    conn.execute(
        "INSERT INTO todos (day, title, state, priority, position, scope) VALUES (?, 'Şartname okuma', 2, 1, 3, 'day')",
        (today_iso,),
    )
    conn.execute(
        "INSERT INTO todos (day, title, state, priority, position, scope) VALUES (?, 'Geciken görev', 0, 1, 4, 'day')",
        (yesterday_iso,),
    )
    conn.commit()
    conn.close()


def _extract_qml_blocks(qml_source: str, component_name: str) -> list[str]:
    blocks: list[str] = []
    pattern = re.compile(rf"\b{re.escape(component_name)}\s*\{{")
    for match in pattern.finditer(qml_source):
        brace_start = qml_source.find("{", match.start())
        depth = 0
        idx = brace_start
        while idx < len(qml_source):
            ch = qml_source[idx]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    blocks.append(qml_source[match.start(): idx + 1])
                    break
            idx += 1
    return blocks


class LiveControllerTests(unittest.TestCase):
    def test_herdr_status_filters_shells_and_sorts_blocked_first(self) -> None:
        fake_payload = {
            "hidden_finished": 4,
            "terminals": [
                {
                    "address": "t2",
                    "agent": "fish",
                    "cwd": "/tmp/proj",
                    "state": "live",
                    "turn": 0,
                    "where": "Shell / 1",
                },
                {
                    "address": "t10",
                    "agent": "antigravity",
                    "cwd": "/tmp/proj",
                    "state": "live",
                    "status": "done",
                    "turn": 3,
                    "where": "Workspace / DoneAgent",
                },
                {
                    "address": "t11",
                    "agent": "claude-code",
                    "cwd": "/tmp/proj",
                    "state": "live",
                    "status": "working",
                    "turn": 1,
                    "where": "Workspace / WorkingAgent",
                },
                {
                    "address": "t12",
                    "agent": "antigravity",
                    "cwd": "/tmp/proj",
                    "state": "live",
                    "status": {"state": "blocked", "msg": "Needs approval", "kind": "permission"},
                    "turn": 2,
                    "where": "Workspace / BlockedAgent",
                },
                {
                    "address": "t99",
                    "agent": "antigravity",
                    "cwd": "/tmp/proj",
                    "state": "finished",
                    "status": "done",
                    "turn": 4,
                    "where": "Old / Finished",
                },
            ],
        }

        # hc kurulu olmayan makinede (CI) de çalışsın: algılama da mock'lanır.
        with mock.patch.object(ctl, "_which", return_value="/usr/bin/hc"), mock.patch.object(
            ctl,
            "_run_cmd",
            side_effect=lambda argv, timeout=2.5: (0, json.dumps(fake_payload), ""),
        ):
            res = ctl.get_herdr_status()

        self.assertTrue(res["available"])
        self.assertEqual(res["workingCount"], 1)
        self.assertEqual(res["blockedCount"], 1)
        self.assertEqual(res["doneCount"], 1)
        self.assertEqual(res["totalCount"], 3)
        self.assertEqual([a["id"] for a in res["agents"]], ["t12", "t11", "t10"])
        self.assertEqual(res["agents"][0]["status"], "blocked")
        self.assertEqual(res["agents"][0]["msg"], "Needs approval")
        self.assertEqual(res["agents"][0]["kind"], "permission")

    def test_focus_herdr_agent_validates_id_and_invokes_herdr_app(self) -> None:
        recorded: list[list[str]] = []

        def fake_run(argv: list[str], timeout: float = 3.0) -> tuple[int, str, str]:
            recorded.append(argv)
            return 0, "{}", ""

        with mock.patch.object(ctl, "_run_cmd", side_effect=fake_run):
            ok_res = ctl.focus_herdr_agent("t1j")
            self.assertEqual(ok_res, {"ok": True, "terminal": "t1j"})
            self.assertEqual(recorded, [["herdr-app", "do", "agent.focus", "--terminal", "t1j"]])

            recorded.clear()
            self.assertFalse(ctl.focus_herdr_agent("--help")["ok"])
            self.assertFalse(ctl.focus_herdr_agent("t1; rm -rf /")["ok"])
            self.assertFalse(ctl.focus_herdr_agent("")["ok"])
            self.assertEqual(recorded, [])

    def test_houra_summary_reads_strictly_readonly_and_aggregates_today(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            nested = Path(tmp) / "Houra Klasörü #1"
            nested.mkdir(parents=True)
            db_file = nested / "houra.sqlite"
            ref_date = dt.date(2026, 11, 14)
            _init_sample_houra_db(db_file, ref_date)

            db_file.chmod(0o444)
            try:
                res = ctl.get_houra_summary(db_path=db_file, ref_date=ref_date)
                self.assertTrue(res["available"])
                self.assertEqual(res["completedSessions"], 2)
                self.assertEqual(res["focusMinutes"], 85)
                self.assertEqual(res["focusSeconds"], 5100)
                self.assertEqual(res["pendingTodos"], 3)
                self.assertEqual(res["completedTodos"], 1)
                self.assertIsNotNone(res["activeSession"])
                self.assertEqual(res["activeSession"]["goal"], "Tez Yazımı")
                self.assertEqual(res["topTodos"][0]["title"], "Birim testleri")
            finally:
                db_file.chmod(0o644)

    def test_houra_summary_missing_db_returns_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nonexistent.sqlite"
            res = ctl.get_houra_summary(db_path=missing)
            self.assertFalse(res["available"])
            self.assertEqual(res["completedSessions"], 0)
            self.assertEqual(res["focusMinutes"], 0)
            self.assertEqual(res["pendingTodos"], 0)

    def test_power_profile_get_and_set_validation(self) -> None:
        def fake_run(argv: list[str], timeout: float = 2.5) -> tuple[int, str, str]:
            if argv == ["powerprofilesctl", "get"]:
                return 0, "balanced\n", ""
            if argv[:2] == ["powerprofilesctl", "set"]:
                return 0, "", ""
            return 1, "", "err"

        with mock.patch.object(ctl, "_run_cmd", side_effect=fake_run):
            st = ctl.get_power_status()
            self.assertTrue(st["available"])
            self.assertEqual(st["profile"], "balanced")

            for valid in ("performance", "balanced", "power-saver"):
                self.assertEqual(ctl.set_power_profile(valid), {"ok": True, "profile": valid})

            self.assertFalse(ctl.set_power_profile("overclock")["ok"])
            self.assertFalse(ctl.set_power_profile("--help")["ok"])

    def test_battery_and_bluetooth_parsers(self) -> None:
        sample_upower = """
          power supply:         yes
          battery
            present:             yes
            state:               discharging
            percentage:          78,6%
            time to empty:       3,2 hours
        """
        bat = ctl._parse_upower_info(sample_upower)
        self.assertTrue(bat["available"])
        self.assertEqual(bat["percentage"], 79)
        self.assertEqual(bat["state"], "discharging")
        self.assertFalse(bat["charging"])
        self.assertFalse(bat["pluggedIn"])
        self.assertEqual(bat["timeRemaining"], "3,2 hours")

        def fake_bt_run(argv: list[str], timeout: float = 2.0) -> tuple[int, str, str]:
            if argv == ["bluetoothctl", "devices", "Connected"]:
                return (
                    0,
                    "Device 11:22:33:44:55:66 MX Master 3S\nDevice AA:BB:CC:DD:EE:FF Sony WH-1000XM5\n",
                    "",
                )
            if argv == ["bluetoothctl", "info", "11:22:33:44:55:66"]:
                return 0, "Alias: MX Master 3S\nConnected: yes\nIcon: input-mouse\n", ""
            if argv == ["bluetoothctl", "info", "AA:BB:CC:DD:EE:FF"]:
                return (
                    0,
                    "Alias: Sony WH-1000XM5\nConnected: yes\nIcon: audio-headphones\n"
                    "UUID: Audio Sink (0000110b)\n"
                    "Battery Percentage: 0x5a (90)\n",
                    "",
                )
            return 1, "", ""

        with mock.patch.object(ctl, "_run_cmd", side_effect=fake_bt_run):
            bt = ctl.get_bluetooth_status()

        self.assertTrue(bt["available"])
        self.assertTrue(bt["connected"])
        self.assertEqual(bt["name"], "Sony WH-1000XM5")
        self.assertTrue(bt["isAudio"])
        self.assertEqual(bt["battery"], 90)
        self.assertEqual(len(bt["devices"]), 2)

    def test_build_full_status_runs_probes_in_parallel_and_isolates_errors(self) -> None:
        # Süre eşiği yerine bariyer: 10 yoklamanın hepsi aynı anda beklemedeyse geçer; sıralı
        # çalışma bariyeri kırar (BrokenBarrierError -> varsayılan değer). Makine hızından bağımsız.
        barrier = threading.Barrier(10, timeout=5)

        def ok(val: dict[str, Any]):
            def _fn(*_args):
                barrier.wait()
                return val
            return _fn

        def failing_probe():
            barrier.wait()
            raise RuntimeError("boom")

        with (
            mock.patch.object(ctl, "_spawn_detached", return_value=(True, "")),
            mock.patch.object(ctl, "get_herdr_status", side_effect=ok({"available": True, "workingCount": 2, "blockedCount": 1, "doneCount": 0, "totalCount": 3, "agents": []})),
            mock.patch.object(ctl, "get_houra_summary", side_effect=ok({"available": True, "completedSessions": 1, "focusMinutes": 25, "focusSeconds": 1500, "pendingTodos": 2, "completedTodos": 0, "activeSession": None, "topTodos": []})),
            mock.patch.object(ctl, "get_power_status", side_effect=ok({"available": True, "profile": "performance", "profiles": ["performance", "balanced", "power-saver"]})),
            mock.patch.object(ctl, "get_battery_status", side_effect=ok({"available": True, "percentage": 88, "state": "discharging", "charging": False, "pluggedIn": False, "timeRemaining": ""})),
            mock.patch.object(ctl, "get_bluetooth_status", side_effect=failing_probe),
            mock.patch.object(ctl, "get_shelf_status", side_effect=ok({"count": 0, "items": []})),
            mock.patch.object(ctl, "get_sysload_status", side_effect=ok({"available": True, "cpuPct": 7})),
            mock.patch.object(ctl, "get_weather_status", side_effect=ok({"available": False})),
            mock.patch.object(ctl, "get_network_status", side_effect=ok({"nmcli": True, "wifiOn": True})),
            mock.patch.object(ctl, "get_toggles_status", side_effect=ok({"dndActive": True, "coffeeActive": False})),
        ):
            status = ctl.build_full_status()

        self.assertFalse(barrier.broken, "Yoklamalar paralel çalışmadı")
        self.assertEqual(status["herdr"]["blockedCount"], 1)
        self.assertEqual(status["houra"]["focusMinutes"], 25)
        self.assertEqual(status["sysload"]["cpuPct"], 7)
        self.assertTrue(status["toggles"]["dndActive"])
        self.assertEqual(status["bluetooth"]["available"], False)

    def test_file_url_accepts_only_empty_or_localhost_host(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sample = Path(tmp) / "belge.txt"
            sample.write_text("ok", encoding="utf-8")
            encoded_path = quote(str(sample))

            empty_host = ctl._classify_shelf_input(f"file://{encoded_path}")
            self.assertIsNotNone(empty_host)
            assert empty_host is not None
            self.assertEqual(empty_host["kind"], "file")
            self.assertEqual(empty_host["value"], str(sample))

            localhost_host = ctl._classify_shelf_input(f"file://localhost{encoded_path}")
            self.assertIsNotNone(localhost_host)
            assert localhost_host is not None
            self.assertEqual(localhost_host["kind"], "file")
            self.assertEqual(localhost_host["value"], str(sample))

            # Remote hosts in file:// URIs must be rejected rather than mapped to local paths.
            self.assertIsNone(ctl._classify_shelf_input(f"file://evil.example.com{encoded_path}"))
            self.assertIsNone(ctl._classify_shelf_input("file://192.168.1.20/etc/passwd"))

    def test_shelf_copy_protects_leading_dash_in_qdbus6(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            shelf_file = Path(tmp) / "shelf.json"
            added = ctl.shelf_add("--system", shelf_file=shelf_file)
            self.assertTrue(added["ok"])
            sid = added["item"]["id"]

            recorded_cmds: list[list[str]] = []

            def fake_run(argv: list[str], timeout: float = 2.0) -> tuple[int, str, str]:
                recorded_cmds.append(argv)
                return 0, "", ""

            with (
                mock.patch.object(ctl, "_which", side_effect=lambda name, env=None: "/usr/bin/qdbus6" if name == "qdbus6" else None),
                mock.patch.object(ctl, "_run_cmd", side_effect=fake_run),
            ):
                res = ctl.shelf_copy(sid, shelf_file=shelf_file)

            self.assertTrue(res["ok"])
            self.assertEqual(res["backend"], "klipper")
            self.assertEqual(
                recorded_cmds,
                [[
                    "qdbus6",
                    "--",
                    "org.kde.klipper",
                    "/klipper",
                    "org.kde.klipper.klipper.setClipboardContents",
                    "--system",
                ]],
            )

    def test_shelf_add_dedup_standalone_batch_remove_clear_and_open(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            shelf_file = tmp_path / "cache" / "shelf.json"
            sample_doc = tmp_path / "Özel Rapor 2026.pdf"
            sample_doc.write_text("pdf-bytes", encoding="utf-8")

            dash_file = tmp_path / "-dash-note.txt"
            dash_file.write_text("safe", encoding="utf-8")

            # 1. Add percent-encoded file:// URI
            encoded_uri = "file://" + quote(str(sample_doc))
            r1 = ctl.shelf_add(encoded_uri, shelf_file=shelf_file)
            self.assertTrue(r1["ok"])
            self.assertEqual(r1["item"]["kind"], "file")
            self.assertEqual(r1["item"]["label"], "Özel Rapor 2026.pdf")
            self.assertEqual(r1["item"]["value"], str(sample_doc))
            first_id = r1["item"]["id"]

            # 2. Add URL, shell-special text, and dash-prefixed filename via batch
            tricky_text = "Not: 'tek' \"çift\" $(whoami) `uname -a` satırı"
            r2 = ctl.shelf_add_many(
                ["https://kde.org/plasma-desktop", tricky_text, str(dash_file)],
                shelf_file=shelf_file,
            )
            self.assertTrue(r2["ok"])
            self.assertEqual(r2["count"], 4)

            # 3. Standalone '--batch' via CLI main() must pin literal '--batch' text
            with (
                mock.patch.dict(os.environ, {"PLASMA_QUOTA_ISLAND_SHELF_PATH": str(shelf_file)}),
                mock.patch("sys.stdout", new_callable=io.StringIO) as fake_out,
            ):
                rc = ctl.main(["shelf-add", "--batch"])
                self.assertEqual(rc, 0)
                parsed_cli = json.loads(fake_out.getvalue())
                self.assertEqual(parsed_cli["item"]["value"], "--batch")

            # 4. Re-adding first file deduplicates and moves it to index 0 with same ID
            r3 = ctl.shelf_add(str(sample_doc), shelf_file=shelf_file)
            self.assertTrue(r3["ok"])
            self.assertEqual(r3["count"], 5)
            self.assertEqual(r3["items"][0]["id"], first_id)

            # 5. Verify shelf-open invokes xdg-open with resolved absolute paths & safe temp note file
            opened_targets: list[list[str]] = []

            def fake_spawn(argv: list[str]) -> tuple[bool, str]:
                opened_targets.append(argv)
                return True, ""

            with mock.patch.object(ctl, "_spawn_detached", side_effect=fake_spawn):
                dash_id = next(it["id"] for it in r3["items"] if it["label"] == "-dash-note.txt")
                open_dash = ctl.shelf_open(dash_id, shelf_file=shelf_file)
                self.assertTrue(open_dash["ok"])
                self.assertEqual(opened_targets[-1][0], "xdg-open")
                self.assertTrue(opened_targets[-1][1].startswith("/"))
                self.assertTrue(opened_targets[-1][1].endswith("/-dash-note.txt"))

                text_id = next(it["id"] for it in r3["items"] if it["value"] == tricky_text)
                open_txt = ctl.shelf_open(text_id, shelf_file=shelf_file)
                self.assertTrue(open_txt["ok"])
                self.assertEqual(Path(open_txt["target"]).read_text(encoding="utf-8"), tricky_text)

            # 6. Missing file detection on status & open
            sample_doc.unlink()
            st = ctl.get_shelf_status(shelf_file=shelf_file)
            missing_entry = next(it for it in st["items"] if it["id"] == first_id)
            self.assertFalse(missing_entry["exists"])
            self.assertEqual(ctl.shelf_open(first_id, shelf_file=shelf_file)["error"], "file_missing")

            # 7. Remove & Clear (including note cleanup & invalid ID rejection)
            self.assertFalse(ctl.shelf_remove("../bad", shelf_file=shelf_file)["ok"])
            rem = ctl.shelf_remove(text_id, shelf_file=shelf_file)
            self.assertTrue(rem["ok"])
            self.assertTrue(rem["removed"])
            self.assertFalse(Path(open_txt["target"]).exists())

            clr = ctl.shelf_clear(shelf_file=shelf_file)
            self.assertTrue(clr["ok"])
            self.assertEqual(clr["items"], [])
            self.assertEqual(ctl.get_shelf_status(shelf_file=shelf_file)["count"], 0)

    def test_live_cli_status_and_shelf_roundtrip(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file())
        self.assertTrue(os.access(SCRIPT_PATH, os.X_OK), "live_ctl.py must be executable (chmod +x)")

        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["PLASMA_QUOTA_ISLAND_SHELF_PATH"] = str(Path(tmp) / "live_shelf.json")

            proc = subprocess.run(
                [str(SCRIPT_PATH), "status"],
                capture_output=True,
                text=True,
                timeout=8.0,
                env=env,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)

            expected_keys = {
                "updatedAt",
                "herdr",
                "houra",
                "power",
                "battery",
                "bluetooth",
                "shelf",
                "sysload",
                "weather",
                "network",
                "toggles",
            }
            self.assertTrue(expected_keys.issubset(data.keys()))
            self.assertIsInstance(data["herdr"]["agents"], list)
            self.assertIsInstance(data["herdr"]["workingCount"], int)
            self.assertIsInstance(data["herdr"]["blockedCount"], int)
            self.assertIsInstance(data["herdr"]["doneCount"], int)
            self.assertIsInstance(data["houra"]["completedSessions"], int)
            self.assertIsInstance(data["houra"]["focusMinutes"], int)
            self.assertIsInstance(data["houra"]["pendingTodos"], int)
            self.assertIn(data["power"]["profile"], ("performance", "balanced", "power-saver"))
            self.assertEqual(data["shelf"], {"count": 0, "items": []})
            self.assertIsInstance(data["sysload"]["cpuPct"], int)
            self.assertIsInstance(data["sysload"]["ramPct"], int)
            self.assertIsInstance(data["sysload"]["diskPct"], int)
            self.assertIsInstance(data["toggles"]["dndActive"], bool)
            self.assertIsInstance(data["toggles"]["coffeeActive"], bool)

            add_proc = subprocess.run(
                [str(SCRIPT_PATH), "shelf-add", "--", "Merhaba Gruvbox Rafı"],
                capture_output=True,
                text=True,
                timeout=5.0,
                env=env,
                check=False,
            )
            self.assertEqual(add_proc.returncode, 0, add_proc.stderr)
            added = json.loads(add_proc.stdout)
            self.assertTrue(added["ok"])
            self.assertEqual(added["count"], 1)
            self.assertEqual(added["items"][0]["kind"], "text")

    def test_sysload_weather_toggles_and_power_action_validation(self) -> None:
        # 1. System load returns bounded percentages and valid floats
        with mock.patch.object(ctl, "_spawn_detached", return_value=(True, "")):
            sysload = ctl.get_sysload_status()
        self.assertTrue(sysload["available"])
        self.assertGreaterEqual(sysload["cpuPct"], 0)
        self.assertLessEqual(sysload["cpuPct"], 100)
        self.assertGreater(sysload["ramTotalGb"], 0.0)
        self.assertGreater(sysload["diskTotalGb"], 0.0)

        # 2. WMO weather code mapping
        desc_clear, icon_clear = ctl._wmo_to_key_and_icon(0, True)
        self.assertEqual(desc_clear, "clear")
        self.assertEqual(icon_clear, "weather-clear-symbolic")
        desc_night, icon_night = ctl._wmo_to_key_and_icon(0, False)
        self.assertEqual(desc_night, "clear")
        self.assertEqual(icon_night, "weather-clear-night-symbolic")
        desc_storm, icon_storm = ctl._wmo_to_key_and_icon(95, True)
        self.assertEqual(desc_storm, "storm")
        self.assertEqual(icon_storm, "weather-storm-symbolic")

        # 3. Toggles status structure
        toggles = ctl.get_toggles_status()
        self.assertIsInstance(toggles["dndActive"], bool)
        self.assertIsInstance(toggles["coffeeActive"], bool)

        # 4. Power action validation rejects unknown commands and executes valid ones via mocked _run_cmd
        recorded: list[list[str]] = []

        def fake_run(argv: list[str], timeout: float = 3.0) -> tuple[int, str, str]:
            recorded.append(argv)
            return 0, "", ""

        with mock.patch.object(ctl, "_run_cmd", side_effect=fake_run):
            self.assertFalse(ctl.run_power_action("format-disk")["ok"])
            self.assertFalse(ctl.run_power_action("--help")["ok"])
            self.assertEqual(recorded, [])

            for act in ("sleep", "lock", "logout", "reboot", "poweroff"):
                res = ctl.run_power_action(act)
                self.assertTrue(res["ok"])
                self.assertEqual(res["action"], act)
            self.assertEqual(len(recorded), 5)

    def test_qml_mandatory_security_backend_binding_and_plasma6_rules(self) -> None:
        for qml_path in (LIVE_QML_PATH, SHELF_QML_PATH):
            with self.subTest(qml=qml_path.name):
                self.assertTrue(qml_path.is_file())
                src = qml_path.read_text(encoding="utf-8")

                text_blocks = _extract_qml_blocks(src, "Text")
                self.assertGreater(len(text_blocks), 0)
                for blk in text_blocks:
                    self.assertIn(
                        "textFormat: Text.PlainText",
                        blk,
                        f"Missing PlainText in {qml_path.name}:\n{blk[:160]}",
                    )

                self.assertNotIn("required property bool enabled", src)
                self.assertIsNone(re.search(r"\bproperty\s+\w+\s+palette\b", src))
                self.assertNotIn("createQmlObject", src)
                self.assertNotIn("createObject", src)

        live_src = LIVE_QML_PATH.read_text(encoding="utf-8")
        self.assertIn("backend.liveData", live_src)
        self.assertIn("backend.focusAgent", live_src)
        self.assertIn("backend.setPowerProfile", live_src)

        shelf_src = SHELF_QML_PATH.read_text(encoding="utf-8")
        self.assertIn("backend.shelfItems", shelf_src)
        self.assertIn("backend.shelfAdd", shelf_src)
        self.assertIn("backend.shelfRemove", shelf_src)
        self.assertIn("backend.shelfClear", shelf_src)
        self.assertIn("backend.shelfOpen", shelf_src)

    def test_qt6_qmllint_passes_zero_warnings_and_errors(self) -> None:
        if not QMLLINT_BIN.is_file():
            self.skipTest("Qt 6 qmllint yok (/usr/lib/qt6/bin/qmllint)")
        qml_files = sorted((REPO_ROOT / "package" / "contents" / "ui").glob("*.qml"))
        proc = subprocess.run(
            [str(QMLLINT_BIN), "--json", "-", "-I", "/usr/lib/qt6/qml", *map(str, qml_files)],
            capture_output=True,
            text=True,
            timeout=30.0,
            check=False,
        )
        report = json.loads(proc.stdout)
        problems: list[str] = []
        for entry in report["files"]:
            lines = Path(entry["filename"]).read_text(encoding="utf-8").splitlines()
            for warn in entry["warnings"]:
                line_no = int(warn.get("line", 0))
                col = int(warn.get("column", 1)) - 1
                token = lines[line_no - 1][col:col + int(warn.get("length", 0))] if line_no > 0 else ""
                # Plasma, i18n*() işlevlerini uygulamacık bağlamına enjekte eder; qmllint bunları göremez.
                if warn.get("id") == "unqualified" and re.fullmatch(r"i18n[cp]{0,2}", token):
                    continue
                problems.append(f"{Path(entry['filename']).name}:{line_no}: {warn.get('id')} {warn.get('message')}")
        self.assertEqual(problems, [], "qmllint:\n" + "\n".join(problems))


class PrivacyAndIntegrationTests(unittest.TestCase):
    def test_weather_defaults_off_without_network_or_spawn(self) -> None:
        self.assertEqual(ctl.parse_weather_opts([])["mode"], "off")
        with (
            mock.patch.object(ctl, "urlopen", side_effect=AssertionError("ağ isteği yapılmamalı")),
            mock.patch.object(ctl, "_spawn_detached", side_effect=AssertionError("süreç başlatılmamalı")),
        ):
            res = ctl.get_weather_status(ctl.parse_weather_opts([]))
            live = ctl.fetch_weather_live(ctl.parse_weather_opts(["--weather", "off"]))
        self.assertFalse(res["enabled"])
        self.assertFalse(live["enabled"])
        self.assertEqual(res["city"], "")

    def test_parse_weather_opts_validates_input(self) -> None:
        opts = ctl.parse_weather_opts(["--weather", "manual", "--city", " Ankara ", "--lat", "39.9", "--lon", "999"])
        self.assertEqual(opts["mode"], "manual")
        self.assertEqual(opts["city"], "Ankara")
        self.assertEqual(opts["lat"], 39.9)
        self.assertIsNone(opts["lon"])
        self.assertEqual(ctl.parse_weather_opts(["--weather", "evil"])["mode"], "off")

    def test_manual_coordinates_never_call_ip_location(self) -> None:
        opts = ctl.parse_weather_opts(["--weather", "manual", "--lat", "39.9", "--lon", "32.8", "--city", "Ankara"])
        with mock.patch.object(ctl, "urlopen", side_effect=AssertionError("ağ isteği yapılmamalı")):
            self.assertEqual(ctl._resolve_weather_location(opts), (39.9, 32.8, "Ankara"))

    def test_herdr_missing_reports_not_installed(self) -> None:
        with mock.patch.object(ctl, "_which", return_value=None):
            res = ctl.get_herdr_status()
        self.assertFalse(res["installed"])
        self.assertFalse(res["available"])

    def test_disabled_integrations_are_not_probed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"PLASMA_QUOTA_ISLAND_CACHE_DIR": tmp}):
            with (
                mock.patch.object(ctl, "get_herdr_status") as herdr_probe,
                mock.patch.object(ctl, "get_houra_summary") as houra_probe,
                mock.patch.object(ctl, "_spawn_detached", return_value=(True, "")),
            ):
                status = ctl.build_full_status(["--no-herdr", "--no-houra"])
        herdr_probe.assert_not_called()
        houra_probe.assert_not_called()
        self.assertFalse(status["herdr"]["installed"])
        self.assertFalse(status["houra"]["installed"])

    def test_diagnostics_reports_only_booleans_never_secrets(self) -> None:
        import sys as _sys

        _sys.path.insert(0, str(SCRIPT_PATH.parent))
        import island_ctl

        secret = "sk-test-SECRET-123"
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.dict(os.environ, {"HOURA_DB_PATH": str(Path(tmp) / "none.sqlite")}), \
                mock.patch.object(ctl, "_which", side_effect=lambda name, env=None: "/usr/bin/wpctl" if name == "wpctl" else None), \
                mock.patch.object(island_ctl, "_read_claude_access_token", return_value=secret), \
                mock.patch.object(island_ctl, "_lookup_agy_access_token", return_value=""), \
                mock.patch.object(island_ctl, "_read_codex_credentials", return_value=(secret, "acc-SECRET")):
            diag = ctl.get_diagnostics()
        dumped = json.dumps(diag)
        self.assertNotIn("SECRET", dumped)
        self.assertNotIn("/usr/bin", dumped)
        self.assertTrue(diag["tools"]["wpctl"])
        self.assertFalse(diag["tools"]["hc"])
        self.assertFalse(diag["files"]["houraDb"])
        self.assertEqual(diag["credentials"], {"claude": True, "agy": False, "codex": True})
        for group in ("tools", "files", "credentials"):
            self.assertTrue(all(isinstance(v, bool) for v in diag[group].values()))

    def test_turkish_translation_covers_every_i18n_string(self) -> None:
        import shutil

        if shutil.which("msgcat") is None:
            self.skipTest("gettext msgcat yok")
        po_text = subprocess.run(
            ["msgcat", "--no-wrap", str(REPO_ROOT / "translate" / "tr.po")],
            capture_output=True, text=True, check=True,
        ).stdout
        translated = {
            m.group(1)
            for m in re.finditer(r'^msgid "((?:[^"\\]|\\.)*)"\n(?:msgid_plural .*\n)?msgstr(?:\[0\])? "(?:[^"\\]|\\.)+"', po_text, re.M)
        }
        missing: list[str] = []
        for qml in sorted((REPO_ROOT / "package" / "contents").rglob("*.qml")):
            for m in re.finditer(r'\bi18n(c?)p?\(\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*"((?:[^"\\]|\\.)*)")?', qml.read_text(encoding="utf-8")):
                msgid = m.group(3) if m.group(1) else m.group(2)
                if msgid not in translated:
                    missing.append(f"{qml.name}: {msgid}")
        self.assertEqual(missing, [], "translate/build.sh çalıştırıp tr.po'yu güncelleyin")
        self.assertTrue((REPO_ROOT / "package" / "contents" / "locale" / "tr" / "LC_MESSAGES"
                         / "plasma_applet_io.github.fatihaydost.island.mo").is_file())

    def test_legacy_cache_dir_is_migrated_once(self) -> None:
        import sys as _sys

        _sys.path.insert(0, str(SCRIPT_PATH.parent))
        import island_ctl

        env_clear = {"PLASMA_QUOTA_ISLAND_CACHE_DIR": "", "PLASMA_QUOTA_ISLAND_SHELF_PATH": ""}
        for resolve in (lambda: ctl._shelf_path().parent, lambda: ctl._cache_dir(), island_ctl.get_cache_dir):
            with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {**env_clear, "XDG_CACHE_HOME": tmp}):
                old = Path(tmp) / "gruvbox-island"
                (old / "notes").mkdir(parents=True)
                old.chmod(0o755)
                (old / "notes").chmod(0o755)
                (old / "shelf.json").write_text('{"items": []}', encoding="utf-8")
                (old / "notes" / "a.txt").write_text("not", encoding="utf-8")
                got = resolve()
                self.assertEqual(got, Path(tmp) / "plasma-quota-island")
                self.assertFalse(old.exists())
                self.assertEqual((got / "notes" / "a.txt").read_text(encoding="utf-8"), "not")
                self.assertTrue((got / "shelf.json").is_file())
                self.assertEqual(got.stat().st_mode & 0o777, 0o700)
                self.assertEqual((got / "notes").stat().st_mode & 0o777, 0o700)
                # Yeni dizin varken eski dizin (yeniden oluşmuşsa) üzerine taşınmaz.
                old.mkdir()
                self.assertEqual(resolve(), Path(tmp) / "plasma-quota-island")
                self.assertTrue(old.exists())

    def test_cache_dir_falls_back_to_legacy_when_rename_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            old = Path(tmp) / "gruvbox-island"
            old.mkdir()
            with mock.patch.object(ctl.os, "rename", side_effect=OSError("busy")):
                self.assertEqual(ctl._default_cache_dir(Path(tmp)), old)

    def test_live_chip_roomy_has_no_self_dependency(self) -> None:
        src = (REPO_ROOT / "package" / "contents" / "ui" / "DashResources.qml").read_text(encoding="utf-8")
        roomy = next(line for line in src.splitlines() if "readonly property bool roomy:" in line)
        # Çip grubunun genişliği çocukların implicitWidth'ine bağlanabilir; roomy satırdan hesaplanmalı.
        self.assertNotIn("chipGroup.width", roomy)
        self.assertIn("bottomRow.width", roomy)
        self.assertIn('i18n("Open Live tab"), liveChip.fullLabel', src)


if __name__ == "__main__":
    unittest.main()
