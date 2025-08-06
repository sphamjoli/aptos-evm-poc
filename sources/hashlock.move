module hashlock::hashlock {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use std::aptos_hash;
    use aptos_std::table::{Self, Table};

    const E_HTLC_NOT_EXISTS: u64 = 1;
    const E_HTLC_ALREADY_EXISTS: u64 = 2;
    const E_invalid_argument: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_HTLC_EXPIRED: u64 = 5;
    const E_HTLC_NOT_EXPIRED: u64 = 6;
    const E_INVALID_PREIMAGE: u64 = 7;
    const E_INVALID_HASH_LENGTH: u64 = 8;
    const E_INVALID_AMOUNT: u64 = 9;
    const E_INVALID_TIMEOUT: u64 = 10;

    const HASH_LENGTH: u64 = 32;
    const MIN_TIMEOUT_DURATION: u64 = 120;

    /// HTLC structure containing all contract details
    struct HTLC<phantom CoinType> has key, store {
        locked_amount: Coin<CoinType>,
        hash_lock: vector<u8>,
        recipient: address,
        sender: address,
        timeout: u64,
        claimed: bool,
        refunded: bool
    }

    /// Container for managing multiple HTLCs per account per coin type
    struct HTLCManager<phantom CoinType> has key {
        next_id: u64,
        htlcs: Table<u64, HTLC<CoinType>>,
        creation_events: EventHandle<HTLCCreatedEvent>,
        claim_events: EventHandle<HTLCClaimedEvent>,
        refund_events: EventHandle<HTLCRefundedEvent>
    }

    struct HTLCCreatedEvent has drop, store {
        htlc_id: u64,
        sender: address,
        recipient: address,
        amount: u64,
        hash_lock: vector<u8>,
        timeout: u64
    }

    struct HTLCClaimedEvent has drop, store {
        htlc_id: u64,
        recipient: address,
        amount: u64,
        preimage: vector<u8>
    }

    struct HTLCRefundedEvent has drop, store {
        htlc_id: u64,
        sender: address,
        amount: u64
    }

    public entry fun initialize<CoinType>(account: &signer) {
        let account_addr = signer::address_of(account);
        assert!(
            !exists<HTLCManager<CoinType>>(account_addr),
            error::already_exists(E_HTLC_ALREADY_EXISTS)
        );

        let manager = HTLCManager<CoinType> {
            next_id: 0,
            htlcs: table::new(),
            creation_events: account::new_event_handle<HTLCCreatedEvent>(account),
            claim_events: account::new_event_handle<HTLCClaimedEvent>(account),
            refund_events: account::new_event_handle<HTLCRefundedEvent>(account)
        };

        move_to(account, manager);
    }

    public entry fun create_htlc<CoinType>(
        sender: &signer,
        recipient: address,
        amount: u64,
        hash_lock: vector<u8>,
        timeout_duration: u64
    ) acquires HTLCManager {
        let sender_addr = signer::address_of(sender);

        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            vector::length(&hash_lock) == HASH_LENGTH,
            error::invalid_argument(E_INVALID_HASH_LENGTH)
        );
        assert!(
            timeout_duration >= MIN_TIMEOUT_DURATION,
            error::invalid_argument(E_INVALID_TIMEOUT)
        );
        assert!(
            coin::balance<CoinType>(sender_addr) >= amount,
            error::invalid_argument(E_invalid_argument)
        );

        if (!exists<HTLCManager<CoinType>>(sender_addr)) {
            initialize<CoinType>(sender);
        };

        let manager = borrow_global_mut<HTLCManager<CoinType>>(sender_addr);
        let htlc_id = manager.next_id;
        manager.next_id = htlc_id + 1;

        let current_time = timestamp::now_seconds();
        let timeout = current_time + timeout_duration;
        let locked_coins = coin::withdraw<CoinType>(sender, amount);

        let htlc = HTLC<CoinType> {
            locked_amount: locked_coins,
            hash_lock,
            recipient,
            sender: sender_addr,
            timeout,
            claimed: false,
            refunded: false
        };

        table::add(&mut manager.htlcs, htlc_id, htlc);

        event::emit_event(
            &mut manager.creation_events,
            HTLCCreatedEvent {
                htlc_id,
                sender: sender_addr,
                recipient,
                amount,
                hash_lock: hash_lock,
                timeout
            }
        );
    }

    public entry fun claim_htlc<CoinType>(
        claimer: &signer,
        sender: address,
        htlc_id: u64,
        preimage: vector<u8>
    ) acquires HTLCManager {
        let claimer_addr = signer::address_of(claimer);

        assert!(
            exists<HTLCManager<CoinType>>(sender),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let manager = borrow_global_mut<HTLCManager<CoinType>>(sender);
        assert!(
            table::contains(&manager.htlcs, htlc_id),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let htlc = table::borrow_mut(&mut manager.htlcs, htlc_id);

        assert!(htlc.recipient == claimer_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(!htlc.claimed && !htlc.refunded, E_HTLC_NOT_EXISTS);

        let current_time = timestamp::now_seconds();
        assert!(current_time < htlc.timeout, E_HTLC_EXPIRED);

        let computed_hash = aptos_hash::keccak256(preimage);
        assert!(computed_hash == htlc.hash_lock, E_INVALID_PREIMAGE);

        htlc.claimed = true;
        let amount = coin::value(&htlc.locked_amount);
        let payment = coin::extract_all(&mut htlc.locked_amount);
        coin::deposit(claimer_addr, payment);

        event::emit_event(
            &mut manager.claim_events,
            HTLCClaimedEvent { htlc_id, recipient: claimer_addr, amount, preimage }
        );
    }

    public entry fun refund_htlc<CoinType>(
        refunder: &signer, htlc_id: u64
    ) acquires HTLCManager {
        let refunder_addr = signer::address_of(refunder);

        assert!(
            exists<HTLCManager<CoinType>>(refunder_addr),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let manager = borrow_global_mut<HTLCManager<CoinType>>(refunder_addr);
        assert!(
            table::contains(&manager.htlcs, htlc_id),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let htlc = table::borrow_mut(&mut manager.htlcs, htlc_id);

        assert!(htlc.sender == refunder_addr, error::permission_denied(E_UNAUTHORIZED));
        assert!(!htlc.claimed && !htlc.refunded, E_HTLC_NOT_EXISTS);

        let current_time = timestamp::now_seconds();
        assert!(current_time >= htlc.timeout, E_HTLC_NOT_EXPIRED);

        htlc.refunded = true;
        let amount = coin::value(&htlc.locked_amount);
        let refund = coin::extract_all(&mut htlc.locked_amount);
        coin::deposit(refunder_addr, refund);

        event::emit_event(
            &mut manager.refund_events,
            HTLCRefundedEvent { htlc_id, sender: refunder_addr, amount }
        );
    }

    #[view]
    public fun get_htlc_details<CoinType>(
        sender: address, htlc_id: u64
    ): (u64, vector<u8>, address, address, u64, bool, bool) acquires HTLCManager {
        assert!(
            exists<HTLCManager<CoinType>>(sender),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let manager = borrow_global<HTLCManager<CoinType>>(sender);
        assert!(
            table::contains(&manager.htlcs, htlc_id),
            error::not_found(E_HTLC_NOT_EXISTS)
        );

        let htlc = table::borrow(&manager.htlcs, htlc_id);
        (
            coin::value(&htlc.locked_amount),
            htlc.hash_lock,
            htlc.recipient,
            htlc.sender,
            htlc.timeout,
            htlc.claimed,
            htlc.refunded
        )
    }

    #[view]
    public fun is_expired<CoinType>(sender: address, htlc_id: u64): bool acquires HTLCManager {
        if (!exists<HTLCManager<CoinType>>(sender)) {
            return false
        };

        let manager = borrow_global<HTLCManager<CoinType>>(sender);
        if (!table::contains(&manager.htlcs, htlc_id)) {
            return false
        };

        let htlc = table::borrow(&manager.htlcs, htlc_id);
        let current_time = timestamp::now_seconds();
        current_time >= htlc.timeout
    }

    #[view]
    public fun htlc_exists<CoinType>(sender: address, htlc_id: u64): bool acquires HTLCManager {
        if (!exists<HTLCManager<CoinType>>(sender)) {
            return false
        };

        let manager = borrow_global<HTLCManager<CoinType>>(sender);
        table::contains(&manager.htlcs, htlc_id)
    }

    #[view]
    public fun get_next_htlc_id<CoinType>(sender: address): u64 acquires HTLCManager {
        if (!exists<HTLCManager<CoinType>>(sender)) {
            return 0
        };

        let manager = borrow_global<HTLCManager<CoinType>>(sender);
        manager.next_id
    }

    #[view]
    public fun version(): u64 {
        1
    }
}
