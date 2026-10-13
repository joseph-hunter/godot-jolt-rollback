"""Run native Godot 4.6 snapshot tests on Windows or Linux."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

SCENARIOS = (
    "restore_active", "restore_initial", "restore_sleeping", "restore_sleeping_pending", "stale_handle",
    "wrong_tick", "wrong_world", "incompatible_mass", "incompatible_shape",
    "ring_wrap", "unsupported_area", "changed_environment", "update_error", "unsafe_capture",
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("godot", help="Godot 4.6 executable path or command")
    parser.add_argument("--scenario", choices=SCENARIOS)
    args = parser.parse_args()
    executable = shutil.which(args.godot) or str(Path(args.godot).resolve())
    root = Path(__file__).resolve().parent.parent
    logs = root / "build" / "rollback-snapshot-tests"
    logs.mkdir(parents=True, exist_ok=True)
    scenarios = (args.scenario,) if args.scenario else SCENARIOS
    for scenario in scenarios:
        log = logs / f"{scenario}.log"
        with tempfile.TemporaryDirectory(prefix="snapshot-test-", dir=logs) as scratch:
            project = root / "examples"
            if scenario == "update_error":
                # Limits are cached when the first space is created, before scene
                # _ready(). Use a separate project rather than modify the examples.
                project = Path(scratch)
                shutil.copytree(root / "examples/addons", project / "addons")
                shutil.copytree(root / "examples/scenes/rollback_poc", project / "scenes/rollback_poc")
                (project / ".godot").mkdir()
                (project / ".godot/extension_list.cfg").write_text(
                    "res://addons/godot-jolt/godot-jolt.gdextension\n", encoding="utf-8")
                (project / "project.godot").write_text(
                    'config_version=5\n[application]\nconfig/name="Snapshot Error Test"\n'
                    '[physics]\ncommon/physics_ticks_per_second=120\n'
                    '3d/physics_engine="Jolt Rollback (Extension)"\n'
                    'jolt_physics_extension_3d/limits/max_contact_constraints=4\n',
                    encoding="utf-8",
                )
            with log.open("w", encoding="utf-8") as output:
                result = subprocess.run(
                    [executable, "--headless", "--path", str(project),
                     "--quit-after", "400", "scenes/rollback_poc/snapshot-test.tscn",
                     "--", f"--scenario={scenario}"],
                    cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=30,
                )
        text = log.read_text(encoding="utf-8", errors="replace")
        marker = f"SNAPSHOT TEST PASS [{scenario}]"
        if result.returncode or marker not in text or "SCRIPT ERROR" in text or "SNAPSHOT TEST FAIL" in text:
            raise SystemExit(f"{scenario} failed (exit {result.returncode}).\n{text}")
        print(marker, flush=True)
    print(f"All {len(scenarios)} snapshot scenarios passed.")


if __name__ == "__main__":
    main()
