# flop-devnet-starter

One bash script that takes you from nothing to an inference call on the [FLOP devnet](https://explorer.devnet.flop.network), using only the official `@flop-labs/cli`, the public gateway and the hosted MCP server.

> **Devnet only.** Devnet FLOP has no value and earns no rewards or airdrop weight. The chain may be reset. Never use a seed phrase or a key that holds real funds with this script.

## What it does

| Step | Command | What happens |
|---|---|---|
| 1 | `./flop-devnet.sh init` | Generates a new **sr25519** agent key in an encrypted Polkadot keystore at `~/.flop-devnet/` (outside the repo). The password is random and stored in a file only you can read. |
| 2 | `./flop-devnet.sh fund` | Requests test FLOP for **your keystore key** from `faucet.flop.network` (needed for `direct`). The CLI checks the faucet's and the RPC's chain identity first. Retries every 60 s while the faucet is busy. |
| 3 | `./flop-devnet.sh credential` | `flop agent credential`: a wallet-signed enrollment for a devnet gateway API key. **The CLI uses its own wallet for this, not your keystore** (see Known issues). Retries while the faucet is busy. The key is saved to `~/.flop-devnet/gateway.key` (mode 600) and never printed. |
| 4 | `./flop-devnet.sh ask "prompt"` | One OpenAI-style chat completion to `api.flop.network/v1/chat/completions`. Request, response headers and body are saved under `~/.flop-devnet/runs/<timestamp>/`. |
| 5 | `./flop-devnet.sh status` | Node health; balance and **settlements** for your keystore key and for the CLI's enrollment wallet; the latest network settlement; network stats; the models the gateway serves. |

`./flop-devnet.sh all "prompt"` runs steps 1 to 5 in order.

Two extras:

- `./flop-devnet.sh direct "prompt"` runs `flop session run` against each miner that quotes the model: a compute channel opened and settled under **your own key** (escrow capped at 2 test FLOP by default). It only works when a miner publishes a live signed offer; see below.
- `./flop-devnet.sh mcp <tool> '<json args>'` calls any tool on the hosted MCP server at `mcp.flop.network/mcp`, for example:

```bash
./flop-devnet.sh mcp flop_get_stats
./flop-devnet.sh mcp flop_list_settlements '{"limit":5}'
./flop-devnet.sh mcp flop_get_compute_channel '{"channel_id":"0x..."}'
```

## Requirements

- Linux, macOS or WSL with `bash`, `curl`, `python3`, `openssl`
- Node.js **22 or newer** (`npx` downloads `@flop-labs/cli@0.4.0` on first use)

## Quick start

```bash
git clone https://github.com/Makabeez/flop-devnet-starter.git
cd flop-devnet-starter
chmod +x flop-devnet.sh
./flop-devnet.sh all "Explain proof of useful inference in one sentence."
```

## Settings

All optional, as environment variables:

| Variable | Default |
|---|---|
| `FLOP_HOME` | `~/.flop-devnet` |
| `FLOP_CLI_VERSION` | `0.4.0` |
| `FLOP_MODEL` | `qwen/qwen2.5-0.5b-instruct` (gateway id) |
| `FLOP_MAX_FLOP` | `2` (escrow cap for `direct`) |
| `FLOP_ASK_TRIES` | `60` gateway attempts, at least 30 s apart, while the gateway is overloaded |
| `FLOP_FUND_TRIES` / `FLOP_FUND_WAIT` | `30` tries, `60` s apart |
| `FLOP_GATEWAY_URL`, `FLOP_MCP_URL`, `FLOP_EXPLORER_URL` | the public devnet endpoints |

## What is verified today (3 Nov 2026)

Checked against the live devnet:

- `init`: key generation, encrypted keystore, owner-only files.
- `status`: the node reports `FLOP Devnet`, version `1.1.0-13ff7e2c334`. Balance, settlement lookups by agent, network stats and the model list all return live data. The gateway serves one model, `qwen/qwen2.5-0.5b-instruct`, with price quotes from 3 miners (quotes, not a count of miners online).
- `mcp`: tool calls against the hosted server.
- `fund`: the faucet returned `503 IP classification unavailable` from about 08:10 to at least 14:00 UTC. It was working again by 15:12 UTC: a fresh key received **25 test FLOP**. Limits from its `/health`: one grant per address per 24 h, 300 per IP per day. The first request can hang for 20 s or more and then answers `Grant pending`; the grant still lands.
- `credential`: works once the faucet is up. It returns a gateway key with a quota of 20,000 that expires after about 24 hours.

Blocked on the network side at the time of writing:

- `ask`: the gateway answered `429 BrokerOverloadedError: gateway channel pool is full` to all 60 attempts between 15:23 and 15:59 UTC, with an occasional `rate_limit_exceeded` when retried faster than about 20 s. Settlements kept landing during that window (all under the shared gateway account), so the gateway's existing channels are in use; new keys just can't get one.
- `direct`: every miner quoting the model answered `no live signed offer for the named miner and model`. So no miner currently accepts direct channels from outside keys.
- `flop chat` (CLI 0.4.0) can't run on the public devnet: given the gateway model id it reports `model not found`; given the on-chain model hash it fails with `Supply a registered HTLC appraisal profile, version, model hash and measurement hash`. Network stats show `totalHTLCs: 0`.

This section will be updated with a real settled run once the gateway has capacity.

## Known issues in `@flop-labs/cli` 0.4.0

Found by reading the published CLI source (`dist/cli.js`, functions `enrollmentWallet`, `walletEnrollment`, `publicDevnetCredential`) and the indexer:

1. **`agent credential` ignores `--keystore`.** It always enrolls with a separate sr25519 wallet that it creates on first use at `~/.flop/devnet-enroll-wallet.json`. That file stores the wallet's **12-word mnemonic in plain text** (mode 600). The CLI also funds that wallet from the faucet itself, and caches the gateway key in `~/.flop/devnet-wallet-agent-key.json`. The file is written before the faucet call, so it exists even when enrollment fails. Devnet only, but never reuse that mnemonic for anything.
2. **Gateway runs don't settle under your address.** Of the 251 settlements indexed so far, 166 have the same agent, `5GsXb3TmNGixuEsbtixqHnqWr9UQJ2M8bkqBQWteNekgF98S`, which looks like the hosted gateway's own account. The only CLI path that settles under your own key is a direct miner channel (`flop session run`, which `direct` wraps).

## What the hosted MCP itself says about receipts

`flop_get_inference_receipt` returns an authenticated TEE quote digest and the verified compute. Per its own description, the other receipt fields are **placeholders**: they do not establish model, input or output commitments, or finalized settlement. TEE quote verification on devnet is **simulated**. Settlements (`flop_list_settlements`) are the on-chain record to rely on: block, extrinsic hash, agent, miner, amount paid and assurance tier.

## Security

- Keys, the keystore password and the gateway key live in `~/.flop-devnet/` (directory mode 700, files 600), never in this repo. `.gitignore` also blocks `*.key`, keystores and `.env*` in case of mistakes.
- The gateway key is passed to `curl` through a temporary header file, deleted right after the call, so it never appears in the process list or in shell history.
- The script never prints a mnemonic: your key is generated straight into an encrypted keystore. The CLI's own enrollment wallet is the exception (see Known issues), and the script warns about it.

## Links

- Explorer: https://explorer.devnet.flop.network
- Faucet: https://faucet.flop.network
- Gateway models: https://api.flop.network/v1/models
- MCP: https://mcp.flop.network/mcp
- Docs: https://docs.flop.network

## License

MIT
