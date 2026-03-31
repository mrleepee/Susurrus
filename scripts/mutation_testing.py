#!/usr/bin/env python3
"""
Mutation Testing Runner for Susurrus Swift Package.

Applies deliberate source-code mutations (mutants) to Swift files and reports
which mutations are killed (caught) vs survive (test weakness).

Usage:
    python3 scripts/mutation_testing.py                    # Run all mutants
    python3 scripts/mutation_testing.py --file AudioCaptureService.swift
    python3 scripts/mutation_testing.py --mutant relationalOperator
    python3 scripts/mutation_testing.py --list
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

# ----------------------------------------------------------------------
# Mutation Operators
# ----------------------------------------------------------------------

@dataclass
class Mutation:
    """A single mutation applied to source code."""
    id: str
    file: str
    line: int
    description: str
    original: str
    replacement: str
    operator: str

@dataclass
class MutationResult:
    """Result of applying a mutation and running tests."""
    mutation: Mutation
    killed: bool = False
    survived: bool = False
    error: str = ""
    test_output: str = ""

class MutationOperator:
    """Base class for mutation operators."""
    name: ClassVar[str]
    description: ClassVar[str]

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        raise NotImplementedError

class RelationalOperator(MutationOperator):
    """Replace relational operators: ==, !=, <, >, <=, >=."""
    name = "relationalOperator"
    description = "Replace relational operators: ==→!=, <→>=, >→<=, etc."

    replacements = {
        "==": "!=",
        "!=": "==",
        "<":  ">=",
        ">":  "<=",
        "<=": ">",
        ">=": "<",
    }

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        for m in re.finditer(r'\b([!=<>]=|[<>]=?)\b', content):
            op = m.group(1)
            if op in cls.replacements:
                line_num = content[:m.start()].count('\n') + 1
                mutants.append(Mutation(
                    id=f"rel_{file_path}_{line_num}",
                    file=file_path,
                    line=line_num,
                    description=f"relationalOperator: '{op}' → '{cls.replacements[op]}'",
                    original=m.group(0),
                    replacement=cls.replacements[op],
                    operator=cls.name,
                ))
        return mutants

class LogicalOperator(MutationOperator):
    """Swap logical operators: && ↔ ||, remove !."""
    name = "logicalOperator"
    description = "Swap &&↔||, remove !"

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        # Replace && with ||
        for m in re.finditer(r'\s(&&)\s', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"log_and_or_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description=f"logicalOperator: '&&' → '||'",
                original=m.group(0),
                replacement=m.group(0).replace("&&", "||"),
                operator=cls.name,
            ))
        # Replace || with &&
        for m in re.finditer(r'\s(\|\|)\s', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"log_or_and_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description=f"logicalOperator: '||' → '&&'",
                original=m.group(0),
                replacement=m.group(0).replace("||", "&&"),
                operator=cls.name,
            ))
        # Remove !
        for m in re.finditer(r'!\s*([(A-Za-z])', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"log_not_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description=f"logicalOperator: '!x' → 'x'",
                original=m.group(0),
                replacement=m.group(1),
                operator=cls.name,
            ))
        return mutants

class BooleanLiteral(MutationOperator):
    """Replace boolean literals: true ↔ false."""
    name = "booleanLiteral"
    description = "Replace true→false, false→true"

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        for m in re.finditer(r'\btrue\b', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"bool_true_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="booleanLiteral: true → false",
                original="true",
                replacement="false",
                operator=cls.name,
            ))
        for m in re.finditer(r'\bfalse\b', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"bool_false_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="booleanLiteral: false → true",
                original="false",
                replacement="true",
                operator=cls.name,
            ))
        return mutants

class NumericLiteral(MutationOperator):
    """Replace numeric literals: 0→1, 1→0, etc."""
    name = "numericLiteral"
    description = "Replace numeric literals: 0→1, 1→0, n→0"

    replacements = {
        "0": "1",
        "1": "0",
    }

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        for m in re.finditer(r'\b([0-9]+)\b', content):
            num = m.group(1)
            if num in cls.replacements:
                line_num = content[:m.start()].count('\n') + 1
                mutants.append(Mutation(
                    id=f"num_{file_path}_{line_num}",
                    file=file_path,
                    line=line_num,
                    description=f"numericLiteral: '{num}' → '{cls.replacements[num]}'",
                    original=num,
                    replacement=cls.replacements[num],
                    operator=cls.name,
                ))
        return mutants

class ReturnValue(MutationOperator):
    """Replace return values with defaults (return true→return false, return nil, etc.)."""
    name = "returnValue"
    description = "Replace return values with defaults"

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        # return true
        for m in re.finditer(r'\breturn\s+true\b', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"ret_true_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="returnValue: return true → return false",
                original=m.group(0),
                replacement=m.group(0).replace("return true", "return false"),
                operator=cls.name,
            ))
        # return false
        for m in re.finditer(r'\breturn\s+false\b', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"ret_false_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="returnValue: return false → return true",
                original=m.group(0),
                replacement=m.group(0).replace("return false", "return true"),
                operator=cls.name,
            ))
        # return nil
        for m in re.finditer(r'\breturn\s+nil\b', content):
            line_num = content[:m.start()].count('\n') + 1
            mutants.append(Mutation(
                id=f"ret_nil_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="returnValue: return nil → return ()",
                original=m.group(0),
                replacement=m.group(0).replace("return nil", "return ()"),
                operator=cls.name,
            ))
        return mutants

class GuardRemoval(MutationOperator):
    """Remove or invert guard conditions."""
    name = "guardRemoval"
    description = "Invert guard conditions or remove early returns"

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        # guard let ... else { throw
        for m in re.finditer(r'guard\s+(let\s+\w+\s+in|let\s+\w+\s+=\s+[^\s]+\s+else)', content):
            line_num = content[:m.start()].count('\n') + 1
            # Get the full guard line
            line_start = content.rfind('\n', 0, m.start()) + 1
            line_end = content.find('\n', m.end())
            if line_end == -1:
                line_end = len(content)
            full_line = content[line_start:line_end]
            # Skip if already mutated
            if "///MUTATED" in full_line:
                continue
            mutants.append(Mutation(
                id=f"guard_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="guardRemoval: invert guard condition",
                original=full_line.strip(),
                replacement=f"///MUTATED: {full_line.strip()}",
                operator=cls.name,
            ))
        return mutants

class ConditionInversion(MutationOperator):
    """Invert boolean conditions in if/guard statements."""
    name = "conditionInversion"
    description = "Invert boolean conditions in if/guard statements"

    @classmethod
    def find_matches(cls, content: str, file_path: str) -> list[Mutation]:
        mutants = []
        for m in re.finditer(r'\bif\s+(let\s+\w+\s+=\s+[^\s]+\s+)\b', content):
            line_num = content[:m.start()].count('\n') + 1
            line_start = content.rfind('\n', 0, m.start()) + 1
            line_end = content.find('\n', m.end())
            if line_end == -1:
                line_end = len(content)
            full_line = content[line_start:line_end]
            if "///MUTATED" in full_line:
                continue
            new_line = re.sub(r'\bif\s+(let\s+\w+\s+=\s+)([^\s]+)', r'if false // \1\2', full_line)
            mutants.append(Mutation(
                id=f"condinv_{file_path}_{line_num}",
                file=file_path,
                line=line_num,
                description="conditionInversion: if let → if false",
                original=full_line.strip(),
                replacement=new_line.strip(),
                operator=cls.name,
            ))
        return mutants

# Registry
OPERATORS: list[type[MutationOperator]] = [
    RelationalOperator,
    LogicalOperator,
    BooleanLiteral,
    NumericLiteral,
    ReturnValue,
    GuardRemoval,
    ConditionInversion,
]

# ----------------------------------------------------------------------
# Mutation Testing Engine
# ----------------------------------------------------------------------

class MutationTestingEngine:
    def __init__(self, repo_path: str, skip_swift_build: bool = False):
        self.repo_path = Path(repo_path)
        self.skip_swift_build = skip_swift_build
        self.results: list[MutationResult] = []
        self.total_mutations = 0
        self.killed = 0
        self.survived = 0
        self.errors = 0

    def discover_mutations(self, operators: list[str], files: list[str] | None = None) -> list[Mutation]:
        """Find all potential mutations in source files."""
        all_mutations = []
        source_files = []

        if files:
            for f in files:
                p = self.repo_path / f
                if p.exists():
                    source_files.append(p)
        else:
            # Auto-discover source files
            for root, _, filenames in os.walk(self.repo_path / "Sources"):
                for fn in filenames:
                    if fn.endswith(".swift"):
                        source_files.append(Path(root) / fn)

        for sf in source_files:
            try:
                content = sf.read_text()
            except Exception:
                continue

            rel_path = str(sf.relative_to(self.repo_path))
            for op_cls in OPERATORS:
                if operators and op_cls.name not in operators:
                    continue
                for mutation in op_cls.find_matches(content, rel_path):
                    all_mutations.append(mutation)

        return all_mutations

    def apply_mutation(self, mutation: Mutation) -> bool:
        """Apply a single mutation to source. Returns True on success."""
        file_path = self.repo_path / mutation.file
        try:
            content = file_path.read_text()
            if mutation.original not in content:
                return False  # Already changed or can't apply

            # For guard/condition mutations, replacement is the new full line
            if mutation.operator in ("guardRemoval", "conditionInversion"):
                new_content = content.replace(mutation.original, mutation.replacement, 1)
            else:
                new_content = content.replace(mutation.original, mutation.replacement, 1)

            file_path.write_text(new_content)
            return True
        except Exception as e:
            print(f"    ERROR applying mutation: {e}")
            return False

    def revert_mutation(self, mutation: Mutation):
        """Revert a mutation."""
        file_path = self.repo_path / mutation.file
        try:
            content = file_path.read_text()
            if mutation.operator in ("guardRemoval", "conditionInversion"):
                # Revert full line replacement
                content = content.replace(mutation.replacement, mutation.original, 1)
            else:
                content = content.replace(mutation.replacement, mutation.original, 1)
            file_path.write_text(content)
        except Exception:
            pass

    def run_tests(self, timeout: int = 120) -> tuple[bool, str]:
        """Run `swift test` and return (success, output)."""
        if self.skip_swift_build:
            result = subprocess.run(
                ["swift", "test", "--skip-build"],
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        else:
            result = subprocess.run(
                ["swift", "build", "--build-tests"],
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            if result.returncode != 0:
                return False, f"BUILD FAILED:\n{result.stderr[:500]}"

            result = subprocess.run(
                ["swift", "test"],
                cwd=self.repo_path,
                capture_output=True,
                text=True,
                timeout=timeout,
            )

        if result.returncode == 0:
            return True, result.stdout[-1000:] if result.stdout else ""
        else:
            return False, (result.stdout + result.stderr)[-1000:]

    def run_mutation(self, mutation: Mutation, dry_run: bool = False) -> MutationResult:
        """Apply mutation, run tests, revert, report."""
        result = MutationResult(mutation=mutation)

        if dry_run:
            result.survived = True
            return result

        print(f"\n  [{mutation.id}] {mutation.description}")
        print(f"    File: {mutation.file}:{mutation.line}")

        applied = self.apply_mutation(mutation)
        if not applied:
            result.error = "Could not apply mutation (text not found or conflict)"
            self.errors += 1
            return result

        print(f"    Applied. Running tests...")
        start = time.time()
        tests_passed, output = self.run_tests()
        elapsed = time.time() - start

        self.revert_mutation(mutation)

        if tests_passed:
            result.survived = True
            print(f"    SURVIVED ({elapsed:.1f}s) — test suite did NOT catch this mutation")
        else:
            result.killed = True
            print(f"    KILLED ({elapsed:.1f}s) — test suite caught the bug")

        return result

    def run_all(self, operators: list[str] | None = None,
                files: list[str] | None = None,
                dry_run: bool = False,
                limit: int = 0):
        """Run all mutations."""
        mutations = self.discover_mutations(operators, files)
        self.total_mutations = len(mutations)

        if limit > 0:
            mutations = mutations[:limit]

        print(f"\nDiscovered {len(mutations)} potential mutations")
        print(f"Operators: {operators or 'all'}")
        print(f"Files: {files or 'all source files'}")
        print(f"Mode: {'dry-run' if dry_run else 'live'}")
        print("=" * 70)

        for i, mutation in enumerate(mutations, 1):
            print(f"\n[{i}/{len(mutations)}]", end="")
            res = self.run_mutation(mutation, dry_run=dry_run)
            self.results.append(res)
            if res.killed:
                self.killed += 1
            elif res.survived:
                self.survived += 1
            elif res.error:
                self.errors += 1

    def report(self):
        """Print final mutation testing report."""
        total = self.killed + self.survived + self.errors
        print("\n" + "=" * 70)
        print("MUTATION TESTING REPORT")
        print("=" * 70)
        print(f"Total mutations applied: {total}")
        print(f"  Killed (caught by tests):   {self.killed}")
        print(f"  Survived (weak tests):      {self.survived}")
        print(f"  Errors (couldn't apply):    {self.errors}")
        if total > 0:
            kill_rate = self.killed / total * 100
            print(f"\nKill rate: {kill_rate:.1f}%")
            if kill_rate < 50:
                print("⚠️  LOW kill rate — tests are weak and likely have gaps")
            elif kill_rate < 80:
                print("⚠️  MODERATE kill rate — room for improvement")
            else:
                print("✅ GOOD kill rate — test suite is reasonably strong")

        # Group by operator
        print("\nBy operator:")
        op_stats: dict = {}
        for r in self.results:
            op = r.mutation.operator
            if op not in op_stats:
                op_stats[op] = {"killed": 0, "survived": 0, "errors": 0}
            if r.killed:
                op_stats[op]["killed"] += 1
            elif r.survived:
                op_stats[op]["survived"] += 1
            elif r.error:
                op_stats[op]["errors"] += 1
        for op, stats in sorted(op_stats.items()):
            total_op = stats["killed"] + stats["survived"] + stats["errors"]
            kr = stats["killed"] / total_op * 100 if total_op > 0 else 0
            print(f"  {op}: {stats['killed']}/{total_op} killed ({kr:.0f}%)")

        # Show survivors
        survivors = [r for r in self.results if r.survived]
        if survivors:
            print(f"\nSurviving mutations (test weaknesses):")
            for r in survivors[:20]:
                print(f"  [{r.mutation.id}] {r.mutation.file}:{r.mutation.line} — {r.mutation.description}")

# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Mutation Testing for Susurrus Swift Package",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Operators:
  relationalOperator  Replace ==, !=, <, >, <=, >=
  logicalOperator     Swap && ↔ ||, remove !
  booleanLiteral       true ↔ false
  numericLiteral       0 ↔ 1
  returnValue          return true ↔ false, return nil
  guardRemoval         Invert guard conditions
  conditionInversion   Invert if let conditions

Examples:
  python3 scripts/mutation_testing.py --dry-run
  python3 scripts/mutation_testing.py --operators relationalOperator --file AudioCaptureService.swift
  python3 scripts/mutation_testing.py --operators booleanLiteral --limit 10
  python3 scripts/mutation_testing.py --list
        """
    )
    parser.add_argument("--repo", "-r", default=".",
                        help="Path to repo (default: .)")
    parser.add_argument("--operators", nargs="+",
                        help=f"Which operators to apply. Options: {[o.name for o in OPERATORS]}")
    parser.add_argument("--file", "-f", dest="files", action="append",
                        help="Only mutate specific file(s)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Don't run tests, just report mutations")
    parser.add_argument("--limit", "-n", type=int, default=0,
                        help="Limit number of mutations (for quick smoke test)")
    parser.add_argument("--list", action="store_true",
                        help="List all available mutations without running")
    parser.add_argument("--skip-build", action="store_true",
                        help="Skip swift build step (use when already built)")
    parser.add_argument("--output", "-o", default="mutation_report.txt",
                        help="Output file for report")

    args = parser.parse_args()

    engine = MutationTestingEngine(args.repo, skip_swift_build=args.skip_build)

    if args.list:
        mutations = engine.discover_mutations(args.operators, args.files)
        print(f"Available mutations: {len(mutations)}")
        for m in mutations[:50]:
            print(f"  [{m.id}] {m.file}:{m.line} — {m.description}")
        if len(mutations) > 50:
            print(f"  ... and {len(mutations)-50} more")
        return

    engine.run_all(
        operators=args.operators,
        files=args.files,
        dry_run=args.dry_run,
        limit=args.limit,
    )
    engine.report()

    # Save report
    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        engine.report()
    Path(args.output).write_text(buf.getvalue())
    print(f"\nReport saved to {args.output}")

if __name__ == "__main__":
    main()
