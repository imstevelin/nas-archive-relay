package relay

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func Initialize(root, name string, endpoints []string) (*Store, error) {
	if _, err := os.Stat(filepath.Join(root, "config.json")); err == nil {
		return Open(root)
	}
	if len(endpoints) == 0 {
		return nil, errors.New("at least one HTTPS endpoint is required")
	}
	for _, v := range endpoints {
		u, err := url.Parse(v)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
			return nil, errors.New("invalid HTTPS endpoint")
		}
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(root, 0700); err != nil {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	cert := x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(1, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
	for _, ep := range endpoints {
		u, _ := url.Parse(ep)
		host := u.Hostname()
		if ip := net.ParseIP(host); ip != nil {
			cert.IPAddresses = append(cert.IPAddresses, ip)
		} else {
			cert.DNSNames = append(cert.DNSNames, host)
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, &cert, &cert, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	if err = os.WriteFile(filepath.Join(root, "server.crt"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		return nil, err
	}
	if err = os.WriteFile(filepath.Join(root, "server.key"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), 0600); err != nil {
		return nil, err
	}
	c := Config{ID: NewID(), Name: name, Endpoints: endpoints, ReserveBytes: 10 << 30, Workers: 1, Clients: []Client{}, Targets: []Target{}}
	if err = atomicJSON(filepath.Join(root, "config.json"), c); err != nil {
		return nil, err
	}
	return Open(root)
}
func (s *Store) AddClient(name, role string) (Connection, error) {
	if name == "" || (role != "admin" && role != "client") {
		return Connection{}, errors.New("invalid client name/role")
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return Connection{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	client := Client{ID: NewID(), Name: name, Role: role, TokenHash: Hash([]byte(token)), Created: time.Now().UnixMilli()}
	if err := s.SaveConfig(func(c *Config) error { c.Clients = append(c.Clients, client); return nil }); err != nil {
		return Connection{}, err
	}
	b, err := os.ReadFile(filepath.Join(s.Root, "server.crt"))
	if err != nil {
		return Connection{}, err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return Connection{}, errors.New("invalid server certificate")
	}
	c := s.Snapshot()
	return Connection{Schema: 1, ServerID: c.ID, Name: c.Name, Endpoints: c.Endpoints, Fingerprint: Hash(block.Bytes), Certificate: base64.StdEncoding.EncodeToString(block.Bytes), Token: token, ClientID: client.ID, Role: role}, nil
}
func (s *Store) Authenticate(token string) (Client, bool) {
	var current Config
	if readJSON(filepath.Join(s.Root, "config.json"), &current) != nil {
		return Client{}, false
	}
	hash := Hash([]byte(token))
	for _, c := range current.Clients {
		if !c.Revoked && subtle.ConstantTimeCompare([]byte(hash), []byte(c.TokenHash)) == 1 {
			return c, true
		}
	}
	return Client{}, false
}
func ConnectionURI(c Connection) string {
	b, _ := json.Marshal(c)
	return "nasrelay://connect?data=" + base64.RawURLEncoding.EncodeToString(b)
}
func AutoEndpoints(port string) []string {
	result := []string{}
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || strings.HasPrefix(iface.Name, "docker") || strings.HasPrefix(iface.Name, "veth") || strings.HasPrefix(iface.Name, "br-") {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, a := range addresses {
			ip, _, err := net.ParseCIDR(a.String())
			if err == nil && ip.To4() != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
				result = append(result, "https://"+net.JoinHostPort(ip.String(), port))
			}
		}
	}
	if len(result) == 0 {
		result = []string{"https://127.0.0.1:" + port}
	}
	return result
}

// RenewCertificate requires the service to be stopped. Existing job IDs and client tokens remain valid.
func (s *Store) RenewCertificate() error {
	lock, err := os.OpenFile(filepath.Join(s.Root, "server.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("stop the relay service before renewing its certificate")
	}
	temp, err := os.MkdirTemp(s.Root, ".certificate-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	c := s.Snapshot()
	if _, err = Initialize(temp, c.Name, c.Endpoints); err != nil {
		return err
	}
	oldCert, err := os.ReadFile(filepath.Join(s.Root, "server.crt"))
	if err != nil {
		return err
	}
	oldKey, err := os.ReadFile(filepath.Join(s.Root, "server.key"))
	if err != nil {
		return err
	}
	for _, name := range []string{"server.crt", "server.key"} {
		if err = os.Rename(filepath.Join(temp, name), filepath.Join(s.Root, name)); err != nil {
			_ = os.WriteFile(filepath.Join(s.Root, "server.crt"), oldCert, 0600)
			_ = os.WriteFile(filepath.Join(s.Root, "server.key"), oldKey, 0600)
			return err
		}
	}
	return nil
}

// DefaultDataRoot follows the root-owned installer pointer for custom storage locations.
func DefaultDataRoot() string { return defaultDataRootFromFile("/etc/nas-archive-relay/data-path") }
func defaultDataRootFromFile(pointer string) string {
	b, err := os.ReadFile(pointer)
	if err == nil {
		value := strings.TrimSuffix(strings.TrimSuffix(string(b), "\n"), "\r")
		if filepath.IsAbs(value) && value != "/" && !strings.ContainsAny(value, "\x00\r\n") {
			return value
		}
	}
	return "/var/lib/nas-archive-relay"
}
