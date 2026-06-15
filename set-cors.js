const { execSync } = require('child_process');
const https = require('https');

// Get Firebase access token
let token;
try {
  token = execSync('firebase login:ci --no-localhost 2>nul', { timeout: 5000 }).toString().trim();
} catch (_) {}

// Use gcloud application-default credentials via firebase CLI token
// Instead, use the Storage JSON API with a service account key or use firebase-admin

// Simpler: write cors.json and call gsutil via npm package
const cors = [
  {
    origin: ["*"],
    method: ["GET", "HEAD", "PUT", "POST", "DELETE", "OPTIONS"],
    responseHeader: [
      "Content-Type",
      "Authorization",
      "Content-Length",
      "User-Agent",
      "x-goog-resumable",
      "x-goog-meta-firebaseStorageDownloadTokens"
    ],
    maxAgeSeconds: 3600
  }
];

require('fs').writeFileSync('cors.json', JSON.stringify(cors, null, 2));
console.log('cors.json written');
