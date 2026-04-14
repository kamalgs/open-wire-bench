// Partition helpers: shard assignment, Zipf-weighted sampling, and parsing
// for screen pools, tick-rate classes, and algo-user tiers.
package main

import (
	"fmt"
	"math"
	"math/rand"
	"sort"
	"strconv"
	"strings"
)

// ─── Shard assignment ─────────────────────────────────────────────────────────

// ShardIndices returns the indices in [0, total) owned by this shard, using a
// modulo stripe so every shard gets a representative mix of all rank buckets.
func ShardIndices(total, shardID, shardCount int) []int {
	out := make([]int, 0, total/shardCount+1)
	for i := shardID; i < total; i += shardCount {
		out = append(out, i)
	}
	return out
}

// ─── Zipf-weighted sampling ───────────────────────────────────────────────────

// ZipfSampler draws k distinct indices from a pool, with probability
// proportional to 1/(globalIdx+1)^alpha. Lower global indices (more popular
// symbols) are more likely to be selected.
type ZipfSampler struct {
	alpha float64
}

// NewZipfSampler creates a sampler with the given Zipf exponent.
func NewZipfSampler(alpha float64) *ZipfSampler {
	return &ZipfSampler{alpha: alpha}
}

// Sample draws k distinct elements from pool. pool contains global symbol indices;
// weights are computed from those indices so popularity ordering is preserved.
// The rng must not be shared across goroutines.
func (z *ZipfSampler) Sample(rng *rand.Rand, pool []int, k int) []int {
	n := len(pool)
	if k <= 0 {
		return nil
	}
	if k >= n {
		out := make([]int, n)
		copy(out, pool)
		return out
	}

	// Build normalised cumulative weights over the pool.
	cum := make([]float64, n)
	total := 0.0
	for _, idx := range pool {
		total += 1.0 / math.Pow(float64(idx+1), z.alpha)
	}
	c := 0.0
	for i, idx := range pool {
		c += 1.0 / math.Pow(float64(idx+1), z.alpha)
		cum[i] = c / total
	}

	picked := make(map[int]bool, k)
	result := make([]int, 0, k)
	maxTries := k * 30
	for len(result) < k && maxTries > 0 {
		maxTries--
		pos := sort.SearchFloat64s(cum, rng.Float64())
		if pos >= n {
			pos = n - 1
		}
		idx := pool[pos]
		if !picked[idx] {
			picked[idx] = true
			result = append(result, idx)
		}
	}
	// Safety: fill remaining slots sequentially in case of extreme alpha.
	for _, idx := range pool {
		if len(result) >= k {
			break
		}
		if !picked[idx] {
			picked[idx] = true
			result = append(result, idx)
		}
	}
	return result
}

// ─── Screen pools ─────────────────────────────────────────────────────────────

// Screen is a named range of symbol indices representing a UI page (home,
// trending, etc.). Users on this screen are biased toward these symbols.
type Screen struct {
	Name  string
	Start int // inclusive
	End   int // exclusive
}

// Indices returns all symbol indices within this screen, clamped to total.
func (s Screen) Indices(total int) []int {
	end := s.End
	if end > total {
		end = total
	}
	out := make([]int, 0, end-s.Start)
	for i := s.Start; i < end; i++ {
		out = append(out, i)
	}
	return out
}

// ParseScreens parses "home:0-49,trending:0-99,midcap:200-499".
// End indices in the spec are inclusive. Returns default screens when spec is empty.
func ParseScreens(spec string, totalSymbols int) ([]Screen, error) {
	if strings.TrimSpace(spec) == "" {
		return defaultScreens(totalSymbols), nil
	}
	var screens []Screen
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		colon := strings.Index(part, ":")
		if colon < 0 {
			return nil, fmt.Errorf("screen %q: missing ':'", part)
		}
		name := part[:colon]
		rangePart := part[colon+1:]
		dash := strings.Index(rangePart, "-")
		if dash < 0 {
			return nil, fmt.Errorf("screen %q: range %q missing '-'", name, rangePart)
		}
		start, err := strconv.Atoi(rangePart[:dash])
		if err != nil {
			return nil, fmt.Errorf("screen %q start: %v", name, err)
		}
		endInclusive, err := strconv.Atoi(rangePart[dash+1:])
		if err != nil {
			return nil, fmt.Errorf("screen %q end: %v", name, err)
		}
		end := endInclusive + 1
		if end > totalSymbols {
			end = totalSymbols
		}
		if start >= end {
			continue
		}
		screens = append(screens, Screen{name, start, end})
	}
	if len(screens) == 0 {
		return defaultScreens(totalSymbols), nil
	}
	return screens, nil
}

func defaultScreens(n int) []Screen {
	// Clamp to symbol count so small symbol pools still work.
	cap50 := 50
	if cap50 > n {
		cap50 = n
	}
	cap100 := 100
	if cap100 > n {
		cap100 = n
	}
	cap500 := 500
	if cap500 > n {
		cap500 = n
	}
	var screens []Screen
	if cap50 > 0 {
		screens = append(screens, Screen{"home", 0, cap50})
	}
	if cap100 > cap50 {
		screens = append(screens, Screen{"trending", 0, cap100})
	}
	if cap500 > cap100 {
		start := cap100
		screens = append(screens, Screen{"midcap", start, cap500})
	}
	if len(screens) == 0 {
		screens = append(screens, Screen{"all", 0, n})
	}
	return screens
}

// ─── Tick classes ─────────────────────────────────────────────────────────────

// TickClass defines a contiguous range of symbols (by rank) that all publish at
// the same tick rate. Rank 0 = most popular = highest rate.
type TickClass struct {
	Name  string
	Start int     // first global symbol index (inclusive)
	End   int     // exclusive
	Rate  float64 // ticks per second per symbol
}

// ParseTickClasses parses "hot:2%@30,warm:8%@8,cool:40%@1,cold:50%@0.1".
// Percentages are of totalSymbols. Any remainder goes to the last class.
func ParseTickClasses(spec string, totalSymbols int) ([]TickClass, error) {
	if strings.TrimSpace(spec) == "" {
		return defaultTickClasses(totalSymbols), nil
	}
	var classes []TickClass
	cursor := 0
	parts := strings.Split(spec, ",")
	for i, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		colon := strings.Index(part, ":")
		at := strings.Index(part, "@")
		if colon < 0 || at < 0 || at <= colon {
			return nil, fmt.Errorf("tick class %q: expected 'name:pct%%@rate'", part)
		}
		name := part[:colon]
		pctStr := strings.TrimSuffix(strings.TrimSpace(part[colon+1:at]), "%")
		rateStr := strings.TrimSpace(part[at+1:])
		pct, err := strconv.ParseFloat(pctStr, 64)
		if err != nil {
			return nil, fmt.Errorf("tick class %q pct: %v", name, err)
		}
		rate, err := strconv.ParseFloat(rateStr, 64)
		if err != nil {
			return nil, fmt.Errorf("tick class %q rate: %v", name, err)
		}
		count := int(math.Round(pct / 100.0 * float64(totalSymbols)))
		if count < 1 {
			count = 1
		}
		end := cursor + count
		// Last class absorbs any rounding remainder.
		if i == len(parts)-1 || end > totalSymbols {
			end = totalSymbols
		}
		if cursor < end {
			classes = append(classes, TickClass{name, cursor, end, rate})
		}
		cursor = end
		if cursor >= totalSymbols {
			break
		}
	}
	// Remaining symbols (rounding gaps) go to the last class.
	if cursor < totalSymbols && len(classes) > 0 {
		classes[len(classes)-1].End = totalSymbols
	}
	return classes, nil
}

func defaultTickClasses(n int) []TickClass {
	type tier struct {
		name string
		pct  float64
		rate float64
	}
	tiers := []tier{
		{"hot", 2, 30},
		{"warm", 8, 8},
		{"cool", 40, 1},
		{"cold", 50, 0.1},
	}
	var classes []TickClass
	cursor := 0
	for i, t := range tiers {
		count := int(math.Round(t.pct / 100.0 * float64(n)))
		if count < 1 {
			count = 1
		}
		end := cursor + count
		if i == len(tiers)-1 || end > n {
			end = n
		}
		if cursor < end {
			classes = append(classes, TickClass{t.name, cursor, end, t.rate})
		}
		cursor = end
		if cursor >= n {
			break
		}
	}
	return classes
}

// ─── Algo tiers ───────────────────────────────────────────────────────────────

// AlgoTier defines a contiguous range of algo users (by index) with matching
// order and trade publishing rates.
type AlgoTier struct {
	Name      string
	Start     int     // first algo user index (inclusive)
	End       int     // exclusive
	OrderRate float64 // orders per second per user
	TradeRate float64 // trades per second per user
}

// ParseAlgoTiers parses "hft:1%@2.0/1.0,mm:10%@0.5/0.3,retail:89%@0.05/0.02".
func ParseAlgoTiers(spec string, totalAlgoUsers int) ([]AlgoTier, error) {
	if strings.TrimSpace(spec) == "" {
		return defaultAlgoTiers(totalAlgoUsers), nil
	}
	var tiers []AlgoTier
	cursor := 0
	parts := strings.Split(spec, ",")
	for i, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		colon := strings.Index(part, ":")
		at := strings.Index(part, "@")
		slash := strings.LastIndex(part, "/")
		if colon < 0 || at < 0 || slash < 0 || at <= colon || slash <= at {
			return nil, fmt.Errorf("algo tier %q: expected 'name:pct%%@order_rate/trade_rate'", part)
		}
		name := part[:colon]
		pctStr := strings.TrimSuffix(strings.TrimSpace(part[colon+1:at]), "%")
		orderStr := strings.TrimSpace(part[at+1 : slash])
		tradeStr := strings.TrimSpace(part[slash+1:])

		pct, err := strconv.ParseFloat(pctStr, 64)
		if err != nil {
			return nil, fmt.Errorf("algo tier %q pct: %v", name, err)
		}
		orderRate, err := strconv.ParseFloat(orderStr, 64)
		if err != nil {
			return nil, fmt.Errorf("algo tier %q order rate: %v", name, err)
		}
		tradeRate, err := strconv.ParseFloat(tradeStr, 64)
		if err != nil {
			return nil, fmt.Errorf("algo tier %q trade rate: %v", name, err)
		}
		count := int(math.Round(pct / 100.0 * float64(totalAlgoUsers)))
		if count < 1 {
			count = 1
		}
		end := cursor + count
		if i == len(parts)-1 || end > totalAlgoUsers {
			end = totalAlgoUsers
		}
		if cursor < end {
			tiers = append(tiers, AlgoTier{name, cursor, end, orderRate, tradeRate})
		}
		cursor = end
		if cursor >= totalAlgoUsers {
			break
		}
	}
	if cursor < totalAlgoUsers && len(tiers) > 0 {
		tiers[len(tiers)-1].End = totalAlgoUsers
	}
	return tiers, nil
}

func defaultAlgoTiers(n int) []AlgoTier {
	type tier struct {
		name             string
		pct, order, trade float64
	}
	defs := []tier{
		{"hft", 1, 2.0, 1.0},
		{"mm", 10, 0.5, 0.3},
		{"retail", 89, 0.05, 0.02},
	}
	var tiers []AlgoTier
	cursor := 0
	for i, d := range defs {
		count := int(math.Round(d.pct / 100.0 * float64(n)))
		if count < 1 {
			count = 1
		}
		end := cursor + count
		if i == len(defs)-1 || end > n {
			end = n
		}
		if cursor < end {
			tiers = append(tiers, AlgoTier{d.name, cursor, end, d.order, d.trade})
		}
		cursor = end
		if cursor >= n {
			break
		}
	}
	return tiers
}
