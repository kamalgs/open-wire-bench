// transport.go — protocol-agnostic Publisher and MsgSub abstractions.
//
// Binary and NATS implementations share the same interface so all business
// logic (tick loops, gap tracking, scroll management) is written once.
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	natsgo "github.com/nats-io/nats.go"
)

// Publisher can publish messages to named subjects.
type Publisher interface {
	Publish(subject string, payload []byte) error
	// Flush flushes any buffered outbound data (no-op for binary).
	Flush()
	Close()
}

// SubHandle represents one active subscription; call Unsubscribe to cancel it.
type SubHandle interface {
	Unsubscribe() error
}

// MsgSub is a live broker connection on which subjects can be subscribed.
// Handlers are invoked synchronously from an internal dispatch goroutine and
// must not block. The payload slice passed to a handler is only valid for the
// duration of that call — handlers must not retain it.
//
// Done closes when the connection is permanently lost (binary transport).
// For NATS (MaxReconnects=-1) it never closes; the client reconnects silently.
type MsgSub interface {
	Subscribe(subject string, handler func(payload []byte)) (SubHandle, error)
	Done() <-chan struct{}
	Close()
}

// ── Binary publisher ──────────────────────────────────────────────────────────

type binaryPub struct {
	conn      net.Conn
	buf       []byte
	drainDone atomic.Bool
}

func newBinaryPub(url string) (Publisher, error) {
	conn, err := net.DialTimeout("tcp", url, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true) //nolint:errcheck
	}
	p := &binaryPub{conn: conn, buf: make([]byte, 0, 512)}
	go drainServer(conn, &p.drainDone)
	return p, nil
}

func (p *binaryPub) Publish(subject string, payload []byte) error {
	p.buf = p.buf[:0]
	appendMsg(&p.buf, []byte(subject), payload)
	_, err := p.conn.Write(p.buf)
	return err
}

func (p *binaryPub) Flush() {}

func (p *binaryPub) Close() {
	p.drainDone.Store(true)
	p.conn.Close()
}

// ── NATS publisher ────────────────────────────────────────────────────────────

type natsPub struct {
	nc *natsgo.Conn
}

func newNATSPub(url, name string) (Publisher, error) {
	nc, err := natsgo.Connect(url,
		natsgo.Name(name),
		natsgo.MaxReconnects(-1),
		natsgo.ReconnectWait(200*time.Millisecond),
	)
	if err != nil {
		return nil, err
	}
	return &natsPub{nc: nc}, nil
}

func (p *natsPub) Publish(subject string, payload []byte) error {
	return p.nc.Publish(subject, payload)
}

func (p *natsPub) Flush() { p.nc.Flush() } //nolint:errcheck

func (p *natsPub) Close() { p.nc.Close() }

// dialPublisher connects with retries until success or stop fires.
// Returns nil only when stop fires before any connection succeeds.
func dialPublisher(cfg *Config, name string, stop *atomic.Bool) Publisher {
	for {
		var (
			pub Publisher
			err error
		)
		if cfg.Protocol == "binary" {
			pub, err = newBinaryPub(cfg.URL)
		} else {
			pub, err = newNATSPub(cfg.URL, name)
		}
		if err == nil {
			return pub
		}
		fmt.Fprintf(os.Stderr, "%s: connect %s: %v — retrying\n", name, cfg.URL, err)
		if stop.Load() {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// ── Binary subscriber ─────────────────────────────────────────────────────────

type binarySub struct {
	conn    net.Conn
	writeMu sync.Mutex
	mu      sync.RWMutex
	nextSID uint32
	// handlers maps exact subject string to its message callback.
	handlers map[string]func([]byte)
	doneCh   chan struct{}
}

type binarySubHandle struct {
	sub     *binarySub
	sid     uint32
	subject string
}

func (h *binarySubHandle) Unsubscribe() error {
	h.sub.mu.Lock()
	delete(h.sub.handlers, h.subject)
	h.sub.mu.Unlock()
	h.sub.writeMu.Lock()
	_, err := h.sub.conn.Write(unsubFrame(h.sid))
	h.sub.writeMu.Unlock()
	return err
}

func newBinarySub(url string) (MsgSub, error) {
	conn, err := net.DialTimeout("tcp", url, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.SetNoDelay(true)          //nolint:errcheck
		tc.SetReadBuffer(256 * 1024) //nolint:errcheck
	}
	s := &binarySub{
		conn:     conn,
		nextSID:  1,
		handlers: make(map[string]func([]byte), 24),
		doneCh:   make(chan struct{}),
	}
	go s.readLoop()
	return s, nil
}

func (s *binarySub) Subscribe(subject string, handler func([]byte)) (SubHandle, error) {
	s.mu.Lock()
	sid := s.nextSID
	s.nextSID++
	s.handlers[subject] = handler
	s.mu.Unlock()

	s.writeMu.Lock()
	_, err := s.conn.Write(subFrame([]byte(subject), sid))
	s.writeMu.Unlock()
	if err != nil {
		s.mu.Lock()
		delete(s.handlers, subject)
		s.mu.Unlock()
		return nil, err
	}
	return &binarySubHandle{sub: s, sid: sid, subject: subject}, nil
}

func (s *binarySub) Done() <-chan struct{} { return s.doneCh }

func (s *binarySub) Close() { s.conn.Close() }

func (s *binarySub) readLoop() {
	defer close(s.doneCh)
	hdr := make([]byte, headerLen)
	// body is reused across messages; handlers must not retain the payload slice.
	body := make([]byte, 512)
	// 64 KiB buffer packs ~500 × 128-byte messages per read syscall.
	br := bufio.NewReaderSize(s.conn, 64*1024)
	for {
		if _, err := io.ReadFull(br, hdr); err != nil {
			return
		}
		subjLen := int(binary.LittleEndian.Uint16(hdr[1:3]))
		replLen := int(binary.LittleEndian.Uint16(hdr[3:5]))
		payLen := int(binary.LittleEndian.Uint32(hdr[5:9]))
		bodyLen := subjLen + replLen + payLen
		if bodyLen > len(body) {
			body = make([]byte, bodyLen+256)
		}
		if bodyLen > 0 {
			if _, err := io.ReadFull(br, body[:bodyLen]); err != nil {
				return
			}
		}
		switch hdr[0] {
		case 0x01: // Ping → Pong
			s.writeMu.Lock()
			s.conn.Write(pongFrame) //nolint:errcheck
			s.writeMu.Unlock()
		case 0x03, 0x04: // Msg, HMsg
			subj := string(body[:subjLen])
			pay := body[subjLen+replLen : bodyLen]
			s.mu.RLock()
			h := s.handlers[subj]
			s.mu.RUnlock()
			if h != nil {
				h(pay)
			}
		}
	}
}

// ── NATS subscriber ───────────────────────────────────────────────────────────

// neverDone is returned by natsSub.Done(). It never closes because
// MaxReconnects(-1) makes the NATS client reconnect indefinitely.
var neverDone = make(chan struct{})

type natsSub struct {
	nc *natsgo.Conn
}

type natsSubHandle struct {
	sub *natsgo.Subscription
}

func (h *natsSubHandle) Unsubscribe() error { return h.sub.Unsubscribe() }

func newNATSSub(url, name string) (MsgSub, error) {
	nc, err := natsgo.Connect(url,
		natsgo.Name(name),
		natsgo.MaxReconnects(-1),
		natsgo.ReconnectWait(200*time.Millisecond),
	)
	if err != nil {
		return nil, err
	}
	return &natsSub{nc: nc}, nil
}

func (s *natsSub) Subscribe(subject string, handler func([]byte)) (SubHandle, error) {
	sub, err := s.nc.Subscribe(subject, func(m *natsgo.Msg) { handler(m.Data) })
	if err != nil {
		return nil, err
	}
	return &natsSubHandle{sub: sub}, nil
}

func (s *natsSub) Done() <-chan struct{} { return neverDone }

func (s *natsSub) Close() { s.nc.Close() }

// dialMsgSub connects with retries until success or stop fires.
// Returns nil only when stop fires before any connection succeeds.
func dialMsgSub(cfg *Config, name string, stop *atomic.Bool) MsgSub {
	for {
		var (
			sub MsgSub
			err error
		)
		if cfg.Protocol == "binary" {
			sub, err = newBinarySub(cfg.URL)
		} else {
			sub, err = newNATSSub(cfg.URL, name)
		}
		if err == nil {
			return sub
		}
		fmt.Fprintf(os.Stderr, "%s: connect %s: %v — retrying\n", name, cfg.URL, err)
		if stop.Load() {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
}
