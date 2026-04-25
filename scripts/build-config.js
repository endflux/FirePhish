require('dotenv').config();
const fs = require('fs');
const path = require('path');

const config = {
  CLOUD_RUN_URL: process.env.CLOUD_RUN_URL || '',
  API_KEY:       process.env.API_KEY       || '',
  TARGET_URL:    process.env.TARGET_URL    || 'https://microsoft.com/devicelogin',
};

const out = path.join(__dirname, '..', 'public', 'config.js');
fs.writeFileSync(out, `window.__CONFIG__ = ${JSON.stringify(config, null, 2)};\n`);
console.log('config.js written →', out);
