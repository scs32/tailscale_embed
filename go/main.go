package tsembed

import (
	"context"
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

	"tailscale.com/tsnet"
)

// Tailscale wraps tsnet.Server and provides an HTTP proxy for routing traffic.
type Tailscale struct {
	server    *tsnet.Server
	proxy     *http.Server
	listener  net.Listener
	proxyPort int
	mu        sync.Mutex
	running   bool
	stateDir  string
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

	return &Tailscale{
		stateDir: stateDir,
		server: &tsnet.Server{
			Dir:       stateDir,
			Hostname:  hostname,
			AuthKey:   authKey,
			Ephemeral: false,
			Logf: func(format string, args ...any) {
				log.Printf("[tsnet] "+format, args...)
			},
		},
	}
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
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	status, err := t.server.Up(ctx)
	if err != nil {
		t.server.Close()
		return 0, fmt.Errorf("failed to start tsnet: %w", err)
	}
	log.Printf("[tsnet] up: %s (%v)", status.Self.HostName, status.TailscaleIPs)

	// Create listener on random port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.server.Close()
		return 0, fmt.Errorf("failed to create listener: %w", err)
	}
	t.listener = listener
	t.proxyPort = listener.Addr().(*net.TCPAddr).Port

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
// a fresh port if it died. Returns the current (possibly new) proxy port.
func (t *Tailscale) EnsureProxy() (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !t.running {
		return 0, fmt.Errorf("tailscale is not running")
	}

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
		return 0, fmt.Errorf("failed to rebind listener: %w", err)
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

	if t.listener != nil {
		t.listener.Close()
	}

	if t.server != nil {
		t.server.Close()
	}

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

// resolveTailnet turns a "host:port" into an "ip:port" that tsnet can dial
// and reports whether the destination belongs to the tailnet.
// The device has no system-wide MagicDNS (that's the whole point of the
// in-app node), so *.ts.net FQDNs and MagicDNS short names won't resolve via
// the OS. We resolve them ourselves from the node's own peer list. IP
// literals and non-tailnet names pass through unchanged and are dialed
// directly via the system dialer.
func (t *Tailscale) resolveTailnet(ctx context.Context, hostport string) (string, bool) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		return hostport, false // no port; leave as-is
	}
	if net.ParseIP(host) != nil {
		return hostport, isTailnetIP(host) // already an IP
	}

	lc, err := t.server.LocalClient()
	if err != nil {
		return hostport, false
	}
	st, err := lc.Status(ctx)
	if err != nil {
		return hostport, false
	}

	want := strings.TrimSuffix(strings.ToLower(host), ".")
	match := func(dnsName, hostName string, ips []netip.Addr) string {
		dns := strings.TrimSuffix(strings.ToLower(dnsName), ".")
		// Full FQDN match, MagicDNS short-name match (first label), or
		// bare hostname match.
		if (dns == want || strings.HasPrefix(dns, want+".") ||
			strings.EqualFold(hostName, host)) && len(ips) > 0 {
			return net.JoinHostPort(ips[0].String(), port)
		}
		return ""
	}
	if st.Self != nil {
		if r := match(st.Self.DNSName, st.Self.HostName, st.Self.TailscaleIPs); r != "" {
			return r, true
		}
	}
	for _, p := range st.Peer {
		if r := match(p.DNSName, p.HostName, p.TailscaleIPs); r != "" {
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
		return t.server.Dial(ctx, network, dest)
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
	httpClient := &http.Client{
		Transport: &http.Transport{
			DialContext: t.dial,
		},
	}
	resp, err := httpClient.Do(outReq)
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
