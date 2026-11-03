# flop-devnet-starter

One bash script that takes you from nothing to an inference call on the [FLOP devnet](https://explorer.devnet.flop.network), using only the official `@flop-labs/cli`, the public gateway and the hosted MCP server.

> **Devnet only.** Devnet FLOP has no value and earns no rewards or airdrop weight. The chain may be reset. Never use a seed phrase or a key that holds real funds with this script.

## What it does

| Step | Command | What happens |
|---|---|---|
| 1 | `./flop-devnet.sh init` | Generates a new **sr25519** agent key in an encrypted Polkadot keystore at `~/.flop-devnet/` (outside the repo). The password is random and stored in a file only you can read. |
| 2 | `./flop-devnet.sh fund` | Requests test FLOP from `faucet.flop.network`. The CLI checks the faucet's and the RPC's chain identity first. Retries every 60 s while the faucet is busy. |
| 3 | `./flop-devnet.sh credential` | `flop agent credential`: a wallet-signed request for a devnet gateway API key. The key is saved to `~/.flop-devnet/gateway.key` (mode 600) and never printed. |
| 4 | `./flop-devnet.sh ask "prompt"` | One OpenAI-style chat completion to `api.flop.network/v1/chat/completions`. Request, response headers and body are saved under `~/.flop-devnet/runs/<timestamp>/`. |
| 5 | `./flop-devnet.sh status` | Node health, your balance, **settlements where your key is the agent**, the latest network settlement, network stats and the models the gateway serves. |

`./flop-devnet.sh all "prompt"` runs steps 1 to 5 in order.

Two extras:

- `./flop-devnet.sh direct "prompt"` runs one `flop chat` turn signed by your own key (capped at 1 test FLOP per turn by default). **Not yet tested:** see below.
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
| `FLOP_REGISTRY_MODEL` | `Qwen/Qwen2.5-0.5B-Instruct` (on-chain id, used by `direct`) |
| `FLOP_MAX_FLOP` | `1` (per-turn cap for `direct`) |
| `FLOP_FUND_TRIES` / `FLOP_FUND_WAIT` | `30` tries, `60` s apart |
| `FLOP_GATEWAY_URL`, `FLOP_MCP_URL`, `FLOP_EXPLORER_URL` | the public devnet endpoints |

## What is verified today (3 Nov 2026)

Checked against the live devnet:

- `init`: key generation, encrypted keystore, owner-only files.
- `status`: the node reports `FLOP Devnet`, version `1.1.0-13ff7e2c334`. Balance, settlement lookups by agent, network stats and the model list all return live data. The gateway serves one model, `qwen/qwen2.5-0.5b-instruct`, priced by 3 miners.
- `mcp`: tool calls against the hosted server.
- `fund`: the retry loop and error handling. The faucet's `/health` is fine, but every `/fund` request currently returns `503 IP classification unavailable; retry later`.

Not verified yet, because the faucet outage blocks them:

- `credential`, `ask` and `direct` need a funded key.

This section will be updated with a real run, including the settlement it produces, once the faucet is back.

## What the hosted MCP itself says about receipts

`flop_get_inference_receipt` returns an authenticated TEE quote digest and the verified compute. Per its own description, the other receipt fields are **placeholders**: they do not establish model, input or output commitments, or finalized settlement. TEE quote verification on devnet is **simulated**. Settlements (`flop_list_settlements`) are the on-chain record to rely on: block, extrinsic hash, agent, miner, amount paid and assurance tier.

## Security

- Keys, the keystore password and the gateway key live in `~/.flop-devnet/` (directory mode 700, files 600), never in this repo. `.gitignore` also blocks `*.key`, keystores and `.env*` in case of mistakes.
- The gateway key is passed to `curl` through a temporary header file, deleted right after the call, so it never appears in the process list or in shell history.
- The script never prints a mnemonic: keys are generated straight into an encrypted keystore.

## Links

- Explorer: https://explorer.devnet.flop.network
- Faucet: https://faucet.flop.network
- Gateway models: https://api.flop.network/v1/models
- MCP: https://mcp.flop.network/mcp
- Docs: https://docs.flop.network

## License

MIT
