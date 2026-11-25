"""Standalone map backend launcher. Stdout contains exactly one JSON result."""
import json
import sys


def main():
    try:
        if sys.version_info < (3, 10):
            raise RuntimeError("Python >= 3.10 required")
        from spatial_backend.cli import run
        result = run(sys.argv[1:])
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))
        return 0
    except Exception as exc:
        # Bounded errors keep malformed source content out of the editor transport.
        print(json.dumps({"ok": False, "error": str(exc)[:2000]}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
