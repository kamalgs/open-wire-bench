// market-sim-bin publishes synthetic market-data messages using the open-wire
// binary protocol. Unlike market-sim (single NATS connection), this tool opens
// multiple TCP connections and partitions symbols across them — one goroutine
// per connection, mirroring real-world partitioned producers (e.g. Kafka).
//
// Subjects: market.sym0000 … market.sym{N-1}
// Message format: [8B ts_ns][8B seq][padding] — see internal/msg
//
// Binary frame: 9-byte header (op u8, subj_len u16le, repl_len u16le, pay_len u32le)
//               followed by subject, reply, payload bytes.
// Op 0x03 = Msg, 0x02 = Pong.
//
// Flags:
//
//	--url       binary broker address (default: localhost:4224)
//	--symbols   number of symbols     (default: 500)
//	--conns     publisher connections  (default: 8)
//	--rate      total publish rate msg/s (default: 1000000)
//	--size      message size in bytes (default: 128, min 16)
//	--duration  how long to publish   (default: 30s)
//
// Symbols are striped across connections: conn[i] owns symbols where sym_index%conns==i.
// Prints a single JSON line on exit:
//
//	{"url":"…","published":N,"elapsed_s":F,"msg_per_sec":F}
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"open-wire-bench/internal/msg"
)

const headerLen = 9

// appendMsg appends a binary Msg frame (op=0x03) for the given subject and payload
// into buf without allocating a new slice.
func appendMsg(buf *[]byte, subject, payload []byte) {
	total := headerLen + len(subject) + len(payload)
	start := len(*buf)
	for cap(*buf)-len(*buf) < total {
		*buf = append(*buf, make([]byte, total)...)
		*buf = (*buf)[:start]
	}
	*buf = (*buf)[:start+total]
	b := (*buf)[start:]
	b[0] = 0x03 // Msg
	binary.LittleEndian.PutUint16(b[1:3], uint16(len(subject)))
	binary.LittleEndian.PutUint16(b[3:5], 0) // no reply
	binary.LittleEndian.PutUint32(b[5:9], uint32(len(payload)))
	copy(b[9:], subject)
	copy(b[9+len(subject):], payload)
}

// writePong writes a single Pong frame to conn.
func writePong(conn net.Conn) {
	conn.Write([]byte{0x02, 0, 0, 0, 0, 0, 0, 0, 0}) //nolint:errcheck
}

// drainPings reads incoming frames, responding to Pings, until the connection
// is closed or an error occurs. This runs in a separate goroutine so sends are
// never blocked by server keepalives.
func drainPings(conn net.Conn, stop *atomic.Bool) {
	hdr := make([]byte, headerLen)
	for !stop.Load() {
		conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond)) //nolint:errcheck
		if _, err := io.ReadFull(conn, hdr); err != nil {
			return
		}
		op := hdr[0]
		subjLen := int(binary.LittleEndian.Uint16(hdr[1:3]))
		replLen := int(binary.LittleEndian.Uint16(hdr[3:5]))
		payLen := int(binary.LittleEndian.Uint32(hdr[5:9]))
		body := subjLen + replLen + payLen
		if body > 0 {
			discard := make([]byte, body)
			if _, err := io.ReadFull(conn, discard); err != nil {
				return
			}
		}
		if op == 0x01 { // Ping
			writePong(conn)
		}
	}
}

func runPublisher(
	addr string,
	subjects [][]byte, // pre-built subject bytes for this conn's partition
	payloadSize int,
	ratePerConn int, // target msg/s for this connection
	stop *atomic.Bool,
	published *atomic.Int64,
	wg *sync.WaitGroup,
) {
	defer wg.Done()

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "publisher: connect %s: %v\n", addr, err)
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true) //nolint:errcheck
	}

	go drainPings(conn, stop)

	payload := make([]byte, payloadSize)
	var seq uint64

	// Batch size: enough frames to stay ahead of TCP but not too large.
	const batchMsgs = 64
	buf := make([]byte, 0, (headerLen+len(subjects[0])+payloadSize)*batchMsgs)

	// Token bucket: tokens accumulate at ratePerConn/s, capped at batchMsgs.
	interval := time.Second / time.Duration(ratePerConn)
	if interval < time.Millisecond {
		interval = time.Millisecond
	}
	msgsPerTick := ratePerConn / int(time.Second/interval)
	if msgsPerTick < 1 {
		msgsPerTick = 1
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	nsymbols := len(subjects)
	var localCount int64

	for !stop.Load() {
		select {
		case <-ticker.C:
			buf = buf[:0]
			for i := 0; i < msgsPerTick; i++ {
				subj := subjects[rand.Intn(nsymbols)]
				msg.Encode(payload, seq)
				seq++
				appendMsg(&buf, subj, payload)
				localCount++
				if localCount == 1024 {
					published.Add(localCount)
					localCount = 0
				}
			}
			if _, err := conn.Write(buf); err != nil {
				return
			}
		}
	}
	if localCount > 0 {
		published.Add(localCount)
	}
}

func main() {
	addr := flag.String("url", "localhost:4224", "binary broker address (host:port)")
	symbols := flag.Int("symbols", 500, "number of symbols")
	conns := flag.Int("conns", 8, "publisher connections")
	rate := flag.Int("rate", 1_000_000, "total publish rate (msg/s)")
	size := flag.Int("size", 128, "message size in bytes (min 16)")
	duration := flag.Duration("duration", 30*time.Second, "publish duration")
	flag.Parse()

	if *size < msg.MinSize {
		fmt.Fprintf(os.Stderr, "size must be >= %d\n", msg.MinSize)
		os.Exit(1)
	}
	if *conns < 1 {
		*conns = 1
	}
	if *conns > *symbols {
		*conns = *symbols
	}

	// Build subject byte slices for all symbols.
	allSubjects := make([][]byte, *symbols)
	for i := range allSubjects {
		allSubjects[i] = []byte(fmt.Sprintf("market.sym%04d", i))
	}

	// Partition symbols across connections (stripe, not block).
	partitions := make([][][]byte, *conns)
	for i, subj := range allSubjects {
		c := i % *conns
		partitions[c] = append(partitions[c], subj)
	}

	var published atomic.Int64
	var stop atomic.Bool
	var wg sync.WaitGroup

	ratePerConn := *rate / *conns
	if ratePerConn < 1 {
		ratePerConn = 1
	}

	start := time.Now()

	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go runPublisher(*addr, partitions[i], *size, ratePerConn, &stop, &published, &wg)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	var deadline <-chan time.Time
	if *duration > 0 {
		deadline = time.After(*duration)
	}

	select {
	case <-deadline:
	case <-sigCh:
	}
	stop.Store(true)
	wg.Wait()

	elapsed := time.Since(start).Seconds()
	total := published.Load()

	out, _ := json.Marshal(map[string]any{
		"url":         *addr,
		"published":   total,
		"elapsed_s":   elapsed,
		"msg_per_sec": float64(total) / elapsed,
	})
	fmt.Println(string(out))
}
