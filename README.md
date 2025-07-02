# 🪙 Decentralized Stablecoin (DSC) System

This project implements a decentralized, algorithmic, crypto-collateralized stablecoin system. The goal is to create a stable digital asset pegged to **$1.00 USD**, while remaining overcollateralized and censorship-resistant.

---

## 🔧 Key Features

### ⚖️ 1. Relative Stability — Anchored to $1.00

- Pegged to the USD value ($1.00).
- Uses **Chainlink decentralized price feeds**.
- Converts accepted collateral (ETH or BTC) into USD value for minting stablecoins.

### 🔁 2. Stability Mechanism — Decentralized Minting

- Algorithmic minting ensures no centralized control.
- Users can **only mint** DSC if they deposit enough collateral.
- Prevents under-collateralization and supports long-term sustainability.

### 🔒 3. Collateral — Exogenous (Crypto-Based)

Accepted collateral types:
- `wETH` (Wrapped Ethereum)
- `wBTC` (Wrapped Bitcoin)

---

## 🧠 How It Works

1. **Price Feeds**: 
   - Chainlink provides real-time ETH/USD and BTC/USD prices to calculate fair value.

2. **Depositing Collateral**:
   - Users deposit `wETH` or `wBTC` into the system.
   - The USD value of the deposit is calculated using Chainlink.

3. **Minting DSC**:
   - Users can mint DSC tokens up to a specific threshold (e.g., 75% LTV).
   - Example: If you deposit $100 worth of ETH, you can mint up to $75 in DSC.

4. **Redeeming Collateral**:
   - Users burn DSC to unlock their deposited collateral.
   - Ensures the system remains solvent and overcollateralized.

5. **Liquidation**:
   - If a user’s position drops below the minimum collateral ratio, others can liquidate it.
   - This keeps the peg and protects the system from bad debt.

---

## 🛠️ Technologies Used

- [Solidity](https://docs.soliditylang.org/) — Smart contract programming
- [Foundry](https://book.getfoundry.sh/) — Fast and secure testing/development framework
- [Chainlink](https://chain.link/) — Decentralized oracles for price feeds
- [OpenZeppelin](https://openzeppelin.com/) — Secure smart contract libraries

---

## 🚀 Getting Started

```bash
# Clone the repo
git clone https://github.com/your-username/your-repo-name.git
cd your-repo-name

# Install dependencies
forge install

# Run tests
forge test
