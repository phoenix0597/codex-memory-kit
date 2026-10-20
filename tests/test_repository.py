"""Source-level portability checks, independent of installed user memory."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SELECTED = set(filter(None, os.environ.get("MEMORY_KIT_TEST_BACKENDS", "").split(",")))


def bash_runtime():
    if os.name == "nt":
        candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        return str(candidate) if candidate.is_file() else None
    return shutil.which("bash")


def bash_path(path):
    value = path.as_posix()
    if os.name == "nt" and len(value) >= 3 and value[1:3] == ":/":
        return "/" + value[0].lower() + value[2:]
    return value


class RepositoryTests(unittest.TestCase):
    def test_shell_sources_use_lf_and_bash_shebang(self):
        for path in (ROOT / "scripts").rglob("*.sh"):
            with self.subTest(path=path.relative_to(ROOT)):
                content = path.read_bytes()
                self.assertTrue(content.startswith(b"#!/usr/bin/env bash\n"))
                self.assertNotIn(b"\r", content, "CRLF breaks Bash entry points")

    def test_text_sources_are_utf8(self):
        paths = list((ROOT / "scripts").rglob("*.ps1"))
        paths += list((ROOT / "scripts").rglob("*.sh"))
        paths += [path for path in (ROOT / "templates").rglob("*") if path.is_file()]
        for path in paths:
            with self.subTest(path=path.relative_to(ROOT)):
                path.read_bytes().decode("utf-8-sig")

    def test_non_ascii_powershell_sources_keep_windows_51_bom(self):
        for path in (ROOT / "scripts").rglob("*.ps1"):
            with self.subTest(path=path.relative_to(ROOT)):
                content = path.read_bytes()
                text = content.decode("utf-8-sig")
                if not text.isascii():
                    self.assertTrue(content.startswith(b"\xef\xbb\xbf"), "Windows PowerShell 5.1 needs a BOM to read non-ASCII UTF-8")

    def test_bash_sources_parse(self):
        if SELECTED and "bash" not in SELECTED:
            self.skipTest("Bash is covered by its own CI job")
        runtime = bash_runtime()
        if not runtime:
            if "bash" in SELECTED:
                self.fail("Requested Bash runtime is unavailable")
            self.skipTest("Bash is unavailable")
        for path in (ROOT / "scripts").rglob("*.sh"):
            with self.subTest(path=path.relative_to(ROOT)):
                result = subprocess.run([runtime, "-n", bash_path(path)], capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", errors="replace"))

    def test_powershell_sources_parse(self):
        runtimes = {}
        if os.name == "nt":
            candidate = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            if candidate.is_file():
                runtimes["powershell"] = str(candidate)
        if shutil.which("pwsh"):
            runtimes["pwsh"] = shutil.which("pwsh")
        if SELECTED:
            requested = SELECTED & {"powershell", "pwsh"}
            self.assertFalse(requested - runtimes.keys(), "Requested PowerShell runtime is unavailable")
            runtimes = {key: value for key, value in runtimes.items() if key in requested}
        if not runtimes:
            self.skipTest("PowerShell is unavailable or covered by its own CI job")
        script = r"""
$ErrorActionPreference = 'Stop'
$failed = $false
Get-ChildItem -LiteralPath $env:MEMORY_KIT_PARSE_SCRIPTS -Filter '*.ps1' -Recurse | ForEach-Object {
  $tokens = $null
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    $failed = $true
    Write-Output $_.FullName
    Write-Output ($errors | Out-String)
  }
}
if ($failed) { exit 1 }
"""
        env = os.environ.copy()
        env["MEMORY_KIT_PARSE_SCRIPTS"] = str(ROOT / "scripts")
        for name, runtime in runtimes.items():
            with self.subTest(runtime=name):
                result = subprocess.run([runtime, "-NoProfile", "-NonInteractive", "-Command", script], env=env, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", errors="replace"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
