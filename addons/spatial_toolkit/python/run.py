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
        arguments = sys.argv[1:]
        if arguments and arguments[0] == "flight-graph":
            from spatial_backend.navigation.__main__ import run
            result = {"ok": True, **run(arguments[1:])}
        elif arguments and arguments[0] == "citygml-download":
            from spatial_backend.citygml_download import run
            result = run(arguments[1:], _report_progress)
        else:
            from spatial_backend.cli import run
            result = run(arguments, progress=_report_progress)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except Exception as exc:
        # Bounded errors keep malformed source content out of the editor transport.
        print(json.dumps({"ok": False, "error": str(exc)[:2000]}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
