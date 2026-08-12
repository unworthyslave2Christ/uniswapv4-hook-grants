### Uniswap v4 Modular LP Protection & Yield Suite

Welcome to the **Modular LP Protection & Yield Suite** repository. This workspace contains a collection of three high-utility, highly specialized Uniswap v4 hooks designed to maximize capital efficiency, suppress predatory MEV extraction, and protect passive Liquidity Providers (LPs) from Loss-Versus-Rebalancing (LVR). 

### 🛠 Project Structure

### 🛠 Essential Project Structure

```text

├── src/
│   ├── DynamicFeeHook.sol                 # Hook 1: Anti-LVR Price Variance Engine (The only tested Hook at the moment)
│   ├── MEVInternalizerHook.sol            # Hook 2: Intra-Block Sandwich Neutralizer
│   └── IdleCapitalHook.sol                # Hook 3: ERC-4626 Sovereign Yield Aggregator
├── test/
│   ├── DynamicFeeHook.t.sol
│   ├── MEVInternalizerHook.t.sol
│   └── IdleCapitalHook.t.sol
├── proposals/
│   ├── DynamicFeeHookProposalBrief.md     # Active Brief: Volatility Fee Grant Info
│   ├── DynamicFeeHookProposalComprehensive.md
│   ├── IdleCapitalHookProposalBrief.md    # Active Brief: Idle Capital Grant Info
│   ├── IdleCapitalHookProposalComprehensive.md
│   ├── MEVInternalizerHookProposalBrief.md # Active Brief: MEV Protection Grant Info
│   └── MEVInternalizerHookProposalComprehensive.md
├── foundry.toml
└── README.md                              # Workspace Root Manifest
```

Use code with caution.


### 🚀 Core Component Architecture

### 1. Volatility-Adjusted Dynamic Fee Hook (The only tested Hook at the moment)

* **Core Utility:** Prevents arbitrage leakage during high-volatility price discovery.
* **Methodology:** Uses an on-chain Exponential Moving Average (EMA) to compute price variance directly from PoolManager.getSlot0() and scales fees up to 5.00% to offset LVR.
* **Status:** Testing Validated ✅ [View Proposal Brief](./proposals/DynamicFeeHookProposalBrief.md)

### 2. MEV-Internalizing Hook

* **Core Utility:** Deters sandwich bots and internalizes MEV revenue.
* **Methodology:** Monopolizes intra-block sequencing metrics. Any subsequent trade hitting the pool inside the exact same block triggers a 1.50% premium penalty, returning the value directly to the pool assets.
* **Status:** Testing NOT YET Validated ✅ [View Proposal Brief](./proposals/MEVInternalizerHookProposalBrief.md)

### 3. Idle Capital Hook

* **Core Utility:** Unlocks yield generation for out-of-range concentrated liquidity positions.
* **Methodology:** Implements a custom accounting mechanism that routes 90% of inactive token balances to ERC-4626 lending vaults while holding a 10% asset buffer inside the manager for gas-friendly everyday retail routing.
* **Status:** Testing NOT YET Validated ✅ [View Proposal Brief](./proposals/IdleCapitalHookProposalBrief.md)

### 💻 Local Testing Lifecycle

This project is built using the **Foundry Smart Contract Development Toolchain**. 

### Dependencies Installation

Ensure you have the core submodules updated before executing test scripts: 

bash

forge install

Use code with caution.

### Run the Integration Testing Framework

To execute the comprehensive validation test suite and view the programmatic state logs across your terminal, run: 

bash

forge test -vvv

Use code with caution.

### 📈 Grant Strategy & Roadmap

Instead of introducing a monolithic, risk-concentrated single contract, this project suite provides a **modular ecosystem solution**. Pool deployers have the freedom to pick, choose, and compose these independent, open-source hooks based on specific asset profile requirements (e.g., executing DynamicFeeHook on highly erratic pairs while binding IdleCapitalHook to stable token hubs).
