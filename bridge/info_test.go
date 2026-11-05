package main

import (
	"testing"

	"github.com/polymorfa/hypermeow/types"
)

func TestPhoneNumber(t *testing.T) {
	for user, want := range map[string]string{
		"436601234567": "+43 660 1234567",
		"15551234567":  "+1 555 1234567",
		"38591234567":  "+385 912 34567",
		"123":          "",
	} {
		if got := phoneNumber(types.NewJID(user, types.DefaultUserServer)); got != want {
			t.Errorf("%s: %q, want %q", user, got, want)
		}
	}
}
