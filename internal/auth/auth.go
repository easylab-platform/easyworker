// Package auth implements the worker's fail-closed access gate.
//
// A worker executes nothing until it holds a bearer token. Two ways to get one:
//
//   - PreAuthorized: the launcher supplies WORKER_TOKEN at boot (per-sandbox
//     unique). No enrollment happens; the claim face is never usable.
//   - Unclaimed: no WORKER_TOKEN — the worker mints a one-time code at boot,
//     prints it to stdout, and the FIRST caller presenting that code claims it
//     EXCLUSIVELY. On claim the worker installs a fresh token and permanently
//     closes the claim face (later claims → ErrAlreadyClaimed).
//
// The one-time code is created in memory, never stored on disk, and destroyed
// on claim. Restarting the worker returns it to Unclaimed with a new code.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Sentinel errors surfaced by Claim.
var (
	ErrAlreadyClaimed = errors.New("worker already claimed")
	ErrBadCode        = errors.New("invalid enrollment code")
	ErrRateLimited    = errors.New("too many failed claims; slow down")
)

// Gate is the worker's auth state machine. It is safe for concurrent use.
type Gate struct {
	mu sync.Mutex

	disabled  bool // WORKER_REQUIRE_AUTH=0 (dev only)
	bootID    string
	preauth   bool
	token     string
	code      string
	claimed   bool
	ownerID   string
	claimedAt time.Time

	// failed-claim rate limiting (per worker process).
	failures       int
	failureWindow  time.Time
	maxFailures    int
	failureLockout time.Duration
}

// Options configures a Gate.
type Options struct {
	// PreAuthorizedToken, when non-empty, installs the token immediately and
	// disables enrollment (managed-sandbox path).
	PreAuthorizedToken string
	// Disabled turns auth off entirely (WORKER_REQUIRE_AUTH=0). Dev only.
	Disabled bool
	// BootID identifies this worker process (surfaced by Status/Info).
	BootID string
}

// New builds the gate from Options. When not pre-authorized and not disabled it
// generates a one-time code; Code() returns it (empty after claim).
func New(opts Options) (*Gate, error) {
	g := &Gate{
		disabled:       opts.Disabled,
		bootID:         opts.BootID,
		maxFailures:    10,
		failureLockout: time.Minute,
	}
	if opts.Disabled {
		return g, nil
	}
	if opts.PreAuthorizedToken != "" {
		g.preauth = true
		g.token = opts.PreAuthorizedToken
		g.claimed = true
		return g, nil
	}
	code, err := randomHex(16)
	if err != nil {
		return nil, fmt.Errorf("mint enrollment code: %w", err)
	}
	g.code = code
	return g, nil
}

// Code returns the one-time enrollment code ("" when pre-authorized, disabled,
// or already claimed).
func (g *Gate) Code() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.code
}

// Disabled reports whether auth is turned off.
func (g *Gate) Disabled() bool { return g.disabled }

// Authorized reports whether the presented bearer token is accepted.
func (g *Gate) Authorized(bearer string) bool {
	if g.disabled {
		return true
	}
	g.mu.Lock()
	want := g.token
	g.mu.Unlock()
	if want == "" {
		return false
	}
	return constantEqual(want, bearer)
}

// Status is a snapshot of the enrollment state.
type Status struct {
	Claimed       bool
	NeedsCode     bool
	Preauthorized bool
	BootID        string
}

// Status returns the current enrollment state.
func (g *Gate) Status() Status {
	g.mu.Lock()
	defer g.mu.Unlock()
	return Status{
		Claimed:       g.disabled || g.claimed,
		NeedsCode:     !g.disabled && !g.claimed,
		Preauthorized: g.preauth,
		BootID:        g.bootID,
	}
}

// Claim consumes the one-time code and installs a worker-issued token. Exactly
// one caller can win per worker lifetime; every later call returns
// ErrAlreadyClaimed.
func (g *Gate) Claim(code, ownerID string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.disabled {
		return "", ErrAlreadyClaimed
	}
	if g.claimed {
		return "", ErrAlreadyClaimed
	}
	if !g.allowAttemptLocked() {
		return "", ErrRateLimited
	}
	if code == "" || subtle.ConstantTimeCompare([]byte(code), []byte(g.code)) != 1 {
		g.failures++
		return "", ErrBadCode
	}
	tok, err := randomHex(32)
	if err != nil {
		return "", fmt.Errorf("mint token: %w", err)
	}
	g.token = tok
	g.claimed = true
	g.ownerID = ownerID
	g.claimedAt = time.Now()
	g.code = "" // destroy the one-time code
	return tok, nil
}

// ErrReleaseForbidden is returned when release is not permitted (a
// pre-authorized worker or an invalid token).
var ErrReleaseForbidden = errors.New("worker release forbidden")

// Release revokes the current token and returns the worker to Unclaimed with a
// fresh one-time code. It requires the CURRENT bearer token, so only the
// present owner can release — after which any caller with the new code may
// claim it. Pre-authorized (managed) workers cannot be released.
func (g *Gate) Release(bearer, ownerID string) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.disabled || g.preauth || !g.claimed {
		return "", ErrReleaseForbidden
	}
	if !constantEqual(g.token, bearer) {
		return "", ErrReleaseForbidden
	}
	code, err := randomHex(16)
	if err != nil {
		return "", fmt.Errorf("mint code: %w", err)
	}
	g.token = ""
	g.claimed = false
	g.ownerID = ownerID
	g.claimedAt = time.Time{}
	g.code = code
	// Reset the failure budget so the new code starts clean.
	g.failures = 0
	return code, nil
}

// allowAttemptLocked enforces the failure rate limit.
func (g *Gate) allowAttemptLocked() bool {
	now := time.Now()
	if g.failed() && now.Sub(g.failureWindow) > g.failureLockout {
		g.failures = 0
	}
	if g.failures >= g.maxFailures {
		return false
	}
	if g.failures == 0 {
		g.failureWindow = now
	}
	return true
}

func (g *Gate) failed() bool { return g.failures >= g.maxFailures }

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func constantEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}
