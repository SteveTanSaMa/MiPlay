#!/usr/bin/env python3
"""Opt-in synthetic Wine + current DXMT + LSFG presentation acceptance.

Only a cloned runtime, a new private Wine prefix and a tiny test executable are
used. No game installation, application data, or production prefix is opened.
The watchdog terminates its own process group and the explicitly owned prefix.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


APP = Path(__file__).resolve().parents[2]
WORKSPACE = APP.parent
LSFG = WORKSPACE / "MiPlay LSFG"
MARKER = ".miplay-lsfg-synthetic-wine-root"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def private_output(requested):
    output = requested.expanduser().resolve() if requested else Path(tempfile.mkdtemp(prefix="MiPlay-LSFG-Wine-", dir="/tmp")).resolve()
    if output in (Path("/"), Path.home(), APP, WORKSPACE):
        raise ValueError("output must be a dedicated synthetic-test directory")
    if not output.is_relative_to(Path("/tmp").resolve()):
        raise ValueError("synthetic runtime and prefix must stay under /tmp")
    if output.exists() and any(output.iterdir()) and not (output / MARKER).is_file():
        raise ValueError("refusing a nonempty output directory without this harness's marker")
    output.mkdir(parents=True, exist_ok=True)
    (output / MARKER).write_text("Synthetic Wine + DXMT presentation acceptance only.\n")
    return output


def within(path, root):
    return path.resolve().is_relative_to(root.resolve())


def copy_asset(source, destination):
    # Wine may create DLL symlinks. Never follow one when staging a test asset.
    if destination.is_symlink():
        destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    destination.write_bytes(data)
    destination.chmod(source.stat().st_mode & 0o777)


def owned_module_mappings(pid, root):
    """Inspect only the new process and descendants, never unrelated games."""
    tree = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=5)
    children = {}
    for line in tree.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2:
            child, parent = map(int, fields)
            children.setdefault(parent, []).append(child)
    owned, todo = set(), [pid]
    while todo:
        current = todo.pop()
        if current not in owned:
            owned.add(current)
            todo.extend(children.get(current, []))
    mappings = set()
    for current in owned:
        result = subprocess.run(["/usr/sbin/lsof", "-p", str(current)], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if not any(name in line for name in ("winemetal.so", "d3d11.dll", "dxgi.dll")):
                continue
            start = line.find(" /")
            if start >= 0:
                path = line[start + 1:]
                if within(Path(path), root):
                    mappings.add(path)
    return mappings


def run_owned(command, *, env, cwd, log, timeout, inspect_root=None):
    started = time.monotonic()
    with log.open("wb") as output:
        process = subprocess.Popen([str(v) for v in command], env=env, cwd=cwd,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        mappings = set()
        try:
            while True:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    status = process.wait(timeout=min(2, remaining))
                    break
                except subprocess.TimeoutExpired:
                    if inspect_root:
                        mappings.update(owned_module_mappings(process.pid, inspect_root))
        except subprocess.TimeoutExpired:
            timed_out = True
            # This group was created by this exact Popen, never by a user's game.
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
            status = process.returncode
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
            raise
    return {"exit": status, "watchdog_timeout": timed_out,
            "seconds": round(time.monotonic() - started, 3), "log": str(log),
            "runtime_module_mappings": sorted(mappings)}


def end_owned_server(runtime, prefix, env, output):
    if not (output / MARKER).is_file() or not within(prefix, output) or not within(runtime, output):
        raise ValueError("refusing to stop a wineserver outside this test root")
    command_env = dict(env, WINEPREFIX=str(prefix))
    # -k selects only the server attached to this private WINEPREFIX.
    return run_owned([runtime / "bin/wineserver", "-k"], env=command_env, cwd=output,
                     log=output / "owned-prefix-stop.log", timeout=15)


def white_center(path):
    header, pixels = path.read_bytes().split(b"\n", 1)
    values = header.split()
    if len(values) != 4 or values[0] != b"P6" or values[3] != b"255":
        raise ValueError(f"unsupported diagnostic image header: {path.name}")
    width, height = int(values[1]), int(values[2])
    if len(pixels) != width * height * 3:
        raise ValueError(f"truncated diagnostic image: {path.name}")
    xs = [index // 3 % width for index in range(0, len(pixels), 3)
          if min(pixels[index:index + 3]) > 220]
    if len(xs) < 100:
        raise ValueError(f"white block missing: {path.name}")
    return {"x": sum(xs) / len(xs), "white_pixels": len(xs), "width": width, "height": height}


def interpolation_result(directory):
    try:
        images = {name: white_center(directory / name) for name in ("previous", "original", "generated0")}
        previous, original, generated = [images[name]["x"] for name in ("previous", "original", "generated0")]
        compatible = len({(value["width"], value["height"]) for value in images.values()}) == 1
        passed = compatible and abs(original - previous) >= 4 and min(previous, original) + 1 < generated < max(previous, original) - 1
        return {"passed": passed, "images": images}
    except (OSError, ValueError, ZeroDivisionError) as error:
        return {"passed": False, "error": str(error)}


def latency_result(text, requested, enabled):
    """Keep batch percentiles; global percentiles cannot be recovered from them."""
    number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
    batches = []
    for line in text.splitlines():
        match = re.search(r"Metal latency kind=(\w+) samples=(\d+) dropped=(\d+)", line)
        if not match:
            continue
        metrics = {name: {"p50_ms": float(p50), "p95_ms": float(p95)}
                   for name, p50, p95 in re.findall(rf"(\w+)_ms=({number})/({number})", line)}
        batches.append({"kind": match[1], "samples": int(match[2]), "dropped": int(match[3]),
                        "metrics": metrics, "log_line": line})
    by_kind = {}
    for kind in sorted({batch["kind"] for batch in batches}):
        selected = [batch for batch in batches if batch["kind"] == kind]
        ranges = {}
        for name in sorted({name for batch in selected for name in batch["metrics"]}):
            values = [batch["metrics"][name] for batch in selected if name in batch["metrics"]]
            ranges[name] = {"batch_p50_min_ms": min(v["p50_ms"] for v in values),
                            "batch_p50_max_ms": max(v["p50_ms"] for v in values),
                            "batch_p95_min_ms": min(v["p95_ms"] for v in values),
                            "batch_p95_max_ms": max(v["p95_ms"] for v in values),
                            "last_batch_p50_ms": values[-1]["p50_ms"],
                            "last_batch_p95_ms": values[-1]["p95_ms"]}
        by_kind[kind] = {"batch_count": len(selected), "samples": sum(b["samples"] for b in selected),
                         "dropped": sum(b["dropped"] for b in selected), "metrics": ranges}
    return {"requested": requested, "enabled_for_case": enabled, "observed": bool(batches),
            "note": "Per-batch p50/p95 in milliseconds; ranges are not global percentiles or input-to-display latency",
            "batches": batches, "by_kind": by_kind}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wine-runtime", type=Path, default=Path.home() / "Library/Application Support/MiPlay/WineVersions/wine-crossover-11.0-1-signed")
    parser.add_argument("--dxmt", type=Path, default=APP / "RuntimeAssets/dxmt")
    parser.add_argument("--shim", type=Path, default=APP / "RuntimeAssets/lsfg/liblsfg_metal.dylib")
    parser.add_argument("--driver", type=Path, default=APP / "RuntimeAssets/lsfg/libMoltenVK.generator.dylib")
    parser.add_argument("--dll", type=Path, default=LSFG / "Lossless Scaling/lsfg-vk.dll")
    parser.add_argument("--launcher", type=Path, default=APP / "MiPlay/Resources/GameLauncher")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--routes", choices=("direct", "helper", "both"), default="both")
    parser.add_argument("--modes", choices=("off", "2x", "3x", "4x", "both", "all"), default="both")
    parser.add_argument("--flow-scale", type=float, default=1.0)
    parser.add_argument("--performance", action="store_true")
    parser.add_argument("--pacing", choices=("vsync", "adaptive"), default="vsync")
    parser.add_argument("--override-present-mode", type=int, choices=(0, 1), default=1)
    parser.add_argument("--target-fps", type=float,
                        help="LSFG display target; omitted keeps the previous fps × multiplier target")
    parser.add_argument("--latency", action="store_true", help="enable per-batch LSFG presentation latency telemetry")
    parser.add_argument("--max-frames-in-flight", type=int, choices=(2, 3),
                        help="override the source drawable pool for latency comparisons; omitted uses the component default")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--foreground", action="store_true", help="pass the fixture's existing foreground argument")
    parser.add_argument("--motion-profile", choices=("moving", "phases"), default="moving",
                        help="phases compares moving/static/moving/one-pixel content with identical draw calls")
    parser.add_argument("--frames", type=int, default=240)
    parser.add_argument("--fps", type=float, default=30)
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--compiler", default="x86_64-w64-mingw32-g++")
    args = parser.parse_args()
    if not 60 <= args.frames <= 1800 or not 10 <= args.fps <= 120:
        parser.error("frames must be 60..1800 and fps 10..120")
    if args.motion_profile == "phases" and args.frames < 480:
        parser.error("phased motion needs at least 480 frames")
    if not 0.25 <= args.flow_scale <= 1:
        parser.error("flow-scale must be 0.25..1")
    if not 128 <= args.width <= 4096 or not 128 <= args.height <= 4096:
        parser.error("width and height must each be 128..4096")
    if args.target_fps is not None and not 1 <= args.target_fps <= 1000:
        parser.error("target-fps must be 1..1000")
    source_runtime, dxmt, shim, driver, dll, launcher = [p.expanduser().resolve() for p in
        (args.wine_runtime, args.dxmt, args.shim, args.driver, args.dll, args.launcher)]
    for path in (source_runtime / "bin/wine", dxmt / "d3d11.dll", dxmt / "winemetal.so", shim, driver, dll):
        if not path.is_file():
            parser.error(f"required component missing: {path}")
    if args.routes != "direct" and not launcher.is_file():
        parser.error(f"GameLauncher missing: {launcher}")
    output = private_output(args.output)
    runtime, prefix = output / "runtime", output / "prefix"
    if runtime.exists() and not within(runtime, output):
        raise ValueError("isolated runtime escaped output directory")
    if prefix.exists() and not within(prefix, output):
        raise ValueError("isolated prefix escaped output directory")
    if not runtime.exists():
        # APFS clones are separate inodes, so DLL staging cannot mutate source.
        subprocess.run(["/bin/cp", "-cR", str(source_runtime), str(runtime)], check=True)
    wine_pe = runtime / "lib/wine/x86_64-windows"
    wine_unix = runtime / "lib/wine/x86_64-unix"
    if not within(wine_pe, runtime) or not within(wine_unix, runtime):
        raise ValueError("Wine library directories escaped the isolated runtime")
    assets = {}
    for name in ("d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"):
        copy_asset(dxmt / name, wine_pe / name)
        assets[name] = {"source": str(dxmt / name), "sha256": sha256(dxmt / name),
                        "isolated_sha256": sha256(wine_pe / name)}
    copy_asset(dxmt / "winemetal.so", wine_unix / "winemetal.so")
    assets["winemetal.so"] = {"source": str(dxmt / "winemetal.so"), "sha256": sha256(dxmt / "winemetal.so"),
                              "isolated_sha256": sha256(wine_unix / "winemetal.so")}
    fixture = output / "d3d11_present_fixture.exe"
    compilation = subprocess.run([args.compiler, "-std=c++17", "-O2", "-static", "-static-libgcc", "-static-libstdc++",
        str(Path(__file__).with_name("d3d11_present_fixture.cpp")), "-o", str(fixture), "-ld3d11", "-ldxgi", "-ld3dcompiler", "-lwinmm", "-luuid"],
        capture_output=True, text=True)
    (output / "compile.log").write_text(compilation.stdout + compilation.stderr)
    if compilation.returncode:
        raise RuntimeError(f"fixture compilation failed: {output / 'compile.log'}")
    base = {key: value for key, value in os.environ.items() if not
        (key.startswith(("DYLD_", "LSFGM_", "MIPLAY_LSFG_", "MIPLAY_FIXTURE_", "MTL_", "METAL_")) or key in ("WINEPREFIX", "WINEARCH", "WINEDLLOVERRIDES"))}
    for sub in ("cache", "config", "temp"):
        (output / sub).mkdir(exist_ok=True)
    base.update(WINEPREFIX=str(prefix), WINEARCH="win64", WINEDLLOVERRIDES="winemenubuilder.exe=d",
                WINEDEBUG="fixme-all,err-unwind", LANG="zh_CN.UTF-8", LC_ALL="zh_CN.UTF-8", LC_CTYPE="zh_CN.UTF-8",
                LC_MESSAGES="zh_CN.UTF-8", LANGUAGE="zh_CN:zh", XDG_CACHE_HOME=str(output / "cache"),
                XDG_CONFIG_HOME=str(output / "config"), TMPDIR=str(output / "temp") + "/")
    routes = ("direct", "helper") if args.routes == "both" else (args.routes,)
    modes = ("off", "2x", "3x", "4x") if args.modes == "all" else ("off", "2x") if args.modes == "both" else (args.modes,)
    report = {"scope": "synthetic Wine + current DXMT only; no game or production prefix", "output": str(output),
              "wine_source": str(source_runtime), "isolated_runtime": str(runtime), "isolated_prefix": str(prefix),
              "dxmt_assets": assets, "shim_sha256": sha256(shim), "driver_sha256": sha256(driver),
              "shader_package_sha256": sha256(dll), "fixture_sha256": sha256(fixture),
              "wine_vulkan_driver_sha256": sha256(runtime / "lib/libMoltenVK.dylib"),
              "launcher_sha256": sha256(launcher) if args.routes != "direct" else None,
              "requested_frames": args.frames, "nominal_source_fps": args.fps,
              "flow_scale": args.flow_scale, "performance_mode": args.performance,
              "pacing": args.pacing, "override_present_mode": args.override_present_mode,
              "target_fps_override": args.target_fps, "latency_requested": args.latency,
              "max_frames_in_flight": args.max_frames_in_flight,
              "width": args.width, "height": args.height, "foreground": args.foreground,
              "motion_profile": args.motion_profile,
              "planned_cases": [f"{route}-{mode}" for route in routes for mode in modes], "cases": []}
    try:
        boot = run_owned([runtime / "bin/wine", "wineboot", "-u"], env=base, cwd=output,
                         log=output / "wineboot.log", timeout=90)
        report["wineboot"] = boot
        if boot["exit"] or boot["watchdog_timeout"] or not (prefix / "drive_c").is_dir():
            raise RuntimeError(f"isolated prefix preparation failed: {output / 'wineboot.log'}")
        end_owned_server(runtime, prefix, base, output)
        system32 = prefix / "drive_c/windows/system32"
        if not within(system32, prefix):
            raise ValueError("system32 escaped the isolated prefix")
        for name in ("d3d10core.dll", "d3d11.dll", "dxgi.dll"):
            original = wine_pe / (name + ".bak")
            if original.is_file():
                copy_asset(original, system32 / name)
        copy_asset(dxmt / "winemetal.dll", system32 / "winemetal.dll")
        for route in routes:
            for mode in modes:
                name = f"{route}-{mode}"
                case_dir = output / name
                case_dir.mkdir(exist_ok=True)
                if not within(case_dir, output):
                    raise ValueError("case directory escaped the synthetic root")
                # Rerunning a marked test root must never pass on old logs,
                # status files or diagnostic images from a previous success.
                for leaf in ("process.log", "child.log", "lsfg.log", "status"):
                    path = case_dir / leaf
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                dump = case_dir / "dump"
                if dump.is_symlink():
                    dump.unlink()
                dump.mkdir(exist_ok=True)
                for leaf in ("previous", "original", "generated0"):
                    path = dump / leaf
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                environment = dict(base)
                environment.update(MIPLAY_LAUNCH_CWD=str(case_dir), MIPLAY_LAUNCH_LOG=str(case_dir / "child.log"),
                                   MIPLAY_LAUNCH_STATUS=str(case_dir / "status"),
                                   MIPLAY_FIXTURE_WIDTH=str(args.width), MIPLAY_FIXTURE_HEIGHT=str(args.height))
                environment["MIPLAY_FIXTURE_MOTION"] = args.motion_profile
                multiplier = 1 if mode == "off" else int(mode[0])
                target_fps = args.target_fps if args.target_fps is not None else round(args.fps * multiplier)
                if mode != "off":
                    environment.update(LSFGM_METAL="1", LSFGM_ENV="1", LSFGM_MULTIPLIER=str(multiplier), LSFGM_STATS="1",
                        LSFGM_FLOW_SCALE=str(args.flow_scale), LSFGM_PERFORMANCE_MODE="1" if args.performance else "0",
                        LSFGM_MOLTENVK=str(runtime / "lib/libMoltenVK.dylib"), LSFGM_GENERATOR_MOLTENVK=str(driver),
                        LSFGM_DLL_PATH=str(dll), LSFGM_PACING_MODE=args.pacing,
                        LSFGM_OVERRIDE_PRESENT_MODE=str(args.override_present_mode),
                        LSFGM_TARGET_FPS=str(target_fps), LSFGM_LOG_FILE=str(case_dir / "lsfg.log"), LSFGM_METAL_DUMP=str(case_dir / "dump"))
                    if args.latency:
                        environment["LSFGM_LATENCY"] = "1"
                    if args.max_frames_in_flight is not None:
                        environment["LSFGM_MAX_FRAMES_IN_FLIGHT"] = str(args.max_frames_in_flight)
                    if route == "direct":
                        environment["DYLD_INSERT_LIBRARIES"] = str(shim)
                    else:
                        environment["MIPLAY_LSFG_LIBRARY"] = str(shim)
                command = [runtime / "bin/wine", fixture, str(args.frames), str(args.fps)]
                if args.foreground:
                    command.append("foreground")
                if route == "helper":
                    command.insert(0, launcher)
                result = run_owned(command, env=environment, cwd=case_dir, log=case_dir / "process.log", timeout=args.timeout,
                                   inspect_root=output)
                end_owned_server(runtime, prefix, base, output)
                text = "\n".join(path.read_text(errors="replace") for path in
                    (case_dir / "process.log", case_dir / "child.log", case_dir / "lsfg.log") if path.exists())
                done = re.findall(r"FIXTURE_DONE presented=(\d+) elapsed=([0-9.]+) measured_source_fps=([0-9.]+)", text)
                stats = [dict((key, int(value)) for key, value in re.findall(r"([a-z_]+)=(\d+)", line))
                         for line in text.splitlines() if "LSFGM_METAL_STATS" in line]
                result.update(test=name, completed_source_frames=int(done[-1][0]) if done else 0,
                              measured_source_fps=float(done[-1][2]) if done else None,
                              source_samples=max((s.get("source", 0) for s in stats), default=0),
                              original_displayed=max((s.get("original_displayed", 0) for s in stats), default=0),
                              generated_displayed=max((s.get("generated_displayed", 0) for s in stats), default=0),
                              quarantined="state=quarantined" in text,
                              active="state=active" in text)
                starts = re.findall(r"FIXTURE_START width=(\d+) height=(\d+)", text)
                result["configuration"] = {"enabled": mode != "off", "multiplier": multiplier,
                    "pacing": args.pacing, "override_present_mode": args.override_present_mode,
                    "target_fps": target_fps if mode != "off" else None,
                    "flow_scale": args.flow_scale, "performance_mode": args.performance,
                    "max_frames_in_flight": args.max_frames_in_flight if mode != "off" else None,
                    "width": args.width, "height": args.height, "foreground": args.foreground}
                result["configuration"]["motion_profile"] = args.motion_profile
                result["fixture_dimensions"] = {"width": int(starts[-1][0]), "height": int(starts[-1][1])} if starts else None
                result["metal_presentations"] = [{"width": int(w), "height": int(h), "multiplier": int(m), "display_hz": float(hz)}
                    for w, h, m, hz in re.findall(r"Metal presentation (\d+)x(\d+) \([^)]*\), multiplier (\d+), display ([0-9.]+) Hz", text)]
                # LSFG writes each line to both stderr and its dedicated file.
                # Read one source so latency batch/sample counts are not doubled.
                latency_log = case_dir / "lsfg.log"
                latency_text = latency_log.read_text(errors="replace") if latency_log.is_file() else text
                result["latency"] = latency_result(latency_text, args.latency, args.latency and mode != "off")
                result["latency"]["source_log"] = str(latency_log) if latency_log.is_file() else "combined process logs (no dedicated LSFG log)"
                result["source_pool_capacities"] = sorted({int(value) for value in
                    re.findall(r"Metal proxy source capacity=(\d+)", latency_text)})
                result["source_pool_exhaustions"] = latency_text.count("Metal drawable pool exhausted")
                result["passed"] = result["exit"] == 0 and not result["watchdog_timeout"] and result["completed_source_frames"] == args.frames
                result["passed"] &= result["fixture_dimensions"] == {"width": args.width, "height": args.height}
                result["current_dxmt_bridge_loaded"] = str(wine_unix / "winemetal.so") in result["runtime_module_mappings"]
                result["passed"] &= result["current_dxmt_bridge_loaded"]
                if route == "helper":
                    status = case_dir / "status"
                    result["helper_status"] = status.read_text().strip() if status.exists() else None
                    result["passed"] &= result["helper_status"] == "exit:0"
                if mode != "off":
                    result["interpolation"] = interpolation_result(case_dir / "dump")
                    result["passed"] &= result["active"] and result["generated_displayed"] > 0 and result["original_displayed"] > 0
                    result["passed"] &= not result["quarantined"] and result["interpolation"]["passed"]
                    if args.max_frames_in_flight is not None:
                        result["passed"] &= result["source_pool_capacities"] == [args.max_frames_in_flight]
                        result["passed"] &= result["source_pool_exhaustions"] == 0
                        if args.latency and args.frames >= 240:
                            result["passed"] &= any("drawable_request_display" in batch["metrics"]
                                for batch in result["latency"]["batches"])
                else:
                    result["passed"] &= not stats and not result["active"]
                report["cases"].append(result)
                (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                print(f"{name}: {'PASS' if result['passed'] else 'FAIL'} source={result['completed_source_frames']} generated_displayed={result['generated_displayed']}", flush=True)
    finally:
        report["owned_server_cleanup"] = end_owned_server(runtime, prefix, base, output)
        report["passed"] = len(report["cases"]) == len(report["planned_cases"]) and all(case["passed"] for case in report["cases"])
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Evidence: {output / 'results.json'}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Synthetic acceptance failed: {error}", file=sys.stderr)
        sys.exit(1)
