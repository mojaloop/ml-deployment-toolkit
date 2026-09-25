#!/usr/bin/env python3
"""Vendor a chart repository's local dependencies.

A chart's file:// dependencies must be packaged before the chart that pulls
them, so the charts are grouped into levels of the dependency graph. Charts
within a level cannot depend on each other and run together.

    tools/vendor-charts.py <repo> [--jobs N] [--render]
"""
import argparse
import concurrent.futures as futures
import os
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

import yaml


def charts_in(root: Path):
    """Every chart in the repo, by path, excluding vendored copies."""
    found = {}
    for cf in root.rglob("Chart.yaml"):
        rel = cf.relative_to(root)
        if "charts" in rel.parts[:-1] or rel.parts[0] in {"repo", "monitoring"}:
            continue
        try:
            found[cf.parent] = yaml.safe_load(cf.read_text()) or {}
        except yaml.YAMLError as err:
            print(f"  unparsable {rel}: {err}", file=sys.stderr)
    return found


def local_deps(charts):
    """Edges from a chart to the charts it pulls over file://."""
    edges = defaultdict(set)
    for path, chart in charts.items():
        for dep in chart.get("dependencies") or []:
            repo = str(dep.get("repository", ""))
            if not repo.startswith("file://"):
                continue
            target = (path / repo[len("file://"):]).resolve()
            if target in charts:
                edges[path].add(target)
    return edges


def levels_of(charts, edges):
    """Charts grouped so everything a level needs sits in an earlier one."""
    depth = {}

    def resolve(node, seen):
        if node in depth:
            return depth[node]
        if node in seen:
            raise SystemExit(f"dependency cycle at {node}")
        seen.add(node)
        d = 1 + max((resolve(m, seen) for m in edges[node]), default=-1)
        depth[node] = d
        return d

    for node in charts:
        resolve(node, set())

    grouped = defaultdict(list)
    for node, d in depth.items():
        if edges[node]:
            grouped[d].append(node)
    return [grouped[d] for d in sorted(grouped)]


def run(chart: Path, root: Path, render: bool):
    env = dict(os.environ)
    cmd = ["helm", "dependency", "update", str(chart), "--skip-refresh"]
    done = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if done.returncode != 0:
        return chart, "vendor", done.stderr.strip().splitlines()[-1:] or [""]
    if render and (chart / "templates").is_dir():
        shown = subprocess.run(["helm", "template", "x", str(chart)],
                               capture_output=True, text=True, env=env)
        if shown.returncode != 0:
            return chart, "render", shown.stderr.strip().splitlines()[-1:] or [""]
    return chart, None, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--jobs", type=int, default=min(32, (os.cpu_count() or 8) * 2))
    ap.add_argument("--render", action="store_true")
    args = ap.parse_args()

    root = Path(args.repo).resolve()
    charts = charts_in(root)
    edges = local_deps(charts)
    plan = levels_of(charts, edges)
    total = sum(len(l) for l in plan)
    print(f"{len(charts)} charts, {total} with local dependencies, "
          f"{len(plan)} levels, {args.jobs} jobs")

    began = time.time()
    failures = []
    for i, level in enumerate(plan):
        mark = time.time()
        with futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for chart, stage, detail in pool.map(lambda c: run(c, root, args.render), level):
                if stage:
                    failures.append((chart.relative_to(root), stage, detail))
        print(f"  level {i}: {len(level):3d} charts in {time.time() - mark:5.1f}s")

    print(f"total {time.time() - began:.1f}s")
    for chart, stage, detail in failures:
        print(f"  {stage.upper():6} {chart}: {' '.join(detail)[:120]}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
