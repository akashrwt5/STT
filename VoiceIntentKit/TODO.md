# VoiceIntentKit Technical Debt & TODOs

## Security
- [ ] **Enforce Ed25519 Cryptographic Signatures** (Target: v1.1 or v2.0)
  - **Context:** During the MVP phase, we made `trustedPublicKeyBase64` optional to unblock development and simplify the initial release. Currently, the SDK only validates SHA256 checksums (integrity) but skips signature verification (authenticity) if the public key is omitted.
  - **Action Item:** Make `trustedPublicKeyBase64` mandatory in `PackValidator`. Inject the official production public key from the backend to ensure malicious OTA payloads intercepted via MITM attacks are rejected.
