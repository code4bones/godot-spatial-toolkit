"""Standalone map backend launcher with one stdout result and stderr progress."""
import json
import sys


def _report_progress(phase, done, total):
    payload = json.dumps([phase, done, total], separators=(",", ":"))
    print("SPATIAL_PROGRESS " + payload, file=sys.stderr, flush=True)


def main():
    try:
        if sys.version_info < (3, 10):
            raise RuntimeError("Python >= 3.10 required")
        from spatial_backend.cli import run
        result = run(sys.argv[1:], progress=_report_progress)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except Exception as exc:
        # Bounded errors keep malformed source content out of the editor transport.
        print(json.dumps({"ok": False, "error": str(exc)[:2000]}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
