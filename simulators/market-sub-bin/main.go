// market-sub-bin subscribes to market data using the open-wire binary protocol.
// Each connection subscribes to a partition of symbols, mirroring real-world
// partitioned consumers (e.g. Kafka consumer group members).
//
// With --conns N: N connections, each subscribing to symbols/N symbols.
// With --conns 0 or --conns == --symbols: one connection per symbol (max granularity).
//
// Binary frame: 9-byte header (op u8, subj_len u16le, repl_len u16le, pay_len u32le)
// Sub frame: op=0x05, subject=pattern, reply=queue(empty), payload=SID u32le
// Msg frame: op=0x03, subject=subj, reply=reply(empty), payload=data
//
// Flags:
//
//	--url       binary broker address  (default: localhost:4224)
//	--symbols   number of symbols      (default: 500)
//	--conns     subscriber connections  (default: 8; each subscribes to symbols/conns symbols)
//	--duration  how long to subscribe  (default: 35s)
//
// Prints a single JSON line on exit:
//
//	{"url":"…","received":N,"elapsed_s":F,"msg_per_sec":F,"p50_us":F,"p99_us":F}
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/signal"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"open-wire-bench/internal/msg"
)

const headerLen = 9

// writeSub sends a binary Sub frame: op=0x05, subject=pattern, reply="" (no queue), payload=SID u32le.
func writeSub(conn net.Conn, subject []byte, sid uint32) error {
	frame := make([]byte, headerLen+len(subject)+4)
	frame[0] = 0x05 // Sub
	binary.LittleEndian.PutUint16(frame[1:3], uint16(len(subject)))
	binary.LittleEndian.PutUint16(frame[3:5], 0) // no queue
	binary.LittleEndian.PutUint32(frame[5:9], 4) // payload = 4-byte SID
	copy(frame[9:], subject)
	binary.LittleEndian.PutUint32(frame[9+len(subject):], sid)
	_, err := conn.Write(frame)
	return err
}

func writePong(conn net.Conn) {
	conn.Write([]byte{0x02, 0, 0, 0, 0, 0, 0, 0, 0}) //nolint:errcheck
}

// runSubscriber handles one binary connection subscribed to a partition of symbols.
// It sends one SUB frame per symbol in the partition (exact-match subscriptions).
func runSubscriber(
	addr string,
	subjects [][]byte, // partition of symbols for this connection
	connIdx int,
	stop *atomic.Bool,
	received *atomic.Int64,
	latCh chan<- []int64,
	wg *sync.WaitGroup,
) {
	defer wg.Done()

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "subscriber[%d]: connect %s: %v\n", connIdx, addr, err)
		latCh <- nil
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)      //nolint:errcheck
		tc.SetReadBuffer(1 << 20) //nolint:errcheck  // 1MB receive buffer
	}

	// Subscribe to each symbol in this partition with a unique SID.
	for i, subj := range subjects {
		sid := uint32(connIdx*len(subjects) + i + 1)
		if err := writeSub(conn, subj, sid); err != nil {
			fmt.Fprintf(os.Stderr, "subscriber[%d]: sub %s: %v\n", connIdx, subj, err)
			latCh <- nil
			return
		}
	}

	hdr := make([]byte, headerLen)
	body := make([]byte, 512) // grows if needed
	var lats []int64
	var localCount int64

	// Close the connection when stop is signalled — unblocks io.ReadFull below.
	stopCh := make(chan struct{})
	go func() {
		for !stop.Load() {
			time.Sleep(50 * time.Millisecond)
		}
		conn.SetDeadline(time.Now().Add(100 * time.Millisecond)) //nolint:errcheck
		close(stopCh)
	}()

	for {
		_, err := io.ReadFull(conn, hdr)
		if err != nil {
			break
		}

		op := hdr[0]
		subjLen := int(binary.LittleEndian.Uint16(hdr[1:3]))
		replLen := int(binary.LittleEndian.Uint16(hdr[3:5]))
		payLen := int(binary.LittleEndian.Uint32(hdr[5:9]))
		bodyLen := subjLen + replLen + payLen
		if bodyLen > len(body) {
			body = make([]byte, bodyLen)
		}
		if bodyLen > 0 {
			if _, err := io.ReadFull(conn, body[:bodyLen]); err != nil {
				break
			}
		}

		switch op {
		case 0x01: // Ping
			writePong(conn)
		case 0x03, 0x04: // Msg, HMsg
			localCount++
			if localCount == 512 {
				received.Add(localCount)
				localCount = 0
			}
			// Sample 1-in-100 messages for latency to cap memory.
			if localCount%100 == 0 {
				payData := body[subjLen+replLen : bodyLen]
				if lat, _, ok := msg.Decode(payData); ok && lat >= 0 {
					lats = append(lats, lat)
				}
			}
		}
	}
	<-stopCh
	if localCount > 0 {
		received.Add(localCount)
	}
	latCh <- lats
}

func pct(sorted []int64, p float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(float64(len(sorted))*p/100.0)) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func main() {
	addr := flag.String("url", "localhost:4224", "binary broker address (host:port)")
	symbols := flag.Int("symbols", 500, "number of symbols")
	conns := flag.Int("conns", 8, "subscriber connections (each subscribes to symbols/conns symbols)")
	duration := flag.Duration("duration", 35*time.Second, "subscribe duration")
	flag.Parse()

	if *conns < 1 {
		*conns = 1
	}
	if *conns > *symbols {
		*conns = *symbols
	}

	// Build subject list and partition across connections (stripe, same as sim).
	allSubjects := make([][]byte, *symbols)
	for i := range allSubjects {
		allSubjects[i] = []byte(fmt.Sprintf("market.sym%04d", i))
	}
	partitions := make([][][]byte, *conns)
	for i, subj := range allSubjects {
		c := i % *conns
		partitions[c] = append(partitions[c], subj)
	}

	var received atomic.Int64
	var stop atomic.Bool
	var wg sync.WaitGroup

	latCh := make(chan []int64, *conns)

	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go runSubscriber(*addr, partitions[i], i, &stop, &received, latCh, &wg)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	var deadline <-chan time.Time
	if *duration > 0 {
		deadline = time.After(*duration)
	}

	start := time.Now()
	select {
	case <-deadline:
	case <-sigCh:
	}
	stop.Store(true)

	doneCh := make(chan struct{})
	var allLats []int64
	var muLats sync.Mutex
	go func() {
		for i := 0; i < *conns; i++ {
			if lats := <-latCh; lats != nil {
				muLats.Lock()
				allLats = append(allLats, lats...)
				muLats.Unlock()
			}
		}
		close(doneCh)
	}()
	wg.Wait()
	<-doneCh

	elapsed := time.Since(start).Seconds()
	total := received.Load()

	sort.Slice(allLats, func(i, j int) bool { return allLats[i] < allLats[j] })

	out, _ := json.Marshal(map[string]any{
		"url":         *addr,
		"received":    total,
		"elapsed_s":   elapsed,
		"msg_per_sec": float64(total) / elapsed,
		"p50_us":      float64(pct(allLats, 50)) / 1000,
		"p99_us":      float64(pct(allLats, 99)) / 1000,
	})
	fmt.Println(string(out))
}
