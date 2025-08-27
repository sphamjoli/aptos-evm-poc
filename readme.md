## Fusion Aptos (POC)

Cross-chain token swaps between EVM chains and Aptos using 1inch Limit Order Protocol with enterprise escrow infrastructure.

```mermaid
sequenceDiagram
    participant ETHUser as ETH User
    participant LOP as 1inch Limit Order Protocol
    participant EthEscrow as Ethereum Escrow Factory
    participant AptosUser as Aptos User
    participant AptosEscrow as Aptos Escrow Factory
    participant EventMonitor as Event Monitor

    Note over ETHUser, AptosEscrow: Cross-Chain Swap: 1 ETH → 3000 APT

    ETHUser->>LOP: Create limit order (1 ETH for 3000 APT)
    Note right of ETHUser: Order includes postInteraction<br/>with escrow creation parameters

    EventMonitor->>AptosUser: Notify: New swap opportunity available
    AptosUser->>AptosUser: Generate secret & hashlock
    AptosUser->>AptosEscrow: Create destination escrow (3000 APT locked)
    AptosEscrow-->>EventMonitor: Emit DstEscrowCreated event

    EventMonitor->>ETHUser: Notify: APT escrow ready for your order
    Note over LOP: Taker fills ETH user's order

    LOP->>EthEscrow: postInteraction: Create source escrow
    EthEscrow->>EthEscrow: Lock 1 ETH with same hashlock
    EthEscrow-->>EventMonitor: Emit SrcEscrowCreated event

    EventMonitor->>ETHUser: Notify: ETH locked, provide secret to claim APT
    ETHUser->>AptosEscrow: Withdraw APT using secret
    AptosEscrow->>AptosEscrow: Verify secret matches hashlock
    AptosEscrow->>ETHUser: Transfer 3000 APT
    AptosEscrow-->>EventMonitor: Emit withdrawal event (secret revealed)

    EventMonitor->>AptosUser: Notify: Secret revealed, claim your ETH
    AptosUser->>EthEscrow: Withdraw ETH using revealed secret
    EthEscrow->>EthEscrow: Verify secret matches hashlock
    EthEscrow->>AptosUser: Transfer 1 ETH

    Note over ETHUser, AptosUser: Swap completed atomically
```

## Architecture Overview

```mermaid
graph TB
    subgraph "Ethereum Network"
        LOP[1inch Limit Order Protocol]
        EthEscrowFactory[Ethereum Escrow Factory]
        SrcEscrow[Source Escrows]
        DstEscrow[Destination Escrows]

        LOP --> EthEscrowFactory
        EthEscrowFactory --> SrcEscrow
        EthEscrowFactory --> DstEscrow
    end

    subgraph "Aptos Network"
        AptosEscrowFactory[Aptos Escrow Factory]
        AptosSrcEscrow[Aptos Source Escrows]
        AptosDstEscrow[Aptos Destination Escrows]

        AptosEscrowFactory --> AptosSrcEscrow
        AptosEscrowFactory --> AptosDstEscrow
    end

    subgraph "Infrastructure"
        EventMonitor[Cross-Chain Event Monitor]
        AddressComputer[Deterministic Address Computer]
        MerkleValidator[Partial Fill Validator]

        EventMonitor --> EthEscrowFactory
        EventMonitor --> AptosEscrowFactory
    end

    subgraph "User Interfaces"
        EthClient[Ethereum Client SDK]
        AptosClient[Aptos Client SDK]
        UserApp[User Applications]

        EthClient --> LOP
        EthClient --> EthEscrowFactory
        AptosClient --> AptosEscrowFactory
        UserApp --> EthClient
        UserApp --> AptosClient
    end

    SrcEscrow -.->|Mirror State| AptosSrcEscrow
    DstEscrow -.->|Mirror State| AptosDstEscrow
```

## Escrow State Machine

```mermaid
stateDiagram-v2
    [*] --> Created: Deploy escrow with hashlock

    Created --> Funded: Lock tokens in escrow
    Created --> Cancelled: Cancel before funding

    Funded --> Claimed: Withdraw with valid secret
    Funded --> Refunded: Timeout expired
    Funded --> PartiallyFilled: Partial order fill

    PartiallyFilled --> Claimed: Complete with final secret
    PartiallyFilled --> Refunded: Timeout expired
    PartiallyFilled --> PartiallyFilled: Additional partial fills

    Claimed --> [*]: Tokens transferred, secret revealed
    Refunded --> [*]: Tokens returned to creator
    Cancelled --> [*]: Escrow destroyed

    note right of Claimed
        Secret revealed on-chain
        Counterparty can now claim
        from paired escrow
    end note

    note right of PartiallyFilled
        Merkle validation ensures
        correct secret for each
        partial fill portion
    end note

    note right of Refunded
        Automatic refund after
        cancellation timeout
        Protects against abandonment
    end note
```

## User Story

Alice holds 1 ETH and wants 3000 APT. Bob holds 5000 APT and wants ETH at current rates.

**Step 1: Alice creates intent**
Alice uses the Ethereum client to create a 1inch limit order: "I'll give 1 ETH for 3000 APT". The order includes postInteraction parameters that will automatically create an escrow when filled.

**Step 2: Bob sees opportunity**
Bob monitors cross-chain swap events and sees Alice's order. He likes the rate and decides to provide the 3000 APT. Bob generates a secret, computes its hash, and creates a destination escrow on Aptos locking his 3000 APT with the hashlock.

**Step 3: Order execution**
A taker on Ethereum fills Alice's limit order normally through 1inch. The postInteraction automatically creates a source escrow on Ethereum, locking the 1 ETH Alice received with the same hashlock Bob used.

**Step 4: Cross-chain completion**
Alice sees the destination escrow is ready and uses Bob's secret to claim her 3000 APT on Aptos. This reveals the secret on-chain. Bob monitors the Aptos chain, sees the secret revelation, and uses it to claim Alice's 1 ETH from the Ethereum escrow.

**Result**: Alice has her 3000 APT, Bob has his 1 ETH, and the swap completed atomically without either party risking their funds.

[Add more stuff blah blah blah blah]
