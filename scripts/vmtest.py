#!/usr/bin/env python3
"""Deploy easyworker to a dockur VM over SSH and run the ewtest suite on it.

Usage: vmtest.py <macos|windows>
Reads dist/ binaries built by scripts/build-all.sh. Prints the remote test
output; exit code mirrors the remote ewtest exit code.
"""
import sys
import time

import paramiko

VMS = {
    "macos": dict(host="ssh-macos.temp.svc.cluster.local", worker="easyworker-darwin-amd64", test="ewtest-darwin-amd64"),
    "windows": dict(host="ssh-windows.temp.svc.cluster.local", worker="easyworker-windows-amd64.exe", test="ewtest-windows-amd64.exe"),
}
USER, PASS = "docker", "admin"


def run(c, cmd, timeout=120, quiet=False):
    if not quiet:
        print(f"  $ {cmd}")
    _, out, err = c.exec_command(cmd, timeout=timeout)
    o = out.read().decode(errors="replace")
    e = err.read().decode(errors="replace")
    rc = out.channel.recv_exit_status()
    if not quiet and (o.strip() or e.strip()):
        print("    " + (o + e).strip().replace("\n", "\n    ")[:4000])
    return rc, o, e


def main():
    which = sys.argv[1]
    vm = VMS[which]
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(vm["host"], port=80, username=USER, password=PASS, timeout=20)
    print(f"== connected {which} ({vm['host']}) ==")

    # stop any previous instance FIRST (Windows locks a running exe), then
    # upload fresh binaries, then start detached via Win32_Process Create.
    if which == "windows":
        run(c, "Stop-Process -Name easyworker-windows-amd64 -Force -ErrorAction SilentlyContinue", quiet=True)
        run(c, "Remove-Item -Recurse -Force C:\\Users\\docker\\ws -ErrorAction SilentlyContinue", quiet=True)
    else:
        run(c, "pkill -f easyworker-darwin || true", quiet=True)
        run(c, "rm -rf /Users/docker/ws && mkdir -p /Users/docker/ws", quiet=True)

    sftp = c.open_sftp()
    if which == "windows":
        home = "C:/Users/docker"
    else:
        home = "/Users/docker"
    for f in (vm["worker"], vm["test"]):
        print(f"  upload dist/{f} -> {home}/")
        sftp.put(f"dist/{f}", f"{home}/{f}")
    sftp.close()

    if which == "windows":
        run(c, "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments "
               "@{CommandLine='C:\\Users\\docker\\easyworker-windows-amd64.exe "
               "-workspace C:\\Users\\docker\\ws -db C:\\Users\\docker\\ws\\jobs.db'}")
    else:
        run(c, "chmod +x /Users/docker/easyworker-darwin-amd64 /Users/docker/ewtest-darwin-amd64", quiet=True)
        run(c, "cd /Users/docker && WORKER_WORKSPACE=/Users/docker/ws WORKER_DB=/Users/docker/ws/jobs.db "
               "nohup ./easyworker-darwin-amd64 > /Users/docker/worker.log 2>&1 & sleep 1; echo started")

    # wait for healthz
    for _ in range(30):
        if which == "windows":
            rc, o, _ = run(c, "curl.exe -s -o NUL -w \"%{http_code}\" http://127.0.0.1:8080/healthz", quiet=True)
        else:
            rc, o, _ = run(c, "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz", quiet=True)
        if o.strip() == "200":
            print("  worker healthy (:8080)")
            break
        time.sleep(1)
    else:
        print("  !! worker did not become healthy; log:")
        run(c, f"cat {home}/worker.log" if which != "windows" else f"type {home}\\worker.log")
        run(c, f"cat {home}/worker.err" if which != "windows" else f"type {home}\\worker.err")
        sys.exit(2)

    print(f"== ewtest on {which} ==")
    tcmd = f"{home}/{vm['test']}".replace("/", "\\") if which == "windows" else f"{home}/{vm['test']}"
    rc, o, e = run(c, tcmd, timeout=300)
    print(o)
    if e.strip():
        print("STDERR:", e)
    print(f"== {which}: ewtest exit={rc} ==")
    c.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
