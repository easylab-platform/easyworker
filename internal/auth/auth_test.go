package auth

import (
	"errors"
	"testing"
)

func TestUnclaimedMintsCodeAndRejectsUntilClaimed(t *testing.T) {
	g, err := New(Options{BootID: "b1"})
	if err != nil {
		t.Fatal(err)
	}
	if g.Code() == "" {
		t.Fatal("unclaimed gate should mint a code")
	}
	st := g.Status()
	if !st.NeedsCode || st.Claimed || st.Preauthorized {
		t.Fatalf("status = %+v", st)
	}
	if g.Authorized("anything") {
		t.Fatal("unclaimed worker must reject all tokens")
	}
}

func TestClaimOnceExclusive(t *testing.T) {
	g, _ := New(Options{BootID: "b1"})
	code := g.Code()

	tok, err := g.Claim(code, "owner-a")
	if err != nil {
		t.Fatalf("first claim: %v", err)
	}
	if tok == "" {
		t.Fatal("claim returned empty token")
	}
	if g.Code() != "" {
		t.Fatal("code must be destroyed after claim")
	}
	if !g.Authorized(tok) {
		t.Fatal("issued token must be accepted")
	}
	if g.Authorized(code) {
		t.Fatal("the one-time code is not a bearer token")
	}

	// Second claim — even with the same (now consumed) code — loses.
	if _, err := g.Claim(code, "owner-b"); !errors.Is(err, ErrAlreadyClaimed) {
		t.Fatalf("second claim err = %v, want ErrAlreadyClaimed", err)
	}
	if g.Status().NeedsCode {
		t.Fatal("claimed worker must not report NeedsCode")
	}
}

func TestWrongCodeRejected(t *testing.T) {
	g, _ := New(Options{})
	if _, err := g.Claim("not-the-code", "o"); !errors.Is(err, ErrBadCode) {
		t.Fatalf("err = %v, want ErrBadCode", err)
	}
	if g.Status().Claimed {
		t.Fatal("wrong code must not claim")
	}
}

func TestClaimRateLimited(t *testing.T) {
	g, _ := New(Options{})
	for i := 0; i < g.maxFailures; i++ {
		_, _ = g.Claim("wrong", "o")
	}
	if _, err := g.Claim(g.Code(), "o"); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("err = %v, want ErrRateLimited", err)
	}
}

func TestPreauthorized(t *testing.T) {
	g, _ := New(Options{PreAuthorizedToken: "fixed-token", BootID: "b2"})
	st := g.Status()
	if !st.Claimed || !st.Preauthorized || st.NeedsCode {
		t.Fatalf("status = %+v", st)
	}
	if g.Code() != "" {
		t.Fatal("preauthorized worker must not mint a code")
	}
	if !g.Authorized("fixed-token") {
		t.Fatal("preauthorized token must be accepted")
	}
	if g.Authorized("other") {
		t.Fatal("wrong token must be rejected")
	}
	if _, err := g.Claim("x", "o"); !errors.Is(err, ErrAlreadyClaimed) {
		t.Fatalf("preauthorized claim err = %v", err)
	}
}

func TestDisabled(t *testing.T) {
	g, _ := New(Options{Disabled: true})
	if !g.Authorized("") || !g.Status().Claimed {
		t.Fatal("disabled gate must authorize everyone")
	}
}

func TestTokensAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		c, _ := randomHex(16)
		if seen[c] {
			t.Fatalf("duplicate code %s", c)
		}
		seen[c] = true
	}
}

func TestReleaseThenReclaim(t *testing.T) {
	g, _ := New(Options{BootID: "b"})
	tok, _ := g.Claim(g.Code(), "owner-a")

	// Wrong bearer cannot release.
	if _, err := g.Release("wrong", "x"); !errors.Is(err, ErrReleaseForbidden) {
		t.Fatalf("bad release err = %v", err)
	}
	// Present owner releases → fresh code, back to Unclaimed.
	code, err := g.Release(tok, "owner-a")
	if err != nil || code == "" {
		t.Fatalf("release: code=%q err=%v", code, err)
	}
	if g.Authorized(tok) {
		t.Fatal("revoked token must not be accepted")
	}
	if !g.Status().NeedsCode {
		t.Fatal("released worker must be claimable again")
	}
	// Another service can now claim with the new code.
	tok2, err := g.Claim(code, "owner-b")
	if err != nil || tok2 == "" {
		t.Fatalf("reclaim: %v", err)
	}
	if !g.Authorized(tok2) {
		t.Fatal("new token must be accepted")
	}
}

func TestReleaseForbiddenForPreauthorized(t *testing.T) {
	g, _ := New(Options{PreAuthorizedToken: "fixed"})
	if _, err := g.Release("fixed", "x"); !errors.Is(err, ErrReleaseForbidden) {
		t.Fatalf("err = %v, want ErrReleaseForbidden", err)
	}
}
