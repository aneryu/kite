package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/aneryu/kite/signal"
)

func main() {
	port := flag.Int("port", 8080, "port to listen on")
	staticDir := flag.String("static", "", "static files directory (overrides embedded files)")
	flag.Parse()

	tm := signal.NewTopicManager()

	// Background cleanup goroutine
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			tm.CleanupStale()
		}
	}()

	handler := signal.NewHandler(tm, *staticDir)

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("signal server listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatal(err)
	}
}
