package server

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/relay"
)

// A minimal in-memory SOCKS5 proxy. No requests leave the computer.
// Captures authenticated SOCKS usernames, then rejects CONNECT before any
// remote network connection is possible.
func isolationSOCKSListener(t *testing.T) (string, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	identities := make(chan string, 8)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(8 * time.Second))
				var greeting [3]byte
				if _, err := io.ReadFull(c, greeting[:]); err != nil || greeting != [3]byte{5, 1, 2} {
					return
				}
				if _, err := c.Write([]byte{5, 2}); err != nil {
					return
				}
				var auth [2]byte
				if _, err := io.ReadFull(c, auth[:]); err != nil || auth[0] != 1 {
					return
				}
				username := make([]byte, int(auth[1]))
				if _, err := io.ReadFull(c, username); err != nil {
					return
				}
				var passLen [1]byte
				if _, err := io.ReadFull(c, passLen[:]); err != nil {
					return
				}
				if _, err := io.CopyN(io.Discard, c, int64(passLen[0])); err != nil {
					return
				}
				if _, err := c.Write([]byte{1, 0}); err != nil {
					return
				}
				var connect [4]byte
				if _, err := io.ReadFull(c, connect[:]); err != nil || connect != [4]byte{5, 1, 0, 3} {
					return
				}
				var hostLen [1]byte
				if _, err := io.ReadFull(c, hostLen[:]); err != nil {
					return
				}
				if _, err := io.CopyN(io.Discard, c, int64(hostLen[0])+2); err != nil {
					return
				}
				identities <- string(username)
				// Deliberately fail the connection before HTTPS is attempted.
				_, _ = c.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
			}(conn)
		}
	}()
	return "tor://" + listener.Addr().String(), identities
}

func TestAnyoneInferenceIdentityReachesSOCKS(t *testing.T) {
	endpoint, identities := isolationSOCKSListener(t)
	client, err := relay.NewClient(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer client.CloseIdleConnections()

	var calls atomic.Int32
	b := &fakeBackend{complete: func(ctx context.Context, _ json.RawMessage) (*http.Response, error) {
		calls.Add(1)
		// This must dial the in-memory SOCKS5 proxy. In a real zkAPI client,
		// Complete uses the same ctx for its provider inference request.
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://no-network.example.invalid/", nil)
		if err != nil {
			t.Error(err)
		} else if resp, err := client.Do(req); err == nil {
			resp.Body.Close()
			t.Error("mock SOCKS proxy unexpectedly permitted external HTTPS")
		}
		return &http.Response{
			StatusCode: 200,
			Header:     http.Header{"Content-Type": {"application/json"}},
			Body:       io.NopCloser(strings.NewReader(`{"choices":[{"message":{"role":"assistant","content":"ok"}}]}`)),
		}, nil
	}}
	api, err := New(b, testKey, 2)
	if err != nil {
		t.Fatal(err)
	}
	api.RequireAPIKey = true
	api.RequireIsolation = true

	requestBody := `{"model":"test/model","messages":[{"role":"user","content":"hello"}],"stream":false}`
	idA := strings.Repeat("a", 64)
	idB := strings.Repeat("b", 64)
	ids := []string{idA, idB, idA}
	for i, id := range ids {
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(requestBody))
		req.Header.Set("Authorization", "Bearer "+testKey)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Anyone-Isolation", id)
		rsp := httptest.NewRecorder()
		api.ServeHTTP(rsp, req)
		if rsp.Code != http.StatusOK {
			t.Fatalf("request %d: status=%d body=%s", i, rsp.Code, rsp.Body.String())
		}
		select {
		case seen := <-identities:
			if seen != id {
				t.Fatalf("request %d: SOCKS auth identity %q != expected %q", i, seen, id)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("request %d: no authenticated SOCKS5 connection observed", i)
		}
	}
	if got := calls.Load(); got != 3 {
		t.Fatalf("backend called %d times; wanted 3", got)
	}
}

func TestAnyoneIsolationRejectsMissingInvalidAndUnauthenticated(t *testing.T) {
	b := &fakeBackend{complete: func(context.Context, json.RawMessage) (*http.Response, error) {
		t.Fatal("invalid request reached inference backend")
		return nil, nil
	}}
	api, err := New(b, testKey, 2)
	if err != nil {
		t.Fatal(err)
	}
	api.RequireAPIKey = true
	api.RequireIsolation = true
	body := `{"model":"test/model","messages":[{"role":"user","content":"hello"}]}`
	cases := []struct {
		name, auth string
		ids        []string
		status     int
	}{
		{"missing", testKey, nil, 400},
		{"short", testKey, []string{"abc"}, 400},
		{"uppercase", testKey, []string{strings.Repeat("A", 64)}, 400},
		{"not-hex", testKey, []string{strings.Repeat("z", 64)}, 400},
		{"repeated", testKey, []string{strings.Repeat("a", 64), strings.Repeat("b", 64)}, 400},
		{"not-authenticated", "wrong-key", []string{strings.Repeat("a", 64)}, 401},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+tc.auth)
			for _, id := range tc.ids {
				req.Header.Add("X-Anyone-Isolation", id)
			}
			rsp := httptest.NewRecorder()
			api.ServeHTTP(rsp, req)
			if rsp.Code != tc.status {
				t.Fatalf("status=%d expected=%d body=%s", rsp.Code, tc.status, rsp.Body.String())
			}
		})
	}
	if got := b.calls.Load(); got != 0 {
		t.Fatalf("blocked calls reached backend %d times", got)
	}
}
