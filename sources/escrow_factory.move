module fusion_aptos::escrow_factory {
    use std::error;
    use std::signer;
    use std::vector;
    use std::bcs;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_std::table::{Self, Table};
    use aptos_std::aptos_hash;

    use fusion_aptos::types::{
        Self,
        Address,
        Timelocks,
        Immutables,
        DstImmutablesComplement,
        ExtraDataArgs,
        ValidationData,
        Order
    };

    const E_ESCROW_NOT_EXISTS: u64 = 1;
    const E_ESCROW_ALREADY_EXISTS: u64 = 2;
    const E_INVALID_ARGUMENT: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_INVALID_SECRETS_AMOUNT: u64 = 5;
    const E_INVALID_PARTIAL_FILL: u64 = 6;
    const E_INSUFFICIENT_ESCROW_BALANCE: u64 = 7;
    const E_INVALID_CREATION_TIME: u64 = 8;
    const E_ESCROW_EXPIRED: u64 = 9;
    const E_ESCROW_NOT_EXPIRED: u64 = 10;
    const E_INVALID_PREIMAGE: u64 = 11;

    const HASH_LENGTH: u64 = 32;
    const ADDRESS_LENGTH: u64 = 32;

    struct EscrowFactory<phantom CoinType> has key {
        escrow_src_implementation: address,
        escrow_dst_implementation: address,
        next_escrow_id: u64,
        escrows: Table<vector<u8>, u64>,
        escrow_data: Table<u64, EscrowData<CoinType>>,
        last_validated: Table<vector<u8>, ValidationData>,
        src_escrow_created_events: EventHandle<SrcEscrowCreatedEvent>,
        dst_escrow_created_events: EventHandle<DstEscrowCreatedEvent>,
        escrow_withdrawal_events: EventHandle<EscrowWithdrawalEvent>,
        escrow_cancelled_events: EventHandle<EscrowCancelledEvent>
    }

    struct EscrowData<phantom CoinType> has store {
        immutables: Immutables,
        locked_coins: Coin<CoinType>,
        escrow_type: u8,
        claimed: bool,
        cancelled: bool
    }

    struct SrcEscrowCreatedEvent has drop, store {
        escrow_id: u64,
        immutables: Immutables,
        dst_complement: DstImmutablesComplement
    }

    struct DstEscrowCreatedEvent has drop, store {
        escrow_id: u64,
        escrow_address: address,
        hashlock: vector<u8>,
        taker: Address
    }

    struct EscrowWithdrawalEvent has drop, store {
        escrow_id: u64,
        secret: vector<u8>,
        recipient: address
    }

    struct EscrowCancelledEvent has drop, store {
        escrow_id: u64,
        refund_recipient: address
    }

    public entry fun initialize<CoinType>(
        account: &signer,
        escrow_src_implementation: address,
        escrow_dst_implementation: address
    ) {
        let account_addr = signer::address_of(account);
        assert!(
            !exists<EscrowFactory<CoinType>>(account_addr),
            error::already_exists(E_ESCROW_ALREADY_EXISTS)
        );

        let factory = EscrowFactory<CoinType> {
            escrow_src_implementation,
            escrow_dst_implementation,
            next_escrow_id: 0,
            escrows: table::new(),
            escrow_data: table::new(),
            last_validated: table::new(),
            src_escrow_created_events: account::new_event_handle<SrcEscrowCreatedEvent>(
                account
            ),
            dst_escrow_created_events: account::new_event_handle<DstEscrowCreatedEvent>(
                account
            ),
            escrow_withdrawal_events: account::new_event_handle<EscrowWithdrawalEvent>(
                account
            ),
            escrow_cancelled_events: account::new_event_handle<EscrowCancelledEvent>(
                account
            )
        };

        move_to(account, factory);
    }

    public entry fun post_interaction<CoinType>(
        caller: &signer,
        order: Order,
        order_hash: vector<u8>,
        taker: address,
        making_amount: u256,
        taking_amount: u256,
        remaining_making_amount: u256,
        extra_data_args: ExtraDataArgs,
        factory_owner: address
    ) acquires EscrowFactory {
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let factory = borrow_global_mut<EscrowFactory<CoinType>>(factory_owner);

        let hashlock: vector<u8>;

        if (types::maker_traits_allow_multiple_fills(order.maker_traits)) {
            let parts_amount =
                types::extract_parts_amount(&extra_data_args.hashlock_info);
            assert!(parts_amount >= 2, error::invalid_argument(E_INVALID_SECRETS_AMOUNT));

            let key_data: vec<u8> = vector::empty<u8>();
            vector::append(&mut key_data, order_hash);
            // Here we need to take lower 240 bits of hashlock_info (30 bytes)
            let hashlock_240 = vector::slice(&extra_data_args.hashlock_info, 2, 32);
            vector::append(&mut key_data, hashlock_240);
            let key = aptos_hash::keccak256(key_data);

            assert!(
                table::contains(&factory.last_validated, key),
                error::invalid_argument(E_INVALID_PARTIAL_FILL)
            );
            let validated = table::borrow(&factory.last_validated, key);
            hashlock = validated.leaf;

            assert!(
                is_valid_partial_fill(
                    making_amount,
                    remaining_making_amount,
                    order.making_amount,
                    parts_amount,
                    validated.index
                ),
                error::invalid_argument(E_INVALID_PARTIAL_FILL)
            );
        } else {
            hashlock = extra_data_args.hashlock_info;
        };

        let current_time = timestamp::now_seconds();
        let timelocks =
            types::timelocks_set_deployed_at(extra_data_args.timelocks, current_time);

        let immutables = Immutables {
            order_hash,
            hashlock,
            maker: order.maker,
            taker: types::address_from_u256(taker as u256),
            token: order.maker_asset,
            amount: making_amount,
            safety_deposit: extra_data_args.deposits >> 128,
            timelocks,
            parameters: vector::empty()
        };

        let dst_complement = DstImmutablesComplement {
            maker: if (types::address_to_u256(&order.receiver) == 0) {
                order.maker
            } else {
                order.receiver
            },
            amount: taking_amount,
            token: extra_data_args.dst_token,
            safety_deposit: extra_data_args.deposits & ((1u256 << 128) - 1),
            chain_id: extra_data_args.dst_chain_id,
            parameters: vector::empty()
        };

        let escrow_id = factory.next_escrow_id;
        factory.next_escrow_id = escrow_id + 1;

        let hash = types::immutables_hash(&immutables);
        let locked_coins = coin::withdraw<CoinType>(caller, (making_amount as u64));

        let escrow_data = EscrowData<CoinType> {
            immutables,
            locked_coins,
            escrow_type: 0,
            claimed: false,
            cancelled: false
        };

        table::add(&mut factory.escrows, hash, escrow_id);
        table::add(&mut factory.escrow_data, escrow_id, escrow_data);

        event::emit_event(
            &mut factory.src_escrow_created_events,
            SrcEscrowCreatedEvent { escrow_id, immutables, dst_complement }
        );
    }

    public entry fun create_dst_escrow<CoinType>(
        creator: &signer,
        dst_immutables: Immutables,
        src_cancellation_timestamp: u64,
        factory_owner: address
    ) acquires EscrowFactory {
        let creator_addr = signer::address_of(creator);
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let factory = borrow_global_mut<EscrowFactory<CoinType>>(factory_owner);

        let current_time = timestamp::now_seconds();
        let immutables = Immutables {
            order_hash: dst_immutables.order_hash,
            hashlock: dst_immutables.hashlock,
            maker: dst_immutables.maker,
            taker: dst_immutables.taker,
            token: dst_immutables.token,
            amount: dst_immutables.amount,
            safety_deposit: dst_immutables.safety_deposit,
            timelocks: types::timelocks_set_deployed_at(
                dst_immutables.timelocks, current_time
            ),
            parameters: dst_immutables.parameters
        };

        let dst_cancellation_time =
            types::timelocks_get_stage(
                &immutables.timelocks, types::STAGE_DST_CANCELLATION()
            );
        assert!(
            dst_cancellation_time <= src_cancellation_timestamp,
            error::invalid_argument(E_INVALID_CREATION_TIME)
        );

        let escrow_id = factory.next_escrow_id;
        factory.next_escrow_id = escrow_id + 1;

        let hash = types::immutables_hash(&immutables);
        let locked_coins = coin::withdraw<CoinType>(creator, (immutables.amount as u64));

        let escrow_data = EscrowData<CoinType> {
            immutables,
            locked_coins,
            escrow_type: 1,
            claimed: false,
            cancelled: false
        };

        table::add(&mut factory.escrows, hash, escrow_id);
        table::add(&mut factory.escrow_data, escrow_id, escrow_data);

        event::emit_event(
            &mut factory.dst_escrow_created_events,
            DstEscrowCreatedEvent {
                escrow_id,
                escrow_address: creator_addr,
                hashlock: immutables.hashlock,
                taker: immutables.taker
            }
        );
    }

    public entry fun withdraw<CoinType>(
        claimer: &signer,
        secret: vector<u8>,
        immutables: Immutables,
        factory_owner: address
    ) acquires EscrowFactory {
        let claimer_addr = signer::address_of(claimer);
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let factory = borrow_global_mut<EscrowFactory<CoinType>>(factory_owner);

        let hash = types::immutables_hash(&immutables);
        assert!(
            table::contains(&factory.escrows, hash),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );

        let escrow_id = *table::borrow(&factory.escrows, hash);
        let escrow_data = table::borrow_mut(&mut factory.escrow_data, escrow_id);

        let computed_hash = aptos_hash::keccak256(secret);
        assert!(
            computed_hash == immutables.hashlock,
            error::invalid_argument(E_INVALID_PREIMAGE)
        );

        let current_time = timestamp::now_seconds();
        let withdrawal_time =
            if (escrow_data.escrow_type == 0) {
                types::timelocks_get_stage(
                    &immutables.timelocks, types::STAGE_SRC_WITHDRAWAL()
                )
            } else {
                types::timelocks_get_stage(
                    &immutables.timelocks, types::STAGE_DST_WITHDRAWAL()
                )
            };

        assert!(current_time >= withdrawal_time, error::invalid_state(E_ESCROW_EXPIRED));
        assert!(
            !escrow_data.claimed && !escrow_data.cancelled,
            error::invalid_state(E_ESCROW_ALREADY_EXISTS)
        );

        let expected_recipient =
            if (escrow_data.escrow_type == 0) {
                types::address_get(&immutables.taker)
            } else {
                types::address_get(&immutables.maker)
            };

        escrow_data.claimed = true;
        let amount = coin::value(&escrow_data.locked_coins);
        let payment = coin::extract_all(&mut escrow_data.locked_coins);
        coin::deposit(claimer_addr, payment);

        event::emit_event(
            &mut factory.escrow_withdrawal_events,
            EscrowWithdrawalEvent { escrow_id, secret, recipient: claimer_addr }
        );
    }

    public entry fun cancel<CoinType>(
        canceller: &signer, immutables: Immutables, factory_owner: address
    ) acquires EscrowFactory {
        let canceller_addr = signer::address_of(canceller);
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let factory = borrow_global_mut<EscrowFactory<CoinType>>(factory_owner);

        let hash = types::immutables_hash(&immutables);
        assert!(
            table::contains(&factory.escrows, hash),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );

        let escrow_id = *table::borrow(&factory.escrows, hash);
        let escrow_data = table::borrow_mut(&mut factory.escrow_data, escrow_id);

        let current_time = timestamp::now_seconds();
        let cancellation_time =
            if (escrow_data.escrow_type == 0) {
                types::timelocks_get_stage(
                    &immutables.timelocks, types::STAGE_SRC_CANCELLATION()
                )
            } else {
                types::timelocks_get_stage(
                    &immutables.timelocks, types::STAGE_DST_CANCELLATION()
                )
            };

        assert!(
            current_time >= cancellation_time,
            error::invalid_state(E_ESCROW_NOT_EXPIRED)
        );
        assert!(
            !escrow_data.claimed && !escrow_data.cancelled,
            error::invalid_state(E_ESCROW_ALREADY_EXISTS)
        );

        escrow_data.cancelled = true;
        let amount = coin::value(&escrow_data.locked_coins);
        let refund = coin::extract_all(&mut escrow_data.locked_coins);
        coin::deposit(canceller_addr, refund);

        event::emit_event(
            &mut factory.escrow_cancelled_events,
            EscrowCancelledEvent { escrow_id, refund_recipient: canceller_addr }
        );
    }

    public entry fun store_validation<CoinType>(
        validator: &signer,
        key: vector<u8>,
        leaf: vector<u8>,
        index: u256,
        factory_owner: address
    ) acquires EscrowFactory {
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let factory = borrow_global_mut<EscrowFactory<CoinType>>(factory_owner);

        let validation_data = ValidationData { leaf, index };

        if (table::contains(&factory.last_validated, key)) {
            *table::borrow_mut(&mut factory.last_validated, key) = validation_data;
        } else {
            table::add(&mut factory.last_validated, key, validation_data);
        };
    }

    fun is_valid_partial_fill(
        making_amount: u256,
        remaining_making_amount: u256,
        order_making_amount: u256,
        parts_amount: u256,
        validated_index: u256
    ): bool {
        let calculated_index =
            (order_making_amount - remaining_making_amount + making_amount - 1)
                * parts_amount / order_making_amount;

        if (remaining_making_amount == making_amount) {
            // Order filled to completion - secret with index i + 1 must be used
            return (calculated_index + 2 == validated_index)
        } else if (order_making_amount != remaining_making_amount) {
            // Not the first fill - calculate previous fill index
            let prev_calculated_index =
                (order_making_amount - remaining_making_amount - 1) * parts_amount
                    / order_making_amount;
            if (calculated_index == prev_calculated_index) return false;
        };

        calculated_index + 1 == validated_index
    }

    #[view]
    public fun address_of_escrow_src<CoinType>(
        immutables: Immutables, factory_owner: address
    ): address acquires EscrowFactory {
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let hash = types::immutables_hash(&immutables);
        factory_owner
    }

    #[view]
    public fun address_of_escrow_dst<CoinType>(
        immutables: Immutables, factory_owner: address
    ): address acquires EscrowFactory {
        assert!(
            exists<EscrowFactory<CoinType>>(factory_owner),
            error::not_found(E_ESCROW_NOT_EXISTS)
        );
        let hash = types::immutables_hash(&immutables);
        factory_owner
    }

    #[view]
    public fun get_escrow_details<CoinType>(
        immutables: Immutables, factory_owner: address
    ): (bool, u8, u256, bool, bool) acquires EscrowFactory {
        if (!exists<EscrowFactory<CoinType>>(factory_owner)) {
            return (false, 0, 0, false, false)
        };

        let factory = borrow_global<EscrowFactory<CoinType>>(factory_owner);
        let hash = types::immutables_hash(&immutables);

        if (!table::contains(&factory.escrows, hash)) {
            return (false, 0, 0, false, false)
        };

        let escrow_id = *table::borrow(&factory.escrows, hash);
        let escrow_data = table::borrow(&factory.escrow_data, escrow_id);

        (
            true,
            escrow_data.escrow_type,
            (coin::value(&escrow_data.locked_coins) as u256),
            escrow_data.claimed,
            escrow_data.cancelled
        )
    }
}
