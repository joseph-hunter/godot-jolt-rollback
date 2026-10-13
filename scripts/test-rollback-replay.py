"""Compare historical correction/replay with a native authoritative reference."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

SCENARIOS = (
    "corrected", "initial", "sleeping", "full_window", "tick_offset", "unfinished",
    "step_without_flush", "duplicate_flush", "final_flush", "wrong_delta",
    "wrong_end", "manual_outside", "missing_input", "nested_restore",
    "double_step", "missing_final_capture", "duplicate_begin", "capture_after_flush",
    "missing_intermediate_capture", "update_error", "release_current_capture",
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("godot")
    parser.add_argument("--scenario", choices=SCENARIOS)
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    executable = shutil.which(args.godot) or str(Path(args.godot).resolve())
    root = Path(__file__).resolve().parent.parent
    logs = root / "build/rollback-replay-tests"
    logs.mkdir(parents=True, exist_ok=True)
    scenarios = (args.scenario,) if args.scenario else SCENARIOS
    runs = [(scenario, iteration) for iteration in range(args.repeat) for scenario in scenarios]
    for scenario, iteration in runs:
        suffix = f"-{iteration + 1}" if args.repeat > 1 else ""
        log = logs / f"{scenario}{suffix}.log"
        with tempfile.TemporaryDirectory(prefix="replay-test-", dir=logs) as scratch:
            assert Path(scratch).resolve().parent == logs.resolve()
            project = root / "examples"
            if scenario == "update_error":
                project = Path(scratch)
                shutil.copytree(root / "examples/addons", project / "addons")
                shutil.copytree(root / "examples/scenes/rollback_poc", project / "scenes/rollback_poc")
                (project / ".godot").mkdir()
                (project / ".godot/extension_list.cfg").write_text(
                    "res://addons/godot-jolt/godot-jolt.gdextension\n", encoding="utf-8")
                (project / "project.godot").write_text(
                    'config_version=5\n[application]\nconfig/name="Replay Error Test"\n'
                    '[physics]\ncommon/physics_ticks_per_second=120\n'
                    '3d/physics_engine="Jolt Rollback (Extension)"\n'
                    'jolt_physics_extension_3d/limits/max_contact_constraints=4\n', encoding="utf-8")
            with log.open("w", encoding="utf-8") as output:
                result = subprocess.run(
                    [executable, "--headless", "--path", str(project),
                     "--quit-after", "500", "scenes/rollback_poc/replay-test.tscn",
                     "--", f"--scenario={scenario}"],
                    cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=45,
                )
        text = log.read_text(encoding="utf-8", errors="replace")
        marker = f"REPLAY TEST PASS [{scenario}]"
        if result.returncode or marker not in text or "SCRIPT ERROR" in text or "REPLAY TEST FAIL" in text:
            raise SystemExit(f"{scenario} failed (exit {result.returncode}).\n{text}")
        print(next(line for line in text.splitlines() if marker in line), flush=True)
    print(f"All {len(runs)} replay scenario runs passed.")


if __name__ == "__main__":
    main()
