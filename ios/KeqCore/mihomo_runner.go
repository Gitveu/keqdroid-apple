package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	mlog "github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type mihomoState struct {
	mu      sync.Mutex
	running bool
	stopLog chan struct{}
}

func injectMihomoTunFd(raw []byte, tunFd int) []byte {
	if tunFd < 0 {
		return raw
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return raw
	}
	tunObj, ok := doc["tun"].(map[string]any)
	if !ok || tunObj == nil {
		return raw
	}
	tunObj["file-descriptor"] = tunFd
	tunObj["auto-route"] = false
	tunObj["auto-detect-interface"] = false
	patched, err := json.Marshal(doc)
	if err != nil {
		return raw
	}
	return patched
}

func (m *mihomoState) start(configPath, dataDir string, tunFd int, logger *coreLogWriter) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if dataDir != "" {
		constant.SetHomeDir(dataDir)
	}
	if configPath != "" {
		constant.SetConfig(configPath)
	}

	raw, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read mihomo config: %w", err)
	}
	raw = injectMihomoTunFd(raw, tunFd)

	if logger != nil {
		sub := mlog.Subscribe()
		stopCh := make(chan struct{})
		m.stopLog = stopCh
		go func() {
			defer mlog.UnSubscribe(sub)
			for {
				select {
				case <-stopCh:
					return
				case ev, ok := <-sub:
					if !ok {
						return
					}
					sev := lvlInfo
					switch ev.LogLevel {
					case mlog.DEBUG:
						sev = lvlDebug
					case mlog.INFO:
						sev = lvlInfo
					case mlog.WARNING:
						sev = lvlWarn
					case mlog.ERROR:
						sev = lvlError
					case mlog.SILENT:
						sev = lvlNone
					}
					logger.WriteLine(sev, fmt.Sprintf("[%s] %s", ev.Type(), ev.Payload))
				}
			}
		}()
	}

	if err := hub.Parse(raw); err != nil {
		if m.stopLog != nil {
			close(m.stopLog)
			m.stopLog = nil
		}
		return fmt.Errorf("start mihomo: %w", err)
	}
	m.running = true
	return nil
}

func (m *mihomoState) reload(configPath string, tunFd int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.running {
		return fmt.Errorf("mihomo is not running")
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read mihomo config: %w", err)
	}
	raw = injectMihomoTunFd(raw, tunFd)
	cfg, err := executor.ParseWithBytes(raw)
	if err != nil {
		return fmt.Errorf("parse mihomo config: %w", err)
	}
	hub.ApplyConfig(cfg)
	resetMihomoConnections()
	return nil
}

func (m *mihomoState) stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.running {
		return
	}
	resetMihomoConnections()
	executor.Shutdown()
	if m.stopLog != nil {
		close(m.stopLog)
		m.stopLog = nil
	}
	m.running = false
}

func resetMihomoConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func readMihomoStats() (rx int64, tx int64) {
	up, down := statistic.DefaultManager.Total()
	return down, up
}
