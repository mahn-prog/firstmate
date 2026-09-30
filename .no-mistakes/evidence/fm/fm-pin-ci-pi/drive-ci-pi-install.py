#!/usr/bin/env python3
"""Run every 'Install the Pi package' step of .github/workflows/ci.yml the way
GitHub Actions would (bash -eo pipefail, workflow+job+step env merged), but
into an isolated npm prefix, then report the Pi version each step installed."""
import os, subprocess, sys, tempfile, yaml, json
wf = yaml.safe_load(open(sys.argv[1]))
base_env = dict(wf.get("env") or {})
print("workflow-level env:", base_env)
results = []
for job_id, job in wf["jobs"].items():
    for step in job.get("steps", []):
        if "pi-coding-agent" not in (step.get("run") or ""):
            continue
        env = {**os.environ, **{k: str(v) for k, v in base_env.items()},
               **{k: str(v) for k, v in (job.get("env") or {}).items()},
               **{k: str(v) for k, v in (step.get("env") or {}).items()}}
        prefix = tempfile.mkdtemp(prefix=f"pi-{job_id}-")
        env["npm_config_prefix"] = prefix
        env.pop("PI_CODING_AGENT_VERSION", None) if "PI_CODING_AGENT_VERSION" not in base_env else None
        print(f"\n== job {job_id}: step '{step['name']}' (prefix {prefix})")
        p = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                           env=env, capture_output=True, text=True)
        print(p.stdout.strip()); print(p.stderr.strip()[-600:])
        pkg = os.path.join(prefix, "lib/node_modules/@earendil-works/pi-coding-agent/package.json")
        ver = json.load(open(pkg))["version"] if os.path.exists(pkg) else None
        print(f"exit={p.returncode} installed_version={ver}")
        results.append((job_id, p.returncode, ver, prefix))
print("\nSUMMARY", json.dumps(results))
