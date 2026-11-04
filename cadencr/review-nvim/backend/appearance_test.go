package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fontFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestAppearanceFollowsCadencRAndAlacrittyAndReloads(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	state := filepath.Join(root, "plugins", "tab-state", "review-nvim")
	prefs := filepath.Join(root, "settings", "settings.json")
	config := filepath.Join(home, ".config", "alacritty", "alacritty.toml")
	fontFile(t, config, `[font]
size = 16
[font.normal]
family = "Alacritty Font"`)
	fontFile(t, prefs, `{"mono_font_family":"Iosevka Nerd Font Mono","unrelated":"never returned"}`)
	got := terminalAppearance(state, home)
	if got.FontSize != 16 || got.FontFamily != fontStack("Iosevka Nerd Font Mono") {
		t.Fatalf("CadencR family must override Alacritty: %+v", got)
	}
	wire, _ := json.Marshal(got)
	if strings.Contains(string(wire), "unrelated") {
		t.Fatal("unrelated preferences leaked")
	}
	fontFile(t, prefs, `{"mono_font_family":"Other Font"}`)
	if terminalAppearance(state, home).FontFamily != fontStack("Other Font") {
		t.Fatal("font changes are not reread")
	}
	fontFile(t, prefs, `{broken`)
	if terminalAppearance(state, home).FontFamily != fontStack("Alacritty Font") {
		t.Fatal("invalid CadencR preferences must retain Alacritty font")
	}
}

func TestAppearanceImportsPrecedenceCyclesAndDefaults(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	state := filepath.Join(root, "plugins", "tab-state", "review-nvim")
	config := filepath.Join(home, ".config", "alacritty", "alacritty.toml")
	imported := filepath.Join(filepath.Dir(config), "fonts.toml")
	fontFile(t, imported, `[general]
import = ["alacritty.toml"]
[font]
size = 17
[font.normal]
family = "Imported"`)
	fontFile(t, config, `[general]
import = ["fonts.toml"]
[font]
size = 15`)
	if got := terminalAppearance(state, home); got.FontSize != 15 || got.FontFamily != fontStack("Imported") {
		t.Fatalf("imports/cycle precedence differs from CadencR: %+v", got)
	}
	fontFile(t, config, `[window]
opacity = 0.9`)
	if got := terminalAppearance(state, home); got.FontSize != 11.25 || got.FontFamily != monoStack {
		t.Fatalf("existing Alacritty config must use its default font size: %+v", got)
	}
	fontFile(t, config, `[general]
import = ["missing.toml"]`)
	if got := terminalAppearance(state, home); got.FontSize != 13 || got.FontFamily != monoStack {
		t.Fatalf("bad config must use CadencR fallback: %+v", got)
	}
	if got := terminalAppearance(t.TempDir(), home); got.FontSize != 13 || got.FontFamily != monoStack {
		t.Fatalf("an ad-hoc hello must not read user preferences: %+v", got)
	}
}

func TestAppearanceRejectsInvalidSizeAndEscapesFontFamily(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	state := filepath.Join(root, "plugins", "tab-state", "review-nvim")
	config := filepath.Join(home, ".config", "alacritty", "alacritty.toml")
	fontFile(t, config, "[font]\nsize = nan\n")
	if got := terminalAppearance(state, home); got.FontSize != 11.25 {
		t.Fatalf("invalid font size was passed to xterm: %+v", got)
	}
	if fontStack("bad\nfont") != monoStack || !strings.HasPrefix(fontStack(`A"Font`), `"A\"Font", `) {
		t.Fatal("font families must be safe single CSS strings")
	}
}
