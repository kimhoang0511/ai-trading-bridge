"""Tests for bridge/analyzer.py — static code analysis (Layer 1 security)."""

import pytest
from analyzer import analyze

# ── Helpers ───────────────────────────────────────────────────────────────────

def ok(code: str):
    safe, errors = analyze(code)
    assert safe, f"Expected safe but got errors: {errors}"

def fail(code: str, keyword: str = ""):
    safe, errors = analyze(code)
    assert not safe, "Expected rejection but code passed"
    if keyword:
        assert any(keyword.lower() in e.lower() for e in errors), \
            f"Expected '{keyword}' in errors, got: {errors}"

# ── Valid code ────────────────────────────────────────────────────────────────

class TestValidCode:
    def test_simple_check(self):
        ok("def check(v):\n    return True")

    def test_with_indicator_logic(self):
        ok(
            "def check(v):\n"
            "    cross = v['ma20'] > v['ma50'] and v['ma20_prev'] < v['ma50_prev']\n"
            "    return cross and v['rsi14'] < 65\n"
        )

    def test_with_helper_call(self):
        ok(
            "def check(v):\n"
            "    return is_bull_engulfing(v)\n"
        )

    def test_helper_function_defined(self):
        ok(
            "def _cross(a, b, ap, bp):\n"
            "    return a > b and ap < bp\n\n"
            "def check(v):\n"
            "    return _cross(v['ma20'], v['ma50'], v['ma20_prev'], v['ma50_prev'])\n"
        )

    def test_arithmetic_and_comparisons(self):
        ok(
            "def check(v):\n"
            "    avg = (v['close_0'] + v['close_1']) / 2\n"
            "    return avg > v['ma20'] and v['rsi14'] < 70\n"
        )

    def test_conditional_logic(self):
        ok(
            "def check(v):\n"
            "    if v['rsi14'] > 70:\n"
            "        return False\n"
            "    return v['ma20'] > v['ma50']\n"
        )

    def test_nested_loop_within_limit(self):
        ok(
            "def check(v):\n"
            "    for i in range(2):\n"
            "        for j in range(2):\n"
            "            pass\n"
            "    return True\n"
        )

# ── Import blocking ───────────────────────────────────────────────────────────

class TestImportBlocking:
    def test_import_os(self):
        fail("import os\ndef check(v):\n    return True", "import")

    def test_from_import(self):
        fail("from os import path\ndef check(v):\n    return True", "import")

    def test_import_sys(self):
        fail("import sys\ndef check(v):\n    return True", "import")

# ── Dangerous builtins ────────────────────────────────────────────────────────

class TestDangerousBuiltins:
    def test_exec_call(self):
        fail("def check(v):\n    exec('x=1')\n    return True", "exec")

    def test_eval_call(self):
        fail("def check(v):\n    eval('1+1')\n    return True", "eval")

    def test_open_call(self):
        fail("def check(v):\n    open('x.txt')\n    return True", "open")

    def test_os_name(self):
        fail("def check(v):\n    return os.path.exists('/')", "os")

    def test_sys_name(self):
        fail("def check(v):\n    return sys.platform == 'win32'", "sys")

    def test_getattr_call(self):
        fail("def check(v):\n    return getattr(v, 'x', None)", "getattr")

    def test_globals_call(self):
        fail("def check(v):\n    return globals()['x']", "globals")

# ── Dunder / blacklisted patterns ─────────────────────────────────────────────

class TestBlacklistedPatterns:
    def test_dunder_import(self):
        fail("def check(v):\n    return __import__('os')", "forbidden")

    def test_dunder_class(self):
        fail("def check(v):\n    return v.__class__", "forbidden")

    def test_base64_pattern(self):
        fail("def check(v):\n    x = 'base64'\n    return True", "base64")

    def test_dunder_in_string_literal_allowed(self):
        # A string containing '__' chars — should pass (it's a string, not code)
        ok("def check(v):\n    x = 'no__dunder'\n    return True")

# ── Structure requirements ────────────────────────────────────────────────────

class TestStructureRequirements:
    def test_missing_check_function(self):
        fail("def foo(v):\n    return True", "check")

    def test_check_without_return(self):
        fail("def check(v):\n    x = 1\n", "return")

    def test_syntax_error(self):
        fail("def check(v):\n    return <<<invalid>>>", "syntax")

    def test_async_function_rejected(self):
        fail("async def check(v):\n    return True", "async")

# ── Length limit ──────────────────────────────────────────────────────────────

class TestLengthLimit:
    def test_code_too_long(self):
        long_code = "def check(v):\n    x = " + "1 + " * 600 + "1\n    return True\n"
        fail(long_code, "too long")

# ── Loop depth ────────────────────────────────────────────────────────────────

class TestLoopDepth:
    def test_triple_nested_loop_rejected(self):
        fail(
            "def check(v):\n"
            "    for i in range(2):\n"
            "        for j in range(2):\n"
            "            for k in range(2):\n"
            "                pass\n"
            "    return True\n",
            "loop"
        )
