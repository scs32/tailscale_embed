package tsembed

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
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
		{"truenas.tail1234.ts.net", "100.101.102.103:8080"},  // full FQDN
		{"Truenas.Tail1234.TS.NET", "100.101.102.103:8080"},  // case-insensitive
		{"truenas.tail1234.ts.net.", "100.101.102.103:8080"}, // trailing dot
		{"truenas", "100.101.102.103:8080"},                  // MagicDNS short name
		{"TrueNAS", "100.101.102.103:8080"},                  // bare hostname
		{"truenas2", ""},                                     // no partial-label match
		{"tail1234.ts.net", ""},                              // suffix alone doesn't match
		{"other.tail1234.ts.net", ""},                        // different node
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
		// A dead DERP-receive func is a relay problem, NOT a UDP-socket
		// failure — a rebind won't fix it, so it must not trigger one.
		{[]string{"The MagicSock function ReceiveDERP is not running"}, false},
		{[]string{"The MagicSock function ReceiveDERP is not running",
			"The MagicSock function ReceiveIPv4 is not running"}, true}, // IPv4 still counts
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

// The watchdog is rebind-ONLY: it must never escalate to a full node restart,
// no matter how long the warning persists. A restart's ~45s down window is a
// hard tailnet outage, worse than the benign relay-degradation the ReceiveIPv4
// warning represents (v0.3.3 shipped the outage; v0.3.5 removes it). The
// warning clearing via rebind/naturally is the intended path; restarts must
// stay at 0. A healthy status resets the attempt counter.
func TestMaybeSelfHealRebindOnlyNeverRestarts(t *testing.T) {
	rebinds := make(chan string, 16)
	restarts := make(chan string, 16)
	ts := &Tailscale{
		rebindFn:  func(r string) { rebinds <- r },
		restartFn: func(r string) { restarts <- r }, // must NEVER fire
	}
	sick := &ipnstate.Status{Health: []string{"The MagicSock function ReceiveIPv4 is not running."}}

	expectRebind := func(step string) {
		t.Helper()
		select {
		case <-rebinds:
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: expected a rebind, none fired", step)
		}
	}
	expectQuiet := func(step string) {
		t.Helper()
		select {
		case r := <-rebinds:
			t.Fatalf("%s: unexpected rebind %q", step, r)
		case r := <-restarts:
			t.Fatalf("%s: unexpected restart %q", step, r)
		case <-time.After(50 * time.Millisecond):
		}
	}

	ts.maybeSelfHeal(sick) // attempt 1 → rebind
	expectRebind("attempt 1")

	ts.maybeSelfHeal(sick) // within selfHealInterval → suppressed
	expectQuiet("rate-limited")

	// Persist the warning across many heal windows — every one must rebind,
	// none may ever restart.
	for i := 2; i <= 6; i++ {
		ts.healMu.Lock()
		ts.lastHeal = time.Now().Add(-selfHealInterval - time.Second)
		ts.healMu.Unlock()
		ts.maybeSelfHeal(sick)
		expectRebind(fmt.Sprintf("attempt %d", i))
	}
	select {
	case r := <-restarts:
		t.Fatalf("watchdog must never restart, got %q", r)
	default:
	}

	ts.maybeSelfHeal(&ipnstate.Status{}) // healthy → counter resets
	ts.healMu.Lock()
	if ts.healAttempts != 0 {
		t.Errorf("healthy status should reset healAttempts, got %d", ts.healAttempts)
	}
	ts.healMu.Unlock()
}

// restartServer must be a quiet no-op when the node isn't running (watchdog
// racing a StopProxy), and safe on a zero-value instance.
func TestRestartServerNotRunning(t *testing.T) {
	ts := NewTailscale(t.TempDir(), "", "test-host")
	ts.restartServer("test")
	(&Tailscale{}).restartServer("test")
}

// Recovery telemetry is the whole point of this build: it must count only real
// rebinds/restarts, carry the last reason + timestamp, reflect the passed-in
// health for needsRebind, and serialize zero timestamps as empty (omitempty).
func TestRecoveryTelemetry(t *testing.T) {
	ts := &Tailscale{}

	snap := ts.recovery(nil)
	if snap.NeedsRebind || snap.Rebinds != 0 || snap.Restarts != 0 || snap.HealAttempts != 0 {
		t.Fatalf("zero-value recovery should be empty, got %+v", snap)
	}
	if snap.LastRebindAt != "" || snap.LastRestartAt != "" {
		t.Errorf("zero timestamps must serialize empty, got %+v", snap)
	}

	ts.recordRebind("tsembed-resume")
	ts.recordRebind("tsembed-pathchange")
	ts.recordRestart("tsembed-selfheal-restart")
	ts.healMu.Lock()
	ts.healAttempts = 3
	ts.healMu.Unlock()

	snap = ts.recovery([]string{"The MagicSock function ReceiveIPv4 is not running"})
	if !snap.NeedsRebind {
		t.Error("needsRebind should reflect the passed-in health")
	}
	if snap.Rebinds != 2 || snap.LastRebindReason != "tsembed-pathchange" {
		t.Errorf("rebind telemetry wrong: %+v", snap)
	}
	if snap.Restarts != 1 || snap.LastRestartReason != "tsembed-selfheal-restart" {
		t.Errorf("restart telemetry wrong: %+v", snap)
	}
	if snap.HealAttempts != 3 {
		t.Errorf("healAttempts = %d, want 3", snap.HealAttempts)
	}
	if snap.LastRebindAt == "" || snap.LastRestartAt == "" {
		t.Error("timestamps should be set after record*")
	}
}

// closeTunnels must force every registered hijacked tunnel closed (so its
// relay goroutines unblock), be safe to call twice, and leave a nil map that
// unregisterTunnel can still be called against without panicking.
func TestCloseTunnels(t *testing.T) {
	ts := &Tailscale{}

	// unregister before any register (nil map) must not panic.
	ts.unregisterTunnel(&connPair{})

	// A fresh proxy lifetime; capture its generation like StartProxy does.
	genA := ts.openTunnels()

	c1, c1peer := net.Pipe()
	d1, d1peer := net.Pipe()
	defer c1peer.Close()
	defer d1peer.Close()
	p := &connPair{client: c1, dest: d1}
	if !ts.registerTunnel(p, genA) {
		t.Fatal("registerTunnel on an open registry should return true")
	}

	ts.tunMu.Lock()
	n := len(ts.tunnels)
	ts.tunMu.Unlock()
	if n != 1 {
		t.Fatalf("registerTunnel: len(tunnels) = %d, want 1", n)
	}

	ts.closeTunnels()

	// Both conns must now be closed: a Read returns an error promptly.
	c1.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := c1.Read(make([]byte, 1)); err == nil {
		t.Error("closeTunnels did not close the client conn")
	}
	if ts.tunnels != nil {
		t.Error("closeTunnels should nil the map")
	}

	// A tunnel that raced past the sweep (registers AFTER closeTunnels, before
	// any restart) must be rejected AND not resurrect the map.
	c2, c2peer := net.Pipe()
	d2, d2peer := net.Pipe()
	defer c2peer.Close()
	defer d2peer.Close()
	late := &connPair{client: c2, dest: d2}
	if ts.registerTunnel(late, genA) {
		t.Error("registerTunnel after closeTunnels should return false")
	}
	if ts.tunnels != nil {
		t.Error("a rejected register must not resurrect the map")
	}

	// openTunnels re-arms the registry for a NEW proxy lifetime (genB != genA).
	genB := ts.openTunnels()
	if genB == genA {
		t.Fatal("openTunnels must bump the generation")
	}
	// A straggler handler from lifetime A (descheduled across the whole
	// stop→start) must NOT join lifetime B's registry — stale generation.
	if ts.registerTunnel(&connPair{client: c2, dest: d2}, genA) {
		t.Error("a stale-generation register after restart must be rejected")
	}
	if ts.tunnels != nil {
		t.Error("a stale-generation register must not resurrect the map")
	}
	// A handler from lifetime B registers fine.
	c3, c3peer := net.Pipe()
	d3, d3peer := net.Pipe()
	defer c3peer.Close()
	defer d3peer.Close()
	if !ts.registerTunnel(&connPair{client: c3, dest: d3}, genB) {
		t.Error("registerTunnel with the current generation should return true")
	}

	// Idempotent + safe after nil-ing.
	ts.closeTunnels()
	ts.unregisterTunnel(p)
}

// halfClose must signal a one-way EOF on conns that support CloseWrite and be
// a no-op (not a panic) on those that don't.
func TestHalfClose(t *testing.T) {
	c, peer := net.Pipe()
	defer c.Close()
	defer peer.Close()
	// net.Pipe conns don't implement CloseWrite — must not panic.
	halfClose(c)

	// A TCP conn does implement CloseWrite: after halfClose the peer reads EOF.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan error, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, err = conn.Read(make([]byte, 1))
		done <- err // want io.EOF once the client half-closes
	}()
	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	halfClose(client)
	if err := <-done; err != io.EOF {
		t.Errorf("after halfClose, peer Read err = %v, want EOF", err)
	}
}

// removeHopHeaders must strip the standard hop-by-hop set AND any header named
// in the Connection header, while leaving end-to-end headers intact.
func TestRemoveHopHeaders(t *testing.T) {
	h := http.Header{}
	h.Set("Connection", "close, X-Custom-Hop")
	h.Set("Keep-Alive", "timeout=5")
	h.Set("Proxy-Connection", "keep-alive")
	h.Set("Transfer-Encoding", "chunked")
	h.Set("Upgrade", "websocket")
	h.Set("X-Custom-Hop", "drop-me") // named in Connection
	h.Set("Content-Type", "video/mp4")
	h.Set("X-Keep", "keep-me")

	removeHopHeaders(h)

	for _, k := range []string{"Connection", "Keep-Alive", "Proxy-Connection",
		"Transfer-Encoding", "Upgrade", "X-Custom-Hop"} {
		if h.Get(k) != "" {
			t.Errorf("hop header %q not stripped", k)
		}
	}
	if h.Get("Content-Type") != "video/mp4" || h.Get("X-Keep") != "keep-me" {
		t.Errorf("end-to-end headers must survive: %v", h)
	}
}

// newServer must carry the retained config so the watchdog's rebuilt server
// is identical to the original (same state dir → same node identity).
func TestNewServerCarriesConfig(t *testing.T) {
	ts := NewTailscale("/tmp/x", "tskey-auth-test", "host-a")
	ts.SetEphemeral(true)
	s := ts.newServer()
	if s.Dir != "/tmp/x" || s.Hostname != "host-a" || s.AuthKey != "tskey-auth-test" || !s.Ephemeral {
		t.Errorf("newServer dropped config: %+v", s)
	}
}
