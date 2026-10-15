#!/usr/bin/env python3
"""Serial downstream build checks, including opt-in and incremental invalidation."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
logs = repo / ".build" / "dependency-plugin-logs"
logs.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-system", choices=["native", "swiftbuild"])
options = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="AppleViewModel plugin fixture ") as directory:
    fixture = Path(directory)
    sources = fixture / "Sources" / "Feature"
    sources.mkdir(parents=True)
    manifest = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DependencyPluginFixture",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "AppleViewModel", path: REPO_PATH)],
    targets: [.target(
        name: "Feature",
        dependencies: [.product(name: "AppleViewModel", package: "AppleViewModel")],
        plugins: PLUGINS
    )]
)
""".replace("REPO_PATH", json.dumps(str(repo)))

    def set_plugin(enabled, name="AppleViewModelDependencyCheck"):
        plugin = f'[.plugin(name: "{name}", package: "AppleViewModel")]'
        (fixture / "Package.swift").write_text(manifest.replace("PLUGINS", plugin if enabled else "[]"))

    def build(label, succeeds=True, replan=False):
        # Native SwiftPM caches plugin plans. Creating/deleting an optional
        # configuration requires a new plan; ordinary edits use declared inputs.
        if replan:
            subprocess.run(["swift", "package", "--package-path", str(fixture), "clean"], check=True)
        result = subprocess.run(
            ["swift", "build", "--package-path", str(fixture)]
            + (["--build-system", options.build_system] if options.build_system else []),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        (logs / f"{label}.log").write_text(result.stdout)
        if (result.returncode == 0) != succeeds:
            raise AssertionError(f"{label} failed:\n{result.stdout}")
        print(f"Passed: {label}", flush=True)
        return result.stdout

    (sources / "Types.swift").write_text("""import AppleViewModel
@MainActor let aSpec = ViewModelSpec<A> { A() }
@MainActor let bSpec = ViewModelSpec<B> { B() }
final class A: ViewModel {}
final class B: ViewModel {}
""")
    cycle_source = """import AppleViewModel
extension A { var b: B { viewModelBinding.read(bSpec) } }
extension B { var a: A { viewModelBinding.watch(aSpec) } }
"""
    cycle_file = sources / "Cycle.swift"
    cycle_file.write_text(cycle_source)
    (sources / "Usage.swift").write_text("""import AppleViewModel
final class LintHost: ViewModel {
    lazy var cached = viewModelBinding.read(aSpec)
}
@MainActor let unkeyedForever = ViewModelSpec<A>(aliveForever: true) { A() }
@MainActor let direct = A()
@MainActor let parameterized = ViewModelSpecWithArg<A, Int>(builder: { _ in A() })
""")

    set_plugin(False)
    disabled = build("disabled")
    assert "Checking AppleViewModel dependency cycles" not in disabled
    assert "potential dependency cycle" not in disabled

    set_plugin(True)
    enabled = build("enabled-warning")
    assert "warning: AppleViewModel: potential dependency cycle: A -> B -> A" in enabled
    assert "Cycle.swift:2:26:" in enabled and "Cycle.swift:3:26:" in enabled
    assert "AppleViewModel [" not in enabled, "Legacy plugin must only check cycles"

    generated = list((fixture / ".build").rglob("AppleViewModelDependencyCheck.generated.swift"))
    assert generated, "Plugin must write its declared output"
    before = {path: path.stat().st_mtime_ns for path in generated}
    build("unchanged")
    assert before == {path: path.stat().st_mtime_ns for path in generated}, "Unchanged inputs reran scanner"

    # Remove a dependency while leaving valid compilable Swift.
    cycle_file.write_text(cycle_source.splitlines(keepends=True)[0] + cycle_source.splitlines(keepends=True)[1])
    edited = build("cycle-removed-by-edit")
    assert "potential dependency cycle" not in edited
    assert all("Potential cycles: 0" in path.read_text() for path in generated)

    set_plugin(True, name="AppleViewModelLint")
    lint_output = build("lint-all-rules")
    lint_generated = list((fixture / ".build").rglob("AppleViewModelLint.generated.swift"))
    assert lint_generated
    rules = ["cached-view-model", "alive-forever-key", "unmanaged-construction", "parameterized-spec-key"]
    for line, rule in zip([3, 5, 6, 7], rules):
        assert f"AppleViewModel [{rule}]" in lint_output
        assert f"Usage.swift:{line}:" in lint_output

    config = fixture / ".apple-view-model-lint.json"
    config.write_text(json.dumps({"disabledRules": ["parameterized-spec-key"]}))
    configured = build("lint-config-added", replan=True)
    assert "AppleViewModel [parameterized-spec-key]" not in configured
    assert "AppleViewModel [cached-view-model]" in configured

    config.write_text(json.dumps({"disabledRules": rules + ["dependency-cycle"]}))
    assert "AppleViewModel [" not in build("lint-config-edited")

    config.write_text('{"disabledRules":["misspelled-rule"]}')
    assert "error: AppleViewModel dependency scanner:" in build("lint-invalid-config", succeeds=False)

    config.unlink()
    restored = build("lint-config-removed", replan=True)
    for rule in rules:
        assert f"AppleViewModel [{rule}]" in restored

    # Restoring and then deleting the entire file must also invalidate the scan.
    cycle_file.write_text(cycle_source)
    assert "A -> B -> A" in build("cycle-restored")
    cycle_file.unlink()
    removed = build("cycle-file-removed")
    assert "potential dependency cycle" not in removed
    assert all("Potential cycles: 0" in path.read_text() for path in lint_generated)

print(f"Dependency plugin integration checks passed. Logs: {logs}")
