// anyone-cover-demo exercises zkAPI's existing bounded HTTPS cover runner
// through the Anyone SOCKS listener. It is not a paid inference client and
// makes no network requests in -check mode.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ethereum/zkapi/zkapi-clientd/internal/cover"
)

const endpoint = "tor://127.0.0.1:9150"

func main() {
	url := flag.String("url", "", "small static HTTPS resource you control or have permission to poll")
	rate := flag.Float64("rate", 0.15, "average requests per second (maximum 5)")
	duration := flag.Duration("duration", 45*time.Second, "maximum duration, 15s to 2m")
	check := flag.Bool("check", false, "validate configuration without making network requests")
	flag.Parse()

	if len(strings.Fields(*url)) != 1 || *duration < 15*time.Second || *duration > 2*time.Minute {
		fmt.Fprintln(os.Stderr, "Provide exactly one authorised HTTPS URL and a duration between 15s and 2m.")
		os.Exit(2)
	}
	cfg := cover.Config{Rate: *rate, Concurrency: 1, URLs: *url}
	if err := cfg.Validate(endpoint); err != nil {
		fmt.Fprintln(os.Stderr, "Invalid cover configuration:", err)
		os.Exit(2)
	}
	if *check {
		fmt.Println("PASS: cover configuration accepted; NO NETWORK REQUESTS SENT")
		fmt.Printf("route=%s, rate=%.2f requests/s, max_duration=%s\n", endpoint, *rate, *duration)
		return
	}

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	ctx, cancel := context.WithTimeout(ctx, *duration)
	defer cancel()

	runner, err := cover.Start(ctx, cfg, endpoint)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Failed to start cover traffic:", err)
		os.Exit(1)
	}
	fmt.Println("[COVER] Running bounded HTTPS noise through Anyone with independent SOCKS authentication")
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			stats := runner.Stats()
			fmt.Printf("[COVER] attempted=%d succeeded=%d failed=%d skipped=%d bytes=%d\n", stats.Attempted, stats.Succeeded, stats.Failed, stats.Skipped, stats.Bytes)
		case <-ctx.Done():
			runner.Close()
			stats := runner.Stats()
			fmt.Printf("[COVER FINISHED] attempted=%d succeeded=%d failed=%d skipped=%d bytes=%d\n", stats.Attempted, stats.Succeeded, stats.Failed, stats.Skipped, stats.Bytes)
			return
		}
	}
}
