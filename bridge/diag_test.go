package main

import (
	"errors"
	"testing"
)

func TestErrCodeDropsAddresses(t *testing.T) {
	for in, want := range map[string]string{
		"read tcp 10.0.0.5:25567->84.12.3.4:51234: read: connection reset by peer": "connection reset by peer",
		"local error: tls: bad record MAC":                                         "bad record MAC",
		"unexpected EOF":                                                           "unexpected EOF",
	} {
		if got := errCode(errors.New(in)); got != want {
			t.Errorf("errCode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCountingLogNoAddress(t *testing.T) {
	errCounts.take()
	countingLog{}.Write([]byte("2026/11/08 http: TLS handshake error from 84.12.3.4:51234: tls: client offered only unsupported versions: []\n"))
	got := errCounts.take()
	if len(got) != 1 || got["tls handshake client offered only unsupported versions: []"] != 1 {
		t.Fatalf("got %v", got)
	}
}

func TestCountingLogReadError(t *testing.T) {
	errCounts.take()
	countingLog{}.Write([]byte("2026/11/09 http: TLS handshake error from 84.12.3.4:51234: read tcp 10.0.0.5:25567->84.12.3.4:51234: read: connection reset by peer\n"))
	got := errCounts.take()
	if got["tls handshake connection reset by peer"] != 1 {
		t.Fatalf("got %v", got)
	}
}
