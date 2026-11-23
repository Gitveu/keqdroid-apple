package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	xlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
	"golang.org/x/net/proxy"
)

type xrayLogBridge struct {
	writer *coreLogWriter
}

func (b *xrayLogBridge) Handle(msg xlog.Message) {
	if b.writer == nil || msg == nil {
		return
	}
	sev := lvlInfo
	if gm, ok := msg.(*xlog.GeneralMessage); ok {
		switch gm.Severity {
		case xlog.Severity_Debug:
			sev = lvlDebug
		case xlog.Severity_Info:
			sev = lvlInfo
		case xlog.Severity_Warning:
			sev = lvlWarn
		case xlog.Severity_Error:
			sev = lvlError
		default:
			sev = lvlInfo
		}
	}
	b.writer.WriteLine(sev, msg.String())
}

// ensureXrayStatsEnabled injects stats + inbound uplink/downlink counters into
// the session JSON config so iOS can report live traffic without Android's
// TrafficStats.getUidRxBytes.
func ensureXrayStatsEnabled(raw []byte) []byte {
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return raw
	}
	if _, ok := doc["stats"]; !ok {
		doc["stats"] = map[string]any{}
	}
	policy, _ := doc["policy"].(map[string]any)
	if policy == nil {
		policy = map[string]any{}
		doc["policy"] = policy
	}
	sys, _ := policy["system"].(map[string]any)
	if sys == nil {
		sys = map[string]any{}
		policy["system"] = sys
	}
	sys["statsInboundUplink"] = true
	sys["statsInboundDownlink"] = true

	// Raise runtime error log to info so dial failures and access logs reach
	// xrayLogBridge, while user display threshold is enforced in coreLogWriter.
	logObj, _ := doc["log"].(map[string]any)
	if logObj == nil {
		logObj = map[string]any{}
		doc["log"] = logObj
	}
	logObj["loglevel"] = "info"
	delete(logObj, "access")
	delete(logObj, "error")

	patched, err := json.Marshal(doc)
	if err != nil {
		return raw
	}
	return patched
}

func startXray(configPath, dataDir string, tunFd int, logger *coreLogWriter) (*core.Instance, error) {
	if dataDir != "" {
		_ = os.Setenv("XRAY_LOCATION_ASSET", dataDir)
	}
	if tunFd >= 0 {
		_ = os.Setenv("XRAY_TUN_FD", strconv.Itoa(tunFd))
	} else {
		_ = os.Unsetenv("XRAY_TUN_FD")
	}

	raw, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("read xray config: %w", err)
	}
	patched := ensureXrayStatsEnabled(raw)

	pbConfig, err := serial.LoadJSONConfig(bytes.NewReader(patched))
	if err != nil {
		return nil, fmt.Errorf("parse xray config: %w", err)
	}

	if logger != nil {
		xlog.RegisterHandler(&xrayLogBridge{writer: logger})
	}

	instance, err := core.New(pbConfig)
	if err != nil {
		return nil, fmt.Errorf("create xray instance: %w", err)
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return nil, fmt.Errorf("start xray instance: %w", err)
	}
	// Re-register after Start() because Xray's log feature replaces the global
	// handler during instance startup.
	if logger != nil {
		xlog.RegisterHandler(&xrayLogBridge{writer: logger})
	}
	return instance, nil
}

func readXrayStats(instance *core.Instance) (rx int64, tx int64) {
	if instance == nil {
		return 0, 0
	}
	feat := instance.GetFeature(stats.ManagerType())
	if feat == nil {
		return 0, 0
	}
	mgr, ok := feat.(stats.Manager)
	if !ok || mgr == nil {
		return 0, 0
	}
	mgr.VisitCounters(func(name string, c stats.Counter) bool {
		if !strings.HasPrefix(name, "inbound>>>") {
			return true
		}
		if strings.HasSuffix(name, ">>>traffic>>>downlink") {
			rx += c.Value()
		} else if strings.HasSuffix(name, ">>>traffic>>>uplink") {
			tx += c.Value()
		}
		return true
	})
	return rx, tx
}

func probeSocksHTTP(socksPort int, testURL string, timeout time.Duration) int64 {
	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), nil, &net.Dialer{
		Timeout: timeout,
	})
	if err != nil {
		return -1
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dialer.Dial(network, addr)
		},
		DisableKeepAlives:     true,
		ResponseHeaderTimeout: timeout,
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	req, err := http.NewRequest(http.MethodGet, testURL, nil)
	if err != nil {
		return -1
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return -1
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	_ = resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return -1
	}
	elapsed := time.Since(start).Milliseconds()
	if elapsed < 1 {
		elapsed = 1
	}
	return elapsed
}

func waitTCPPortReady(port int, deadline time.Time) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

// urlTestXrayBatch starts an isolated in-process Xray instance with one or more
// SOCKS5 inbounds, runs concurrent URL probes, and shuts the instance down.
func urlTestXrayBatch(configJSON, dataDir string, ports []int, testURL string, timeoutMs int) map[int]int64 {
	results := make(map[int]int64, len(ports))
	for i := range ports {
		results[i] = -1
	}
	if len(ports) == 0 {
		return results
	}
	if dataDir != "" {
		_ = os.Setenv("XRAY_LOCATION_ASSET", dataDir)
	}
	_ = os.Unsetenv("XRAY_TUN_FD")

	pbConfig, err := serial.LoadJSONConfig(strings.NewReader(configJSON))
	if err != nil {
		return results
	}
	inst, err := core.New(pbConfig)
	if err != nil {
		return results
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return results
	}
	defer func() { _ = inst.Close() }()

	if !waitTCPPortReady(ports[0], time.Now().Add(2*time.Second)) {
		return results
	}

	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for i, port := range ports {
		wg.Add(1)
		go func(idx, p int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			ms := probeSocksHTTP(p, testURL, timeout)
			mu.Lock()
			results[idx] = ms
			mu.Unlock()
		}(i, port)
	}
	wg.Wait()
	return results
}
