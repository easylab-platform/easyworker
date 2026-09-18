// Command trustprobe checks that a worker image's TLS trust is configured for
// the egress sidecar: it runs a set of protocol commands THROUGH the worker
// API (so the worker's job-env allowlist is exercised, not just the image
// environment) and reports which ones succeed.
//
// Usage:
//
//	trustprobe -addr http://<pod-ip>:48080
//
// It is used to validate the easyworker preset images
// (easyworker/images): a preset must pass the probes with a pod spec that
// injects nothing beyond the egress sidecar.
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"

	"connectrpc.com/connect"
	workerv1 "github.com/easylab-platform/easyworker/gen/worker/v1"
	"github.com/easylab-platform/easyworker/gen/worker/v1/workerv1connect"
)

// Each probe names the binary it needs (so a missing toolchain is a SKIP, not
// a trust failure) and the command that must exit 0.
var probes = []struct{ name, need, cmd string }{
	{"node https", "node", `node -e "require('https').get('https://registry.npmjs.org/left-pad',r=>{console.log('status',r.statusCode);process.exit(r.statusCode===200?0:1)}).on('error',e=>{console.error('ERR',e.message);process.exit(1)})"`},
	{"npm view", "npm", `npm view left-pad version --no-audit --no-fund`},
	{"pip download", "pip", `pip download --no-deps --no-cache-dir -d /tmp/tp six >/dev/null && echo ok`},
	{"uv pip", "uv", `uv pip install --no-cache --target /tmp/uvt six >/dev/null 2>&1 && echo ok`},
	{"cargo search", "cargo", `cargo search anyhow >/dev/null && echo ok`},
	{"go get", "go", `d=$(mktemp -d) && cd "$d" && go mod init t >/dev/null 2>&1 && go get golang.org/x/text@v0.14.0 >/dev/null 2>&1 && echo ok`},
	{"gem fetch", "gem", `gem fetch thor --quiet >/dev/null && echo ok`},
	{"composer", "composer", `d=$(mktemp -d) && cd "$d" && COMPOSER_HOME=/tmp/tpch composer require monolog/monolog --no-interaction --no-progress --quiet >/dev/null 2>&1 && echo ok`},
	{"hex", "mix", `export MIX_HOME=/root/.mix HEX_HOME=/root/.hex; mix archive.install /opt/hex-archive/hex.ez --force >/dev/null 2>&1 || true; w=$(mktemp -d) && cd "$w" && printf 'defmodule P.MixProject do\n  use Mix.Project\n  def project, do: [app: :p, version: "0.1.0", elixir: "~> 1.16", deps: [{:jason, "1.4.4"}]]\n  def application, do: []\nend\n' > mix.exs && mix deps.get >/dev/null 2>&1 && echo ok`},
	{"dotnet", "dotnet", `dotnet nuget list source >/dev/null && echo ok`},
	{"dart pub", "dart", `dart pub cache add http --version 1.2.2 >/dev/null 2>&1 && echo ok`},
	{"java cacerts", "keytool", `keytool -list -cacerts -storepass changeit 2>/dev/null | grep -qi easylab && echo ok`},
	{"apk search", "apk", `apk search -q jq >/dev/null && echo ok`},
	{"apt update", "apt-get", `apt-get update -o Acquire::http::Proxy=http://127.0.0.1:80 >/dev/null 2>&1 && echo ok`},
	{"dnf search", "dnf", `dnf -q --refresh search jq >/dev/null 2>&1 && echo ok`},
	{"conda search", "conda", `conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main >/dev/null 2>&1; conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r >/dev/null 2>&1; conda search --override-channels -c defaults zlib >/dev/null 2>&1 && echo ok`},
}

func main() {
	addr := flag.String("addr", "", "worker base URL, e.g. http://10.0.0.1:48080")
	only := flag.String("only", "", "comma-separated probe names to run (default: all that apply)")
	flag.Parse()
	if *addr == "" {
		flag.Usage()
		os.Exit(2)
	}

	cli := workerv1connect.NewWorkerServiceClient(http.DefaultClient, *addr)
	want := map[string]bool{}
	for _, n := range strings.Split(*only, ",") {
		if n = strings.TrimSpace(n); n != "" {
			want[n] = true
		}
	}

	pass, fail := 0, 0
	for _, p := range probes {
		if len(want) > 0 && !want[p.name] {
			continue
		}
		cmd := p.cmd
		if p.need != "" {
			cmd = "command -v " + p.need + " >/dev/null 2>&1 || exit 127; " + cmd
		}
		out, code, err := run(cli, cmd)
		switch {
		case err != nil:
			fmt.Printf("ERR  %-14s %v\n", p.name, err)
			fail++
		case code == 127:
			fmt.Printf("SKIP %-14s (tool unavailable)\n", p.name)
		case code == 0:
			fmt.Printf("PASS %-14s %s\n", p.name, lastLine(out))
			pass++
		default:
			fmt.Printf("FAIL %-14s exit=%d %s\n", p.name, code, lastLine(out))
			fail++
		}
	}
	fmt.Printf("\n%d pass, %d fail\n", pass, fail)
	if fail > 0 {
		os.Exit(1)
	}
}

func run(cli workerv1connect.WorkerServiceClient, cmd string) (string, int, error) {
	res, err := cli.Execute(context.Background(), connect.NewRequest(&workerv1.ExecuteRequest{Command: cmd}))
	if err != nil {
		return "", -1, err
	}
	stream, err := cli.WatchJob(context.Background(), connect.NewRequest(&workerv1.WatchJobRequest{JobId: res.Msg.JobId}))
	if err != nil {
		return "", -1, err
	}
	var out strings.Builder
	code := -1
	for stream.Receive() {
		m := stream.Msg()
		out.WriteString(m.GetOutput())
		if d := m.GetDone(); d != nil {
			code = int(d.GetExitCode())
		}
	}
	return out.String(), code, stream.Err()
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) == 0 {
		return ""
	}
	return strings.TrimSpace(lines[len(lines)-1])
}
