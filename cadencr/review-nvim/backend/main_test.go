package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestProtocol(t *testing.T) {
	input := strings.NewReader(`{"type":"hello","protocol":1,"worktree":"/tmp","state_dir":"/tmp"}
malformed
{"type":"request","id":"first","method":"unknown","params":null}
{"type":"request","id":2,"method":"also-unknown","params":{}}
`)
	var output, log bytes.Buffer
	if err := serve(input, &output, &log); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected ready and two responses, got %q", output.String())
	}
	if lines[0] != `{"protocol":1,"type":"ready"}` {
		t.Fatalf("unexpected ready: %s", lines[0])
	}
	ids := map[string]bool{}
	for _, line := range lines[1:] {
		var response struct {
			Type   string          `json:"type"`
			ID     json.RawMessage `json:"id"`
			Error  fault           `json:"error"`
			Result json.RawMessage `json:"result"`
		}
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			t.Fatal(err)
		}
		if response.Type != "response" || response.Error.Code != "METHOD_NOT_FOUND" || len(response.Result) != 0 {
			t.Fatalf("unexpected response: %s", line)
		}
		ids[string(response.ID)] = true
	}
	if !ids[`"first"`] || !ids["2"] || !strings.Contains(log.String(), "malformed") {
		t.Fatal("request IDs or malformed-line handling changed")
	}
}

func TestBadHandshakeDoesNotWriteStdout(t *testing.T) {
	for _, input := range []string{
		"", "invalid\n", `{"type":"hello","protocol":2}` + "\n",
		`{"type":"request","protocol":1}` + "\n",
	} {
		var output, log bytes.Buffer
		if serve(strings.NewReader(input), &output, &log) == nil || output.Len() != 0 {
			t.Fatalf("accepted invalid handshake %q", input)
		}
	}
}
