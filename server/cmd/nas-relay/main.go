package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/imstevelin/nas-archive-relay/server/internal/relay"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

type endpoints []string

func (e *endpoints) String() string     { return fmt.Sprint([]string(*e)) }
func (e *endpoints) Set(v string) error { *e = append(*e, v); return nil }
func fail(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
func printJSON(v any) { b, err := json.MarshalIndent(v, "", "  "); fail(err); fmt.Println(string(b)) }
func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: nas-relay init|serve|client|certificate-renew|info|version [options]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(relay.Version)
	case "init":
		f := flag.NewFlagSet("init", flag.ExitOnError)
		data := f.String("data", relay.DefaultDataRoot(), "state directory")
		name := f.String("name", "NAS Relay", "server display name")
		port := f.String("port", "8743", "API port")
		var addresses endpoints
		f.Var(&addresses, "endpoint", "advertised HTTPS URL (repeatable)")
		_ = f.Parse(os.Args[2:])
		if len(addresses) == 0 {
			addresses = relay.AutoEndpoints(*port)
		}
		_, existing := os.Stat(filepath.Join(*data, "config.json"))
		s, err := relay.Initialize(*data, *name, addresses)
		fail(err)
		if existing == nil {
			printJSON(map[string]any{"initialized": true, "server_id": s.Snapshot().ID, "message": "Existing credentials preserved. Use: nas-relay client add --role admin"})
			return
		}
		c, err := s.AddClient("Administrator", "admin")
		fail(err)
		fmt.Println("Server initialized. Keep this connection information private:")
		fmt.Println(relay.ConnectionURI(c))
		printJSON(c)
	case "certificate-renew":
		f := flag.NewFlagSet("certificate-renew", flag.ExitOnError)
		data := f.String("data", relay.DefaultDataRoot(), "state directory")
		_ = f.Parse(os.Args[2:])
		s, err := relay.Open(*data)
		fail(err)
		fail(s.RenewCertificate())
		fmt.Println("Certificate renewed. Restart the service and import updated connection information on each client.")
	case "discover":
		f := flag.NewFlagSet("discover", flag.ExitOnError)
		port := f.String("port", "8743", "API port")
		_ = f.Parse(os.Args[2:])
		for _, ep := range relay.AutoEndpoints(*port) {
			fmt.Println(ep)
		}
	case "info":
		f := flag.NewFlagSet("info", flag.ExitOnError)
		data := f.String("data", relay.DefaultDataRoot(), "state directory")
		field := f.String("field", "", "name, endpoints, or data")
		_ = f.Parse(os.Args[2:])
		s, err := relay.Open(*data)
		fail(err)
		c := s.Snapshot()
		if *field != "" {
			switch *field {
			case "name":
				fmt.Println(c.Name)
			case "endpoints":
				for _, ep := range c.Endpoints {
					fmt.Println(ep)
				}
			case "data":
				fmt.Println(s.Root)
			default:
				log.Fatal("unknown info field")
			}
			return
		}
		printJSON(map[string]any{"server_id": c.ID, "name": c.Name, "endpoints": c.Endpoints, "version": relay.Version})
	case "client":
		if len(os.Args) < 3 {
			log.Fatal("Usage: nas-relay client add|list|revoke")
		}
		f := flag.NewFlagSet("client", flag.ExitOnError)
		data := f.String("data", relay.DefaultDataRoot(), "state directory")
		name := f.String("name", "New client", "client name")
		role := f.String("role", "client", "admin or client")
		id := f.String("id", "", "client id to revoke")
		_ = f.Parse(os.Args[3:])
		s, err := relay.Open(*data)
		fail(err)
		switch os.Args[2] {
		case "add":
			c, err := s.AddClient(*name, *role)
			fail(err)
			fmt.Println(relay.ConnectionURI(c))
		case "list":
			clients := s.Snapshot().Clients
			for i := range clients {
				clients[i].TokenHash = ""
			}
			printJSON(clients)
		case "revoke":
			if *id == "" {
				log.Fatal("--id is required")
			}
			fail(s.SaveConfig(func(c *relay.Config) error {
				for i := range c.Clients {
					if c.Clients[i].ID == *id {
						c.Clients[i].Revoked = true
						return nil
					}
				}
				return os.ErrNotExist
			}))
			fmt.Println("Client revoked")
		default:
			log.Fatal("unknown client command")
		}
	case "serve":
		f := flag.NewFlagSet("serve", flag.ExitOnError)
		data := f.String("data", relay.DefaultDataRoot(), "state directory")
		listen := f.String("listen", ":8743", "HTTPS listen address")
		_ = f.Parse(os.Args[2:])
		s, err := relay.Open(*data)
		fail(err)
		lock, err := os.OpenFile(filepath.Join(*data, "server.lock"), os.O_CREATE|os.O_RDWR, 0600)
		fail(err)
		defer lock.Close()
		fail(syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
		a := relay.NewServer(s)
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer cancel()
		server := &http.Server{Addr: *listen, Handler: a.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second, MaxHeaderBytes: 32 << 10, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13}}
		go a.Run(ctx)
		go func() {
			<-ctx.Done()
			c, done := context.WithTimeout(context.Background(), 20*time.Second)
			defer done()
			_ = server.Shutdown(c)
		}()
		log.Printf("NAS Relay %s listening on %s", relay.Version, *listen)
		err = server.ListenAndServeTLS(filepath.Join(*data, "server.crt"), filepath.Join(*data, "server.key"))
		if err != nil && err != http.ErrServerClosed {
			fail(err)
		}
	default:
		log.Fatal("unknown command")
	}
}
