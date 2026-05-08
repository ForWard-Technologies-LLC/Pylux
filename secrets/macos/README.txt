macOS signing & notarization

One credentials file for both local build and GitHub Actions setup:
  credentials.env     - Your values (gitignored)

GitHub Actions:
  github-actions/ForwardTechLLCCert.p12 - Your .p12 certificate

Local build: ./scripts/build-macos.sh auto-loads credentials.env if present.

CLI overrides (file can stay in place):
  --no-notarize           Skip notarization (still Developer ID if MACOS_SIGN_ID set)
  --ad-hoc                Ad-hoc sign only; ignores MACOS_SIGN_ID from the file
  --skip-notary-keychain  Skip notarytool store-credentials
  --no-credentials-file   Do not load credentials.env (use env exports only, or ad-hoc)

GitHub Secrets (Settings → Secrets and variables → Actions):
  MACOS_CERTIFICATE_P12_BASE64  = base64 -i secrets/macos/github-actions/ForwardTechLLCCert.p12 | pbcopy
  MACOS_CERTIFICATE_PASSWORD    = from credentials.env
  APPLE_ID                      = from credentials.env
  APPLE_APP_SPECIFIC_PASSWORD   = from credentials.env
  APPLE_TEAM_ID                 = from credentials.env (KG7LUU8FX7)
