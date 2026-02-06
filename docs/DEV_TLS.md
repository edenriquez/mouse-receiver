# Development TLS Setup

This project uses **mutual TLS** and **certificate pinning** (SHA-256 of the peer certificate) for development.

## Generate a local CA

```sh
openssl genrsa -out inputshare-dev-ca.key 4096
openssl req -x509 -new -nodes -key inputshare-dev-ca.key -sha256 -days 3650 -out inputshare-dev-ca.crt -subj "/CN=InputShare Dev CA"
```

## Generate a certificate for a device

Choose a unique common name per machine.

```sh
CN="InputShare Device A"
openssl genrsa -out device-a.key 2048
openssl req -new -key device-a.key -out device-a.csr -subj "/CN=$CN"
openssl x509 -req -in device-a.csr -CA inputshare-dev-ca.crt -CAkey inputshare-dev-ca.key -CAcreateserial -out device-a.crt -days 825 -sha256
```

## Export as PKCS#12 (.p12)

```sh
openssl pkcs12 -export -inkey device-a.key -in device-a.crt -certfile inputshare-dev-ca.crt -out device-a.p12
```

## Compute the pin (SHA-256 of peer certificate)

The CLI expects `--pin-sha256` as the **lowercase hex** SHA-256 of the peer leaf certificate DER.

```sh
openssl x509 -in device-a.crt -outform der | shasum -a 256 | awk '{print $1}'
```

## Run

Receiver:

```sh
swift run inputshare receive --port 4242 --identity-p12 device-a.p12 --identity-pass <p12-pass> --pin-sha256 <peer-cert-sha256>
```

Sender:

```sh
swift run inputshare send --host <receiver-ip> --port 4242 --identity-p12 device-b.p12 --identity-pass <p12-pass> --pin-sha256 <peer-cert-sha256>
```

## Notes

- Both sides must present a client certificate (mutual TLS).
- Both sides must provide the peer pin; otherwise the TLS verify block rejects the connection.
- This is development tooling only; production pairing should move long-term identity keys into Keychain.
