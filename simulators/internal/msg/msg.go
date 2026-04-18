// Package msg defines the wire format for benchmark messages.
//
// Layout: [8B ts_ns uint64 LE][8B seq uint64 LE][N-16B zero padding]
// Minimum size: 16 bytes.
// Latency is measured as (now_ns - ts_ns) on the subscriber side.
package msg

import (
	"encoding/binary"
	"time"
)

// MinSize is the minimum valid message size (timestamp + sequence).
const MinSize = 16

// Encode fills buf with the current nanosecond timestamp and the given
// sequence number. buf must be at least MinSize bytes; any remaining
// bytes are left unchanged (zero-padded by the caller on first use).
func Encode(buf []byte, seq uint64) {
	binary.LittleEndian.PutUint64(buf[0:8], uint64(time.Now().UnixNano()))
	binary.LittleEndian.PutUint64(buf[8:16], seq)
}

// Decode extracts the one-way latency and sequence number from a received
// message. Returns ok=false if data is shorter than MinSize.
func Decode(data []byte) (latencyNs int64, seq uint64, ok bool) {
	if len(data) < MinSize {
		return 0, 0, false
	}
	sentNs := int64(binary.LittleEndian.Uint64(data[0:8]))
	seq = binary.LittleEndian.Uint64(data[8:16])
	latencyNs = time.Now().UnixNano() - sentNs
	return latencyNs, seq, true
}
