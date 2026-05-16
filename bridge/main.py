"""
AI Trading Bridge — Entry Point
Run this file to start the bridge: python main.py
"""

import logging
import sys
import os

# ── Logging setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("bridge.log", encoding="utf-8"),
    ]
)
log = logging.getLogger("main")


def check_requirements():
    """Verify environment before starting."""
    errors = []

    # Python version
    if sys.version_info < (3, 10):
        errors.append(f"Python 3.10+ required (found {sys.version})")

    # Windows check
    if sys.platform != "win32":
        errors.append("Named Pipe requires Windows")

    # API key
    from config import ANTHROPIC_API_KEY
    if not ANTHROPIC_API_KEY:
        errors.append(
            "ANTHROPIC_API_KEY not set.\n"
            "  Option 1: set ANTHROPIC_API_KEY=sk-ant-... in environment\n"
            "  Option 2: edit bridge/config.py and set ANTHROPIC_API_KEY"
        )

    # pywin32
    try:
        import win32pipe
    except ImportError:
        errors.append("pywin32 not installed: pip install pywin32")

    # anthropic
    try:
        import anthropic
    except ImportError:
        errors.append("anthropic not installed: pip install anthropic")

    return errors


def print_banner():
    print()
    print("=" * 60)
    print("  AI Trading Bridge")
    print("  Natural language → MT4/MT5 trading strategies")
    print("=" * 60)
    print()


def main():
    print_banner()

    # Check requirements
    errors = check_requirements()
    if errors:
        print("ERROR — cannot start:\n")
        for e in errors:
            print(f"  • {e}")
        print()
        sys.exit(1)

    # Pre-load PA helpers sandbox (first access initializes thread-local)
    log.info("Loading PA Helpers...")
    from sandbox import _get_base_sandbox
    _get_base_sandbox()
    log.info("PA Helpers loaded OK")

    # Start pipe server (blocks forever)
    from bridge import run as run_bridge

    from config import MAX_STRATEGIES
    log.info(f"Max simultaneous strategies: {MAX_STRATEGIES}")
    log.info("Bridge ready. Start MT4 and attach AI_EA to a chart.")
    log.info("Press Ctrl+C to stop.\n")

    try:
        run_bridge()
    except KeyboardInterrupt:
        log.info("Bridge stopped by user.")
        sys.exit(0)


if __name__ == "__main__":
    main()
