// Command easyworker is the sandbox worker: a single static binary exposing
// the WorkerService Connect API. It runs (a) as a plain host process on
// windows/macos/linux (the forgejo-runner desktop model: register and dial
// out), and (b) as the worker injected into cluster sandboxes (WORKER_PORT
// pins the listen port there; the legacy default was 8080, sandboxes pin
// 48080).
//
// Every command executes through the builtin mvdan.cc/sh/v3 interpreter —
// no passthrough, no fallback — so bash semantics are identical everywhere.
package main

import (
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"connectrpc.com/connect"
	workerv1connect "github.com/easylab-platform/easyworker/gen/worker/v1/workerv1connect"
	"github.com/easylab-platform/easyworker/internal"
	"github.com/easylab-platform/easyworker/internal/filesvc"
	"github.com/easylab-platform/easyworker/internal/jobsvc"
	"github.com/easylab-platform/easyworker/internal/shellh"
)

func main() {
	addr := flag.String("addr", "", "listen address (default 0.0.0.0:${WORKER_PORT:-8080})")
	workspace := flag.String("workspace", "", "workspace root (default ${WORKER_WORKSPACE} or ~/EasyLab/workspace)")
	dbPath := flag.String("db", "", "job history sqlite path (default ${WORKER_DB} or ./easyworker.db)")
	flag.Parse()

	listen := *addr
	if listen == "" {
		port := envOr("WORKER_PORT", "8080")
		listen = "0.0.0.0:" + port
	}
	ws := *workspace
	if ws == "" {
		ws = envOr("WORKER_WORKSPACE", defaultWorkspace())
	}
	if err := os.MkdirAll(ws, 0o755); err != nil {
		log.Fatalf("workspace: %v", err)
	}
	db := *dbPath
	if db == "" {
		db = envOr("WORKER_DB", "easyworker.db")
	}

	// Job env: clean base + passthrough of proxy/registry knobs (ext-ops /
	// easylab inject these; the worker's own environ is NOT inherited — the
	// binary may hold platform tokens).
	env := jobEnv()

	runner := shellh.New(ws, env)
	store, err := jobsvc.OpenStore(db)
	if err != nil {
		log.Fatalf("open store %s: %v", db, err)
	}
	jobs := jobsvc.NewManager(runner, store, 10000, 1000)
	files := filesvc.New(ws)
	svc := internal.NewService(jobs, files, runner)

	mux := http.NewServeMux()
	mux.Handle(workerv1connect.NewWorkerServiceHandler(svc))
	// Plain health endpoint for probes (Connect has its own but a 200 GET /
	// is the cheapest readiness signal).
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	// Dual-stack h1 + h2c, mirroring easylab's listener shape so both Connect
	// over h1 (browsers/curl) and h2c-prior-knowledge clients work.
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{
		Addr:      listen,
		Handler:   mux,
		Protocols: protocols,
	}

	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("easyworker listening on %s (os=%s arch=%s workspace=%s shell=builtin)",
		listen, runtime.GOOS, runtime.GOARCH, ws)
	log.Fatal(server.Serve(ln))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// defaultWorkspace is per-platform (host mode): ~/EasyLab/workspace.
// In cluster sandboxes easylab sets WORKER_WORKSPACE=/workspace.
func defaultWorkspace() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, "EasyLab", "workspace")
}

// jobEnv builds the base environment for interpreted jobs: proxy + registry
// knobs only (explicitly allowlisted). Everything else is dropped.
func jobEnv() []string {
	var out []string
	pass := []string{
		"HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
		"NO_PROXY", "no_proxy",
		"NPM_CONFIG_REGISTRY", "PIP_INDEX_URL", "GOPROXY", "GOSUMDB",
		"CARGO_REGISTRIES_CRATES_IO_INDEX",
		"PATH", // toolchains need PATH; the host PATH is acceptable (no secrets)
		"HOME", "TMPDIR", "USER",
	}
	for _, k := range pass {
		if v, ok := os.LookupEnv(k); ok {
			out = append(out, k+"="+v)
		}
	}
	// Windows: ensure SystemRoot etc are present or the loader fails.
	if runtime.GOOS == "windows" {
		for _, k := range []string{"SystemRoot", "SYSTEMROOT", "windir", "TEMP", "USERPROFILE", "APPDATA"} {
			if v, ok := os.LookupEnv(k); ok && !containsKey(out, k) {
				out = append(out, k+"="+v)
			}
		}
	}
	if runtime.GOOS != "windows" && !containsKey(out, "PATH") {
		out = append(out, "PATH="+defaultUnixPath())
	}
	return out
}

func containsKey(env []string, key string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			return true
		}
	}
	return false
}

// defaultUnixPath: inside minimal containers PATH may be unset in the worker's
// own environ; give the common toolchain locations.
func defaultUnixPath() string {
	return strings.Join([]string{
		"/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin",
		"/sbin", "/bin", "/root/.cargo/bin", "/root/go/bin",
	}, ":")
}

var _ = connect.NewError // keep import when flag set shrinks
