<p align="center"><img src="app/hormus-logo.svg" width="72" alt="HORMUS"></p>

<h1 align="center">hormus</h1>

<p align="center">Token research and trading on Robinhood Chain.<br>
<a href="https://hormus.io">hormus.io</a> · <a href="https://app.hormus.io">app</a> · <a href="https://docs.hormus.io">docs</a> · <a href="https://x.com/hormusapp">x</a></p>

---

hormus reads Robinhood Chain for you. It shows what is moving right now, what just launched on Pons, who is buying and selling, and lets you swap from your own wallet. You can ask the research terminal a question in plain words and get an answer with the sources it used, or set up agents that watch the market on a schedule and write short reports.

This repo holds the parts that run in your browser and the vault contracts, so anyone can check what the app does with their wallet.

## What is in here

```
app/         the website and app (hormus.io and app.hormus.io)
docs/        the docs site (docs.hormus.io)
contracts/   HORMUS USDG vault contracts and their tests
```

The app is a single `index.html` with no build step. Sign-in and the embedded wallet come from Privy (`privy-auth.js`). Market data is served by the HORMUS API, which is not part of this repo.

## Contracts

All on Robinhood Chain (chain id 4663).

| Contract | Address | Status |
|---|---|---|
| HormusAgentVault (v1) | [`0xC1a68e303354537A29F34aA178821F799a91D32e`](https://robinhoodchain.blockscout.com/address/0xC1a68e303354537A29F34aA178821F799a91D32e) | Live, source verified on Blockscout |
| HormusAgentVaultV2 | not deployed | Work in progress |
| USDG | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) | Token used by the vault |

The v1 vault keeps your USDG under your address. You deposit, set a budget for each agent and withdraw with your own signature. Budgets are bookkeeping only: v1 has no function that lets an agent or the HORMUS backend move your funds. The owner key can only pause new deposits and new budgets; releasing a budget and withdrawing always stay open.

v2 adds optional agent trading inside the limits you set. It is not deployed and nothing in the app uses it yet.

## Run it locally

The app and docs are static files, so any static server works:

```bash
npx serve app
npx serve docs
```

You can browse the site locally, but sign-in may not work there: Privy only accepts sign-ins from the domains allowed in its dashboard.

To compile the contracts and run the vault tests:

```bash
cd contracts
npm install
npm test
```

## Safety

- hormus never asks for your seed phrase or private key.
- Every swap is simulated before you sign it, and you sign it in your own wallet.
- Always check the contract address of a token. Names and tickers can be copied.
- Nothing here is financial advice.

Found a problem? Open an issue, or for anything security related send a DM to [@hormusapp](https://x.com/hormusapp) instead of posting it publicly.

## License

MIT
