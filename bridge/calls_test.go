package main

import "testing"

func TestULawRoundTrip(t *testing.T) {
	for _, s := range []int16{0, 1, -1, 100, -100, 1000, -1000, 8000, -8000, 32000, -32000} {
		got := ulawDecode(ulawEncode(s))
		diff := int(got) - int(s)
		if diff < 0 {
			diff = -diff
		}
		limit := int(s) / 16
		if limit < 0 {
			limit = -limit
		}
		if diff > limit+8 {
			t.Errorf("%d -> %d (off by %d)", s, got, diff)
		}
	}
}
