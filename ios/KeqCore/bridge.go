package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/constant"
	xcore "github.com/xtls/xray-core/core"
)

var (
	coreMu       sync.Mutex
	activeEngine string
	xrayInst     *xcore.Instance
	mihomoInst   = &mihomoState{}
	activeLogger *coreLogWriter
	activeTunFd  = -1
)

//export KeqCoreInitMemory
func KeqCoreInitMemory(limitBytes C.int64_t, gcPercent C.int) {
	if limitBytes > 0 {
		debug.SetMemoryLimit(int64(limitBytes))
	}
	if gcPercent > 0 {
		debug.SetGCPercent(int(gcPercent))
	}
}

//export KeqCoreStart
func KeqCoreStart(
	engineC *C.char,
	configPathC *C.char,
	dataDirC *C.char,
	tunFd C.int,
	logLevelC *C.char,
	logPathC *C.char,
) *C.char {
	coreMu.Lock()
	defer coreMu.Unlock()

	stopLocked()

	engine := strings.ToLower(strings.TrimSpace(C.GoString(engineC)))
	configPath := C.GoString(configPathC)
	dataDir := C.GoString(dataDirC)
	logLevel := C.GoString(logLevelC)
	logPath := C.GoString(logPathC)
	fd := int(tunFd)

	logger := newCoreLogWriter(logPath, logLevel)

	switch engine {
	case "", "xray":
		inst, err := startXray(configPath, dataDir, fd, logger)
		if err != nil {
			logger.Close()
			return C.CString(err.Error())
		}
		xrayInst = inst
		activeEngine = "xray"
		activeLogger = logger
		activeTunFd = fd
	case "mihomo":
		if err := mihomoInst.start(configPath, dataDir, fd, logger); err != nil {
			logger.Close()
			return C.CString(err.Error())
		}
		activeEngine = "mihomo"
		activeLogger = logger
		activeTunFd = fd
	default:
		logger.Close()
		return C.CString(fmt.Sprintf("unsupported engine: %s", engine))
	}

	return nil
}

func stopLocked() {
	if xrayInst != nil {
		_ = xrayInst.Close()
		xrayInst = nil
	}
	if activeEngine == "mihomo" {
		mihomoInst.stop()
	}
	if activeLogger != nil {
		activeLogger.Close()
		activeLogger = nil
	}
	activeEngine = ""
	activeTunFd = -1
	runtime.GC()
	debug.FreeOSMemory()
}

//export KeqCoreStop
func KeqCoreStop() {
	coreMu.Lock()
	defer coreMu.Unlock()
	stopLocked()
}

//export KeqCoreIsRunning
func KeqCoreIsRunning() C.int {
	coreMu.Lock()
	defer coreMu.Unlock()
	if activeEngine != "" {
		return 1
	}
	return 0
}

//export KeqCoreReloadMihomo
func KeqCoreReloadMihomo(configPathC *C.char) *C.char {
	coreMu.Lock()
	defer coreMu.Unlock()
	if activeEngine != "mihomo" {
		return C.CString("mihomo is not active")
	}
	if err := mihomoInst.reload(C.GoString(configPathC), activeTunFd); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export KeqCoreResetConnections
func KeqCoreResetConnections() {
	coreMu.Lock()
	defer coreMu.Unlock()
	if activeEngine == "mihomo" {
		resetMihomoConnections()
	}
}

//export KeqCoreGetStats
func KeqCoreGetStats(outRx *C.int64_t, outTx *C.int64_t, outDialFailures *C.int64_t) {
	coreMu.Lock()
	engine := activeEngine
	xi := xrayInst
	logger := activeLogger
	coreMu.Unlock()

	var rx, tx int64
	switch engine {
	case "xray":
		rx, tx = readXrayStats(xi)
	case "mihomo":
		rx, tx = readMihomoStats()
	}
	if outRx != nil {
		*outRx = C.int64_t(rx)
	}
	if outTx != nil {
		*outTx = C.int64_t(tx)
	}
	if outDialFailures != nil {
		*outDialFailures = C.int64_t(logger.DialFailures())
	}
}

//export KeqCoreUrlTest
func KeqCoreUrlTest(
	configJsonC *C.char,
	dataDirC *C.char,
	socksPort C.int,
	testUrlC *C.char,
	timeoutMs C.int,
) C.int64_t {
	res := urlTestXrayBatch(
		C.GoString(configJsonC),
		C.GoString(dataDirC),
		[]int{int(socksPort)},
		C.GoString(testUrlC),
		int(timeoutMs),
	)
	return C.int64_t(res[0])
}

//export KeqCoreUrlTestBatch
func KeqCoreUrlTestBatch(
	configJsonC *C.char,
	dataDirC *C.char,
	portsJsonC *C.char,
	testUrlC *C.char,
	timeoutMs C.int,
) *C.char {
	var ports []int
	if err := json.Unmarshal([]byte(C.GoString(portsJsonC)), &ports); err != nil {
		return C.CString("{}")
	}
	res := urlTestXrayBatch(
		C.GoString(configJsonC),
		C.GoString(dataDirC),
		ports,
		C.GoString(testUrlC),
		int(timeoutMs),
	)
	encoded, err := json.Marshal(res)
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(encoded))
}

//export KeqCoreGetVersions
func KeqCoreGetVersions() *C.char {
	payload := map[string]string{
		"xray":   xcore.Version(),
		"mihomo": constant.Version,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(encoded))
}

//export KeqCoreFreeString
func KeqCoreFreeString(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

func main() {}
