// Refresh Google identity for the two Solo gateway providers at request time.
// Do not use the inherited GCLOUD_IDENTITY_TOKEN: OpenCode loads config once,
// so that value otherwise expires while a long coding session is still open.
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);
const providers = new Set(["solo-fireworks", "solo-claude"]);
const gateway = "https://agentgateway-llm-front.is.solo.io/inference/v1";
let cached = "", expires = 0, pending;

async function identity() {
  if (cached && expires > Date.now() / 1000 + 90) return cached;
  if (!pending) pending = (async () => {
    const env = { ...process.env };
    delete env.GOOGLE_CLOUD_UNIVERSE_DOMAIN;
    delete env.CLOUDSDK_CORE_UNIVERSE_DOMAIN;
    const account = process.env.SOLO_GCLOUD_ACCOUNT || "tom.orourke@solo.io";
    const configuration = process.env.SOLO_GCLOUD_CONFIGURATION || "default";
    try {
      const { stdout } = await exec(process.env.SOLO_GCLOUD_BIN || "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
        [`--configuration=${configuration}`, `--account=${account}`, "auth", "print-identity-token"],
        { env, timeout: 30000, maxBuffer: 65536 });
      const token = stdout.trim();
      const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
      if (!(claims.exp > Date.now() / 1000 + 60) || claims.email !== account) {
        throw new Error("Unexpected identity or expiry");
      }
      cached = token;
      expires = claims.exp;
      return token;
    } catch {
      // Never log the bearer token or a subprocess result carrying it.
      throw new Error(`Solo gateway identity refresh failed. Run: gcloud --configuration=${configuration} auth login --account=${account}`);
    }
  })().finally(() => { pending = undefined; });
  return pending;
}

export default async () => ({
  "chat.headers": async (input, output) => {
    if (!providers.has(input.model.providerID)) return;
    if (String(input.provider.options.baseURL || "").replace(/\/$/, "") !== gateway) {
      throw new Error("Solo identity plugin refused an unexpected gateway URL");
    }
    // HTTP header names are case-insensitive; remove alternate casing first.
    for (const key of Object.keys(output.headers)) {
      if (key.toLowerCase() === "authorization") delete output.headers[key];
    }
    output.headers.Authorization = "Bearer " + await identity();
  },
});
