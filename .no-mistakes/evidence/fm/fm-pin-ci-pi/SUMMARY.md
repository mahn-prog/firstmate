# CI Pi pin (0.87.1) — targeted validation

| What | Pi 0.87.1 (this PR's pinned install step) | Pi 0.99.1 (base's unpinned install step) |
|---|---|---|
| Install steps, both jobs (`drive-ci-pi-install.py`) | both install 0.87.1 (`ci-pi-install-steps.log`) | both install 0.99.1 (`ci-pi-install-steps.base.log`) |
| tests/fm-calm-pi-extension.test.sh (serial 2) | 15/15 ok, exit 0 | check 15 **not ok - rendered export DOM violated the Calm conversation boundary** |
| tests/fm-pi-branch-extension.test.sh check 1 (serial 4) | ok - Calm-off and HTML export stay stock | **Calm-off ToolExecutionComponent rendering differs from Pi stock** |
| fm-pi-branch check 3 (local only) | times out after 2.5 s on this Mac; passes with a 25 s budget (probeB) | same timeout (probeA): happens on both versions, so it's a local timing issue |
