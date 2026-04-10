"""
System limits and best-practice guidance:

Single message size (prompt):
    - Roughly 10–20k tokens total (including context).
    - A few tens of pages of text/code is fine.
    - Hundreds of pages will be truncated.

Response size:
    - Up to a few thousand tokens per reply.
    - Long answers possible, but not book-length.

Best-practice working size:
    - For technical work, keep each message under 5–8k tokens (~40–60k chars).
    - If bigger, split into multiple, logically separated messages.
    - If >50–80 printed pages, chunk it.
"""

import argparse
import ast
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Set

from perplexity_webui_scraper import Perplexity, ClientConfig

__all__ = [
    "load_token",
    "run_get_perplexity_session_token",
    "find_related_files",
    "build_fix_prompt",
    "build_edit_prompt",
    "filter_diff_to_known_files",
    "apply_unified_diff",
    "main",
    "cli_entry",
]

MAX_LINES = 40  # limit code context per file to save tokens (smaller for API limits)


def load_token(cli_token: Optional[str] = None) -> Optional[str]:
    """
    Load the Perplexity session token from (in order of precedence):
    1. CLI argument
    2. Environment variable PERPLEXITY_SESSION_TOKEN
    3. .env file in current directory
    Returns the token string if found, else None.
    """
    if cli_token:
        return cli_token
    token = os.environ.get("PERPLEXITY_SESSION_TOKEN")
    if token:
        return token
    try:
        with open(".env", "r", encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("PERPLEXITY_SESSION_TOKEN"):
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        token = parts[1].strip().strip('"')
                        print("[INFO] Loaded token from .env")
                        return token
    except Exception:
        pass
    return None


def write_token_to_env(token: str, path: str = ".env") -> None:
    """Write the Perplexity session token into a .env file."""
    try:
        lines: List[str] = []
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                lines = f.readlines()

        token_line = f'PERPLEXITY_SESSION_TOKEN="{token}"\n'
        updated = False
        for index, line in enumerate(lines):
            if line.strip().startswith("PERPLEXITY_SESSION_TOKEN"):
                lines[index] = token_line
                updated = True
                break

        if not updated:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(token_line)

        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines)

        print(f"[INFO] Saved token to {path}")
    except Exception as exc:
        print(f"[ERROR] Could not write {path}: {exc}", file=sys.stderr)


def run_get_perplexity_session_token() -> int:
    """
    Run the Perplexity session token CLI generator in interactive mode.
    The installed module handles saving the token to .env.
    """
    print("[INFO] Launching Perplexity session token CLI...")
    proc = subprocess.run(
        [sys.executable, "-m", "perplexity_webui_scraper.cli.get_perplexity_session_token"],
    )
    return proc.returncode


def load_tail(path: str, max_lines: int = MAX_LINES) -> str:
    """
    Load only the last `max_lines` lines of a file to keep prompts small.
    """
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    return "".join(lines[-max_lines:])


def find_related_files(entrypoint: str, root: str = ".") -> List[str]:
    """
    Starting from entrypoint (e.g. run_with_dashboard.py), walk imports
    and return a list of .py files in the same project that are transitively used.
    Only follows imports that resolve under `root`.
    """
    root_path = Path(root).resolve()
    visited_modules: Set[str] = set()
    files: Set[Path] = set()

    def module_to_path(module: str) -> Optional[Path]:
        """
        Convert 'pkg.mod' -> root/pkg/mod.py if it exists.
        Also handle single-name modules in root.
        """
        parts = module.split(".")
        candidate = root_path.joinpath(*parts).with_suffix(".py")
        if candidate.is_file():
            return candidate
        # Try package __init__.py
        pkg_init = root_path.joinpath(*parts, "__init__.py")
        if pkg_init.is_file():
            return pkg_init
        return None

    def visit_file(path: Path) -> None:
        if not path.is_file() or path.suffix != ".py":
            return
        try:
            rel_mod = path.relative_to(root_path).with_suffix("")
        except ValueError:
            # outside root
            return
        module_name = ".".join(rel_mod.parts)
        if module_name in visited_modules:
            return
        visited_modules.add(module_name)
        files.add(path)

        try:
            src = path.read_text(encoding="utf-8")
        except Exception:
            return
        try:
            tree = ast.parse(src, filename=str(path))
        except SyntaxError:
            return

        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    mod_name = alias.name
                    mod_path = module_to_path(mod_name)
                    if mod_path:
                        visit_file(mod_path)
            elif isinstance(node, ast.ImportFrom):
                if node.module is None:
                    continue
                mod_name = node.module
                # Handle relative imports (from .foo import bar)
                if node.level:
                    parent_parts = module_name.split(".")[: -node.level]
                    if parent_parts:
                        mod_name = ".".join(parent_parts + [mod_name])
                mod_path = module_to_path(mod_name)
                if mod_path:
                    visit_file(mod_path)

    entry_path = Path(entrypoint).resolve()
    if not entry_path.is_file():
        print(f"[ERROR] Entrypoint not found: {entrypoint}", file=sys.stderr)
        return []

    visit_file(entry_path)
    return [str(p) for p in sorted(files)]


def build_fix_prompt(user_text: str, files: List[str]) -> str:
    """
    Build a compact prompt for analysis / bug-finding.
    Sends only the tail of each file and asks for a short, high-signal answer.
    """
    snippets = []
    for path in files:
        if os.path.isfile(path):
            ext = os.path.splitext(path)[1]
            tail = load_tail(path)
            if ext == ".py":
                snippets.append(f"# File: {path}\n```python\n{tail}\n```")
            elif ext in (".sh", ".bash", ".zsh"):
                snippets.append(f"# File: {path}\n```bash\n{tail}\n```")
            else:
                # Generic code block for other file types
                snippets.append(f"# File: {path}\n```")
                snippets.append(f"{tail}\n```")

    code_block = "\n\n".join(snippets)

    return (
        "You are a static analyser for codebases (Python, shell scripts, etc).\n"
        "Task: find concrete bugs and obvious performance issues in the code.\n"
        "Return a very short, numbered list of at most 5 items.\n"
        "Each item: one line with file:line (or function) and short description.\n"
        "Do not repeat the code and do not explain language basics.\n\n"
        f"User message:\n{user_text}\n\n"
        f"Relevant code snippets (tail only):\n{code_block}\n"
    )


def build_edit_prompt(user_instruction: str, files: List[str]) -> str:
    """
    Build a prompt asking for a unified diff to edit the given files.
    Only the tail of each file is sent to save tokens.
    """
    parts = []
    for path in files:
        if os.path.isfile(path) and path.endswith(".py"):
            tail = load_tail(path)
            parts.append(f"# File: {path}\n```python\n{tail}\n```")

    files_block = "\n\n".join(parts)

    return (
        "You are a precise Python code editor for a crypto trading bot.\n"
        "Apply the requested changes to the code below.\n"
        "Return ONLY a unified diff (git-style) that can be applied with the 'patch' command.\n"
        "Format exactly like:\n"
        "  --- path/to/file.py\n"
        "  +++ path/to/file.py\n"
        "  @@ -old_start,old_len +new_start,new_len @@\n"
        "  -old line\n"
        "  +new line\n"
        "No explanations, no commentary, no markdown, no code fences.\n"
        "Preserve existing logic unless explicitly requested.\n"
        "If no change is needed, return an empty diff.\n\n"
        f"User request:\n{user_instruction}\n\n"
        f"Relevant code snippets (tail only for each file):\n{files_block}\n"
    )


def filter_diff_to_known_files(diff_text: str, allowed_files: List[str]) -> str:
    """
    Keep only hunks for files under allowed_files.
    Assumes '--- path' / '+++ path' lines.
    """
    if not diff_text or not diff_text.strip():
        return diff_text

    allowed_set = {str(Path(p).resolve()) for p in allowed_files}
    result_lines: List[str] = []
    current_file_resolved: Optional[str] = None
    keep = False

    lines = diff_text.splitlines(keepends=True)
    for line in lines:
        if line.startswith("--- "):
            # '--- path'
            path_str = line[4:].strip()
            # Some diffs use 'a/path', so normalise directly
            current_file_resolved = str(Path(path_str).resolve())
            keep = current_file_resolved in allowed_set
            if keep:
                result_lines.append(line)
        elif line.startswith("+++ "):
            if keep:
                result_lines.append(line)
        else:
            if keep:
                result_lines.append(line)

    return "".join(result_lines)


def apply_unified_diff(diff_text: str) -> None:
    """
    Apply a unified diff to local files using the `patch` command.
    """
    if not diff_text or not diff_text.strip():
        print("[INFO] Empty diff; nothing to apply.")
        return

    proc = subprocess.Popen(
        ["patch", "-p0"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    out, _ = proc.communicate(diff_text)
    print(out)
    if proc.returncode != 0:
        print(f"[ERROR] patch failed with code {proc.returncode}", file=sys.stderr)


def main() -> None:
    """
    Main CLI entrypoint.
    Uses only prompt + relevant code; never uploads attachments.
    """
    parser = argparse.ArgumentParser(description="Perplexity WebUI Scraper CLI")
    parser.add_argument(
        "--token", type=str, default=None, help="Perplexity session token (from browser cookie)"
    )
    parser.add_argument(
        "--prompt",
        type=str,
        help="Natural-language instruction/question. No code needed; script finds code.",
    )
    parser.add_argument(
        "--prompt-file",
        type=str,
        help="Path to a file containing the prompt text (overrides --prompt if set)",
        default=None,
    )
    parser.add_argument(
        "--get-token",
        action="store_true",
        help="Run the interactive session token generator and exit.",
    )
    parser.add_argument(
        "--mode",
        type=str,
        choices=["free", "fix", "edit"],
        default="free",
        help="free = normal Q&A, fix = analyse code, edit = get diff and apply it",
    )
    parser.add_argument(
        "--entrypoint",
        type=str,
        required=True,
        help="Path to the main entrypoint file for analysis (e.g., windows-install.sh)",
    )
    parser.add_argument(
        "--root",
        type=str,
        default=".",
        help="Project root directory for resolving imports.",
    )
    args = parser.parse_args()

    # Use the provided entrypoint
    args.entry = args.entrypoint

    if args.get_token:
        return_code = run_get_perplexity_session_token()
        sys.exit(return_code if return_code >= 0 else 1)

    prompt_text = None
    if args.prompt_file:
        try:
            with open(args.prompt_file, "r", encoding="utf-8") as f:
                prompt_text = f.read()
        except Exception as e:
            print(f"[ERROR] Could not read prompt file: {e}", file=sys.stderr)
            sys.exit(1)
    elif args.prompt:
        prompt_text = args.prompt
    if not prompt_text:
        print(
            "[ERROR] --prompt or --prompt-file is required (describe what you want).",
            file=sys.stderr,
        )
        sys.exit(1)


    # --- System limits and best-practice checks ---
    MAX_PROMPT_CHARS = 20000  # ~3k tokens
    MAX_CODE_CHARS = 8000

    # In free mode, if entrypoint is a shell script, append its content to the prompt
    if args.mode == "free" and os.path.isfile(args.entry):
        ext = os.path.splitext(args.entry)[1]
        if ext in (".sh", ".bash", ".zsh"):
            try:
                with open(args.entry, "r", encoding="utf-8") as f:
                    shell_code = f.read()
                prompt_text = (
                    f"{prompt_text}\n\n---\nAttached shell script ({args.entry}):\n" +
                    f"```bash\n{shell_code}\n```"
                )
            except Exception as e:
                print(f"[WARN] Could not read shell script for prompt: {e}", file=sys.stderr)

    if len(prompt_text) > MAX_PROMPT_CHARS:
        print(
            f"[WARN] Prompt is very large ({len(prompt_text)} chars). Truncating to {MAX_PROMPT_CHARS} chars.",
            file=sys.stderr,
        )
        prompt_text = prompt_text[:MAX_PROMPT_CHARS]

    # For fix/edit modes, check and enforce code context size
    related_files: List[str] = []
    code_context_snippets = []
    code_context_size = 0
    if args.mode in ("fix", "edit"):
        related_files = find_related_files(args.entry, root=args.root)
        if not related_files:
            print(
                f"[WARN] No related files found for entrypoint {args.entry}; falling back to entry only.",
                file=sys.stderr,
            )
            entry_path = Path(args.entry).resolve()
            if entry_path.is_file():
                related_files = [str(entry_path)]
        # Collect code context, truncate if needed
        for path in related_files:
            if os.path.isfile(path) and path.endswith(".py"):
                try:
                    snippet = load_tail(path)
                    code_context_snippets.append((path, snippet))
                    code_context_size += len(snippet)
                except Exception:
                    pass
        if code_context_size > MAX_CODE_CHARS:
            print(
                f"[WARN] Code context is very large ({code_context_size} chars). Truncating to {MAX_CODE_CHARS} chars.",
                file=sys.stderr,
            )
            # Truncate code context to MAX_CODE_CHARS
            truncated_snippets = []
            total = 0
            for path, snippet in code_context_snippets:
                if total + len(snippet) > MAX_CODE_CHARS:
                    remain = MAX_CODE_CHARS - total
                    if remain > 0:
                        truncated_snippets.append((path, snippet[:remain]))
                    break
                truncated_snippets.append((path, snippet))
                total += len(snippet)
            code_context_snippets = truncated_snippets
            code_context_size = total

    session_token = load_token(args.token)
    if not session_token:
        print(
            "[ERROR] Please provide --token, set PERPLEXITY_SESSION_TOKEN, or run with --get-token first.",
            file=sys.stderr,
        )
        sys.exit(1)

    # Discover relevant files (for fix/edit)
    related_files: List[str] = []
    if args.mode in ("fix", "edit"):
        related_files = find_related_files(args.entry, root=args.root)
        if not related_files:
            print(
                f"[WARN] No related files found for entrypoint {args.entry}; falling back to entry only.",
                file=sys.stderr,
            )
            entry_path = Path(args.entry).resolve()
            if entry_path.is_file():
                related_files = [str(entry_path)]


    # --- Perplexity client with retry/backoff config ---
    try:
        config = ClientConfig(
            max_retries=5,           # Retry up to 5 times
            retry_backoff=2.0,       # Exponential backoff starting at 2s
            timeout=60,              # 60s timeout per request
        )
        client = Perplexity(session_token=session_token, config=config)
        conversation = client.create_conversation()

        if args.mode == "fix":
            if not related_files:
                print("[ERROR] No files to analyse.", file=sys.stderr)
                sys.exit(1)
            fix_prompt = build_fix_prompt(prompt_text, related_files)
            conversation.ask(fix_prompt, files=None)
            print(conversation.answer)
            return

        if args.mode == "edit":
            if not related_files:
                print("[ERROR] No files to edit.", file=sys.stderr)
                sys.exit(1)
            edit_prompt = build_edit_prompt(prompt_text, related_files)
            conversation.ask(edit_prompt, files=None)
            raw_diff = conversation.answer
            safe_diff = filter_diff_to_known_files(raw_diff, related_files)
            apply_unified_diff(safe_diff)
            return

        # free mode: just use your prompt, no code context, no attachments
        conversation.ask(prompt_text, files=None)
        print(conversation.answer)

    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


def cli_entry():
    try:
        main()
    except Exception as exc:
        print(f"[FATAL ERROR] {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    cli_entry()
