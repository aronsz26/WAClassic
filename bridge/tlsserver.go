package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// tlsServer for away from home. iOS 6 only does TLS <= 1.2 with CBC,
// iOS 4 has no ECDHE at all. self-signed cert, app pins the sha256.
func tlsServer(dataDir, addr string, h http.Handler) (*http.Server, string, error) {
	cert, err := loadOrCreateCert(dataDir)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(cert.Certificate[0])
	fingerprint := hex.EncodeToString(sum[:])
	os.WriteFile(filepath.Join(dataDir, "tls.sha256"), []byte(fingerprint+"\n"), 0o600)
	srv := &http.Server{
		Addr:    addr,
		Handler: h,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS10,
			// TLSFix (Skyglow) puts openssl 1.1.1 into every app. its tls 1.3 breaks with go
			// ("bad record MAC"), 1.2 works. ios 4-6 itself never goes above 1.2 anyway
			MaxVersion: tls.VersionTLS12,
			CipherSuites: []uint16{
				tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
				tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
				tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
				tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
				tls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
				tls.TLS_RSA_WITH_AES_128_CBC_SHA, // iOS 4
				tls.TLS_RSA_WITH_AES_256_CBC_SHA, // iOS 4
			},
		},
		ReadHeaderTimeout: 20 * time.Second,
		ErrorLog:          log.New(countingLog{}, "", log.LstdFlags),
	}
	return srv, fingerprint, nil
}

func loadOrCreateCert(dataDir string) (tls.Certificate, error) {
	certPath, keyPath := filepath.Join(dataDir, "tls.crt"), filepath.Join(dataDir, "tls.key")
	if c, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		return c, nil
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "WA4S bridge"},
		NotBefore:             time.Now().Add(-24 * time.Hour),
		NotAfter:              time.Now().AddDate(20, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		SignatureAlgorithm:    x509.SHA256WithRSA,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return tls.Certificate{}, err
	}
	return tls.X509KeyPair(certPEM, keyPEM)
}
