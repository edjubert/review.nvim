package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
)

type hello struct {
	Type      string `json:"type"`
	Protocol  int    `json:"protocol"`
	Worktree  string `json:"worktree"`
	StateDir  string `json:"state_dir"`
	FeatureID int64  `json:"feature_id"`
}

type request struct {
	Type   string          `json:"type"`
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type fault struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (f *fault) Error() string { return f.Message }

func fail(code, message string) error { return &fault{code, message} }

func serve(input io.Reader, output, log io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 4*1024*1024)
	var cx hello
	if !scanner.Scan() || json.Unmarshal(scanner.Bytes(), &cx) != nil ||
		cx.Type != "hello" || cx.Protocol != 1 || cx.Worktree == "" || cx.StateDir == "" {
		return fmt.Errorf("expected a protocol-1 hello with worktree and state_dir")
	}
	encoder := json.NewEncoder(output)
	if err := encoder.Encode(map[string]any{"type": "ready", "protocol": 1}); err != nil {
		return err
	}
	terminal := &session{context: cx}
	defer terminal.close()
	var writeMu sync.Mutex
	var pending sync.WaitGroup
	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil || req.Type != "request" || len(req.ID) == 0 {
			fmt.Fprintln(log, "Ignoring malformed backend request.")
			continue
		}
		// Reads and keyboard input must not wait for a slow Neovim startup.
		pending.Add(1)
		go func() {
			defer pending.Done()
			result, err := terminal.handle(req.Method, req.Params)
			answer := map[string]any{"type": "response", "id": req.ID}
			if err != nil {
				problem, ok := err.(*fault)
				if !ok {
					problem = &fault{"BACKEND_ERROR", err.Error()}
				}
				answer["error"] = problem
			} else {
				answer["result"] = result
			}
			writeMu.Lock()
			defer writeMu.Unlock()
			if err := encoder.Encode(answer); err != nil {
				fmt.Fprintln(log, "Unable to write backend response:", err)
			}
		}()
	}
	terminal.close()
	pending.Wait()
	return scanner.Err()
}

func main() {
	if err := serve(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
