#!/usr/bin/env python3
"""SnapMark pre-build static audit.

Fast checks that run before `swift build` (no SDK needed):

1. `#if canImport(...)` / `#endif` balance per file.
2. References to optionally-available symbols (Apple Intelligence /
   Translation frameworks) only appear inside a matching
   `#if canImport(...)` region.
3. Brace/paren/bracket balance outside strings and comments.
4. Warns (does not fail) on `try!` and `fatalError(` occurrences.

Exit 0 = clean, exit 1 = problems (messages go to stdout for the build log).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "SnapMark"
TESTS = ROOT / "Tests" / "SnapMarkTests"

# symbol -> required canImport framework
GUARDED = {
    "SmartText": "FoundationModels",
    "SystemLanguageModel": "FoundationModels",
    "LanguageModelSession": "FoundationModels",
    "LocalTranslate": "Translation",
    "TranslationSession": "Translation",
}

CANIMPORT_RE = re.compile(r"#if\s+canImport\((\w+)\)")
ENDIF_RE = re.compile(r"^\s*#endif\b")
ELSE_RE = re.compile(r"^\s*#else\b")
ELIF_RE = re.compile(r"^\s*#elseif\s+canImport\((\w+)\)")
IF_RE = re.compile(r"^\s*#if\b")

# matches #"..."# raw strings, "..." strings, and // comments
TOKEN_RE = re.compile(r'#?"(?:\\.|[^"\\])*"#?|//.*')


def strip_code(line: str) -> str:
    return TOKEN_RE.sub("", line)


def audit_file(path: Path):
    errors, warnings = [], []
    lines = path.read_text().splitlines()
    cond_stack = []  # active #if canImport frameworks
    if_depth = 0

    for i, raw in enumerate(lines, start=1):
        line = raw.strip()

        m = CANIMPORT_RE.search(line)
        if m and IF_RE.match(line):
            cond_stack.append(m.group(1))
            if_depth += 1
            continue
        if IF_RE.match(line):
            cond_stack.append(None)
            if_depth += 1
            continue
        if ENDIF_RE.match(line):
            if if_depth == 0:
                errors.append(f"{path.name}:{i}: #endif without #if")
            else:
                if_depth -= 1
                cond_stack.pop()
            continue
        if ELSE_RE.match(line) or ELIF_RE.match(line):
            if if_depth == 0:
                errors.append(f"{path.name}:{i}: #else/#elseif without #if")
            else:
                m2 = ELIF_RE.search(line)
                cond_stack[-1] = m2.group(1) if m2 else None
            continue

        code = strip_code(raw)
        for sym, fw in GUARDED.items():
            if re.search(rf"\b{re.escape(sym)}\b", code):
                # `import X` lines and the canImport lines themselves are fine
                if fw not in cond_stack:
                    errors.append(
                        f"{path.name}:{i}: '{sym}' used outside "
                        f"#if canImport({fw})"
                    )
        if "try!" in code:
            warnings.append(f"{path.name}:{i}: uses try!")
        if "fatalError(" in code:
            warnings.append(f"{path.name}:{i}: uses fatalError(")

    if if_depth != 0:
        errors.append(f"{path.name}: unbalanced #if/#endif ({if_depth} unclosed)")

    # balance check on code without strings/comments
    cleaned = "\n".join(strip_code(l) for l in lines)
    for a, b, name in [("{", "}", "braces"), ("(", ")", "parens"), ("[", "]", "brackets")]:
        if cleaned.count(a) != cleaned.count(b):
            errors.append(
                f"{path.name}: unbalanced {name} ({cleaned.count(a)} vs {cleaned.count(b)})"
            )
    return errors, warnings


def main() -> int:
    files = sorted(SOURCES.glob("*.swift")) + sorted(TESTS.glob("*.swift"))
    if not files:
        print("audit: no Swift files found")
        return 1
    all_errors, all_warnings = [], []
    for f in files:
        e, w = audit_file(f)
        all_errors += e
        all_warnings += w
    for w in all_warnings:
        print(f"warning: {w}")
    if all_errors:
        print(f"\naudit FAILED: {len(all_errors)} problem(s)")
        for e in all_errors:
            print(f"  error: {e}")
        return 1
    print(f"audit OK: {len(files)} files checked"
          + (f", {len(all_warnings)} warning(s)" if all_warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
