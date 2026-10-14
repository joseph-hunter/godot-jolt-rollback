"""Exercise the reusable GDScript manager against an ordinary reference world."""
import argparse
from pathlib import Path
import shutil
import subprocess

SCENARIOS = ("corrected", "sleeping", "full_window", "wrap", "offset", "future",
             "stale", "missing", "object", "backend_failure", "snapshot_object",
             "restore_failure", "gameplay_failure", "unchanged", "detach", "repeated")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("godot")
    parser.add_argument("--scenario", choices=SCENARIOS)
    args = parser.parse_args()
    executable = shutil.which(args.godot) or str(Path(args.godot).resolve())
    root = Path(__file__).resolve().parent.parent
    logs = root / "build/rollback-manager-tests"
    logs.mkdir(parents=True, exist_ok=True)
    for scenario in (args.scenario,) if args.scenario else SCENARIOS:
        log = logs / f"{scenario}.log"
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(
                [executable, "--headless", "--path", str(root / "examples"),
                 "--quit-after", "600", "scenes/rollback_poc/manager-test.tscn",
                 "--", f"--scenario={scenario}"], cwd=root,
                stdout=output, stderr=subprocess.STDOUT, timeout=45)
        text = log.read_text(encoding="utf-8", errors="replace")
        marker = f"MANAGER TEST PASS [{scenario}]"
        if result.returncode or marker not in text or "SCRIPT ERROR" in text or "MANAGER TEST FAIL" in text:
            raise SystemExit(f"{scenario} failed (exit {result.returncode}).\n{text}")
        print(marker, flush=True)
    print("All manager scenarios passed.")


if __name__ == "__main__":
    main()
