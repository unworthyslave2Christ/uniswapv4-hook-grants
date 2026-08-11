# Uniswap v4 Grant Proposal 1: Dynamic Volatility-Adjusted Fee Hook

## 1. Executive Summary

### Project Name

**Dynamic Volatility-Adjusted Fee Hook**

### Target Track

**Core Ecosystem Infrastructure & Tooling**

### Problem

Liquidity providers (LPs) in AMM pools are exposed to **Loss-Versus-Rebalancing (LVR)** when market prices move rapidly. During periods of sharp price movement, arbitrageurs can trade against stale pool prices and capture value from liquidity before the pool's price fully reflects external market conditions.

A static fee tier does not adapt to these changing market conditions. A fee that is appropriate during a stable market may be insufficient during periods of rapid price movement, while maintaining a high fee permanently can unnecessarily reduce trading activity during normal conditions.

### Proposed Solution

The **Dynamic Volatility-Adjusted Fee Hook** is a Uniswap v4 hook that dynamically adjusts the swap fee according to recently observed price movement within the pool.

The hook uses Uniswap v4's hook lifecycle to:

1. Observe the pool's initial tick.
2. Apply the fee determined by the currently stored volatility state before a swap.
3. Observe the actual post-swap tick.
4. Calculate the absolute tick movement produced by the completed swap.
5. Update an exponentially weighted moving average (EWMA) of that movement.
6. Use the updated volatility state to determine the fee for subsequent swaps.

This creates a feedback loop in which periods of increased price movement cause subsequent swaps to face higher fees, while periods of lower movement allow the volatility metric and corresponding fee to decay.

The current implementation defines:

* **Minimum fee:** 0.05% (`500`)
* **Base fee:** 0.30% (`3000`)
* **Maximum fee:** 5.00% (`50000`)
* **Smoothing factor:** `8`

The objective is not to eliminate LVR, but to **make pool pricing more responsive to changing market conditions and increase the fee charged to potentially toxic flow during periods of elevated volatility**.

---

# 2. Technical Architecture

## 2.1 Hook Lifecycle

The current implementation uses three relevant lifecycle stages:

```text
                 POOL INITIALIZATION
                        │
                        ▼
                afterInitialize()
                        │
                Store initial tick
                        │
                        ▼
                  USER SWAP N
                        │
                        ▼
                   beforeSwap()
                        │
              Read current volatility
                        │
                 Calculate fee
                        │
                        ▼
                 Swap executes
                        │
                        ▼
                   afterSwap()
                        │
               Read post-swap tick
                        │
                        ▼
              Calculate tick movement
                        │
                        ▼
                Update EWMA
                        │
                        ▼
                  USER SWAP N+1
                        │
                        ▼
             Apply updated fee
```

This separation is important.

The hook cannot know the price movement caused by a swap before that swap executes. Therefore:

* `beforeSwap` determines the fee using **previously observed volatility**.
* `afterSwap` measures the price movement produced by the completed swap.
* That observation becomes part of the volatility state used by the next swap.

This avoids incorrectly treating the current swap's outcome as information available before execution.

---

# 3. Volatility Measurement

## 3.1 Tick-Movement-Based Volatility

The current implementation does not calculate statistical variance or a TWAP.

Instead, it uses **absolute tick movement** as a lightweight on-chain proxy for short-term volatility.

For each completed swap:

[
\Delta Tick =
Tick_{current} - Tick_{previous}
]

and:

[
|\Delta Tick| =
|Tick_{current} - Tick_{previous}|
]

The hook then incorporates this observation into an exponentially weighted moving average.

---

## 3.2 Exponentially Weighted Moving Average

The volatility state is updated using:

[
V_{new} =
\frac{
V_{old}(S-1) + |\Delta Tick|\times K
}{S}
]

where:

* (V_{new}) = updated volatility metric
* (V_{old}) = previous volatility metric
* (|\Delta Tick|) = absolute tick movement
* (S) = smoothing factor
* (K) = precision/scaling factor
* current implementation uses (S=8)

The scaling factor allows small tick movements to retain sufficient precision in Solidity's integer arithmetic.

### Why EWMA?

An EWMA provides several useful properties for an on-chain implementation:

* No historical arrays are required.
* No iteration over previous swaps is required.
* Storage requirements remain small.
* Recent observations have greater influence than older observations.
* The volatility metric naturally decays when subsequent price movement becomes smaller.
* Large movements can rapidly increase the metric.

Importantly, **the volatility metric is not expected to increase monotonically**.

For example:

```text
Large movement
      ↓
Volatility increases

Smaller movement
      ↓
EWMA begins to decay

Repeated large movements
      ↓
Volatility rises again
```

This behavior is intentional.

---

# 4. Dynamic Fee Model

The current fee model maps the volatility metric to a Uniswap v4 dynamic LP fee.

Conceptually:

[
Fee =
BASE_FEE +
(V \times M)
]

subject to:

[
MIN_FEE \le Fee \le MAX_FEE
]

The implementation currently uses:

```solidity
MIN_FEE  = 500;      // 0.05%
BASE_FEE = 3000;     // 0.30%
MAX_FEE  = 50000;    // 5.00%
```

and a volatility multiplier.

The maximum fee acts as a hard safety boundary so that an abnormal volatility observation cannot cause an unbounded fee.

---

# 5. Why the Fee Is Applied on the Following Swap

One of the important design characteristics of the implementation is the separation between **observation** and **response**.

Consider two consecutive swaps:

```text
Swap 1
│
├── beforeSwap
│     └── uses existing volatility
│
├── Swap executes
│
└── afterSwap
      └── observes price movement
            │
            ▼
      volatility updated


Swap 2
│
└── beforeSwap
      └── uses the newly updated volatility
            │
            ▼
        higher/lower fee
```

This creates a causal feedback mechanism.

The hook does not claim to predict volatility before it occurs. Instead, it **reacts to observed price movement**.

This distinction is important both technically and economically.

---

# 6. Demonstrated Behavior

The current Foundry integration testing demonstrates the intended mechanism.

In an observed test sequence, the first trade was executed while the pool had no prior volatility history:

```text
First trade:

Fee selected:       500
Volatility observed: 125000
```

The following trade then entered `beforeSwap` with the newly observed volatility:

```text
Second trade:

Fee selected:       3015
Volatility:         109375
```

The important observation is that although the EWMA volatility metric itself decreased between observations, the second trade still received a substantially higher fee than the initial 0.05% floor.

This demonstrates that the fee response is based on **recently observed volatility**, rather than requiring volatility to increase on every consecutive swap.

---

# 7. LVR Mitigation Rationale

The objective of the hook is to improve LP economics during periods in which the pool experiences rapid price movement.

During stable conditions:

```text
Low price movement
       ↓
Low volatility metric
       ↓
Low fee
       ↓
Competitive trading environment
```

During periods of rapid price movement:

```text
Large price movement
       ↓
Higher volatility metric
       ↓
Higher subsequent swap fee
       ↓
More expensive potentially toxic flow
       ↓
Additional fee revenue for LPs
```

The mechanism therefore introduces a form of **adaptive pricing for LP risk**.

It does not guarantee that arbitrage becomes unprofitable, nor does it eliminate LVR. Instead, it attempts to make the fee environment more responsive to the conditions under which LVR can become particularly significant.

---

# 8. Why Uniswap v4?

Uniswap v4's hook architecture makes this mechanism possible without modifying the core AMM itself.

The hook can interact with the pool lifecycle at well-defined points:

* `afterInitialize`
* `beforeSwap`
* `afterSwap`

The implementation therefore keeps the dynamic fee policy outside the core PoolManager while allowing the PoolManager to remain responsible for actual swap execution.

This makes the mechanism potentially reusable across different pools without requiring changes to Uniswap's core swap engine.

---

# 9. Gas and Storage Design

The design intentionally avoids maintaining a historical array of prices or swaps.

Per pool, the hook primarily maintains:

```text
lastObservedTick
poolMovingVolatility
```

and associated bookkeeping used for testing/observability.

The volatility calculation requires a small number of arithmetic operations and does not iterate over historical observations.

The design therefore favors:

* Constant-time volatility updates.
* Minimal historical state.
* No external oracle dependency for the basic mechanism.
* No off-chain computation required for fee selection.
* Deterministic fee calculation.

A formal gas benchmark should be included before making quantitative gas-efficiency claims in the final grant submission.

---

# 10. Security and Risk Considerations

The design will explicitly address several risks.

### Fee Bounds

The dynamic fee is constrained between:

```text
0.05% ≤ fee ≤ 5.00%
```

preventing uncontrolled fee growth.

### PoolManager Authorization

Hook state transitions are restricted to calls originating from the configured PoolManager.

### Permission Validation

The hook validates its required Uniswap v4 hook permissions during deployment.

### Deterministic Hook Deployment

The deployment process uses the appropriate hook permission flags when mining the hook address.

### Volatility Manipulation

Because the volatility signal is derived from pool price movement, adversarial traders may attempt to manipulate the signal.

The final implementation and security review should therefore evaluate:

* Small-volume price manipulation.
* Repeated oscillating trades.
* Volatility amplification attacks.
* Fee griefing.
* Interaction with concentrated liquidity.
* Extremely low-liquidity pools.
* Large tick movements.
* Fee-boundary behavior.
* Integer overflow/underflow conditions.

---

# 11. Grant Milestones

## Milestone 1 — Core Hook & Simulation Framework

**Timeline: 3 weeks**
**Funding Request: $15,000**

### Deliverables

* Production-oriented Dynamic Volatility-Adjusted Fee Hook.
* Foundry unit and integration tests.
* Hook permission validation.
* Dynamic fee boundary tests.
* Volatility EWMA tests.
* Market-stress simulations.
* Fuzz testing for volatility and fee calculations.
* Documentation of the fee/volatility mechanism.

### Success Criteria

The implementation should demonstrate that:

1. The initial pool state uses the minimum fee.
2. Completed swaps update the volatility metric.
3. Subsequent swaps respond to the observed volatility.
4. Fees remain within configured bounds.
5. Volatility naturally decays when price movement decreases.
6. Extreme volatility cannot produce a fee above `MAX_FEE`.

---

# 12. Milestone 2 — Analytics & Deployment Infrastructure

**Timeline: 4 weeks**
**Funding Request: $20,000**

### Deliverables

An open-source analytics dashboard demonstrating:

* Current pool tick.
* Tick movement.
* Volatility metric.
* Current dynamic fee.
* Historical fee changes.
* Swap activity.
* Relationship between price movement and fee changes.

A deployment toolkit will also provide:

* Hook deployment scripts.
* Hook address mining.
* Pool initialization examples.
* Testnet deployment configuration.
* Example pool configuration.

The objective is to make the hook understandable and reproducible for developers and LPs rather than providing only a smart contract implementation.

---

# 13. Milestone 3 — Security Review & Testnet/Mainnet Deployment

**Timeline: 4 weeks**
**Funding Request: $25,000 + Audit Subsidy Coverage**

### Deliverables

* Independent smart contract security review.
* Expanded fuzz and invariant testing.
* Testnet deployment.
* Performance and gas benchmarking.
* Documentation of known limitations.
* Deployment tooling.
* Mainnet/L2 deployment subject to audit findings and deployment readiness.

The proposal should **not** imply that a specific auditing firm has agreed to perform the review unless such an arrangement already exists.

---

# 14. Success Metrics

Rather than promising a specific LVR reduction before benchmarking, the project will measure the following.

### 1. Fee Responsiveness

Measure how quickly the fee responds to changes in observed price movement.

### 2. Fee Stability

Measure whether the EWMA prevents excessive fee oscillation during normal market activity.

### 3. LVR Comparison

Compare:

```text
Static-fee pool
        vs.
Dynamic-fee pool
```

under identical simulated market conditions.

Relevant measurements include:

* LP returns.
* Arbitrageur profit.
* Fee revenue.
* Price impact.
* Volume.
* Inventory divergence.

### 4. Gas Overhead

Measure:

* `beforeSwap` gas cost.
* `afterSwap` gas cost.
* Additional storage cost.
* Total swap overhead relative to a comparable pool without the hook.

### 5. Stress-Test Performance

Evaluate the mechanism against:

* Gradual price movements.
* Sudden price crashes.
* Repeated large trades.
* High-frequency alternating trades.
* Low-liquidity conditions.
* High-volatility periods followed by market stabilization.

---

# 15. Limitations and Future Development

The current implementation intentionally uses **tick movement as a lightweight volatility proxy**.

It should therefore not currently be described as an on-chain TWAP or full historical variance estimator.

Future versions can investigate:

### TWAP-Based Volatility

Use accumulated tick observations over a configurable time window to estimate price movement relative to a moving reference.

### Time-Normalized Volatility

Incorporate elapsed time between observations so that:

```text
10 ticks in 1 second
```

can be distinguished from:

```text
10 ticks in 10 minutes
```

rather than treating both observations identically.

### Adaptive Smoothing

Adjust the EWMA smoothing parameter according to pool conditions.

### Pool-Specific Parameters

Allow different pools to configure:

* Minimum fee.
* Base fee.
* Maximum fee.
* Volatility multiplier.
* Smoothing factor.

subject to safe governance constraints.

### Cross-Pool / External Reference Pricing

Future research could investigate whether external market references can improve detection of toxic order flow while maintaining appropriate oracle-manipulation protections.

---

# 16. Expected Ecosystem Impact

The project aims to provide a reusable framework for **risk-aware dynamic fee policies in Uniswap v4**.

Rather than treating the swap fee as a static parameter, the hook demonstrates how pool-specific on-chain observations can be used to adapt fees to changing market conditions.

Potential beneficiaries include:

* Liquidity providers.
* Pool creators.
* Protocol developers.
* Uniswap v4 hook developers.
* DeFi applications managing concentrated liquidity.

The resulting implementation will be open source and designed as an experimental infrastructure component that other hook developers can extend.

---

# 17. Summary

The Dynamic Volatility-Adjusted Fee Hook explores a simple question:

> **Can a Uniswap v4 pool make its fee more responsive to the market conditions that increase LP risk?**

The proposed implementation answers this through a lightweight feedback mechanism:

```text
          PRICE MOVEMENT
                │
                ▼
        afterSwap observation
                │
                ▼
       EWMA volatility metric
                │
                ▼
         Dynamic fee curve
                │
                ▼
         Next beforeSwap
                │
                ▼
       Higher/lower fee
                │
                ▼
       LP fee generation
```

The current prototype demonstrates the core mechanism: a first swap can establish a volatility observation, and a subsequent swap can receive a higher fee as a result.

The project's next stage is to rigorously benchmark whether this adaptive fee structure actually improves LP outcomes under realistic volatility and arbitrage conditions, while maintaining acceptable gas overhead and avoiding new manipulation vectors.

---

## 18. Future Development & Research Roadmap

The current implementation establishes the core adaptive-fee mechanism using observed tick movement and an exponentially weighted moving average (EWMA). Future development will extend this foundation toward a more robust, time-aware volatility engine capable of distinguishing transient price movements from sustained market volatility.

### 18.1 TWAP-Based Volatility Measurement

A key next step is integrating an **on-chain Time-Weighted Average Price (TWAP)** into the volatility calculation.

The current implementation measures:

<<<<<<< HEAD
[
|\Delta Tick| = |Tick_{current} - Tick_{previous}|
]
=======
∣ΔTick∣=∣Tickcurrent​−Tickprevious​∣
>>>>>>> fdc42310841de9aa3a5b38c894cfdaf895f4db1b

While this is inexpensive and responsive, it does not explicitly account for **time**. A 100-tick movement occurring within one second and the same movement occurring over several minutes would currently be treated similarly.

A TWAP-based implementation would maintain or derive cumulative tick observations over a configurable time window:

[
TWAP =
\frac{\sum Tick_i \times \Delta t_i}
{\sum \Delta t_i}
]

The hook could then compare the current pool price against its short-term TWAP:

[
Deviation =
|Tick_{current} - Tick_{TWAP}|
]

This provides a more meaningful indication of whether the pool has moved materially away from its recent market equilibrium.

The resulting architecture could become:

```text
Pool Tick
   │
   ├───────────────┐
   │               │
   ▼               ▼
Current Tick     TWAP Tick
   │               │
   └───────┬───────┘
           ▼
     Price Deviation
           │
           ▼
    Volatility Engine
           │
           ▼
      Dynamic Fee
```

This would allow the hook to distinguish **persistent market movement from isolated tick noise**.

---

### 18.2 Time-Normalized Volatility

Future versions will incorporate elapsed time between observations.

Instead of measuring only:

[
|\Delta Tick|
]

the hook could measure:

[
Volatility =
\frac{|\Delta Tick|}
{\Delta t}
]

where (\Delta t) represents the time between observations.

This allows the system to differentiate between rapid and gradual price movements.

For example:

```text
Scenario A
100 ticks / 2 seconds
→ extremely rapid movement
→ stronger fee response


Scenario B
100 ticks / 10 minutes
→ gradual movement
→ weaker fee response
```

This makes the volatility signal more closely aligned with the market risk the hook is attempting to measure.

---

### 18.3 Hybrid TWAP + EWMA Model

A particularly promising direction is combining TWAP deviation with the existing EWMA mechanism.

The proposed model would use two complementary signals:

**1. Price deviation**

[
D = |Tick_{current} - Tick_{TWAP}|
]

**2. Short-term movement**

[
M = |\Delta Tick|
]

These signals could then be combined:

[
V_{new}
=======

\alpha V_{old}
+
(1-\alpha)(w_DD+w_MM)
]

where:

* (V) = volatility state
* (D) = deviation from TWAP
* (M) = recent tick movement
* (\alpha) = smoothing coefficient
* (w_D) = TWAP-deviation weight
* (w_M) = short-term-movement weight

This would create a more robust volatility engine than relying on either signal independently.

---

### 18.4 Adaptive Fee Curves

The current implementation uses a relatively simple linear relationship between volatility and fee.

Future versions could investigate alternative fee curves.

For example:

[
Fee = BASE_FEE + kV
]

could be replaced with a piecewise or nonlinear curve:

```text
Low volatility
     │
     ▼
0.05% ────────────────┐
                       │
Moderate volatility    ▼
                       0.30%
                       │
High volatility        ▼
                       1.00%
                       │
Extreme volatility     ▼
                       5.00%
```

A nonlinear curve could provide a gentler response to ordinary market activity while responding more aggressively to extreme conditions.

---

### 18.5 Pool-Specific Risk Profiles

Different pools have different volatility characteristics.

A stablecoin pool, for example, should not necessarily use the same volatility parameters as a highly volatile asset pair.

Future versions could allow pool-specific configuration of:

* Minimum fee
* Base fee
* Maximum fee
* TWAP window
* EWMA smoothing factor
* Volatility multiplier
* Time-normalization parameters

This would allow the hook to become a generalized **adaptive fee framework** rather than a single fixed fee policy.

---

### 18.6 Multi-Window Volatility Detection

Another research direction is the use of multiple volatility windows.

For example:

```text
Short-term window
       │
       ▼
Immediate market shock


Medium-term window
       │
       ▼
Persistent volatility


Long-term window
       │
       ▼
Market regime
```

The hook could combine these signals to distinguish between:

* temporary price shocks,
* sustained volatility,
* structural market changes.

This could reduce unnecessary fee changes caused by isolated transactions.

---

### 18.7 External Market Reference and Oracle Validation

A future version may investigate comparing the pool's internal TWAP with an independent market reference.

For example:

```text
External Reference Price
          │
          ▼
       Compare
          ▲
          │
     Pool TWAP
```

A significant divergence could indicate that the pool is temporarily stale relative to broader market conditions.

However, this introduces additional oracle and manipulation considerations. Any external reference mechanism would therefore be subject to extensive security analysis before being incorporated into production deployment.

---

### 18.8 MEV and Arbitrage-Aware Fee Modeling

The long-term objective is to move beyond volatility as a proxy and investigate whether the hook can directly identify conditions associated with adverse or toxic order flow.

Future research could examine relationships between:

* Price deviation from TWAP
* Trade size
* Tick movement
* Swap frequency
* Liquidity depth
* Price impact
* Consecutive directional swaps

The goal would be to determine whether a combination of these variables can provide a stronger signal for **LVR-sensitive flow** than volatility alone.

This could eventually produce an adaptive fee model such as:

[
Fee =
f(
Volatility,
TWAPDeviation,
TradeSize,
LiquidityDepth,
MarketRegime
)
]

rather than relying exclusively on a single volatility metric.

---

### 18.9 Backtesting Against Historical Market Conditions

Before making quantitative claims about LVR reduction, the hook should be evaluated against historical market data and simulated arbitrage environments.

The research framework would compare:

```text
Static Fee Pool
       vs.
Dynamic Fee Pool
       vs.
TWAP + Dynamic Fee Pool
```

Metrics would include:

* LP returns
* Fee revenue
* Arbitrageur profit
* LVR
* Trading volume
* Price impact
* Number of swaps
* Average fee
* Maximum fee
* Gas overhead

This will provide an empirical basis for determining whether adaptive fees actually improve LP outcomes.

---

### 18.10 Formal Verification and Invariant Testing

As the volatility engine becomes more sophisticated, additional invariant testing will be introduced.

Important invariants include:

```text
MIN_FEE <= selectedFee <= MAX_FEE
```

and:

```text
volatilityMetric >= 0
```

The implementation should also guarantee that:

* Fee calculations cannot overflow.
* Extreme tick movements cannot corrupt state.
* Invalid hook callers cannot update volatility state.
* TWAP calculations cannot use invalid time intervals.
* Pool-specific parameters remain within safe bounds.
* Dynamic fee flags are correctly applied.
* Hook state remains isolated between pools.

---

### 18.11 Long-Term Vision

The long-term objective is to evolve the prototype into a **general-purpose risk-aware dynamic fee framework for Uniswap v4**.

The development path can therefore be summarized as:

```text
CURRENT
Tick Movement
     │
     ▼
EWMA Volatility
     │
     ▼
Dynamic Fee


NEXT
Tick Movement
     +
TWAP Deviation
     +
Time Normalization
     │
     ▼
Improved Volatility Engine
     │
     ▼
Adaptive Fee Curve


LONG TERM
Volatility
     +
TWAP
     +
Liquidity Conditions
     +
Trade Characteristics
     +
Market Regime
     │
     ▼
Risk-Aware Fee Engine
     │
     ▼
Improved LP Protection
```

The purpose of this roadmap is not to assume that every proposed component will necessarily be deployed in production. Instead, each stage will be **benchmarked, fuzz-tested, economically simulated, and security-reviewed** before being incorporated into the production hook.

This staged approach allows the project to begin with a simple, transparent, and gas-conscious mechanism while providing a clear path toward a more sophisticated **TWAP-aware and LVR-sensitive dynamic fee system**.

