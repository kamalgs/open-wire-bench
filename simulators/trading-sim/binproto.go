// Package main — binary protocol helpers shared across all actor roles.
//
// Frame layout (9-byte header):
//
//	op(u8) | subj_len(u16 LE) | repl_len(u16 LE) | pay_len(u32 LE)
//	followed by subject, reply, payload bytes.
//
// Client-facing ops used here:
//
//	Ping  0x01 — server keepalive
//	Pong  0x02 — reply to Ping
//	Msg   0x03 — published message
//	Sub   0x05 — subscribe: subject=pattern, reply=queue(empty), payload=SID u32LE
//	Unsub 0x06 — unsubscribe: subject=SID u32LE, reply=empty, pay_len=0
package main

import (
	"encoding/binary"
	"io"
	"net"
	"sync/atomic"
	"time"
)

const headerLen = 9

// appendMsg encodes a binary Msg frame (op=0x03) and appends it to *buf,
// growing the backing array if needed.
func appendMsg(buf *[]byte, subject, payload []byte) {
	total := headerLen + len(subject) + len(payload)
	start := len(*buf)
	if cap(*buf)-start < total {
		next := make([]byte, start, start+total+512)
		copy(next, *buf)
		*buf = next
	}
	*buf = (*buf)[:start+total]
	b := (*buf)[start:]
	b[0] = 0x03
	binary.LittleEndian.PutUint16(b[1:3], uint16(len(subject)))
	binary.LittleEndian.PutUint16(b[3:5], 0)
	binary.LittleEndian.PutUint32(b[5:9], uint32(len(payload)))
	copy(b[9:], subject)
	copy(b[9+len(subject):], payload)
}

// subFrame builds a Sub frame: op=0x05, subject=pattern, reply=queue(empty), payload=SID u32LE.
func subFrame(subject []byte, sid uint32) []byte {
	frame := make([]byte, headerLen+len(subject)+4)
	frame[0] = 0x05
	binary.LittleEndian.PutUint16(frame[1:3], uint16(len(subject)))
	binary.LittleEndian.PutUint16(frame[3:5], 0)
	binary.LittleEndian.PutUint32(frame[5:9], 4)
	copy(frame[9:], subject)
	binary.LittleEndian.PutUint32(frame[9+len(subject):], sid)
	return frame
}

// unsubFrame builds an Unsub frame: op=0x06, subject=SID u32LE (4 bytes), pay_len=0.
func unsubFrame(sid uint32) []byte {
	frame := make([]byte, headerLen+4)
	frame[0] = 0x06
	binary.LittleEndian.PutUint16(frame[1:3], 4) // subj_len=4 (SID as subject bytes)
	binary.LittleEndian.PutUint16(frame[3:5], 0)
	binary.LittleEndian.PutUint32(frame[5:9], 0)
	binary.LittleEndian.PutUint32(frame[9:], sid)
	return frame
}

var pongFrame = []byte{0x02, 0, 0, 0, 0, 0, 0, 0, 0}

// drainServer reads frames from conn, responding to Pings with Pong, until stop
// fires or conn closes. Intended for publisher connections that only receive Pings.
func drainServer(conn net.Conn, stop *atomic.Bool) {
	hdr := make([]byte, headerLen)
	for !stop.Load() {
		conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond)) //nolint:errcheck
		if _, err := io.ReadFull(conn, hdr); err != nil {
			return
		}
		bodyLen := int(binary.LittleEndian.Uint16(hdr[1:3])) +
			int(binary.LittleEndian.Uint16(hdr[3:5])) +
			int(binary.LittleEndian.Uint32(hdr[5:9]))
		if bodyLen > 0 {
			discard := make([]byte, bodyLen)
			if _, err := io.ReadFull(conn, discard); err != nil {
				return
			}
		}
		if hdr[0] == 0x01 { // Ping
			conn.Write(pongFrame) //nolint:errcheck
		}
	}
}
