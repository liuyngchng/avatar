// Package certgen generates self-signed TLS certificates for local
// and LAN deployment. Self-signed certs let the server serve HTTPS so
// browsers grant microphone access (getUserMedia requires a secure context).
package certgen

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"time"
)

// Generate writes a self-signed TLS certificate and private key to the
// given paths. The certificate covers the given hosts and IPs so that
// browsers can validate it against the address they used to connect.
func Generate(certPath, keyPath string, hosts []string, ips []net.IP) error {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("certgen: generate key: %w", err)
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("certgen: serial: %w", err)
	}

	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "Avatar Web",
			Organization: []string{"Avatar Web Local"},
		},
		NotBefore: time.Now().Add(-time.Hour),
		NotAfter:  time.Now().AddDate(10, 0, 0), // 10 years

		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,

		DNSNames:    hosts,
		IPAddresses: ips,
	}

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return fmt.Errorf("certgen: create cert: %w", err)
	}

	certOut, err := os.OpenFile(certPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("certgen: open cert file: %w", err)
	}
	defer certOut.Close()
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		return fmt.Errorf("certgen: encode cert: %w", err)
	}

	keyOut, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("certgen: open key file: %w", err)
	}
	defer keyOut.Close()

	keyBytes, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return fmt.Errorf("certgen: marshal key: %w", err)
	}
	if err := pem.Encode(keyOut, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}); err != nil {
		return fmt.Errorf("certgen: encode key: %w", err)
	}

	return nil
}

// LocalIPs returns all non-loopback IPv4 addresses on this machine, used
// as SAN entries so clients on the LAN can connect via the server's IP.
func LocalIPs() []net.IP {
	var ips []net.IP
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ips
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok {
			if ip4 := ipnet.IP.To4(); ip4 != nil && !ip4.IsLoopback() {
				ips = append(ips, ip4)
			}
		}
	}
	return ips
}