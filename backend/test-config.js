const fs = require("fs");

const ENV_FILE = ".env";

const SECRET_KEYS = new Set([
  "GEMINI_API_KEY",
  "HF_TOKEN",
  "OPENROUTER_API_KEY",
  "DEEPGRAM_API_KEY",
  "FISH_AUDIO_API_KEY",
  "DEEPSEEK_API_KEY",
  "OPENAI_API_KEY",
]);

if (!fs.existsSync(ENV_FILE)) {
  console.error("❌ .env file nahi mili.");
  process.exit(1);
}

const text = fs.readFileSync(ENV_FILE, "utf8");

const lines = text.split(/\r?\n/);
const entries = new Map();
const duplicates = [];

for (const rawLine of lines) {
  const line = rawLine.trim();

  if (!line || line.startsWith("#")) continue;

  const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
  if (!match) continue;

  const key = match[1];
  const value = match[2];

  if (entries.has(key)) {
    duplicates.push(key);
  }

  entries.set(key, value);
}

console.log("\n==============================");
console.log(" ChaTG .env CONFIG TEST");
console.log("==============================\n");

console.log(`Total entries found: ${entries.size}`);

const uniqueDuplicates = [...new Set(duplicates)];

if (uniqueDuplicates.length > 0) {
  console.log("\n⚠️ DUPLICATE ENTRIES:");
  for (const key of uniqueDuplicates) {
    console.log(`  - ${key}`);
  }
} else {
  console.log("\n✅ No duplicate variable names found.");
}

console.log("\n🔐 SECRET STATUS:");

for (const key of SECRET_KEYS) {
  if (!entries.has(key)) {
    console.log(`  ❌ ${key} -> MISSING`);
    continue;
  }

  const value = entries.get(key);

  if (!value || value.trim() === "") {
    console.log(`  ⚠️ ${key} -> EMPTY`);
  } else {
    console.log(`  ✅ ${key} -> PRESENT (hidden)`);
  }
}

console.log("\n🤖 MODEL / CONFIG ENTRIES:");

for (const [key, value] of entries) {
  if (
    key.endsWith("_MODEL") ||
    key === "EMBEDDING_MODEL" ||
    key === "DOTS_MODEL"
  ) {
    const shownValue = value.trim() || "[EMPTY]";
    console.log(`  ${key} = ${shownValue}`);
  }
}

console.log("\n==============================");
console.log(" Test complete");
console.log("==============================\n");