package main

import (
	"encoding/json"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// Same fallback stack and precedence as CadencR's terminal in v0.16.0.
const monoStack = `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace`

type appearance struct {
	FontFamily string  `json:"fontFamily"`
	FontSize   float64 `json:"fontSize"`
}

type fontLayer struct {
	General struct {
		Import []string `toml:"import"`
	} `toml:"general"`
	Font struct {
		Size   *float64 `toml:"size"`
		Normal struct {
			Family *string `toml:"family"`
		} `toml:"normal"`
	} `toml:"font"`
}

func boundedFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, 1024*1024))
}

func fontConfig(path, home string, active map[string]bool, budget *int) (fontLayer, bool) {
	var empty fontLayer
	if *budget <= 0 {
		return empty, false
	}
	*budget--
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return empty, false
	}
	if active[canonical] {
		return empty, true
	}
	raw, err := boundedFile(canonical)
	var own fontLayer
	if err != nil || toml.Unmarshal(raw, &own) != nil {
		return empty, false
	}
	active[canonical] = true
	defer delete(active, canonical)
	var merged fontLayer
	for _, imported := range own.General.Import {
		if strings.HasPrefix(imported, "~/") {
			imported = filepath.Join(home, imported[2:])
		} else if !filepath.IsAbs(imported) {
			imported = filepath.Join(filepath.Dir(path), imported)
		}
		layer, ok := fontConfig(imported, home, active, budget)
		if !ok {
			return empty, false
		}
		overlayFont(&merged, layer)
	}
	overlayFont(&merged, own)
	return merged, true
}

func overlayFont(base *fontLayer, layer fontLayer) {
	if layer.Font.Size != nil {
		base.Font.Size = layer.Font.Size
	}
	if layer.Font.Normal.Family != nil {
		base.Font.Normal.Family = layer.Font.Normal.Family
	}
}

func fontStack(family string) string {
	family = strings.TrimSpace(family)
	if family == "" || strings.ContainsAny(family, "\x00\r\n") || len(family) > 512 {
		return monoStack
	}
	// A family is a single CSS string, never a fragment of stylesheet code.
	family = strings.ReplaceAll(strings.ReplaceAll(family, `\`, `\\`), `"`, `\"`)
	return `"` + family + `", ` + monoStack
}

func terminalAppearance(stateDir, home string) appearance {
	result := appearance{FontFamily: monoStack, FontSize: 13}
	// Derive the active CadencR home from the host's explicit writable state
	// path. A test/ad-hoc hello must never accidentally read real user settings.
	parent := filepath.Dir(stateDir)
	plugins := filepath.Dir(parent)
	if filepath.Base(parent) != "tab-state" || filepath.Base(plugins) != "plugins" {
		return result
	}
	if home != "" {
		budget := 64
		font, ok := fontConfig(filepath.Join(home, ".config", "alacritty", "alacritty.toml"),
			home, map[string]bool{}, &budget)
		if ok {
			result.FontSize = 11.25 // Alacritty's default when its file exists.
			if font.Font.Size != nil && !math.IsNaN(*font.Font.Size) && !math.IsInf(*font.Font.Size, 0) &&
				*font.Font.Size >= 4 && *font.Font.Size <= 100 {
				result.FontSize = *font.Font.Size
			}
			if font.Font.Normal.Family != nil {
				result.FontFamily = fontStack(*font.Font.Normal.Family)
			}
		}
	}
	// v0.16's tab SDK exposes colors only. Decode just the font preference from
	// CadencR's non-secret global preferences; never read authentication files
	// or return unrelated settings to the webview.
	raw, err := boundedFile(filepath.Join(filepath.Dir(plugins), "settings", "settings.json"))
	var prefs struct {
		Family string `json:"mono_font_family"`
	}
	if err == nil && json.Unmarshal(raw, &prefs) == nil && strings.TrimSpace(prefs.Family) != "" {
		result.FontFamily = fontStack(prefs.Family)
	}
	return result
}
