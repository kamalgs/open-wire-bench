// otel.go — OpenTelemetry metrics setup for trading-sim.
//
// Instruments:
//   - Float64Histogram "trading.latency.seconds" with "channel" attribute
//   - Int64ObservableCounters for pub/rx per channel (driven by shard atomics)
//
// Two readers:
//   - ManualReader (always): used for end-of-run JSON snapshot via Collect()
//   - Prometheus exporter (when --metrics-port > 0): live /metrics scraping
package main

import (
	"context"
	"fmt"
	"net/http"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel/attribute"
	otelprometheus "go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

// latBucketBoundaries are the histogram bucket upper bounds in seconds,
// tuned for trading latency (0.1ms–1s range).
var latBucketBoundaries = []float64{
	0.0001, 0.0002, 0.0005,
	0.001, 0.002, 0.005,
	0.010, 0.020, 0.050,
	0.100, 0.200, 0.500,
	1.0,
}

// OTelState holds the meter provider and instrumentation handles.
type OTelState struct {
	provider     *sdkmetric.MeterProvider
	manualReader *sdkmetric.ManualReader

	// Latency is the end-to-end histogram. Record values in seconds.
	Latency metric.Float64Histogram

	// Pre-built attribute options — avoids per-call allocations on the hot path.
	MktAttr metric.MeasurementOption
	OrdAttr metric.MeasurementOption
	TrdAttr metric.MeasurementOption

	// Pointers to shard counters. Set after shard creation; read by OTel callbacks
	// at Prometheus scrape time. Nil pointers are safely skipped.
	MarketPub  *atomic.Int64
	MarketRx   *atomic.Int64
	OrdersPub  *atomic.Int64
	OrdersRx   *atomic.Int64
	TradesPub  *atomic.Int64
	TradesRx   *atomic.Int64
	ScrollEvts *atomic.Int64
}

// SetupOTel initialises a MeterProvider with a ManualReader (always present) and
// an optional Prometheus exporter on metricsPort. Wire OTelState counter pointer
// fields to shard atomics before the first Prometheus scrape.
func SetupOTel(metricsPort int) (*OTelState, error) {
	state := &OTelState{}

	// View: override default histogram buckets for the latency instrument.
	latView := sdkmetric.NewView(
		sdkmetric.Instrument{Name: "trading.latency.seconds"},
		sdkmetric.Stream{
			Aggregation: sdkmetric.AggregationExplicitBucketHistogram{
				Boundaries: latBucketBoundaries,
			},
		},
	)

	manualReader := sdkmetric.NewManualReader()
	state.manualReader = manualReader

	opts := []sdkmetric.Option{
		sdkmetric.WithReader(manualReader),
		sdkmetric.WithView(latView),
	}

	if metricsPort > 0 {
		promExporter, err := otelprometheus.New()
		if err != nil {
			return nil, fmt.Errorf("prometheus exporter: %w", err)
		}
		opts = append(opts, sdkmetric.WithReader(promExporter))
		go func() {
			_ = http.ListenAndServe(fmt.Sprintf(":%d", metricsPort), promhttp.Handler())
		}()
	}

	provider := sdkmetric.NewMeterProvider(opts...)
	state.provider = provider
	meter := provider.Meter("trading-sim")

	var err error
	state.Latency, err = meter.Float64Histogram(
		"trading.latency.seconds",
		metric.WithDescription("End-to-end message latency"),
		metric.WithUnit("s"),
	)
	if err != nil {
		return nil, fmt.Errorf("latency histogram: %w", err)
	}

	state.MktAttr = metric.WithAttributes(attribute.String("channel", "market"))
	state.OrdAttr = metric.WithAttributes(attribute.String("channel", "orders"))
	state.TrdAttr = metric.WithAttributes(attribute.String("channel", "trades"))

	// Observable counters — callbacks run at scrape time, zero hot-path cost.
	type spec struct {
		name string
		desc string
		ptr  **atomic.Int64
	}
	for _, c := range []spec{
		{"trading.market.published_total", "Market messages published", &state.MarketPub},
		{"trading.market.received_total", "Market messages received", &state.MarketRx},
		{"trading.orders.published_total", "Order messages published", &state.OrdersPub},
		{"trading.orders.received_total", "Order messages received", &state.OrdersRx},
		{"trading.trades.published_total", "Trade messages published", &state.TradesPub},
		{"trading.trades.received_total", "Trade messages received", &state.TradesRx},
		{"trading.scroll.events_total", "User scroll events", &state.ScrollEvts},
	} {
		ptr := c.ptr // capture loop variable
		if _, err := meter.Int64ObservableCounter(c.name,
			metric.WithDescription(c.desc),
			metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
				if *ptr != nil {
					o.Observe((*ptr).Load())
				}
				return nil
			}),
		); err != nil {
			return nil, fmt.Errorf("counter %s: %w", c.name, err)
		}
	}

	return state, nil
}

// Collect gathers a single metrics snapshot from the ManualReader for
// end-of-run percentile and histogram computation.
func (s *OTelState) Collect() metricdata.ResourceMetrics {
	var rm metricdata.ResourceMetrics
	_ = s.manualReader.Collect(context.Background(), &rm)
	return rm
}

// ChannelResult extracts p50/p99/p99.9 (in µs) and bucket histogram data for
// the named channel from a snapshot. Returns zero percentiles and nil histogram
// when no data is present.
func ChannelResult(rm *metricdata.ResourceMetrics, channel string) (p50, p99, p999 float64, hist *BucketData) {
	for i := range rm.ScopeMetrics {
		for j := range rm.ScopeMetrics[i].Metrics {
			m := &rm.ScopeMetrics[i].Metrics[j]
			if m.Name != "trading.latency.seconds" {
				continue
			}
			hdata, ok := m.Data.(metricdata.Histogram[float64])
			if !ok {
				continue
			}
			for k := range hdata.DataPoints {
				dp := &hdata.DataPoints[k]
				v, ok := dp.Attributes.Value(attribute.Key("channel"))
				if !ok || v.AsString() != channel {
					continue
				}
				p50 = pctFromHistogram(dp, 50)
				p99 = pctFromHistogram(dp, 99)
				p999 = pctFromHistogram(dp, 99.9)
				hist = bucketDataFromDP(dp)
				return
			}
		}
	}
	return
}

// pctFromHistogram computes percentile p (0–100) in µs using linear
// interpolation within the containing bucket.
func pctFromHistogram(dp *metricdata.HistogramDataPoint[float64], p float64) float64 {
	if dp.Count == 0 {
		return 0
	}
	target := float64(dp.Count) * p / 100.0
	var cum float64
	for i, count := range dp.BucketCounts {
		cum += float64(count)
		if cum < target {
			continue
		}
		var lower, upper float64
		if i > 0 {
			lower = dp.Bounds[i-1]
		}
		if i < len(dp.Bounds) {
			upper = dp.Bounds[i]
		} else {
			// Overflow bucket: extend by one bucket width.
			n := len(dp.Bounds)
			if n >= 2 {
				upper = dp.Bounds[n-1] + (dp.Bounds[n-1] - dp.Bounds[n-2])
			} else if n == 1 {
				upper = dp.Bounds[0] * 2
			} else {
				upper = 1.0
			}
		}
		prevCum := cum - float64(count)
		frac := float64(0)
		if count > 0 {
			frac = (target - prevCum) / float64(count)
		}
		return (lower + frac*(upper-lower)) * 1e6 // seconds → µs
	}
	if len(dp.Bounds) > 0 {
		return dp.Bounds[len(dp.Bounds)-1] * 1e6
	}
	return 0
}

// bucketDataFromDP converts an OTel histogram data point to BucketData with
// bounds in µs (matching the _us convention used throughout the JSON output).
func bucketDataFromDP(dp *metricdata.HistogramDataPoint[float64]) *BucketData {
	bounds := make([]float64, len(dp.Bounds))
	for i, b := range dp.Bounds {
		bounds[i] = b * 1e6
	}
	counts := make([]uint64, len(dp.BucketCounts))
	copy(counts, dp.BucketCounts)
	return &BucketData{Bounds: bounds, Counts: counts}
}
