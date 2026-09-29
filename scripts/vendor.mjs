// Copia as bibliotecas de node_modules para www/vendor (o app funciona sem CDN, inclusive offline)
import { copyFileSync, mkdirSync } from "node:fs";
const out = "www/vendor";
mkdirSync(out, { recursive: true });
const files = {
  "node_modules/@supabase/supabase-js/dist/umd/supabase.js": "supabase.js",
  "node_modules/xlsx/dist/xlsx.full.min.js": "xlsx.full.min.js",
  "node_modules/jspdf/dist/jspdf.umd.min.js": "jspdf.umd.min.js",
  "node_modules/qrcode-generator/qrcode.js": "qrcode.js",
};
for (const [src, dst] of Object.entries(files)) {
  copyFileSync(src, `${out}/${dst}`);
  console.log(`vendor/${dst}`);
}
