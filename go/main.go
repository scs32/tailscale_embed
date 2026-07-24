package tsembed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// Stable error codes carried in error strings as "tsembed:CODE: …" so they
// survive the gomobile→NSError→FlutterError trip intact. The native side
// parses the prefix into a structured error code; message text is for humans.
const (
	ErrCodeAuthTimeout      = "AUTH_TIMEOUT"       // control plane unreachable / Up() deadline
	ErrCodeAuthKeyInvalid   = "AUTH_KEY_INVALID"   // key invalid, expired, or already used
	ErrCodeAuthKeyWrongType = "AUTH_KEY_WRONG_TYPE" // API token / OAuth secret, not a node auth key
	ErrCodeStartFailed      = "START_FAILED"        // any other tsnet startup failure
	ErrCodeProxyBindFailed  = "PROXY_BIND_FAILED"   // couldn't bind the local proxy listener
	ErrCodeNotRunning       = "NOT_RUNNING"         // operation requires a running node
)

func codedErr(code string, err error) error {
	return fmt.Errorf("tsembed:%s: %w", code, err)
}

// classifyUpError maps a tsnet Up() failure to a stable error code. The
// classification happens here, at the source, where the full error chain is
// still available (substring matching after gomobile flattening is fragile).
func classifyUpError(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return ErrCodeAuthTimeout
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "cannot be used for node auth"):
		return ErrCodeAuthKeyWrongType
	case strings.Contains(msg, "invalid key"):
		return ErrCodeAuthKeyInvalid
	case strings.Contains(msg, "deadline") || strings.Contains(msg, "timeout"):
		return ErrCodeAuthTimeout
	default:
		return ErrCodeStartFailed
	}
}

// statusCacheTTL bounds how stale routing decisions may be. resolveTailnet
// runs on EVERY proxied dial (a browser fires dozens concurrently), so
// Status() must not be an IPC round-trip each time.
const statusCacheTTL = 3 * time.Second

// selfHealInterval rate-limits watchdog-triggered heal attempts. A heal
// that fixes the receive path clears the health warning within one status
// refresh; one that doesn't shouldn't be retried in a tight loop on every
// proxied dial.
const selfHealInterval = 30 * time.Second

// selfHealRestartInterval rate-limits the watchdog's escalation to a full
// tsnet server restart. A restart that worked clears the warning well within
// this window; one that didn't shouldn't restart-loop the node.
const selfHealRestartInterval = 2 * time.Minute

// Tailscale wraps tsnet.Server and provides an HTTP proxy for routing traffic.
type Tailscale struct {
	server    *tsnet.Server
	proxy     *http.Server
	httpClient *http.Client // shared transport for non-CONNECT requests
	listener  net.Listener
	proxyPort int
	mu        sync.Mutex
	running   bool
	stateDir  string
	identity  string

	upTimeout    time.Duration
	acceptRoutes bool

	// Retained so the watchdog can rebuild the tsnet.Server from scratch —
	// a dead magicsock receive goroutine is only respawned by a full
	// device bind cycle, which tsnet exposes solely as Close + new server.
	hostname  string
	authKey   string
	ephemeral bool

	stMu sync.Mutex
	st   *ipnstate.Status
	stAt time.Time

	healMu       sync.Mutex
	lastHeal     time.Time
	lastRestart  time.Time
	healAttempts int

	restartMu sync.Mutex   // serializes watchdog restarts
	srvMu     sync.RWMutex // guards the server pointer against a mid-dial swap

	// Test seams; nil means the real rebindMagicsock / restartServer.
	rebindFn  func(reason string)
	restartFn func(reason string)
}

// NewTailscale creates a new Tailscale instance with the given state
// directory, auth key, and tailnet hostname for the embedded node.
func NewTailscale(stateDir, authKey, hostname string) *Tailscale {
	if hostname == "" {
		hostname = "tailscale-embed"
	}
	// Set environment variables that tsnet needs on iOS where os.Executable() fails
	os.Setenv("HOME", stateDir)
	os.Setenv("TS_LOGS_DIR", stateDir)

	t := &Tailscale{
		stateDir:     stateDir,
		upTimeout:    45 * time.Second,
		acceptRoutes: true,
		hostname:     hostname,
		authKey:      authKey,
	}
	t.server = t.newServer()
	return t
}

// newServer builds a tsnet.Server from the retained config. Used at
// construction and by the watchdog's full restart (a fresh Server is the only
// public path to a wireguard bind cycle; a Closed one can't be reused).
func (t *Tailscale) newServer() *tsnet.Server {
	return &tsnet.Server{
		Dir:       t.stateDir,
		Hostname:  t.hostname,
		AuthKey:   t.authKey,
		Ephemeral: t.ephemeral,
		Logf: func(format string, args ...any) {
			log.Printf("[tsnet] "+format, args...)
		},
	}
}

// srv returns the current tsnet server. The watchdog's full restart swaps
// the pointer while dials and status reads are in flight; they must see
// either the old (closed, errors cleanly) or the new server, never a torn
// read.
func (t *Tailscale) srv() *tsnet.Server {
	t.srvMu.RLock()
	defer t.srvMu.RUnlock()
	return t.server
}

// setSrv swaps the server pointer. Callers hold t.mu.
func (t *Tailscale) setSrv(s *tsnet.Server) {
	t.srvMu.Lock()
	t.server = s
	t.srvMu.Unlock()
}

// SetEphemeral marks the node ephemeral (deregisters when it disconnects).
// Call before StartProxy.
func (t *Tailscale) SetEphemeral(v bool) {
	t.ephemeral = v
	t.server.Ephemeral = v
}

// SetIdentity records the logical identity name this instance's state dir
// belongs to, so StatusJSON can report which identity is active. The name is
// purely informational here — the native layer owns the identity→path
// mapping. Call before StartProxy.
func (t *Tailscale) SetIdentity(name string) {
	t.identity = name
}

// SetUpTimeoutSeconds overrides how long StartProxy waits for the node to
// authenticate and come up (default 45s). Call before StartProxy.
func (t *Tailscale) SetUpTimeoutSeconds(secs int) {
	if secs > 0 {
		t.upTimeout = time.Duration(secs) * time.Second
	}
}

// SetAcceptRoutes controls whether destinations inside peer-advertised
// subnet routes are dialed through the tailnet (default true — always
// correct; at worst a same-LAN destination hairpins through its subnet
// router). Call before StartProxy.
func (t *Tailscale) SetAcceptRoutes(v bool) {
	t.acceptRoutes = v
}

// StartProxy starts the tsnet server and HTTP proxy, returning the proxy port.
func (t *Tailscale) StartProxy() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.running {
		return t.proxyPort, nil
	}

	// Start tsnet and block until the node is authenticated and running,
	// so auth-key failures surface to the caller instead of silently
	// leaving the node in NeedsLogin.
	ctx, cancel := context.WithTimeout(context.Background(), t.upTimeout)
	defer cancel()
	status, err := t.server.Up(ctx)
	if err != nil {
		t.server.Close()
		return 0, codedErr(classifyUpError(err), fmt.Errorf("failed to start tsnet: %w", err))
	}
	log.Printf("[tsnet] up: %s (%v)", status.Self.HostName, status.TailscaleIPs)

	// tsnet defaults RouteAll (accept-routes) to false; enable it so the
	// embedded netstack routes peer-advertised subnets. This only affects
	// the in-app node — no OS routing tables are touched.
	if t.acceptRoutes {
		t.applyRouteAll(ctx, t.server)
	}

	// Create listener on random port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.server.Close()
		return 0, codedErr(ErrCodeProxyBindFailed, fmt.Errorf("failed to create listener: %w", err))
	}
	t.listener = listener
	t.proxyPort = listener.Addr().(*net.TCPAddr).Port

	// One shared transport for all plain-HTTP proxying, so connections are
	// reused across requests instead of building a Transport per request.
	t.httpClient = &http.Client{
		Transport: &http.Transport{
			DialContext:         t.dial,
			MaxIdleConns:        64,
			MaxIdleConnsPerHost: 8,
			IdleConnTimeout:     90 * time.Second,
		},
		// The proxy must relay redirects to the client, not follow them.
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	// Create HTTP proxy server
	t.proxy = &http.Server{
		Handler:      http.HandlerFunc(t.handleProxy),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}

	// Start proxy in background
	go func() {
		err := t.proxy.Serve(listener)
		log.Printf("[proxy] server exited: %v", err)
	}()
	log.Printf("[proxy] listening on 127.0.0.1:%d", t.proxyPort)

	t.running = true
	return t.proxyPort, nil
}

// EnsureProxy verifies the local proxy listener is still accepting
// connections (iOS reclaims sockets during app suspension) and rebinds it on
// a fresh port if it died. It also rebinds magicsock's UDP sockets, which iOS
// parks independently of the proxy listener. Returns the current (possibly
// new) proxy port.
func (t *Tailscale) EnsureProxy() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return 0, codedErr(ErrCodeNotRunning, errors.New("tailscale is not running"))
	}

	// The proxy listener surviving suspension says nothing about magicsock's
	// UDP sockets — without a rebind the node can come back with dead receive
	// loops ("the MagicSock function ReceiveIPv4 is not running" health
	// warning) and silently fall back to DERP relay. Rebind unconditionally,
	// as the official iOS client does on wake.
	t.rebindMagicsock("tsembed-resume")

	// Health check: can we reach our own listener?
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", t.proxyPort), 2*time.Second)
	if err == nil {
		conn.Close()
		return t.proxyPort, nil
	}
	log.Printf("[proxy] listener on port %d is dead (%v), rebinding", t.proxyPort, err)

	if t.listener != nil {
		t.listener.Close()
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, codedErr(ErrCodeProxyBindFailed, fmt.Errorf("failed to rebind listener: %w", err))
	}
	t.listener = listener
	t.proxyPort = listener.Addr().(*net.TCPAddr).Port

	go func() {
		err := t.proxy.Serve(listener)
		log.Printf("[proxy] server exited: %v", err)
	}()
	log.Printf("[proxy] rebound on 127.0.0.1:%d", t.proxyPort)
	return t.proxyPort, nil
}

// RebindNetwork re-binds magicsock's UDP sockets and re-runs STUN discovery.
// The native layer calls this on every network path change (NWPathMonitor):
// iOS invalidates UDP sockets on WiFi↔cellular handoffs and radio power
// transitions that can happen while the app is foregrounded, where no resume
// event — and thus no EnsureProxy — ever fires. The official iOS client
// pairs its wake rebind with exactly this path-change rebind. Quiet no-op
// when the node isn't running.
func (t *Tailscale) RebindNetwork() {
	if !t.IsRunning() {
		return
	}
	t.rebindMagicsock("tsembed-pathchange")
}

// rebindMagicsock closes and re-binds magicsock's UDP sockets and re-runs
// STUN endpoint discovery (Rebind's doc requires the follow-up ReSTUN). It
// then drops the cached status so the next StatusJSON re-reads health instead
// of serving the pre-rebind warning. Safe to call on an instance that never
// started (tsnet populates Sys() only during start).
func (t *Tailscale) rebindMagicsock(reason string) {
	s := t.srv()
	if s == nil {
		return
	}
	sys := s.Sys()
	if sys == nil {
		return
	}
	ms, ok := sys.MagicSock.GetOK()
	if !ok {
		return
	}
	ms.Rebind()
	ms.ReSTUN(reason)
	t.stMu.Lock()
	t.st = nil
	t.stMu.Unlock()
	log.Printf("[tsnet] magicsock rebound (%s)", reason)
}

// healthNeedsRebind reports whether any health warning says magicsock's
// receive paths are down ("the MagicSock function ReceiveIPv4 is not
// running", tailscale#10976 class) — the state a rebind fixes.
func healthNeedsRebind(health []string) bool {
	for _, w := range health {
		lw := strings.ToLower(w)
		if strings.Contains(lw, "magicsock") && strings.Contains(lw, "not running") {
			return true
		}
	}
	return false
}

// applyRouteAll enables accept-routes on a running server (see StartProxy).
func (t *Tailscale) applyRouteAll(ctx context.Context, s *tsnet.Server) {
	lc, err := s.LocalClient()
	if err != nil {
		return
	}
	if _, err := lc.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:       ipn.Prefs{RouteAll: true},
		RouteAllSet: true,
	}); err != nil {
		log.Printf("[tsnet] enabling accept-routes failed: %v", err)
	}
}

// restartServer tears down the tsnet server and builds a fresh one on the
// same state directory. This is the watchdog's escalation: the "MagicSock
// function ReceiveIPv4 is not running" warning means wireguard-go's receive
// goroutine has permanently exited (health only flags a func with zero calls
// that isn't blocked mid-call), and nothing short of a full wireguard bind
// cycle respawns it — Rebind() merely swaps the socket under a loop that is
// no longer running (tailscale#10976 class). tsnet exposes that cycle only
// as Close + new Server. The proxy listener and port are untouched, so
// consumers never observe the restart; while the node is down, status()
// errors and proxied dials fall back to the direct path, so non-tailnet
// traffic keeps flowing.
func (t *Tailscale) restartServer(reason string) {
	if !t.restartMu.TryLock() {
		return // a restart is already in flight
	}
	defer t.restartMu.Unlock()

	t.mu.Lock()
	if !t.running {
		t.mu.Unlock()
		return
	}
	old := t.server
	t.mu.Unlock()

	log.Printf("[tsnet] restarting node (%s)", reason)
	old.Close()

	ns := t.newServer()
	ctx, cancel := context.WithTimeout(context.Background(), t.upTimeout)
	defer cancel()
	if _, err := ns.Up(ctx); err != nil {
		// Up only watches an already-Started backend: on error the server
		// keeps running and converges once the network allows. Keep it —
		// the old server's receive path is dead either way, so there is
		// nothing better to fall back to.
		log.Printf("[tsnet] restart (%s): Up not confirmed: %v (keeping server; it will converge)", reason, err)
	} else if t.acceptRoutes {
		t.applyRouteAll(ctx, ns)
	}

	t.mu.Lock()
	if !t.running {
		// StopProxy ran while we were coming up; don't resurrect the node.
		t.mu.Unlock()
		ns.Close()
		return
	}
	t.setSrv(ns)
	t.mu.Unlock()

	t.stMu.Lock()
	t.st = nil
	t.stMu.Unlock()
	log.Printf("[tsnet] node restarted (%s)", reason)
}

// maybeSelfHeal is the watchdog half of the recovery story: whenever a
// freshly fetched status carries the dead-receive-path warning, heal
// (rate-limited by selfHealInterval). Recovery is thereby observable-state-
// driven, catching whatever the resume hook and the native path monitor miss
// — status() runs on every proxied dial and every StatusJSON, so a degraded
// node heals as soon as anything looks at it.
//
// Healing escalates: the first attempt is a cheap magicsock rebind; if the
// warning survives into a second attempt (≥selfHealInterval later, i.e. the
// rebind demonstrably didn't fix it — field evidence and source both say it
// can't once the receive goroutine has exited), do the full server restart,
// the only recovery ever observed to clear this state. Restarts are further
// rate-limited by selfHealRestartInterval. A healthy status resets the
// ladder. Heals run async: status() backs dials and must not block on
// socket churn (and it still holds stMu, which both heal paths take to drop
// the cache).
func (t *Tailscale) maybeSelfHeal(st *ipnstate.Status) {
	if st == nil {
		return
	}
	if !healthNeedsRebind(st.Health) {
		t.healMu.Lock()
		t.healAttempts = 0
		t.healMu.Unlock()
		return
	}
	t.healMu.Lock()
	if time.Since(t.lastHeal) < selfHealInterval {
		t.healMu.Unlock()
		return
	}
	t.lastHeal = time.Now()
	t.healAttempts++
	attempt := t.healAttempts
	escalate := attempt >= 2 && time.Since(t.lastRestart) >= selfHealRestartInterval
	if escalate {
		t.lastRestart = time.Now()
	}
	rebind, restart := t.rebindFn, t.restartFn
	t.healMu.Unlock()

	if rebind == nil {
		rebind = t.rebindMagicsock
	}
	if restart == nil {
		restart = t.restartServer
	}
	if escalate {
		log.Printf("[tsnet] magicsock receive path still dead after rebind (attempt %d); escalating to full node restart", attempt)
		go restart("tsembed-selfheal-restart")
	} else {
		log.Printf("[tsnet] health reports dead magicsock receive path; self-healing (attempt %d)", attempt)
		go rebind("tsembed-selfheal")
	}
}

// StopProxy stops the HTTP proxy and tsnet server.
func (t *Tailscale) StopProxy() {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return
	}

	if t.proxy != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		t.proxy.Shutdown(ctx)
	}

	if t.httpClient != nil {
		t.httpClient.CloseIdleConnections()
	}

	if t.listener != nil {
		t.listener.Close()
	}

	if t.server != nil {
		t.server.Close()
	}

	t.stMu.Lock()
	t.st = nil
	t.stMu.Unlock()

	t.running = false
	t.proxyPort = 0
}

// IsRunning returns whether the proxy is currently running.
func (t *Tailscale) IsRunning() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.running
}

// GetPort returns the current proxy port, or 0 if not running.
func (t *Tailscale) GetPort() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.proxyPort
}

// StatusJSON returns a JSON summary of the node's state for consumer UIs:
//
//	{
//	  "running": bool, "identity": "default", "proxyPort": int,
//	  "backendState": "Running",
//	  "health": ["…"],
//	  "tailnet": {"name": "…", "magicDNSSuffix": "…"},
//	  "self": {"hostName": "…", "dnsName": "…", "ips": ["100.x.y.z"], "online": bool},
//	  "peers": [{"hostName": …, "dnsName": …, "ips": […], "online": bool, "routes": ["192.168.1.0/24"]}]
//	}
//
// When the node is not running it returns {"running": false} (plus the
// identity, when one was set).
func (t *Tailscale) StatusJSON() (string, error) {
	if !t.IsRunning() {
		b, err := json.Marshal(struct {
			Running  bool   `json:"running"`
			Identity string `json:"identity,omitempty"`
		}{false, t.identity})
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	st, err := t.status(ctx)
	if err != nil {
		return "", codedErr(ErrCodeNotRunning, fmt.Errorf("status unavailable: %w", err))
	}

	type node struct {
		HostName string   `json:"hostName"`
		DNSName  string   `json:"dnsName"`
		IPs      []string `json:"ips"`
		Online   bool     `json:"online"`
		Routes   []string `json:"routes,omitempty"`
	}
	out := struct {
		Running      bool     `json:"running"`
		Identity     string   `json:"identity,omitempty"`
		ProxyPort    int      `json:"proxyPort"`
		BackendState string   `json:"backendState"`
		Health       []string `json:"health,omitempty"`
		Tailnet      *struct {
			Name           string `json:"name"`
			MagicDNSSuffix string `json:"magicDNSSuffix"`
		} `json:"tailnet,omitempty"`
		Self  *node  `json:"self,omitempty"`
		Peers []node `json:"peers"`
	}{
		Running:      true,
		Identity:     t.identity,
		ProxyPort:    t.GetPort(),
		BackendState: st.BackendState,
		Health:       st.Health,
		Peers:        []node{},
	}
	if st.CurrentTailnet != nil {
		out.Tailnet = &struct {
			Name           string `json:"name"`
			MagicDNSSuffix string `json:"magicDNSSuffix"`
		}{st.CurrentTailnet.Name, st.CurrentTailnet.MagicDNSSuffix}
	}
	toNode := func(hostName, dnsName string, ips []netip.Addr, online bool, routes []netip.Prefix) node {
		n := node{
			HostName: hostName,
			DNSName:  strings.TrimSuffix(dnsName, "."),
			IPs:      []string{},
			Online:   online,
		}
		for _, ip := range ips {
			n.IPs = append(n.IPs, ip.String())
		}
		for _, r := range routes {
			n.Routes = append(n.Routes, r.String())
		}
		return n
	}
	if st.Self != nil {
		n := toNode(st.Self.HostName, st.Self.DNSName, st.Self.TailscaleIPs, st.Self.Online, nil)
		out.Self = &n
	}
	for _, p := range st.Peer {
		var routes []netip.Prefix
		if p.PrimaryRoutes != nil {
			routes = p.PrimaryRoutes.AsSlice()
		}
		out.Peers = append(out.Peers, toNode(p.HostName, p.DNSName, p.TailscaleIPs, p.Online, routes))
	}

	b, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// status returns the node status, cached for statusCacheTTL — it backs every
// proxied dial, so it must not hit the LocalClient each time.
func (t *Tailscale) status(ctx context.Context) (*ipnstate.Status, error) {
	t.stMu.Lock()
	defer t.stMu.Unlock()
	if t.st != nil && time.Since(t.stAt) < statusCacheTTL {
		return t.st, nil
	}
	lc, err := t.srv().LocalClient()
	if err != nil {
		return nil, err
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return nil, err
	}
	t.st, t.stAt = st, time.Now()
	t.maybeSelfHeal(st)
	return st, nil
}

// tailnetCGNAT / tailnetULA are the address ranges Tailscale assigns to
// nodes; destinations inside them must be dialed through tsnet, anything
// else is dialed directly (the proxy carries ALL traffic when a webview is
// pointed at it, not just tailnet traffic).
var (
	tailnetCGNAT = netip.MustParsePrefix("100.64.0.0/10")
	tailnetULA   = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

func isTailnetIP(host string) bool {
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return tailnetCGNAT.Contains(addr) || tailnetULA.Contains(addr.Unmap())
}

// routesCover reports whether addr falls inside any advertised subnet route.
// Default routes (exit nodes) are ignored — sending ALL traffic through an
// exit node is a policy decision, not something to infer from a 0/0 route.
func routesCover(addr netip.Addr, routes []netip.Prefix) bool {
	addr = addr.Unmap()
	for _, r := range routes {
		if r.Bits() == 0 {
			continue
		}
		if r.Contains(addr) {
			return true
		}
	}
	return false
}

// matchNode returns "ip:port" when host names this node — by full DNS name,
// MagicDNS short name (first label), or bare hostname — or "" otherwise.
func matchNode(host, port, dnsName, hostName string, ips []netip.Addr) string {
	if len(ips) == 0 {
		return ""
	}
	want := strings.TrimSuffix(strings.ToLower(host), ".")
	dns := strings.TrimSuffix(strings.ToLower(dnsName), ".")
	if dns == want || strings.HasPrefix(dns, want+".") || strings.EqualFold(hostName, host) {
		return net.JoinHostPort(ips[0].String(), port)
	}
	return ""
}

// subnetRoutes returns all peer-advertised subnet routes from the cached
// status (empty when accept-routes is disabled).
func (t *Tailscale) subnetRoutes(ctx context.Context) []netip.Prefix {
	if !t.acceptRoutes {
		return nil
	}
	st, err := t.status(ctx)
	if err != nil {
		return nil
	}
	var routes []netip.Prefix
	for _, p := range st.Peer {
		if p.PrimaryRoutes != nil {
			routes = append(routes, p.PrimaryRoutes.AsSlice()...)
		}
	}
	return routes
}

// resolveTailnet turns a "host:port" into an "ip:port" that tsnet can dial
// and reports whether the destination belongs to the tailnet.
// The device has no system-wide MagicDNS (that's the whole point of the
// in-app node), so *.ts.net FQDNs and MagicDNS short names won't resolve via
// the OS. We resolve them ourselves from the node's own peer list. IP
// literals inside the tailnet ranges — or inside a peer-advertised subnet
// route — dial via tsnet; everything else via the system dialer.
func (t *Tailscale) resolveTailnet(ctx context.Context, hostport string) (string, bool) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return hostport, false // no port; leave as-is
	}
	if addr, err := netip.ParseAddr(strings.Trim(host, "[]")); err == nil {
		if isTailnetIP(addr.String()) {
			return hostport, true
		}
		return hostport, routesCover(addr, t.subnetRoutes(ctx))
	}

	st, err := t.status(ctx)
	if err != nil {
		return hostport, false
	}
	if st.Self != nil {
		if r := matchNode(host, port, st.Self.DNSName, st.Self.HostName, st.Self.TailscaleIPs); r != "" {
			return r, true
		}
	}
	for _, p := range st.Peer {
		if r := matchNode(host, port, p.DNSName, p.HostName, p.TailscaleIPs); r != "" {
			log.Printf("[proxy] resolved %s -> %s", host, r)
			return r, true
		}
	}
	return hostport, false
}

// dial resolves the destination and dials it through tsnet when it belongs
// to the tailnet, or directly via the system dialer otherwise (system DNS
// resolves non-tailnet names).
func (t *Tailscale) dial(ctx context.Context, network, hostport string) (net.Conn, error) {
	dest, viaTailnet := t.resolveTailnet(ctx, hostport)
	if viaTailnet {
		return t.srv().Dial(ctx, network, dest)
	}
	var d net.Dialer
	return d.DialContext(ctx, network, dest)
}

// handleProxy handles HTTP CONNECT requests for proxying through Tailscale.
func (t *Tailscale) handleProxy(w http.ResponseWriter, r *http.Request) {
	log.Printf("[proxy] %s %s (host=%s)", r.Method, r.URL, r.Host)
	if r.Method == http.MethodConnect {
		t.handleConnect(w, r)
	} else {
		t.handleHTTP(w, r)
	}
}

// handleConnect handles HTTPS CONNECT tunneling.
func (t *Tailscale) handleConnect(w http.ResponseWriter, r *http.Request) {
	// Dial the destination — through Tailscale for tailnet hosts (resolving
	// MagicDNS names from the peer list; no system-wide MagicDNS on this
	// device), directly for everything else.
	destConn, err := t.dial(r.Context(), "tcp", r.Host)
	if err != nil {
		log.Printf("[proxy] CONNECT dial %s failed: %v", r.Host, err)
		http.Error(w, fmt.Sprintf("failed to dial: %v", err), http.StatusBadGateway)
		return
	}
	log.Printf("[proxy] CONNECT dial %s ok", r.Host)
	defer destConn.Close()

	// Hijack the client connection
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}

	clientConn, _, err := hijacker.Hijack()
	if err != nil {
		http.Error(w, fmt.Sprintf("hijack failed: %v", err), http.StatusInternalServerError)
		return
	}
	defer clientConn.Close()

	// Send 200 Connection Established
	clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	// Bidirectional copy
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		io.Copy(destConn, clientConn)
	}()

	go func() {
		defer wg.Done()
		io.Copy(clientConn, destConn)
	}()

	wg.Wait()
}

// handleHTTP handles regular HTTP requests (non-CONNECT).
func (t *Tailscale) handleHTTP(w http.ResponseWriter, r *http.Request) {
	// Create a new request to the destination
	outReq := r.Clone(r.Context())
	outReq.RequestURI = ""

	// Dial through tsnet for tailnet hosts, directly otherwise. The original
	// Host header is left intact so the destination still sees its own name.
	resp, err := t.httpClient.Do(outReq)
	if err != nil {
		log.Printf("[proxy] HTTP %s %s failed: %v", outReq.Method, outReq.URL, err)
		http.Error(w, fmt.Sprintf("request failed: %v", err), http.StatusBadGateway)
		return
	}
	log.Printf("[proxy] HTTP %s %s -> %d", outReq.Method, outReq.URL, resp.StatusCode)
	defer resp.Body.Close()

	// Copy response headers
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)

	// Copy response body
	io.Copy(w, resp.Body)
}

// main is empty as this is a library for gomobile.
func main() {}
