#!/bin/bash
# ==============================================================================
# SCRIPT COMPACT D'AUTOMATISATION DE LA PKI ENVIRO-LOCAL
# ==============================================================================
set -euo pipefail

PKI_DIR="pki"
CONFIG_FILE="$PKI_DIR/openssl.cnf"

log() { echo -e "\033[0;34m[*] $1\033[0m"; }
success() { echo -e "\033[0;32m[✓] $1\033[0m"; }

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erreur : $CONFIG_FILE introuvable." && exit 1
fi

# 1. INITIALISATION DE L'ARBORESCENCE
log "Initialisation des répertoires et fichiers d'état..."
[ -d "$PKI_DIR" ] && find "$PKI_DIR" -type f ! -name 'openssl.cnf' -delete
mkdir -p "$PKI_DIR"/{root,intermediate,certs,csr,crl}
chmod 700 "$PKI_DIR/root" "$PKI_DIR/intermediate"

touch "$PKI_DIR/root/index.txt" "$PKI_DIR/intermediate/index.txt"
echo 1000 > "$PKI_DIR/root/serial"
echo 1000 > "$PKI_DIR/intermediate/serial"
echo 1000 > "$PKI_DIR/intermediate/crlnumber"

# 2. CONFIGURATION DES EXTENSIONS TEMPORAIRES
cat <<EOF > "$PKI_DIR/pki_extensions.cnf"
[v3_root]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, cRLSign, keyCertSign

[v3_inter]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, cRLSign, keyCertSign

[server_ext]
basicConstraints = CA:FALSE
nsCertType = server
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = DNS:localhost,IP:127.0.0.1

[client_ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[codesign_ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# 3. GÉNÉRATION DE LA CA RACINE (ROOT CA)
log "Génération de la CA Racine (RSA 4096)..."
openssl genrsa -out "$PKI_DIR/root/root.key" 4096 2>/dev/null
chmod 400 "$PKI_DIR/root/root.key"
openssl req -config "$CONFIG_FILE" -new -sha256 -subj "/C=MG/O=EnviroLocal/CN=Root CA" -key "$PKI_DIR/root/root.key" -out "$PKI_DIR/csr/root.csr"
openssl x509 -req -days 3650 -in "$PKI_DIR/csr/root.csr" -signkey "$PKI_DIR/root/root.key" -extfile "$PKI_DIR/pki_extensions.cnf" -extensions v3_root -out "$PKI_DIR/root/root.crt" 2>/dev/null

# 4. GÉNÉRATION DE LA CA INTERMÉDIAIRE
log "Génération de la CA Intermédiaire (RSA 2048)..."
openssl genrsa -out "$PKI_DIR/intermediate/intermediate.key" 2048 2>/dev/null
chmod 400 "$PKI_DIR/intermediate/intermediate.key"
openssl req -config "$CONFIG_FILE" -new -sha256 -subj "/C=MG/O=EnviroLocal/CN=Intermediate CA" -key "$PKI_DIR/intermediate/intermediate.key" -out "$PKI_DIR/csr/intermediate.csr"
openssl x509 -req -in "$PKI_DIR/csr/intermediate.csr" -CA "$PKI_DIR/root/root.crt" -CAkey "$PKI_DIR/root/root.key" -CAcreateserial -extfile "$PKI_DIR/pki_extensions.cnf" -extensions v3_inter -days 1825 -sha256 -out "$PKI_DIR/intermediate/intermediate.crt" 2>/dev/null

# Consolidation de la chaîne de confiance publique
cat "$PKI_DIR/intermediate/intermediate.crt" "$PKI_DIR/root/root.crt" > "$PKI_DIR/certs/ca-chain.pem"

# 5. ÉMISSION DES CERTIFICATS FEUILLES
log "Émission des certificats finaux (Serveur, Client, CodeSign)..."
for type in server client codesign; do
    openssl genrsa -out "$PKI_DIR/certs/$type.key" 2048 2>/dev/null
    openssl req -config "$CONFIG_FILE" -new -sha256 -subj "/C=MG/CN=$type" -key "$PKI_DIR/certs/$type.key" -out "$PKI_DIR/csr/$type.csr"
    openssl ca -config "$CONFIG_FILE" -batch -extfile "$PKI_DIR/pki_extensions.cnf" -extensions "${type}_ext" -days 365 -in "$PKI_DIR/csr/$type.csr" -out "$PKI_DIR/certs/$type.crt" 2>/dev/null
done

# 6. VÉRIFICATION DE LA CHAÎNE ET CRÉATION CRL
log "Validation et gestion des révocations..."
openssl verify -CAfile "$PKI_DIR/certs/ca-chain.pem" "$PKI_DIR/certs/server.crt" > /dev/null

# Simulation de révocation (Client TLS) et génération de la CRL
openssl ca -config "$CONFIG_FILE" -batch -revoke "$PKI_DIR/certs/client.crt" 2>/dev/null
openssl ca -config "$CONFIG_FILE" -gencrl -out "$PKI_DIR/crl/intermediate.crl" 2>/dev/null

# Nettoyage
rm -f "$PKI_DIR/pki_extensions.cnf"

success "Pipeline exécuté avec succès. Fichiers opérationnels dans ./$PKI_DIR/"
