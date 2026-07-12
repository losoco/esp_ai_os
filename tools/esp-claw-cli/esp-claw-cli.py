#!/usr/bin/env python3
"""
esp-claw-cli — ADB-style CLI tool for ESP-Claw devices.

Push/pull files to/from the device SD card, list/delete remote files,
run Lua scripts, and execute one-liners — all over HTTP (WiFi).

Usage examples:
  esp-claw-cli push local.txt /inbox/local.txt
  esp-claw-cli pull /sdcard/capture.jpg ./capture.jpg
  esp-claw-cli ls /inbox/
  esp-claw-cli rm /inbox/old.txt
  esp-claw-cli run test.lua
  esp-claw-cli exec "print(1+1)"
  esp-claw-cli --host 192.168.8.100 ls /
  esp-claw-cli discover          # mDNS auto-discovery
"""

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "0.1.0"
DEFAULT_HOST = "esp-claw.local"
DEFAULT_PORT = 80
CHUNK_SIZE = 65536   # 64 KB upload chunk
BUFSIZ = 65536       # 64 KB download buffer
DEFAULT_TIMEOUT = 30

# ────────────────────────────────────────────────────────────────── helpers

def _resolve_host(host: str, port: int) -> str:
    """Resolve mDNS .local name to IP if needed."""
    if host.endswith(".local"):
        try:
            import socket
            addrs = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
            ip = addrs[0][4][0] if addrs else host
        except Exception:
            ip = host
        return ip
    return host


def _url(host: str, port: int, path: str, query: dict = None) -> str:
    """Build a full HTTP URL."""
    ip = _resolve_host(host, port)
    base = f"http://{ip}:{port}{path}"
    if query:
        qs = urllib.parse.urlencode(query)
        base = f"{base}?{qs}"
    return base


def _json_get(host: str, port: int, path: str, query: dict = None, timeout=DEFAULT_TIMEOUT):
    """HTTP GET → parsed JSON."""
    url = _url(host, port, path, query)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Connection failed: {e.reason}")


def _file_exists(host: str, port: int, path: str) -> bool:
    """Check if remote file exists via HEAD-style check on /files."""
    url = _url(host, port, f"/files{path}")
    req = urllib.request.Request(url, method="HEAD")
    try:
        urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT)
        return True
    except Exception:
        return False


def _progress_bar(done: int, total: int, width: int = 40):
    if total <= 0:
        return
    pct = min(done / total, 1.0)
    filled = int(width * pct)
    bar = "█" * filled + "░" * (width - filled)
    sys.stderr.write(f"\r  [{bar}] {done}/{total} bytes ({pct*100:.0f}%)")
    sys.stderr.flush()
    if done >= total:
        sys.stderr.write("\n")


# ──────────────────────────────────────────────────────────── subcommands

def cmd_discover(args):
    """Discover ESP-Claw devices via mDNS hostname resolution and HTTP probing."""
    try:
        import socket
    except ImportError:
        raise SystemExit("Device discovery requires Python socket module")

    # Common hostname patterns
    candidates = [
        "esp-claw.local",
        f"esp-claw-{args.host_suffix}.local" if args.host_suffix else None,
    ]
    candidates = [c for c in candidates if c is not None]

    if not args.host_suffix:
        # Also try scanning a range of names
        for suffix in ["", "1", "2", "3"]:
            name = f"esp-claw{suffix}.local"
            if name not in candidates:
                candidates.append(name)

    found = []
    for hostname in candidates[:10]:  # Limit to 10 tries
        ip = _resolve_host(hostname, args.port)
        if ip != hostname:  # Resolved successfully
            # Verify it's an ESP-Claw by checking /api/status
            try:
                url = f"http://{ip}:{args.port}/api/status"
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=3) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    found.append({
                        "hostname": hostname,
                        "ip": ip,
                        "port": args.port,
                        "ssid": data.get("ap_ssid", "?"),
                        "storage": data.get("storage_base_path", "?"),
                    })
            except Exception:
                # Host resolved but not an ESP-Claw or not ready yet
                pass

    if found:
        print(f"Found {len(found)} device(s):")
        for d in found:
            print(f"  {d['hostname']} → {d['ip']}:{d['port']}  AP={d['ssid']}  storage={d['storage']}")
    else:
        print("No ESP-Claw devices found.")
        print("Tips:")
        print("  - Ensure the device is powered on and connected to the same WiFi network")
        print("  - Try specifying the IP directly: esp-claw-cli --host <ip> info")
        print("  - Use --host-suffix to try hostnames like esp-claw-8BA109.local")


def cmd_push(args):
    """Upload a local file to the device SD card."""
    local_path = Path(args.local)
    if not local_path.is_file():
        raise SystemExit(f"Local file not found: {args.local}")

    remote = args.remote
    if not remote.startswith("/"):
        remote = "/" + remote
    url = _url(args.host, args.port, "/api/files/upload", {"path": remote})

    file_size = local_path.stat().st_size
    if file_size > 16 * 1024 * 1024:
        raise SystemExit(f"File too large ({file_size} bytes), max 16 MB")

    print(f"Pushing {args.local} ({file_size} bytes) → {remote}")

    with open(local_path, "rb") as f:
        file_data = f.read()

    req = urllib.request.Request(
        url,
        data=file_data,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("ok"):
                print(f"  Uploaded {file_size} bytes successfully")
            else:
                raise SystemExit(f"Upload failed: {result}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Connection failed: {e.reason}")


def cmd_pull(args):
    """Download a file from the device SD card."""
    remote = args.remote
    if not remote.startswith("/"):
        remote = "/" + remote
    url = _url(args.host, args.port, f"/files{remote}")

    local = Path(args.local)
    if local.is_dir():
        local = local / os.path.basename(remote)

    print(f"Pulling {remote} → {args.local}")

    # Download with progress
    done = 0
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            # Try to get content-length for progress
            total = int(resp.headers.get("Content-Length", 0))
            with open(local, "wb") as f:
                while True:
                    chunk = resp.read(BUFSIZ)
                    if not chunk:
                        break
                    f.write(chunk)
                    done += len(chunk)
                    _progress_bar(done, total)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Connection failed: {e.reason}")

    print(f"  Downloaded {done} bytes → {local}")


def cmd_ls(args):
    """List files in a remote directory."""
    path = args.path
    if not path.startswith("/"):
        path = "/" + path

    data = _json_get(args.host, args.port, "/api/files", {"path": path})
    entries = data.get("entries", [])
    if not entries:
        print(f"{path}  (empty)")
        return

    # Sort: dirs first, then files, alphabetical
    entries.sort(key=lambda e: (not e.get("is_dir", False), e.get("name", "").lower()))

    for e in entries:
        icon = "[DIR]" if e.get("is_dir") else "     "
        size = e.get("size", 0)
        if e.get("is_dir"):
            size_str = ""
        elif size < 1024:
            size_str = f"{size}B"
        elif size < 1024 * 1024:
            size_str = f"{size/1024:.1f}K"
        else:
            size_str = f"{size/(1024*1024):.1f}M"
        print(f"  {icon}  {size_str:>8s}  {e['name']}")


def cmd_rm(args):
    """Delete a file or directory on the device."""
    path = args.path
    if not path.startswith("/"):
        path = "/" + path

    query = {"path": path}
    if args.recursive:
        query["recursive"] = "1"

    url = _url(args.host, args.port, "/api/files", query)
    req = urllib.request.Request(url, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("ok"):
                print(f"Deleted: {path}")
            else:
                raise SystemExit(f"Delete failed: {result}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        try:
            info = json.loads(body)
            if info.get("error") == "directory_not_empty":
                print(f"Directory not empty: {path}")
                print(f"  Use --recursive to delete all contents")
                sys.exit(1)
        except Exception:
            pass
        raise SystemExit(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Connection failed: {e.reason}")


def cmd_mkdir(args):
    """Create a directory on the device."""
    path = args.path
    if not path.startswith("/"):
        path = "/" + path

    body = {"path": path}
    if args.parents:
        body["recursive"] = True

    url = _url(args.host, args.port, "/api/files/mkdir")
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            if result.get("ok"):
                print(f"Created: {path}")
            else:
                raise SystemExit(f"mkdir failed: {result}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Connection failed: {e.reason}")


def _upload_and_resolve(host, port, local_file, remote_rel):
    """Upload a file and return the relative path for execution.
    The backend /api/files/run resolves the path through the storage base."""

    # Clean up: if the user passed /sdcard prefix, strip it since backend prepends it
    resolved = remote_rel
    if resolved.startswith("/sdcard"):
        resolved = resolved[6:]  # strip /sdcard prefix
    if not resolved.startswith("/"):
        resolved = "/" + resolved

    url = _url(host, port, "/api/files/upload", {"path": resolved})
    with open(local_file, "rb") as f:
        file_data = f.read()
    req = urllib.request.Request(
        url, data=file_data,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            r = json.loads(resp.read().decode("utf-8"))
            if not r.get("ok"):
                raise SystemExit(f"Upload failed: {r}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Upload HTTP {e.code}")
    return resolved


def _run_lua_http(host, port, path, args_json=None, timeout_ms=0, poll_interval=1.5, max_wait=60):
    """POST /api/files/run then poll /api/files/run/<id> until done."""
    body = {"path": path}
    if timeout_ms is not None:
        body["timeout_ms"] = timeout_ms
    if args_json:
        body["args_json"] = args_json

    url = _url(host, port, "/api/files/run")
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            info = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"Run failed: HTTP {e.code} {body_text}")

    job_id = info.get("job_id")
    if not job_id:
        raise SystemExit(f"Failed to start: {info}")

    print(f"Job {job_id} started{', timeout_ms=' + str(timeout_ms) if timeout_ms else ''}")
    status_url = _url(host, port, f"/api/files/run/{job_id}")
    elapsed = 0.0

    while elapsed < max_wait:
        time.sleep(poll_interval)
        elapsed += poll_interval
        try:
            with urllib.request.urlopen(status_url, timeout=5) as resp:
                job = json.loads(resp.read().decode("utf-8"))
        except Exception:
            continue

        status = job.get("status", "running")
        runtime = float(job.get("runtime_s", 0))
        tail = job.get("tail", job.get("recent_log", ""))

        # Print live tail output
        if tail:
            for line in tail.split('\n'):
                line = line.strip()
                if line:
                    print(f"  {line}")

        if status in ("done", "failed", "timeout", "stopped"):
            if status == "done":
                print(f"  → completed in {runtime:.1f}s")
            elif status == "timeout":
                print(f"  → timed out after {runtime:.1f}s")
            elif status == "stopped":
                print(f"  → stopped after {runtime:.1f}s")
            else:
                error = job.get("error", "unknown error")
                print(f"  → failed: {error}")
            return job_id

        sys.stderr.write(f"\r  running... {runtime:.0f}s")
        sys.stderr.flush()

    sys.stderr.write("\n")
    print(f"  → still running (waited {max_wait}s), job_id={job_id}")
    return job_id


def cmd_run(args):
    """Upload and run a Lua script on the device over HTTP."""
    if args.no_upload:
        run_path = args.script if args.script.startswith("/") else "/" + args.script
    else:
        local = Path(args.script)
        if not local.is_file():
            raise SystemExit(f"Local script not found: {args.script}")
        remote_rel = f"/inbox/{local.name}"
        print(f"Uploading {args.script} → {remote_rel}")
        run_path = _upload_and_resolve(args.host, args.port, local, remote_rel)

    timeout_ms = args.timeout_ms if args.timeout_ms is not None else 60000
    _run_lua_http(args.host, args.port, run_path,
                  args_json=args.args_json,
                  timeout_ms=timeout_ms,
                  poll_interval=args.poll or 1.5,
                  max_wait=args.wait or 120)


def cmd_exec(args):
    """Execute a Lua one-liner on the device over HTTP."""
    code = args.code
    remote_rel = f"/inbox/__exec_{int(time.time())}.lua"
    print(f"Uploading inline script → {remote_rel}")
    url = _url(args.host, args.port, "/api/files/upload", {"path": remote_rel})
    data = code.encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            r = json.loads(resp.read().decode("utf-8"))
            if not r.get("ok"):
                raise SystemExit(f"Upload failed: {r}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Upload HTTP {e.code}")

    run_path = remote_rel  # relative path, backend resolves to /sdcard/...
    timeout_ms = args.timeout_ms or 30000
    _run_lua_http(args.host, args.port, run_path,
                  timeout_ms=timeout_ms,
                  poll_interval=args.poll or 1.0,
                  max_wait=args.wait or 60)


def cmd_stop(args):
    """Stop a running Lua job by job_id over HTTP."""
    job_id = args.job_id
    url = _url(args.host, args.port, f"/api/files/run/{job_id}/stop")
    req = urllib.request.Request(url, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
            info = json.loads(resp.read().decode("utf-8"))
            if info.get("ok") or info.get("status") == "stopped":
                print(f"Job {job_id} stopped")
            else:
                raise SystemExit(f"Stop failed: {info}")
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body_text}")


def cmd_jobs(args):
    """List all async Lua jobs over HTTP."""
    job_id = args.job_id
    if job_id:
        url = _url(args.host, args.port, f"/api/files/run/{job_id}")
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                job = json.loads(resp.read().decode("utf-8"))
                _print_job(job)
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")[:200]
            raise SystemExit(f"HTTP {e.code}: {body_text}")
        return

    # No job_id → list all via the list endpoint
    url = _url(args.host, args.port, "/api/files/run/list")
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")[:200]
        raise SystemExit(f"HTTP {e.code}: {body_text}")

    jobs = data.get("jobs", [])
    if not jobs:
        print("No running jobs")
        return
    for job in jobs:
        _print_job(job)


def _print_job(job):
    status = job.get("status", "?")
    icon = {"running": "▶", "done": "✓", "failed": "✗", "timeout": "⏱", "stopped": "■"}.get(status, "?")
    runtime = float(job.get("runtime_s", 0))
    print(f"  {icon} {job.get('job_id','?')}  {status:8s}  {runtime:.0f}s  {job.get('path','')}")
    summary = job.get("summary") or job.get("recent_log")
    if summary:
        print(f"         {summary[:120]}")


def cmd_shell(args):
    """Open interactive monitoring via serial (requires pyserial)."""
    try:
        import select
        import serial
    except ImportError:
        raise SystemExit("Shell mode requires: pip install pyserial")

    port = args.port
    if not port:
        # Try to auto-detect
        import glob
        candidates = glob.glob("/dev/cu.usbmodem*") + glob.glob("/dev/ttyUSB*")
        if not candidates:
            raise SystemExit("No serial port found. Specify with --port")
        port = candidates[0]
        print(f"Auto-detected port: {port}")

    baud = args.baud or 115200
    print(f"Connecting to {port} @ {baud}... (Ctrl+] to quit, Ctrl+T for menu)")

    s = serial.Serial(port, baud, timeout=0.1)
    try:
        while True:
            if s.in_waiting:
                data = s.read(s.in_waiting)
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if sys.stdin in select.select([sys.stdin], [], [], 0.05)[0]:
                line = sys.stdin.readline()
                if not line:
                    break
                s.write(line.encode())
    except KeyboardInterrupt:
        print("\nDisconnected.")
    finally:
        s.close()


def cmd_info(args):
    """Show device status and info."""
    data = _json_get(args.host, args.port, "/api/status")
    print(f"Device        : esp-claw")
    print(f"WiFi connected: {data.get('wifi_connected', False)}")
    print(f"IP            : {data.get('ip', 'N/A')}")
    print(f"AP active     : {data.get('ap_active', False)}")
    print(f"AP SSID       : {data.get('ap_ssid', 'N/A')}")
    print(f"Storage       : {data.get('storage_base_path', 'N/A')}")
    print(f"Mode          : {data.get('wifi_mode', 'N/A')}")


def main():
    parser = argparse.ArgumentParser(
        description="esp-claw-cli — ADB-style tool for ESP-Claw devices",
        prog="esp-claw-cli",
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Device hostname or IP (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"HTTP port (default: {DEFAULT_PORT})")
    parser.add_argument("--version", action="version", version=f"esp-claw-cli {VERSION}")

    sub = parser.add_subparsers(dest="command", title="commands")

    # push
    p_push = sub.add_parser("push", help="Upload a file to the device")
    p_push.add_argument("local", help="Local file path")
    p_push.add_argument("remote", help="Remote path on device (e.g. /inbox/file.txt)")

    # pull
    p_pull = sub.add_parser("pull", help="Download a file from the device")
    p_pull.add_argument("remote", help="Remote path on device (e.g. /sdcard/capture.jpg)")
    p_pull.add_argument("local", help="Local file path")

    # ls
    p_ls = sub.add_parser("ls", help="List files in a remote directory")
    p_ls.add_argument("path", nargs="?", default="/", help="Remote directory path (default: /)")

    # rm
    p_rm = sub.add_parser("rm", help="Delete a file or directory")
    p_rm.add_argument("path", help="Remote path")
    p_rm.add_argument("-r", "--recursive", action="store_true", help="Recursive delete for directories")

    # mkdir
    p_mkdir = sub.add_parser("mkdir", help="Create a directory on the device")
    p_mkdir.add_argument("path", help="Remote directory path")
    p_mkdir.add_argument("-p", "--parents", action="store_true", help="Create parent directories")

    # run
    p_run = sub.add_parser("run", help="Upload and run a Lua script on the device over HTTP")
    p_run.add_argument("script", help="Local Lua script path")
    p_run.add_argument("--no-upload", action="store_true", help="script is already a remote path")
    p_run.add_argument("--args-json", default=None, help="JSON arguments for the script")
    p_run.add_argument("--timeout-ms", type=int, default=None, help="Execution timeout in ms (default: 60000, 0 = no timeout)")
    p_run.add_argument("--poll", type=float, default=1.5, help="Polling interval in seconds")
    p_run.add_argument("--wait", type=int, default=120, help="Maximum wait time in seconds")

    # exec
    p_exec = sub.add_parser("exec", help="Upload and run a Lua one-liner over HTTP")
    p_exec.add_argument("code", help="Lua code to execute")
    p_exec.add_argument("--timeout-ms", type=int, default=30000, help="Execution timeout in ms")
    p_exec.add_argument("--poll", type=float, default=1.0, help="Polling interval in seconds")
    p_exec.add_argument("--wait", type=int, default=60, help="Maximum wait time in seconds")

    # stop
    p_stop = sub.add_parser("stop", help="Stop a running Lua job")
    p_stop.add_argument("job_id", help="Job ID to stop")

    # jobs
    p_jobs = sub.add_parser("jobs", help="List or inspect async Lua jobs")
    p_jobs.add_argument("job_id", nargs="?", default=None, help="Optional job ID to inspect")

    # shell
    p_shell = sub.add_parser("shell", help="Open serial console (requires pyserial)")
    p_shell.add_argument("--port", default=None, help="Serial port (auto-detect if omitted)")
    p_shell.add_argument("--baud", type=int, default=115200, help="Baud rate")

    # discover
    p_discover = sub.add_parser("discover", help="Discover ESP-Claw devices via mDNS")
    p_discover.add_argument("--host-suffix", default=None, help="Try hostname suffix (e.g. 8BA109 for esp-claw-8BA109.local)")

    # info
    sub.add_parser("info", help="Show device status")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    handlers = {
        "push": cmd_push,
        "pull": cmd_pull,
        "ls": cmd_ls,
        "rm": cmd_rm,
        "mkdir": cmd_mkdir,
        "run": cmd_run,
        "exec": cmd_exec,
        "stop": cmd_stop,
        "jobs": cmd_jobs,
        "shell": cmd_shell,
        "discover": cmd_discover,
        "info": cmd_info,
    }
    handler = handlers.get(args.command)
    if handler:
        handler(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
