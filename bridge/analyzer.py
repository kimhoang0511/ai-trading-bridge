"""
Static code analysis — Layer 1 security.
Runs BEFORE execution. Rejects dangerous code at parse time.
"""

import ast
import re
from typing import Tuple

# Node types that are never allowed
BLACKLIST_NODES = (
    ast.Import,
    ast.ImportFrom,
    ast.Global,
    ast.Nonlocal,
    ast.Delete,
    ast.Yield,
    ast.YieldFrom,
    ast.AsyncFunctionDef,
    ast.AsyncFor,
    ast.AsyncWith,
    ast.Await,
)

# Names that must not appear anywhere
BLACKLIST_NAMES = {
    "__import__", "__builtins__", "__class__", "__subclasses__",
    "__bases__", "__mro__", "__globals__", "__code__", "__closure__",
    "eval", "exec", "compile", "open", "input", "print",
    "os", "sys", "subprocess", "shutil", "pathlib", "socket",
    "requests", "urllib", "http", "ftplib", "smtplib",
    "globals", "locals", "vars", "dir",
    "getattr", "setattr", "delattr", "hasattr",
    "breakpoint", "exit", "quit", "help",
    "chr", "ord", "hex", "oct", "bin",
    "memoryview", "bytearray", "bytes",
    "classmethod", "staticmethod", "property",
    "super", "type", "object",
}

BLACKLIST_ATTRS = {
    "__class__", "__bases__", "__mro__", "__subclasses__",
    "__globals__", "__code__", "__closure__", "__dict__",
    "__module__", "__qualname__", "__annotations__",
    "func_globals", "gi_frame", "cr_frame",
    "f_locals", "f_globals", "f_builtins",
}

BLACKLIST_REGEX = [
    r'__[\w]+__',      # any dunder
    r'base64',
    r'pickle',
    r'marshal',
    r'ctypes',
    r'cffi',
]

MAX_LOOP_DEPTH = 2


class _Visitor(ast.NodeVisitor):
    def __init__(self):
        self.errors: list[str] = []
        self._loop_depth = 0

    def visit_Import(self, node):
        self.errors.append("import statements are not allowed")

    def visit_ImportFrom(self, node):
        self.errors.append("from...import statements are not allowed")

    def visit_Global(self, node):
        self.errors.append("global statements are not allowed")

    def visit_Nonlocal(self, node):
        self.errors.append("nonlocal statements are not allowed")

    def visit_Delete(self, node):
        self.errors.append("del statements are not allowed")

    def visit_AsyncFunctionDef(self, node):
        self.errors.append("async functions are not allowed")

    def visit_Await(self, node):
        self.errors.append("await is not allowed")

    def visit_Call(self, node):
        if isinstance(node.func, ast.Name):
            if node.func.id in BLACKLIST_NAMES:
                self.errors.append(f"Forbidden function call: {node.func.id}()")
        if isinstance(node.func, ast.Attribute):
            if node.func.attr in BLACKLIST_ATTRS:
                self.errors.append(f"Forbidden attribute call: .{node.func.attr}()")
        self.generic_visit(node)

    def visit_Name(self, node):
        if node.id in BLACKLIST_NAMES:
            self.errors.append(f"Forbidden name: {node.id}")
        self.generic_visit(node)

    def visit_Attribute(self, node):
        if node.attr in BLACKLIST_ATTRS:
            self.errors.append(f"Forbidden attribute: .{node.attr}")
        self.generic_visit(node)

    def visit_While(self, node):
        self._loop_depth += 1
        if self._loop_depth > MAX_LOOP_DEPTH:
            self.errors.append(f"Loop nesting too deep (max {MAX_LOOP_DEPTH})")
        self.generic_visit(node)
        self._loop_depth -= 1

    def visit_For(self, node):
        self._loop_depth += 1
        if self._loop_depth > MAX_LOOP_DEPTH:
            self.errors.append(f"Loop nesting too deep (max {MAX_LOOP_DEPTH})")
        self.generic_visit(node)
        self._loop_depth -= 1


def analyze(code: str) -> tuple[bool, list[str]]:
    """
    Returns (is_safe, error_list).
    is_safe=True means code passed all checks and is safe to sandbox-execute.
    """
    errors: list[str] = []

    # 1. Length check
    from config import MAX_CODE_LENGTH
    if len(code) > MAX_CODE_LENGTH:
        return False, [f"Code too long: {len(code)} chars (max {MAX_CODE_LENGTH})"]

    # 2. Regex blacklist (catches obfuscation before AST)
    for pattern in BLACKLIST_REGEX:
        if re.search(pattern, code):
            errors.append(f"Forbidden pattern detected: {pattern}")

    if errors:
        return False, errors

    # 3. AST parse
    try:
        tree = ast.parse(code)
    except SyntaxError as e:
        return False, [f"Syntax error: {e}"]

    # 4. Must contain def check(v):
    func_names = [
        node.name for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef)
    ]
    if "check" not in func_names:
        errors.append("Code must define: def check(v: dict) -> bool:")

    # 5. check() must have a return statement
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "check":
            has_return = any(isinstance(n, ast.Return) for n in ast.walk(node))
            if not has_return:
                errors.append("check() must have a return statement")

    # 6. AST visitor for blacklisted constructs
    visitor = _Visitor()
    visitor.visit(tree)
    errors.extend(visitor.errors)

    return len(errors) == 0, errors
