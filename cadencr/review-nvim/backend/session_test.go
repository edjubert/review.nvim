package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// A native fake Neovim keeps process/PTY tests offline and cannot post a review.
func TestMain(m *testing.M) {
	if os.Getenv("REVIEW_TEST_CHILD") == "1" {
		cwd, _ := os.Getwd()
		data, _ := json.Marshal(map[string]any{
			"args": os.Args[1:], "url": os.Getenv("REVIEW_NVIM_URL"),
			"runtime": os.Getenv("REVIEW_NVIM_RUNTIME"), "cwd": cwd,
		})
		fmt.Println("CHILD:" + string(data))
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			fmt.Println("INPUT:" + scanner.Text())
			if scanner.Text() == "exit" {
				os.Exit(0)
			}
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fixture(t *testing.T) (*session, string) {
	t.Helper()
	root := t.TempDir()
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	runtimePath := filepath.Join(root, "dist", "runtime", "lua", "review")
	if err := os.MkdirAll(runtimePath, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runtimePath, "init.lua"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	for _, file := range []string{"bootstrap.lua", "start.lua"} {
		if err := os.WriteFile(filepath.Join(root, "dist", "runtime", file), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(old); err != nil {
			t.Error(err)
		}
	})
	t.Setenv("REVIEW_TEST_CHILD", "1")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	s := &session{context: hello{Worktree: root, StateDir: t.TempDir(), FeatureID: 12}}
	t.Cleanup(s.close)
	return s, binary
}

func until(t *testing.T, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for the pseudo-terminal")
}

func output(t *testing.T, s *session) string {
	t.Helper()
	result, err := s.read(0)
	if err != nil {
		t.Fatal(err)
	}
	bytes, err := base64.StdEncoding.DecodeString(result.(map[string]any)["data"].(string))
	if err != nil {
		t.Fatal(err)
	}
	return string(bytes)
}

func TestPTYStartupInputReloadAndShutdown(t *testing.T) {
	s, binary := fixture(t)
	url := `https://github.com/owner/repo/pull/12?x='";|qa! $(touch unwanted)`
	p := startParams{URL: url, NvimPath: binary, Cols: 80, Rows: 24}
	if _, err := s.start(p); err != nil {
		t.Fatal(err)
	}
	until(t, func() bool { return strings.Contains(output(t, s), "CHILD:") })
	transcript := output(t, s)
	first := strings.Index(transcript, "CHILD:") + len("CHILD:")
	var child struct {
		Args    []string `json:"args"`
		URL     string   `json:"url"`
		Runtime string   `json:"runtime"`
		Cwd     string   `json:"cwd"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(strings.Split(transcript[first:], "\n")[0])), &child); err != nil {
		t.Fatal(err)
	}
	if child.URL != url || child.Cwd != s.context.Worktree ||
		child.Runtime != filepath.Join(s.context.Worktree, "dist", "runtime") ||
		slices.Contains(child.Args, url) || len(child.Args) != 4 {
		t.Fatalf("URL must remain data outside command arguments: %+v", child)
	}
	pid := s.cmd.Process.Pid
	p.URL = ""
	if _, err := s.start(p); err != nil || s.cmd.Process.Pid != pid {
		t.Fatal("webview reload restarted Neovim")
	}
	if _, err := s.handle("terminal.resize", json.RawMessage(`{"cols":100,"rows":30}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.handle("terminal.input", json.RawMessage(`{"data":"aGVsbG8K"}`)); err != nil {
		t.Fatal(err)
	}
	until(t, func() bool { return strings.Contains(output(t, s), "INPUT:hello") })
	s.close()
	select {
	case <-s.done:
	case <-time.After(time.Second):
		t.Fatal("Neovim was left running after stdin closed")
	}
}

func TestExitedPTYCanRestart(t *testing.T) {
	s, binary := fixture(t)
	p := startParams{NvimPath: binary, Cols: 80, Rows: 24}
	if _, err := s.start(p); err != nil {
		t.Fatal(err)
	}
	until(t, func() bool { return strings.Contains(output(t, s), "CHILD:") })
	if err := s.write([]byte("exit\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-s.done:
	case <-time.After(3 * time.Second):
		t.Fatal("fake Neovim did not exit")
	}
	pid := s.cmd.Process.Pid
	if _, err := s.start(p); err != nil || s.cmd.Process.Pid == pid {
		t.Fatal("unable to restart an exited Neovim")
	}
	until(t, func() bool { return strings.Contains(output(t, s), "CHILD:") })
	if strings.Contains(output(t, s), "INPUT:exit") {
		t.Fatal("a restarted terminal retained the previous output")
	}
}

func TestOutputChunksPreserveBytesAndDrainBeforeExit(t *testing.T) {
	data := append([]byte(strings.Repeat("x", chunkLimit)), []byte("déjà 🙂\x1b[0m")...)
	s := &session{cmd: &exec.Cmd{}, output: data, exited: true}
	first, err := s.read(0)
	if err != nil {
		t.Fatal(err)
	}
	chunk := first.(map[string]any)
	if chunk["offset"] != int64(chunkLimit) || chunk["exited"] != false {
		t.Fatal("exit was announced before draining output")
	}
	second, err := s.read(chunk["offset"].(int64))
	if err != nil {
		t.Fatal(err)
	}
	tail := second.(map[string]any)
	decoded, _ := base64.StdEncoding.DecodeString(tail["data"].(string))
	if string(decoded) != "déjà 🙂\x1b[0m" || tail["exited"] != true {
		t.Fatal("UTF-8 or terminal escape bytes changed")
	}
	s.base = 10
	reset, _ := s.read(0)
	if reset.(map[string]any)["reset"] != true {
		t.Fatal("a truncated stream must explicitly reset the terminal")
	}
	if _, err := s.read(-1); err == nil {
		t.Fatal("accepted an invalid output offset")
	}
}

func TestInvalidTerminalRequestsAndMissingNeovim(t *testing.T) {
	s, _ := fixture(t)
	for _, item := range []struct{ method, params string }{
		{"terminal.start", `{"cols":0,"rows":24}`},
		{"terminal.start", `{"cols":80,"rows":24,"url":"bad\nurl"}`},
		{"terminal.input", `{"data":"not base64!"}`},
		{"terminal.read", `{"offset":0}`},
		{"terminal.resize", `{"cols":80,"rows":24}`},
		{"terminal.start", "null"},
		{"terminal.start", `{"cols":80,"rows":24,"nvimPath":"/missing/nvim"}`},
	} {
		if _, err := s.handle(item.method, json.RawMessage(item.params)); err == nil {
			t.Fatalf("accepted invalid request: %+v", item)
		}
	}
	if s.cmd != nil {
		t.Fatal("an invalid request launched Neovim")
	}
}

func TestEnvironmentReplacesStaleIntegrationVariables(t *testing.T) {
	env := nvimEnvironment([]string{
		"PATH=/bin", "TERM=dumb", "COLORTERM=wrong", "REVIEW_NVIM_URL=old", "CODEBERG_TOKEN=inherited",
	}, "/runtime", "", "/state")
	if slices.Contains(env, "REVIEW_NVIM_URL=old") || slices.Contains(env, "TERM=dumb") ||
		!slices.Contains(env, "REVIEW_NVIM_URL=") || !slices.Contains(env, "CODEBERG_TOKEN=inherited") {
		t.Fatal("the child environment did not retain CLI authentication or replace startup data")
	}
}

func TestMissingBootstrapDoesNotLaunchNeovim(t *testing.T) {
	s, binary := fixture(t)
	if err := os.Remove(filepath.Join(s.context.Worktree, "dist", "runtime", "bootstrap.lua")); err != nil {
		t.Fatal(err)
	}
	_, err := s.start(startParams{NvimPath: binary, Cols: 80, Rows: 24})
	problem, ok := err.(*fault)
	if !ok || problem.Code != "RUNTIME_MISSING" || s.cmd != nil {
		t.Fatalf("missing bootstrap must fail before launching Neovim: %v", err)
	}
}
