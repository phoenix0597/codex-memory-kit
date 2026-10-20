"""Integration tests: every install, import and project lives in a disposable home."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINTS = {
    "codex": ".codex/AGENTS.md",
    "dsh": ".dsh/AGENTS.md",
    "mimocode": ".config/mimocode/AGENTS.md",
    "zcode": ".zcode/AGENTS.md",
    "antigravity": ".gemini/GEMINI.md",
}
ANTIGRAVITY_RULE = ".agents/rules/antigravity-memory-adapter.md"
LOCATOR = ".agents/memory-kit.conf"
BEGIN = "<!-- memory-kit:begin -->"
END = "<!-- memory-kit:end -->"
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
AVAILABLE_BACKENDS = BACKENDS.copy()
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
    return {
        str(p.relative_to(path)) + ("/" if p.is_dir() else ""): None if p.is_dir() else p.read_bytes()
        for p in path.rglob("*")
    }


def normalized_path(value):
    value = value.replace("\\", "/")
    if os.name == "nt":
        match = re.match(r"^/(?:mnt/)?([A-Za-z])(?:/|$)(.*)", value)
        if match:
            value = match[1] + ":/" + match[2]
        # TEMP may contain an 8.3 parent such as RUNNER~1, while a native
        # runtime records its long name. Compare the actual filesystem path.
        value = Path(value).resolve().as_posix().casefold()
    return value.rstrip("/")


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

    def run_kit(self, command, expect=0, environment=None, **options):
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
        env["PYTHONUTF8"] = "1"
        if environment:
            env.update({key: str(value) for key, value in environment.items()})
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

    def assert_locator(self, home=None, memory=None):
        home = home or self.home
        content = text(home / LOCATOR)
        self.assertIn("VERSION=1", content)
        values = dict(line.split("=", 1) for line in content.splitlines() if "=" in line)
        self.assertEqual(normalized_path(values["GLOBAL_MEMORY_DIR"]), normalized_path(str(memory or home / ".agents/memories")))
        self.assertIn("KIT_ROOT=", content)

    def test_new_dsh_install_and_project(self):
        self.run_kit("install")
        self.run_kit("init-project", project_name="DSH & Codex | проект")
        self.check()
        self.assertTrue((self.shared / "memory-architecture.md").is_file())
        self.assertTrue((self.home / ".dsh/AGENTS.md").is_file())
        self.assertFalse((self.home / "AGENTS.md").exists())
        self.assertFalse((self.home / ".codex").exists())
        self.assertFalse((self.repo / ".gemini").exists())
        self.assertIn("DSH & Codex | проект", text(self.repo / "assistant-memory.md"))
        self.assert_locator()

    def test_every_named_agent_has_a_native_entrypoint(self):
        for agent, relative in ENTRYPOINTS.items():
            with self.subTest(agent=agent):
                home = self.base / (agent + " home")
                repo = self.base / (agent + " project")
                repo.mkdir()
                self.run_kit("install", home=home, agent=agent)
                self.run_kit("init-project", home=home, repo=repo, agent=agent)
                self.check(home=home, repo=repo, agent=agent)
                self.assertTrue((home / relative).is_file())
                self.assertIn("memory-kit.conf", text(home / relative))
                self.assert_locator(home=home)
                for other, other_relative in ENTRYPOINTS.items():
                    if other != agent:
                        self.assertFalse((home / other_relative).exists(), "An individual profile must not install another harness")
                self.assertEqual((repo / ANTIGRAVITY_RULE).exists(), agent == "antigravity")

    def test_all_agents_share_one_store(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        before = snapshot(self.base)
        self.check(agent="all")
        self.assertEqual(before, snapshot(self.base), "check must be read-only")
        for relative in ENTRYPOINTS.values():
            self.assertTrue((self.home / relative).is_file())
            self.assertIn("memory-kit.conf", text(self.home / relative))
        self.assertTrue((self.repo / ANTIGRAVITY_RULE).is_file())
        self.assertFalse((self.repo / ".gemini/rules/antigravity-memory-adapter.md").exists())
        self.assert_locator()

    def test_existing_legacy_memory_is_kept(self):
        put(self.legacy / "global-collaboration-rules.md", "custom user rules\n")
        put(self.legacy / "memory-architecture.md", "custom architecture\n")
        self.run_kit("install")
        self.run_kit("init-project")
        self.check()
        self.assertEqual(text(self.legacy / "global-collaboration-rules.md"), "custom user rules\n")
        self.assertFalse(self.shared.exists())
        self.assert_locator(memory=self.legacy)

    def test_custom_memory_and_harness_paths(self):
        memory = self.base / "shared memory = & правила"
        codex = self.base / "codex profile"
        dsh = self.base / "dsh profile"
        mimo = self.base / "mimo config"
        zcode = self.base / "zcode profile"
        antigravity = self.base / "antigravity profile"
        options = dict(global_memory_dir=memory, codex_dir=codex, dsh_dir=dsh, mimocode_config_dir=mimo, zcode_dir=zcode, antigravity_dir=antigravity, agent="all")
        self.run_kit("install", **options)
        self.run_kit("init-project", **options)
        self.check(**options)
        self.assert_locator(memory=memory)
        for entry in (codex / "AGENTS.md", dsh / "AGENTS.md", mimo / "AGENTS.md", zcode / "AGENTS.md", antigravity / "GEMINI.md"):
            self.assertTrue(entry.is_file())
            self.assertIn("memory-kit.conf", text(entry))
        self.assertFalse(self.legacy.exists())
        self.assertFalse(self.shared.exists())

    def test_ambiguous_roots_require_selection(self):
        self.shared.mkdir(parents=True)
        self.legacy.mkdir(parents=True)
        before = snapshot(self.base)
        self.run_kit("install", expect=2)
        self.assertEqual(snapshot(self.base), before)
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

    def test_native_bootstraps_append_and_keep_user_text_idempotently(self):
        custom = "# User instructions\nKeep this custom rule: café & кириллица.\n"
        paths = [self.home / relative for relative in ENTRYPOINTS.values()]
        for path in paths:
            put(path, custom)
        self.run_kit("install", agent="all")
        for path in paths:
            with self.subTest(path=path):
                content = text(path)
                self.assertTrue(content.startswith(custom))
                self.assertEqual(content.count(BEGIN), 1)
                self.assertEqual(content.count(END), 1)
                self.assertIn("~/.agents/memory-kit.conf", content)
        before = snapshot(self.home)
        self.run_kit("install", agent="all")
        self.assertEqual(before, snapshot(self.home))
        self.check(mode="global", agent="all")

    def test_existing_home_agents_is_untouched_by_every_memory_operation(self):
        home_agents = self.home / "AGENTS.md"
        user_bytes = b"\xef\xbb\xbf# User-owned home instructions\r\n" + "Правило пользователя сохраняется побайтно.\r\n".encode("utf-8") + b"{{USER_PLACEHOLDER}}\r\n<!-- memory-kit:begin -->\r\n"
        home_agents.write_bytes(user_bytes)
        operations = (
            ("install", dict(agent="all")),
            ("init-project", dict(agent="all")),
            ("check", dict(agent="all", repo=self.repo, strict=True)),
            ("install", dict(agent="all", force=True)),
            ("init-project", dict(agent="all", force=True)),
            ("install", dict(agent="all", update_adapters=True)),
            ("init-project", dict(agent="all", update_adapters=True)),
        )
        for command, options in operations:
            with self.subTest(command=command, options=options):
                self.run_kit(command, **options)
                self.assertEqual(home_agents.read_bytes(), user_bytes)
        archive = self.base / "home-independent archive"
        self.run_kit("export", agent="all", repo=self.repo, output_dir=archive)
        self.run_kit("export", agent="all", repo=self.repo, output_dir=archive, force=True)
        self.assertEqual(home_agents.read_bytes(), user_bytes)
        self.assertFalse((archive / "global/AGENTS.md").exists())
        put(archive / "global/AGENTS.md", "Archived home instructions must be ignored.\n")
        destination = self.base / "existing-home-file import"
        destination_agents = destination / "AGENTS.md"
        destination_bytes = b"# Destination home instructions\r\nDo not replace this user file.\r\n"
        destination_agents.parent.mkdir()
        destination_agents.write_bytes(destination_bytes)
        repo = self.base / "existing-home-file project"
        for options in ({}, {"force": True}, {"update_adapters": True}):
            with self.subTest(import_options=options):
                self.run_kit("import", home=destination, repo=repo, agent="all", input_dir=archive, **options)
                self.assertEqual(destination_agents.read_bytes(), destination_bytes)
                self.assertEqual(home_agents.read_bytes(), user_bytes)
                self.check(home=destination, repo=repo, agent="all")
        for relative in ENTRYPOINTS.values():
            self.assertTrue((destination / relative).is_file())
        self.assertTrue((repo / "AGENTS.md").is_file())

    def test_fresh_homes_never_receive_agents_from_install_or_old_archives(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        self.check(agent="all")
        self.assertFalse((self.home / "AGENTS.md").exists())
        archive = self.base / "archive with obsolete home index"
        self.run_kit("export", agent="all", repo=self.repo, output_dir=archive)
        self.assertFalse((archive / "global/AGENTS.md").exists())
        put(archive / "global/AGENTS.md", "# Obsolete kit home index\n{{OLD_HOME_PATH}}\n")
        for version in ("v2", "legacy"):
            with self.subTest(archive_version=version):
                if version == "legacy":
                    (archive / "memory-kit-export.conf").unlink()
                destination = self.base / (version + " fresh import home")
                repo = self.base / (version + " fresh import project")
                self.run_kit("import", home=destination, repo=repo, agent="all", input_dir=archive, force=True, update_adapters=True)
                self.assertFalse((destination / "AGENTS.md").exists())
                self.check(home=destination, repo=repo, agent="all")
                for relative in ENTRYPOINTS.values():
                    self.assertTrue((destination / relative).is_file())
                self.assertTrue((repo / "AGENTS.md").is_file())

    def test_removed_home_index_flag_is_rejected_without_writes(self):
        before = snapshot(self.base)
        self.run_kit("install", no_home_agents=True, expect=None)
        self.assertEqual(before, snapshot(self.base))

    def test_force_replaces_only_native_managed_block(self):
        self.run_kit("install")
        path = self.home / ".dsh/AGENTS.md"
        original = text(path)
        user_prefix = "# User header\nKeep user's configuration.\n"
        user_suffix = "\n# User footer\nKeep this trailing note.\n"
        put(path, user_prefix + original.replace("memory-kit.conf", "stale-memory.conf") + user_suffix)
        before = snapshot(self.home)
        self.run_kit("install", expect=None)
        self.assertEqual(before, snapshot(self.home))
        self.run_kit("install", force=True)
        updated = text(path)
        self.assertTrue(updated.startswith(user_prefix))
        self.assertTrue(updated.endswith(user_suffix))
        self.assertIn("~/.agents/memory-kit.conf", updated)
        self.assertNotIn("stale-memory.conf", updated)
        self.assertEqual(updated.count(BEGIN), 1)
        self.check(mode="global")

    def test_update_adapters_keeps_custom_canonical_memory(self):
        self.run_kit("install")
        self.run_kit("init-project")
        rules = self.shared / "global-collaboration-rules.md"
        with rules.open("a", encoding="utf-8") as stream:
            stream.write("\nUser's permanent rule: preserve this sentinel.\n")
        path = self.home / ".dsh/AGENTS.md"
        prefix, suffix = "# Existing user instructions\n", "\n# Existing user footer\n"
        put(path, prefix + text(path).replace("memory-kit.conf", "stale-memory.conf") + suffix)
        before = snapshot(self.shared), snapshot(self.repo), (self.home / LOCATOR).read_bytes()
        self.run_kit("install", update_adapters=True)
        self.assertEqual(before, (snapshot(self.shared), snapshot(self.repo), (self.home / LOCATOR).read_bytes()))
        updated = text(path)
        self.assertTrue(updated.startswith(prefix))
        self.assertTrue(updated.endswith(suffix))
        self.assertIn("~/.agents/memory-kit.conf", updated)
        self.assertNotIn("stale-memory.conf", updated)
        self.assertEqual(updated.count(BEGIN), 1)
        self.check()

    def test_import_regenerates_antigravity_managed_rule_and_preserves_user_text(self):
        self.run_kit("install", agent="antigravity")
        self.run_kit("init-project", agent="antigravity")
        source_adapter = self.repo / ANTIGRAVITY_RULE
        archived_prefix = "# Archived user note\n"
        archived_footer = "\n# Archived user footer\n"
        stale = text(source_adapter).replace(BEGIN, archived_prefix + BEGIN).replace("memory-kit.conf", "stale-archive.conf") + archived_footer
        put(source_adapter, stale)
        canonical = {relative: (self.repo / relative).read_bytes() for relative in ("AGENTS.md", "START-HERE.md", "assistant-memory.md")}
        global_before = snapshot(self.shared)
        archive = self.base / "stale Antigravity rule archive"
        self.run_kit("export", repo=self.repo, output_dir=archive, agent="antigravity")
        home = self.base / "Antigravity import home"
        repo = self.base / "Antigravity import project"
        self.run_kit("import", home=home, repo=repo, input_dir=archive, agent="antigravity")
        adapter = repo / ANTIGRAVITY_RULE
        regenerated = text(adapter)
        self.assertIn("~/.agents/memory-kit.conf", regenerated)
        self.assertNotIn("stale-archive.conf", regenerated)
        self.assertIn(archived_prefix, regenerated)
        self.assertTrue(regenerated.endswith(archived_footer))
        self.check(home=home, repo=repo, agent="antigravity")
        self.assertEqual(global_before, snapshot(home / ".agents/memories"))
        for relative, expected in canonical.items():
            self.assertEqual((repo / relative).read_bytes(), expected)
        destination_footer = "\n# Destination user note\n"
        put(adapter, regenerated.replace("memory-kit.conf", "stale-destination.conf") + destination_footer)
        previous = text(adapter)
        prefix = previous.split(BEGIN, 1)[0]
        suffix = previous.split(END, 1)[1]
        before = snapshot(home / ".agents/memories"), {relative: (repo / relative).read_bytes() for relative in canonical}
        self.run_kit("import", home=home, repo=repo, input_dir=archive, agent="antigravity", update_adapters=True)
        updated = text(adapter)
        self.assertTrue(updated.startswith(prefix))
        self.assertTrue(updated.endswith(suffix))
        self.assertNotIn("stale-destination.conf", updated)
        self.assertIn("~/.agents/memory-kit.conf", updated)
        self.assertEqual(before, (snapshot(home / ".agents/memories"), {relative: (repo / relative).read_bytes() for relative in canonical}))
        self.check(home=home, repo=repo, agent="antigravity")

    def test_malformed_native_managed_block_is_rejected_without_writes(self):
        path = self.home / ".dsh/AGENTS.md"
        put(path, "# Custom rules\n" + BEGIN + "\nUnclosed managed block\n")
        before = snapshot(self.home)
        self.run_kit("install", expect=2)
        self.assertEqual(before, snapshot(self.home))

    def test_dry_run_writes_nothing(self):
        self.assertIn("DRY-RUN", self.run_kit("install", dry_run=True))
        self.run_kit("init-project", dry_run=True)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(list(self.repo.iterdir()), [])

    def test_strict_check_rejects_wrong_entrypoint_link(self):
        self.run_kit("install")
        entry = self.home / ".dsh/AGENTS.md"
        put(entry, text(entry).replace("memory-kit.conf", "wrong-memory.conf"))
        self.check(mode="global", expect=3)

    def test_strict_check_requires_startup_references_inside_managed_block(self):
        self.run_kit("install")
        entry = self.home / ".dsh/AGENTS.md"
        put(entry, "# Historical reference examples\n~/.agents/memory-kit.conf\nglobal-collaboration-rules.md\nmemory-architecture.md\n" + BEGIN + "\nNo startup references in this block.\n" + END + "\n")
        before = snapshot(self.base)
        self.check(mode="global", expect=3)
        self.assertEqual(before, snapshot(self.base))

    def test_strict_check_rejects_wrong_project_link(self):
        self.run_kit("install")
        self.run_kit("init-project")
        entry = self.repo / "AGENTS.md"
        put(entry, text(entry).replace("memory-kit.conf", "wrong-memory.conf"))
        self.check(expect=3)

    def test_strict_check_rejects_unresolved_placeholder(self):
        self.run_kit("install")
        entry = self.shared / "memory-architecture.md"
        put(entry, text(entry) + "\n{{UNKNOWN_SETTING}}\n")
        self.check(mode="global", expect=3)

    def test_strict_check_rejects_empty_core_memory_files(self):
        self.run_kit("install")
        self.run_kit("init-project")
        for path in (self.shared / "global-collaboration-rules.md", self.shared / "memory-architecture.md", self.repo / "AGENTS.md"):
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_bytes(b"")
                before = snapshot(self.base)
                self.check(expect=3)
                self.assertEqual(before, snapshot(self.base))
                path.write_bytes(original)

    def test_renderer_rejects_unknown_placeholder(self):
        source = self.base / "custom kit"
        shutil.copytree(ROOT / "templates", source / "templates")
        put(source / "templates/global/global-collaboration-rules.md", "{{UNKNOWN_SETTING}}")
        self.run_kit("install", source_root=source, expect=None)
        self.assertEqual(snapshot(self.home), {}, "A failed preflight must not create even empty directories")

    def test_codex_override_is_reported(self):
        self.run_kit("install", agent="codex")
        put(self.home / ".codex/AGENTS.override.md", "Some other instructions")
        self.check(mode="global", agent="codex", expect=3)

    def test_neutral_export_import(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        archive = self.base / "archive"
        self.run_kit("export", repo=self.repo, output_dir=archive, agent="all")
        self.assertTrue((archive / "global/memories/memory-architecture.md").is_file())
        self.assertTrue((archive / "global/agents/dsh/AGENTS.md").is_file())
        self.assertFalse((archive / "global/.codex").exists())
        self.assertIn("VERSION=2", text(archive / "memory-kit-export.conf"))
        self.assertIn("AGENT=all", text(archive / "memory-kit-export.conf"))
        before = snapshot(self.home), snapshot(self.repo)
        # Only delete the disposable fixture to exercise a true round trip.
        shutil.rmtree(self.home)
        shutil.rmtree(self.repo)
        self.home.mkdir()
        self.repo.mkdir()
        self.run_kit("import", input_dir=archive, repo=self.repo, agent="all")
        self.check(agent="all")
        self.assertEqual(before, (snapshot(self.home), snapshot(self.repo)))

    def test_legacy_global_archive_is_readable_without_rewriting_user_text(self):
        archive = self.base / "legacy archive"
        put(archive / "global/.codex/memories/global-collaboration-rules.md", "Legacy user rules\n")
        put(archive / "global/.codex/memories/memory-architecture.md", "Legacy architecture with original links\n")
        output = self.run_kit("import", input_dir=archive)
        self.assertIn("LEGACY ARCHIVE", output)
        self.assertEqual(text(self.shared / "global-collaboration-rules.md"), "Legacy user rules\n")
        self.assertEqual(text(self.shared / "memory-architecture.md"), "Legacy architecture with original links\n")

    def test_legacy_absolute_project_links_need_explicit_migration(self):
        self.run_kit("install")
        self.run_kit("init-project")
        archive = self.base / "legacy project archive"
        self.run_kit("export", output_dir=archive, repo=self.repo)
        (archive / "memory-kit-export.conf").unlink()
        old_instructions = (
            "# Legacy project instructions\n"
            + self.path_arg(self.shared / "global-collaboration-rules.md") + "\n"
            + self.path_arg(self.shared / "memory-architecture.md") + "\n"
            + "Read START-HERE.md and memory/current-work-queue.md.\n"
        )
        put(archive / "project/AGENTS.md", old_instructions)
        destination = self.base / "legacy destination"
        repo = self.base / "legacy destination project"
        self.run_kit("import", home=destination, repo=repo, input_dir=archive)
        self.run_kit("install", home=destination)
        self.check(home=destination, mode="global")
        self.check(home=destination, repo=repo, expect=3)
        self.assertEqual(text(repo / "AGENTS.md"), old_instructions)

    def test_export_import_to_another_home_and_memory_preserves_canonical_bytes(self):
        self.run_kit("install", agent="all")
        self.run_kit("init-project", agent="all")
        user_note = self.shared / "user-global-note.md"
        put(user_note, "Global user note must move too.\n")
        with (self.repo / "assistant-memory.md").open("a", encoding="utf-8") as stream:
            stream.write("\nA historical path that must stay literal: " + str(self.home) + "\n")
        before_global = snapshot(self.shared)
        before_project = snapshot(self.repo)
        archive = self.base / "portable archive"
        self.run_kit("export", repo=self.repo, agent="all", output_dir=archive)
        destination = self.base / "new home & другой"
        memory = self.base / "new shared memory & память"
        repo = self.base / "new project"
        self.run_kit("import", input_dir=archive, home=destination, repo=repo, global_memory_dir=memory, agent="all")
        self.check(home=destination, repo=repo, global_memory_dir=memory, agent="all")
        self.assert_locator(home=destination, memory=memory)
        self.assertEqual(before_global, snapshot(memory))
        self.assertEqual(before_project, snapshot(repo))

    def test_optional_project_documents_round_trip(self):
        self.run_kit("install")
        self.run_kit("init-project")
        optional = {
            "technical-specification-mvp.md": "# User requirements\nPreserve specification bytes.\n",
            "article-notes.md": "# User article notes\nKeep quoted paths and notes unchanged.\n",
        }
        for relative, content in optional.items():
            put(self.repo / relative, content)
        expected = {relative: (self.repo / relative).read_bytes() for relative in optional}
        archive = self.base / "optional documents archive"
        self.run_kit("export", repo=self.repo, output_dir=archive)
        destination = self.base / "optional documents home"
        repo = self.base / "optional documents project"
        self.run_kit("import", home=destination, repo=repo, input_dir=archive)
        for relative, content in expected.items():
            self.assertEqual((repo / relative).read_bytes(), content)
        self.check(home=destination, repo=repo)

    def test_overlapping_archive_trees_are_rejected_before_writes(self):
        self.run_kit("install")
        self.run_kit("init-project")
        for output in (self.shared / "nested backup", self.repo / "memory/nested backup"):
            with self.subTest(output=output):
                before = snapshot(self.base)
                self.run_kit("export", output_dir=output, repo=self.repo, expect=2)
                self.assertEqual(before, snapshot(self.base))
        archive = self.base / "valid archive"
        self.run_kit("export", repo=self.repo, output_dir=archive)
        destination = self.base / "overlap rejected home"
        before = snapshot(self.base)
        self.run_kit("import", home=destination, input_dir=archive, global_memory_dir=archive / "global/memories", expect=2)
        self.assertEqual(before, snapshot(self.base))
        self.assertFalse(destination.exists())

    def test_force_import_preserves_unmanaged_project_files(self):
        self.run_kit("install")
        self.run_kit("init-project")
        archive = self.base / "archive"
        self.run_kit("export", repo=self.repo, output_dir=archive)
        put(self.repo / "memory/user-note.md", "Keep this user-owned note")
        self.run_kit("import", input_dir=archive, repo=self.repo, force=True)
        self.assertEqual(text(self.repo / "memory/user-note.md"), "Keep this user-owned note")

    def test_import_adds_missing_files_and_preserves_conflicts_without_force(self):
        self.run_kit("install")
        self.run_kit("init-project")
        put(self.repo / "memory/new-note.md", "Imported new note")
        put(self.repo / "memory/conflict.md", "Archive value")
        put(self.shared / "global-added-note.md", "Imported global note")
        archive = self.base / "archive"
        self.run_kit("export", repo=self.repo, output_dir=archive)
        destination = self.base / "destination home"
        repo = self.base / "destination repo"
        repo.mkdir()
        self.run_kit("install", home=destination)
        self.run_kit("init-project", home=destination, repo=repo)
        put(repo / "memory/conflict.md", "Destination value")
        put(repo / "memory/destination-only.md", "Keep destination-only note")
        self.run_kit("import", input_dir=archive, home=destination, repo=repo)
        self.assertEqual(text(repo / "memory/new-note.md"), "Imported new note")
        self.assertEqual(text(repo / "memory/conflict.md"), "Destination value")
        self.assertEqual(text(repo / "memory/destination-only.md"), "Keep destination-only note")
        self.assertEqual(text(destination / ".agents/memories/global-added-note.md"), "Imported global note")
        self.check(home=destination, repo=repo)

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
        self.assertFalse((self.home / ".config/mimocode").exists())
        self.assertFalse((self.home / ".zcode").exists())
        self.assertFalse((self.home / ".gemini").exists())

    def test_portable_templates_do_not_embed_machine_paths(self):
        self.run_kit("install")
        self.run_kit("init-project")
        for path in (self.shared / "memory-architecture.md", self.repo / "AGENTS.md", self.repo / "START-HERE.md", self.repo / "assistant-memory.md"):
            with self.subTest(path=path):
                content = text(path)
                self.assertNotIn(str(self.home), content)
                self.assertNotIn(self.path_arg(self.home), content)
                self.assertIn("memory-kit.conf" if path.name in ("memory-architecture.md", "AGENTS.md") else "AGENTS.md", content)

    def test_locator_is_data_only_and_rejects_unknown_versions(self):
        self.run_kit("install")
        locator = self.home / LOCATOR
        put(locator, text(locator).replace("VERSION=1", "VERSION=999"))
        before = snapshot(self.base)
        self.check(mode="global", expect=2)
        self.run_kit("install", expect=2)
        self.assertEqual(before, snapshot(self.base))

    def test_malformed_locators_are_rejected_without_writes(self):
        self.run_kit("install")
        locator = self.home / LOCATOR
        good = text(locator)
        malicious = self.base / "unexpected-command-output"
        cases = {
            "missing-version": good.replace("VERSION=1\n", ""),
            "duplicate-version": good + "\nVERSION=1\n",
            "missing-memory": "VERSION=1\nKIT_ROOT=" + self.path_arg(ROOT) + "\n",
            "relative-memory": "VERSION=1\nGLOBAL_MEMORY_DIR=relative/memory\nKIT_ROOT=" + self.path_arg(ROOT) + "\n",
            "shell-expression": "VERSION=1\nGLOBAL_MEMORY_DIR=$(echo injected > " + self.path_arg(malicious) + ")\nKIT_ROOT=" + self.path_arg(ROOT) + "\n",
        }
        for label, bad in cases.items():
            with self.subTest(case=label):
                put(locator, bad)
                before = snapshot(self.base)
                self.check(mode="global", expect=2)
                self.run_kit("install", expect=2)
                self.assertEqual(before, snapshot(self.base))
                self.assertFalse(malicious.exists())

    def test_strict_check_rejects_locator_pointing_elsewhere(self):
        self.run_kit("install")
        locator = self.home / LOCATOR
        wrong = self.base / "nonexistent memory"
        put(locator, re.sub(r"(?m)^GLOBAL_MEMORY_DIR=.*$", lambda _: "GLOBAL_MEMORY_DIR=" + self.path_arg(wrong), text(locator)))
        before = snapshot(self.base)
        self.check(mode="global", expect=3)
        self.assertEqual(before, snapshot(self.base))

    def test_strict_check_rejects_explicit_memory_locator_mismatch(self):
        self.run_kit("install")
        memory = self.base / "other valid global memory"
        shutil.copytree(self.shared, memory)
        before = snapshot(self.base)
        self.check(mode="global", global_memory_dir=memory, expect=3)
        self.assertEqual(before, snapshot(self.base))

    def test_strict_check_rejects_missing_locator(self):
        self.run_kit("install")
        (self.home / LOCATOR).unlink()
        before = snapshot(self.base)
        self.check(mode="global", expect=3)
        self.assertEqual(before, snapshot(self.base))

    def test_strict_check_rejects_kit_root_without_kit_sources(self):
        self.run_kit("install")
        empty = self.base / "existing empty source directory"
        empty.mkdir()
        locator = self.home / LOCATOR
        put(locator, re.sub(r"(?m)^KIT_ROOT=.*$", lambda _: "KIT_ROOT=" + self.path_arg(empty), text(locator)))
        before = snapshot(self.base)
        self.check(mode="global", expect=3)
        self.assertEqual(before, snapshot(self.base))

    def test_explicit_home_isolates_harness_environment(self):
        outside = self.base / "environment profiles"
        environment = {
            key: self.path_arg(outside / key)
            for key in ("CODEX_HOME", "DSH_HOME", "MIMOCODE_CONFIG_DIR", "MIMOCODE_HOME", "XDG_CONFIG_HOME", "ZCODE_HOME", "GEMINI_HOME")
        }
        self.run_kit("install", agent="all", environment=environment)
        self.check(mode="global", agent="all", environment=environment)
        self.assertFalse(outside.exists())
        for relative in ENTRYPOINTS.values():
            self.assertTrue((self.home / relative).is_file())

    def test_mimocode_environment_config_priority_without_home_flag(self):
        for selected_root in ("config-dir", "mimocode-home", "xdg"):
            with self.subTest(selected_root=selected_root):
                home = self.base / (selected_root + " isolated home")
                memory = home / ".agents/memories"
                explicit = self.base / (selected_root + " explicit config")
                mimo_home = self.base / (selected_root + " mimo home")
                xdg = self.base / (selected_root + " xdg")
                environment = {
                    "HOME": self.path_arg(home),
                    "USERPROFILE": str(home),
                    "MIMOCODE_CONFIG_DIR": self.path_arg(explicit) if selected_root == "config-dir" else "",
                    "MIMOCODE_HOME": self.path_arg(mimo_home) if selected_root != "xdg" else "",
                    "XDG_CONFIG_HOME": self.path_arg(xdg),
                }
                expected = explicit if selected_root == "config-dir" else mimo_home / "config" if selected_root == "mimocode-home" else xdg / "mimocode"
                self.run_kit("install", home=None, agent="mimocode", global_memory_dir=memory, environment=environment)
                self.assertTrue((expected / "AGENTS.md").is_file())
                self.check(home=None, agent="mimocode", mode="global", global_memory_dir=memory, environment=environment)
                self.assert_locator(home=home, memory=memory)

    def test_codex_and_dsh_environment_roots_without_home_flag(self):
        codex = self.base / "runtime codex root"
        dsh = self.base / "runtime dsh root"
        environment = {
            "HOME": self.path_arg(self.home),
            "USERPROFILE": str(self.home),
            "CODEX_HOME": self.path_arg(codex),
            "DSH_HOME": self.path_arg(dsh),
        }
        for agent, directory in (("codex", codex), ("dsh", dsh)):
            with self.subTest(agent=agent):
                self.run_kit("install", home=None, agent=agent, global_memory_dir=self.shared, environment=environment)
                self.assertTrue((directory / "AGENTS.md").is_file())
                self.assertFalse((self.home / ENTRYPOINTS[agent]).exists())
                self.check(home=None, agent=agent, mode="global", global_memory_dir=self.shared, environment=environment)

    def test_existing_codex_home_memory_is_kept_without_home_flag(self):
        codex = self.base / "runtime legacy codex root"
        legacy = codex / "memories"
        put(legacy / "global-collaboration-rules.md", "Existing runtime user rules\n")
        put(legacy / "memory-architecture.md", "Existing runtime architecture\n")
        before = snapshot(legacy)
        environment = {"HOME": self.path_arg(self.home), "USERPROFILE": str(self.home), "CODEX_HOME": self.path_arg(codex)}
        self.run_kit("install", home=None, agent="codex", environment=environment)
        self.assert_locator(memory=legacy)
        self.assertFalse(self.shared.exists())
        self.assertEqual(before, snapshot(legacy))
        self.check(home=None, agent="codex", mode="global", environment=environment)

    def test_antigravity_requires_active_rule_with_always_on_trigger(self):
        self.run_kit("install", agent="antigravity")
        self.run_kit("init-project", agent="antigravity")
        adapter = self.repo / ANTIGRAVITY_RULE
        good = text(adapter)
        self.assertRegex(good, r"(?m)^trigger:\s*always_on\s*$")
        put(adapter, re.sub(r"(?m)^trigger:.*$", "trigger: manual", good))
        self.check(agent="antigravity", expect=3)
        put(adapter, re.sub(r"(?m)^trigger:.*\n", "", good))
        self.check(agent="antigravity", expect=3)
        put(adapter, good)
        inactive = self.repo / ".gemini/rules/antigravity-memory-adapter.md"
        inactive.parent.mkdir(parents=True)
        adapter.rename(inactive)
        self.check(agent="antigravity", expect=3)

    def test_antigravity_rule_utf8_byte_limit_includes_boundary(self):
        self.run_kit("install", agent="antigravity")
        self.run_kit("init-project", agent="antigravity")
        for path in (self.home / ".gemini/GEMINI.md", self.repo / ANTIGRAVITY_RULE):
            with self.subTest(path=path):
                original = path.read_bytes()
                self.assertLess(len(original), 24000)
                at_limit = original + b"\n#" + b"x" * (24000 - len(original) - 2)
                self.assertEqual(len(at_limit), 24000)
                path.write_bytes(at_limit)
                self.check(agent="antigravity")
                path.write_bytes(at_limit + b"x")
                self.check(agent="antigravity", expect=3)
                path.write_bytes(original)
        self.run_kit("install", agent="dsh")
        dsh = self.home / ".dsh/AGENTS.md"
        put(dsh, text(dsh) + "\n# " + "я" * 12001)
        self.assertGreater(dsh.stat().st_size, 24000)
        self.check(agent="dsh", mode="global")

    def test_unknown_agent_and_invalid_path_characters_write_nothing(self):
        self.run_kit("install", agent="unsupported-harness", expect=None)
        self.assertEqual(snapshot(self.home), {})
        for forbidden in ("\n", "\r", "\t"):
            with self.subTest(character=repr(forbidden)):
                memory = self.base / ("invalid" + forbidden + "memory")
                self.run_kit("install", global_memory_dir=memory, expect=2)
                self.assertEqual(snapshot(self.home), {})

    def test_manifest_rejects_unknown_archive_version_before_writing(self):
        self.run_kit("install")
        archive = self.base / "archive"
        self.run_kit("export", output_dir=archive)
        manifest = archive / "memory-kit-export.conf"
        put(manifest, text(manifest).replace("VERSION=2", "VERSION=999"))
        destination = self.base / "rejected archive destination"
        self.run_kit("import", input_dir=archive, home=destination, expect=2)
        self.assertFalse(destination.exists())

    def test_import_uses_current_kit_and_does_not_execute_archive_code(self):
        self.run_kit("install")
        archive = self.base / "archive with untrusted code"
        self.run_kit("export", output_dir=archive)
        marker = self.base / "archive code must never execute"
        put(archive / "global/memory-kit.conf", "VERSION=1\nGLOBAL_MEMORY_DIR=" + self.path_arg(self.shared) + "\nKIT_ROOT=" + self.path_arg(archive) + "\n")
        put(archive / "scripts/install.sh", "#!/usr/bin/env bash\nprintf unsafe > '" + self.path_arg(marker) + "'\n")
        put(archive / "scripts/memory-kit.ps1", "Set-Content -LiteralPath '" + str(marker).replace("'", "''") + "' -Value unsafe\n")
        destination = self.base / "safe import destination"
        self.run_kit("import", home=destination, input_dir=archive)
        self.assertFalse(marker.exists())
        locator = dict(line.split("=", 1) for line in text(destination / LOCATOR).splitlines() if "=" in line)
        self.assertEqual(normalized_path(locator["KIT_ROOT"]), normalized_path(str(ROOT)))
        self.check(home=destination, mode="global")


class PathComparisonTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows 8.3 path aliases are platform-specific")
    def test_windows_short_alias_identifies_the_same_directory(self):
        import ctypes

        get_short_path = ctypes.windll.kernel32.GetShortPathNameW
        get_short_path.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
        get_short_path.restype = ctypes.c_uint
        with tempfile.TemporaryDirectory(prefix="memory-kit-long-directory-name-") as directory:
            long_path = str(Path(directory).resolve())
            required = get_short_path(long_path, None, 0)
            if not required:
                raise ctypes.WinError()
            buffer = ctypes.create_unicode_buffer(required)
            if not get_short_path(long_path, buffer, required):
                raise ctypes.WinError()
            short_path = buffer.value
            if short_path.casefold() == long_path.casefold():
                self.skipTest("This volume does not expose a distinct 8.3 alias")
            self.assertEqual(normalized_path(short_path), normalized_path(long_path))
            msys_short_path = "/" + short_path[0].lower() + short_path[2:].replace("\\", "/")
            self.assertEqual(normalized_path(msys_short_path), normalized_path(long_path))


for name, runtime in BACKENDS.items():
    globals()["Test_" + name] = type("Test_" + name, (MemoryKitTests, unittest.TestCase), {"backend": name, "runtime": runtime})


@unittest.skipUnless(os.environ.get("MEMORY_KIT_TEST_INTEROP") == "1", "Enable MEMORY_KIT_TEST_INTEROP=1 for cross-shell checks")
class InteroperabilityTests(unittest.TestCase):
    setUp = MemoryKitTests.setUp
    path_arg = MemoryKitTests.path_arg
    run_kit = MemoryKitTests.run_kit
    check = MemoryKitTests.check
    assert_locator = MemoryKitTests.assert_locator

    def test_each_backend_reads_another_backend_installation(self):
        if len(AVAILABLE_BACKENDS) < 2:
            self.skipTest("At least two runtimes are required")
        for source, source_runtime in AVAILABLE_BACKENDS.items():
            home = self.base / ("interop " + source)
            repo = self.base / ("interop project " + source)
            repo.mkdir()
            self.backend, self.runtime = source, source_runtime
            self.run_kit("install", home=home, agent="all")
            self.run_kit("init-project", home=home, repo=repo, agent="all")
            before = snapshot(home), snapshot(repo)
            for target, target_runtime in AVAILABLE_BACKENDS.items():
                if source == target:
                    continue
                with self.subTest(source=source, target=target):
                    self.backend, self.runtime = target, target_runtime
                    self.check(home=home, repo=repo, agent="all")
                    self.assert_locator(home=home)
                    self.run_kit("install", home=home, agent="all")
                    self.assertEqual(before, (snapshot(home), snapshot(repo)), "Switching shells must not rewrite shared memory or configuration")


if __name__ == "__main__":
    unittest.main(verbosity=2)
