Android Google Play & GitHub Actions Secrets
=============================================

Two sets of secrets are needed:
  1. Upload signing key — Google Play requires AABs signed with an upload key
  2. Service account JSON — authorizes the API upload to Google Play

Local files (gitignored — place in this folder):
  1. release.jks             Your upload keystore (.jks or .keystore)
  2. play-credentials.json   Google Play API service account key

GitHub Actions secrets (Settings > Secrets and variables > Actions):
  1. GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64   base64 of play-credentials.json
  2. ANDROID_KEYSTORE_BASE64                   base64 of the upload keystore
  3. ANDROID_KEYSTORE_PASSWORD                 keystore password
  4. ANDROID_KEY_ALIAS                         key alias inside the keystore
  5. ANDROID_KEY_PASSWORD                      key password

How to generate base64 values:
  base64 -i secrets/android/play-credentials.json | tr -d '\n' | pbcopy
  base64 -i secrets/android/release.jks | tr -d '\n' | pbcopy

Where to get the service account JSON:
  1. Google Play Console > Setup > API access
  2. Link or create a Google Cloud project
  3. Create a Service Account (or use existing one)
  4. Grant "Release manager" permissions in Play Console
  5. Download the JSON key file

Where to get the upload keystore:
  If Google Play App Signing is managing your key, you still need
  an upload key. Check your local android/local.properties for the
  chiakiKeystore path, or create a new one:
    keytool -genkey -v -keystore release.jks \
      -keyalg RSA -keysize 2048 -validity 10000 -alias <alias>
