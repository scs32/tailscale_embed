package tsembed

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
)

func TestIsTailnetIP(t *testing.T) {
	tests := []struct {
		host string
		want bool
	}{
		{"100.64.0.1", true},
		{"100.100.100.100", true},
		{"100.127.255.255", true},
		{"100.63.255.255", false}, // just below CGNAT
		{"100.128.0.0", false},    // just above CGNAT
		{"192.168.1.10", false},
		{"8.8.8.8", false},
		{"fd7a:115c:a1e0::1", true},
		{"fd7a:115c:a1e1::1", false},
		{"2606:4700::1", false},
		{"not-an-ip", false},
		{"example.com", false},
		{"", false},
	}
	for _, tt := range tests {
		if got := isTailnetIP(tt.host); got != tt.want {
			t.Errorf("isTailnetIP(%q) = %v, want %v", tt.host, got, tt.want)
		}
	}
}

func TestRoutesCover(t *testing.T) {
	routes := []netip.Prefix{
		netip.MustParsePrefix("192.168.64.0/24"),
		netip.MustParsePrefix("10.0.0.0/8"),
		netip.MustParsePrefix("0.0.0.0/0"), // exit node — must be ignored
		netip.MustParsePrefix("::/0"),      // exit node — must be ignored
	}
	tests := []struct {
		addr string
		want bool
	}{
		{"192.168.64.42", true},
		{"192.168.65.42", false},
		{"10.1.2.3", true},
		{"11.1.2.3", false}, // only covered by 0/0, which is ignored
		{"8.8.8.8", false},
		{"2606:4700::1", false}, // only covered by ::/0, which is ignored
	}
	for _, tt := range tests {
		if got := routesCover(netip.MustParseAddr(tt.addr), routes); got != tt.want {
			t.Errorf("routesCover(%s) = %v, want %v", tt.addr, got, tt.want)
		}
	}
	if routesCover(netip.MustParseAddr("8.8.8.8"), nil) {
		t.Error("routesCover with no routes should be false")
	}
}

func TestMatchNode(t *testing.T) {
	ips := []netip.Addr{
		netip.MustParseAddr("100.101.102.103"),
		netip.MustParseAddr("fd7a:115c:a1e0::1"),
	}
	const dnsName = "truenas.tail1234.ts.net." // control sends trailing dot
	const hostName = "TrueNAS"

	tests := []struct {
		host string
		want string
	}{
		{"truenas.tail1234.ts.net", "100.101.102.103:8080"}, // full FQDN
		{"Truenas.Tail1234.TS.NET", "100.101.102.103:8080"}, // case-insensitive
		{"truenas.tail1234.ts.net.", "100.101.102.103:8080"}, // trailing dot
		{"truenas", "100.101.102.103:8080"},                 // MagicDNS short name
		{"TrueNAS", "100.101.102.103:8080"},                 // bare hostname
		{"truenas2", ""},              // no partial-label match
		{"tail1234.ts.net", ""},       // suffix alone doesn't match
		{"other.tail1234.ts.net", ""}, // different node
		{"", ""},
	}
	for _, tt := range tests {
		if got := matchNode(tt.host, "8080", dnsName, hostName, ips); got != tt.want {
			t.Errorf("matchNode(%q) = %q, want %q", tt.host, got, tt.want)
		}
	}

	if got := matchNode("truenas", "80", dnsName, hostName, nil); got != "" {
		t.Errorf("matchNode with no IPs should return \"\", got %q", got)
	}
}

func TestClassifyUpError(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{
		{context.DeadlineExceeded, ErrCodeAuthTimeout},
		{fmt.Errorf("up: %w", context.DeadlineExceeded), ErrCodeAuthTimeout},
		{errors.New("backend error: invalid key: unable to validate API key"), ErrCodeAuthKeyInvalid},
		{errors.New("register request: key type cannot be used for node auth"), ErrCodeAuthKeyWrongType},
		{errors.New("i/o timeout"), ErrCodeAuthTimeout},
		{errors.New("something exploded"), ErrCodeStartFailed},
	}
	for _, tt := range tests {
		if got := classifyUpError(tt.err); got != tt.want {
			t.Errorf("classifyUpError(%v) = %q, want %q", tt.err, got, tt.want)
		}
	}
}

func TestCodedErrFormat(t *testing.T) {
	err := codedErr(ErrCodeAuthKeyInvalid, errors.New("boom"))
	const want = "tsembed:AUTH_KEY_INVALID: boom"
	if err.Error() != want {
		t.Errorf("codedErr = %q, want %q", err.Error(), want)
	}
}

// resolveTailnet must classify IP literals without a status lookup (the
// server isn't up in tests — a status call would just fail and return
// direct, which is what non-tailnet IPs expect anyway).
func TestResolveTailnetIPLiterals(t *testing.T) {
	ts := &Tailscale{server: nil}
	// Guard: these must not reach t.status()/t.server.
	tests := []struct {
		hostport string
		wantDest string
		wantVia  bool
	}{
		{"100.101.102.103:8080", "100.101.102.103:8080", true},
		{"[fd7a:115c:a1e0::1]:443", "[fd7a:115c:a1e0::1]:443", true},
		// Non-tailnet IP with accept-routes off: direct, no status lookup.
		{"192.168.1.5:80", "192.168.1.5:80", false},
		{"no-port-here", "no-port-here", false},
	}
	for _, tt := range tests {
		dest, via := ts.resolveTailnet(context.Background(), tt.hostport)
		if dest != tt.wantDest || via != tt.wantVia {
			t.Errorf("resolveTailnet(%q) = (%q, %v), want (%q, %v)",
				tt.hostport, dest, via, tt.wantDest, tt.wantVia)
		}
	}
}

// rebindMagicsock runs on every EnsureProxy (foreground/resume), including
// paths where the node was constructed but never started — it must be a
// quiet no-op there, not a panic. A started node can't be exercised in unit
// tests (needs a real control plane); the real suspend/resume behavior is
// verified on-device.
func TestRebindMagicsockNotStarted(t *testing.T) {
	// server present but never started: Sys() is nil.
	ts := NewTailscale(t.TempDir(), "", "test")
	ts.rebindMagicsock("test")
	// no server at all (mirrors other unit-test constructions).
	(&Tailscale{}).rebindMagicsock("test")
}

// RebindNetwork is driven by the native path monitor, which can fire at any
// point in the node's lifecycle — before start, after stop. It must be a
// quiet no-op on a non-running instance.
func TestRebindNetworkNotRunning(t *testing.T) {
	NewTailscale(t.TempDir(), "", "test").RebindNetwork()
	(&Tailscale{}).RebindNetwork()
}

func TestHealthNeedsRebind(t *testing.T) {
	tests := []struct {
		health []string
		want   bool
	}{
		{nil, false},
		{[]string{}, false},
		{[]string{"The MagicSock function ReceiveIPv4 is not running"}, true},
		{[]string{"The MagicSock function ReceiveIPv6 is not running"}, true},
		{[]string{"the magicsock function receiveipv4 is not running"}, true}, // case-insensitive
		{[]string{"router: some unrelated warning"}, false},
		{[]string{"not running"}, false}, // needs the magicsock half too
		{[]string{"unrelated", "The MagicSock function ReceiveIPv4 is not running"}, true},
	}
	for _, tt := range tests {
		if got := healthNeedsRebind(tt.health); got != tt.want {
			t.Errorf("healthNeedsRebind(%q) = %v, want %v", tt.health, got, tt.want)
		}
	}
}

// The watchdog must rate-limit: a warning that survives a rebind reappears in
// every fresh status (which backs every proxied dial), and that must not
// become a rebind storm.
func TestMaybeSelfHealRateLimit(t *testing.T) {
	ts := &Tailscale{} // no server: rebindMagicsock is a no-op, timing still recorded
	st := &ipnstate.Status{Health: []string{"The MagicSock function ReceiveIPv4 is not running"}}

	ts.maybeSelfHeal(st)
	first := ts.lastHeal
	if first.IsZero() {
		t.Fatal("first maybeSelfHeal should record a heal attempt")
	}
	ts.maybeSelfHeal(st)
	if ts.lastHeal != first {
		t.Error("second maybeSelfHeal within selfHealInterval should be suppressed")
	}
	ts.lastHeal = time.Now().Add(-selfHealInterval - time.Second)
	ts.maybeSelfHeal(st)
	if ts.lastHeal == first || ts.lastHeal.IsZero() {
		t.Error("maybeSelfHeal after selfHealInterval should rebind again")
	}

	healthy := &Tailscale{}
	healthy.maybeSelfHeal(&ipnstate.Status{})
	if !healthy.lastHeal.IsZero() {
		t.Error("maybeSelfHeal must not fire on a healthy status")
	}
	healthy.maybeSelfHeal(nil)
}

// EnsureProxy on a non-running instance must fail with NOT_RUNNING before
// touching magicsock or the listener.
func TestEnsureProxyNotRunning(t *testing.T) {
	ts := NewTailscale(t.TempDir(), "", "test")
	_, err := ts.EnsureProxy()
	if err == nil || !strings.Contains(err.Error(), ErrCodeNotRunning) {
		t.Errorf("EnsureProxy() err = %v, want tsembed:%s", err, ErrCodeNotRunning)
	}
}

// StatusJSON must report the identity even when the node is not running, so
// consumers can tell which identity a stopped instance belongs to.
func TestStatusJSONIdentityNotRunning(t *testing.T) {
	ts := &Tailscale{}
	got, err := ts.StatusJSON()
	if err != nil || got != `{"running":false}` {
		t.Errorf("StatusJSON() = (%q, %v), want ({\"running\":false}, nil)", got, err)
	}
	ts.SetIdentity("work")
	got, err = ts.StatusJSON()
	if err != nil || got != `{"running":false,"identity":"work"}` {
		t.Errorf("StatusJSON() = (%q, %v), want identity \"work\"", got, err)
	}
}
