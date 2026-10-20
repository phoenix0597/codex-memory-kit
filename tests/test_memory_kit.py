"""Integration tests using disposable homes; Python is only a test dependency."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BACKENDS = {}
if os.name == "nt":
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    if git_bash.is_file():
        BACKENDS["bash"] = str(git_bash)
    windows_ps = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    if windows_ps.is_file():
        BACKENDS["powershell"] = str(windows_ps)
else:
    if shutil.which("bash"):
        BACKENDS["bash"] = shutil.which("bash")
if shutil.which("pwsh"):
    BACKENDS["pwsh"] = shutil.which("pwsh")
selected = os.environ.get("MEMORY_KIT_TEST_BACKENDS")
if selected:
    requested = selected.split(",")
    missing = set(requested) - BACKENDS.keys()
    if missing:
        raise RuntimeError(f"Requested test backends unavailable: {sorted(missing)}")
    BACKENDS = {name: BACKENDS[name] for name in requested}
if not BACKENDS:
    raise RuntimeError("No supported Bash or PowerShell runtime found")


def text(path):
    return path.read_text(encoding="utf-8-sig")


def put(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def snapshot(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}


class MemoryKitTests:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="memory-kit-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home with spaces & кириллица"
        self.repo = self.base / "project with spaces"
        self.home.mkdir()
        self.repo.mkdir()
        self.shared = self.home / ".agents/memories"
        self.legacy = self.home / ".codex/memories"

    def path_arg(self, value):
        value = str(value)
        if self.backend == "bash":
            value = value.replace("\\", "/")
            if os.name == "nt" and re.match(r"^[A-Za-z]:/", value):
                value = "/" + value[0].lower() + value[2:]
        return value

    def run_kit(self, command, expect=0, **options):
        options.setdefault("home", self.home)
        options.setdefault("agent", "dsh")
        if self.backend == "bash":
            scripts = {"export": "export-memory", "import": "import-memory"}
            argv = [self.runtime, self.path_arg(ROOT / "scripts" / (scripts.get(command, command) + ".sh"))]
        else:
            argv = [self.runtime, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "scripts/memory-kit.ps1"), command]
        for name, value in options.items():
            if value is False or value is None:
                continue
            flag = "--" + name.replace("_", "-") if self.backend == "bash" else "-" + "".join(word.title() for word in name.split("_"))
            argv.append(flag)
            if value is not True:
                argv.append(self.path_arg(value) if isinstance(value, Path) else str(value))
        env = os.environ.copy()
        env["PYTHONIOENCODING"] = "utf-8"
        result = subprocess.run(argv, cwd=self.repo, env=env, capture_output=True, timeout=60)
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        if expect is None:
            self.assertNotEqual(result.returncode, 0, output)
        else:
            self.assertEqual(result.returncode, expect, output)
        return output

    def check(self, **options):
        options.setdefault("repo", self.repo)
        options.setdefault("strict", True)
        return self.run_kit("check", **options)

    def test_new_dsh_install_and_project(self):
        self.run_kit("install", no_home_agents=True)
        self.run_kit("init-project", project_name="DSH & Codex | проект")
        self.check(no_home_agents=True)
        self.assertTrue((self.shared / "memory-architecture.md").is_file())
        self.assertTrue((self.home / ".dsh/AGENTS.md").is_file())
        self.assertFalse((self.home / "AGENTS.md").exists())
        self.assertFalse((self.home / ".codex").exists())
        self.assertFalse((self.repo / ".gemini").exists())
        self.assertIn("DSH & Codex | проект", text(self.repo / "assistant-memory.md"))

    def test_all_agents_share_one_store(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        before = snapshot(self.base)
        self.check(agent="all")
        self.assertEqual(before, snapshot(self.base), "check must be read-only")
        self.assertEqual(text(self.home / ".codex/AGENTS.md"), text(self.home / ".dsh/AGENTS.md"))
        self.assertTrue((self.repo / ".gemini/rules/antigravity-memory-adapter.md").is_file())

    def test_existing_legacy_memory_is_kept(self):
        put(self.legacy / "global-collaboration-rules.md", "custom user rules\n")
        put(self.legacy / "memory-architecture.md", "custom architecture\n")
        self.run_kit("install")
        self.run_kit("init-project")
        self.check()
        self.assertEqual(text(self.legacy / "global-collaboration-rules.md"), "custom user rules\n")
        self.assertFalse(self.shared.exists())

    def test_custom_memory_and_harness_paths(self):
        memory = self.base / "shared memory & правила"
        codex = self.base / "codex profile"
        dsh = self.base / "dsh profile"
        options = dict(global_memory_dir=memory, codex_dir=codex, dsh_dir=dsh, agent="all")
        self.run_kit("install", **options)
        self.run_kit("init-project", **options)
        self.check(**options)
        self.assertIn(self.path_arg(memory) if self.backend == "bash" else str(memory), text(dsh / "AGENTS.md"))
        self.assertFalse(self.legacy.exists())
        self.assertFalse(self.shared.exists())

    def test_ambiguous_roots_require_selection(self):
        self.shared.mkdir(parents=True)
        self.legacy.mkdir(parents=True)
        output = self.run_kit("install", expect=2)
        self.assertIn("Both shared and legacy memory exist", output)
        self.assertEqual(snapshot(self.base), {})
        self.run_kit("install", global_memory_dir=self.shared)
        self.check(mode="global", global_memory_dir=self.shared)

    def test_explicit_codex_dir_keeps_old_default(self):
        codex = self.base / "legacy custom codex"
        self.run_kit("install", codex_dir=codex)
        self.assertTrue((codex / "memories/memory-architecture.md").is_file())
        self.check(mode="global", codex_dir=codex)

    def test_repeated_install_preserves_user_content(self):
        self.run_kit("install")
        self.run_kit("init-project")
        with (self.repo / "assistant-memory.md").open("a", encoding="utf-8") as f:
            f.write("\nUser decision: keep this.\n")
        before = snapshot(self.base)
        self.run_kit("install")
        self.run_kit("init-project")
        self.assertEqual(before, snapshot(self.base))

    def test_dry_run_writes_nothing(self):
        self.assertIn("DRY-RUN", self.run_kit("install", dry_run=True))
        self.run_kit("init-project", dry_run=True)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(list(self.repo.iterdir()), [])

    def test_strict_check_rejects_wrong_entrypoint_link(self):
        self.run_kit("install")
        entry = self.home / ".dsh/AGENTS.md"
        put(entry, text(entry).replace("memories", "wrong-memory"))
        self.check(mode="global", expect=3)

    def test_strict_check_rejects_wrong_project_link(self):
        self.run_kit("install")
        self.run_kit("init-project")
        entry = self.repo / "START-HERE.md"
        put(entry, text(entry).replace("memories", "wrong-memory"))
        self.check(expect=3)

    def test_strict_check_rejects_unresolved_placeholder(self):
        self.run_kit("install")
        entry = self.shared / "memory-architecture.md"
        put(entry, text(entry) + "\n{{UNKNOWN_SETTING}}\n")
        self.check(mode="global", expect=3)

    def test_renderer_rejects_unknown_placeholder(self):
        source = self.base / "custom kit"
        shutil.copytree(ROOT / "templates", source / "templates")
        put(source / "templates/global/global-collaboration-rules.md", "{{UNKNOWN_SETTING}}")
        self.run_kit("install", source_root=source, expect=None)
        self.assertEqual(snapshot(self.home), {})

    def test_codex_override_is_reported(self):
        self.run_kit("install", agent="codex")
        put(self.home / ".codex/AGENTS.override.md", "Some other instructions")
        self.check(mode="global", agent="codex", expect=3)

    def test_neutral_export_import_and_legacy_archive(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        archive = self.base / "archive"
        self.run_kit("export", repo=self.repo, output_dir=archive, agent="all")
        self.assertTrue((archive / "global/memories/memory-architecture.md").is_file())
        self.assertTrue((archive / "global/agents/dsh/AGENTS.md").is_file())
        self.assertFalse((archive / "global/.codex").exists())
        before = snapshot(self.home), snapshot(self.repo)
        # Only delete the disposable fixture to exercise a true round trip.
        shutil.rmtree(self.home)
        shutil.rmtree(self.repo)
        self.home.mkdir()
        self.repo.mkdir()
        self.run_kit("import", input_dir=archive, repo=self.repo, agent="all")
        self.check(agent="all")
        self.assertEqual(before, (snapshot(self.home), snapshot(self.repo)))
        (archive / "global/.codex").mkdir()
        (archive / "global/memories").rename(archive / "global/.codex/memories")
        restored = self.base / "legacy archive destination"
        self.run_kit("import", input_dir=archive, home=restored)
        self.assertTrue((restored / ".agents/memories/memory-architecture.md").is_file())

    def test_force_import_preserves_unmanaged_project_files(self):
        self.run_kit("install")
        self.run_kit("init-project")
        archive = self.base / "archive"
        self.run_kit("export", repo=self.repo, output_dir=archive)
        put(self.repo / "memory/user-note.md", "Keep this user-owned note")
        self.run_kit("import", input_dir=archive, repo=self.repo, force=True)
        self.assertEqual(text(self.repo / "memory/user-note.md"), "Keep this user-owned note")

    def test_incomplete_archive_is_rejected(self):
        archive = self.base / "incomplete"
        archive.mkdir()
        self.run_kit("import", input_dir=archive, expect=2)
        self.assertEqual(snapshot(self.home), {})

    def test_generic_profile_has_no_harness_files(self):
        self.run_kit("install", agent="none")
        self.check(mode="global", agent="none")
        self.assertFalse((self.home / ".codex").exists())
        self.assertFalse((self.home / ".dsh").exists())

    def test_legacy_home_relative_links_are_accepted(self):
        self.legacy.mkdir(parents=True)
        self.run_kit("install")
        entry = self.home / ".dsh/AGENTS.md"
        absolute = self.path_arg(self.legacy) if self.backend == "bash" else str(self.legacy)
        content = text(entry).replace(absolute, ".codex/memories")
        if self.backend != "bash":
            content = content.replace(".codex/memories\\", ".codex/memories/")
        put(entry, content)
        self.check(mode="global")


for name, runtime in BACKENDS.items():
    globals()["Test_" + name] = type("Test_" + name, (MemoryKitTests, unittest.TestCase), {"backend": name, "runtime": runtime})

if __name__ == "__main__":
    unittest.main(verbosity=2)
