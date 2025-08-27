#[test_only]
module fusion_aptos::escrow_factory_tests {
    use std::vector;
    use std::string;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_std::aptos_hash;
    use aptos_std::debug;
    use fusion_aptos::test_helpers::{
        setup_test_env,
        create_test_immutables,
        create_test_immutables_with_hash
    };
    use fusion_aptos::types::{
        Self,
        Address,
        Timelocks,
        Immutables,
        DstImmutablesComplement,
        ExtraDataArgs,
        Order
    };
    use fusion_aptos::escrow_factory;

    struct TestCoin has key {}

    const MAKER_ADDR: address = @0x1234;
    const TAKER_ADDR: address = @0x5678;
    const FACTORY_ADDR: address = @0xabcd;

    fun create_test_order(): Order {
        types::Order {
            salt: 12345,
            maker: types::address_from_u256(MAKER_ADDR as u256),
            receiver: types::address_from_u256(0),
            maker_asset: types::address_from_u256(0x1111),
            taker_asset: types::address_from_u256(0x2222),
            making_amount: 100000,
            taking_amount: 200000,
            maker_traits: 0
        }
    }

    fun create_test_timelocks(): Timelocks {
        let current_time = timestamp::now_seconds();
        types::timelocks_new(
            current_time + 1800,
            current_time + 3600,
            current_time + 1800,
            current_time + 7200
        )
    }

    #[test]
    fun test_factory_initialization() {
        let (factory_account, _maker_account, _taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        assert!(
            escrow_factory::address_of_escrow_src<TestCoin>(
                create_test_immutables(), FACTORY_ADDR
            ) == FACTORY_ADDR,
            1
        );
    }

    #[test]
    fun test_src_escrow_creation() {
        let (factory_account, maker_account, _taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let order = create_test_order();
        let order_hash = vector::empty<u8>();
        vector::push_back(&mut order_hash, 0x12);
        vector::append(&mut order_hash, vector::tabulate(31, |_| 0x34));

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);

        let extra_data_args = ExtraDataArgs {
            hashlock_info: hashlock,
            dst_chain_id: 1,
            dst_token: types::address_from_u256(0x3333),
            deposits: (50000u256 << 128) + 25000u256,
            timelocks: create_test_timelocks()
        };

        escrow_factory::post_interaction<TestCoin>(
            &maker_account,
            order,
            order_hash,
            TAKER_ADDR,
            100000,
            200000,
            0,
            extra_data_args,
            FACTORY_ADDR
        );

        let immutables = create_test_immutables_with_hash(order_hash, hashlock);
        let (exists, escrow_type, amount, claimed, cancelled) =
            escrow_factory::get_escrow_details<TestCoin>(immutables, FACTORY_ADDR);

        assert!(exists, 2);
        assert!(escrow_type == 0, 3);
        assert!(amount == 100000, 4);
        assert!(!claimed, 5);
        assert!(!cancelled, 6);
    }

    #[test]
    fun test_dst_escrow_creation() {
        let (factory_account, _maker_account, taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);
        let immutables =
            create_test_immutables_with_hash(
                vector::tabulate(32, |i| (i as u8)), hashlock
            );

        escrow_factory::create_dst_escrow<TestCoin>(
            &taker_account,
            immutables,
            timestamp::now_seconds() + 10000,
            FACTORY_ADDR
        );

        let (exists, escrow_type, amount, claimed, cancelled) =
            escrow_factory::get_escrow_details<TestCoin>(immutables, FACTORY_ADDR);

        assert!(exists, 7);
        assert!(escrow_type == 1, 8);
        assert!(amount == 200000, 9);
        assert!(!claimed, 10);
        assert!(!cancelled, 11);
    }

    #[test]
    fun test_escrow_withdrawal() {
        let (factory_account, maker_account, taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);
        let immutables =
            create_test_immutables_with_hash(
                vector::tabulate(32, |i| (i as u8)), hashlock
            );

        escrow_factory::create_dst_escrow<TestCoin>(
            &taker_account,
            immutables,
            timestamp::now_seconds() + 10000,
            FACTORY_ADDR
        );

        timestamp::update_global_time_for_testing_secs(timestamp::now_seconds() + 2000);

        let initial_balance = coin::balance<TestCoin>(MAKER_ADDR);

        escrow_factory::withdraw<TestCoin>(
            &maker_account,
            *secret,
            immutables,
            FACTORY_ADDR
        );

        let final_balance = coin::balance<TestCoin>(MAKER_ADDR);
        assert!(final_balance == initial_balance + 200000, 12);

        let (exists, _escrow_type, amount, claimed, cancelled) =
            escrow_factory::get_escrow_details<TestCoin>(immutables, FACTORY_ADDR);

        assert!(exists, 13);
        assert!(amount == 0, 14);
        assert!(claimed, 15);
        assert!(!cancelled, 16);
    }

    #[test]
    fun test_escrow_cancellation() {
        let (factory_account, _maker_account, taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);
        let immutables =
            create_test_immutables_with_hash(
                vector::tabulate(32, |i| (i as u8)), hashlock
            );

        escrow_factory::create_dst_escrow<TestCoin>(
            &taker_account,
            immutables,
            timestamp::now_seconds() + 10000,
            FACTORY_ADDR
        );

        timestamp::update_global_time_for_testing_secs(timestamp::now_seconds() + 8000);

        let initial_balance = coin::balance<TestCoin>(TAKER_ADDR);

        escrow_factory::cancel<TestCoin>(&taker_account, immutables, FACTORY_ADDR);

        let final_balance = coin::balance<TestCoin>(TAKER_ADDR);
        assert!(final_balance == initial_balance + 200000, 17);

        let (exists, _escrow_type, amount, claimed, cancelled) =
            escrow_factory::get_escrow_details<TestCoin>(immutables, FACTORY_ADDR);

        assert!(exists, 18);
        assert!(amount == 0, 19);
        assert!(!claimed, 20);
        assert!(cancelled, 21);
    }

    #[test]
    fun test_partial_fill_validation() {
        let (factory_account, maker_account, _taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let order = types::Order {
            salt: 12345,
            maker: types::address_from_u256(MAKER_ADDR as u256),
            receiver: types::address_from_u256(0),
            maker_asset: types::address_from_u256(0x1111),
            taker_asset: types::address_from_u256(0x2222),
            making_amount: 100000,
            taking_amount: 200000,
            maker_traits:
                0x4000000000000000000000000000000000000000000000000000000000000000
        };

        let order_hash = vector::tabulate(32, |i| (i as u8));

        let hashlock_info: vec<u8> = vector::empty<u8>();
        vector::push_back(&mut hashlock_info, 0x00);
        vector::push_back(&mut hashlock_info, 0x04);
        vector::append(
            &mut hashlock_info,
            vector::tabulate(30, |i| (i as u8))
        );

        let key_data = vector::empty<u8>();
        vector::append(&mut key_data, order_hash);
        vector::append(
            &mut key_data,
            vector::slice(&hashlock_info, 2, 32)
        );
        let key = aptos_hash::keccak256(key_data);

        let secret = b"partial_fill_secret_for_testing_32";
        let leaf = aptos_hash::keccak256(*secret);

        escrow_factory::store_validation<TestCoin>(
            &factory_account,
            key,
            leaf,
            1,
            FACTORY_ADDR
        );

        let extra_data_args = ExtraDataArgs {
            hashlock_info,
            dst_chain_id: 1,
            dst_token: types::address_from_u256(0x3333),
            deposits: (50000u256 << 128) + 25000u256,
            timelocks: create_test_timelocks()
        };

        escrow_factory::post_interaction<TestCoin>(
            &maker_account,
            order,
            order_hash,
            TAKER_ADDR,
            25000,
            50000,
            75000,
            extra_data_args,
            FACTORY_ADDR
        );

        let immutables = create_test_immutables_with_hash(order_hash, leaf);
        let (exists, escrow_type, amount, claimed, cancelled) =
            escrow_factory::get_escrow_details<TestCoin>(immutables, FACTORY_ADDR);

        assert!(exists, 22);
        assert!(escrow_type == 0, 23);
        assert!(amount == 25000, 24);
        assert!(!claimed, 25);
        assert!(!cancelled, 26);
    }

    #[test]
    #[expected_failure(abort_code = 0x80003)]
    fun test_invalid_secret_withdrawal() {
        let (factory_account, _maker_account, taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);
        let immutables =
            create_test_immutables_with_hash(
                vector::tabulate(32, |i| (i as u8)), hashlock
            );

        escrow_factory::create_dst_escrow<TestCoin>(
            &taker_account,
            immutables,
            timestamp::now_seconds() + 10000,
            FACTORY_ADDR
        );

        timestamp::update_global_time_for_testing_secs(timestamp::now_seconds() + 2000);

        let wrong_secret = b"wrong_secret_should_fail_testing_32";
        escrow_factory::withdraw<TestCoin>(
            &taker_account,
            *wrong_secret,
            immutables,
            FACTORY_ADDR
        );
    }

    #[test]
    #[expected_failure(abort_code = 0x80008)]
    fun test_invalid_dst_escrow_timing() {
        let (factory_account, _maker_account, taker_account) = setup_test_env();

        escrow_factory::initialize<TestCoin>(&factory_account, @0x1111, @0x2222);

        let secret = b"test_secret_for_escrow_testing_32";
        let hashlock = aptos_hash::keccak256(*secret);

        let current_time = timestamp::now_seconds();
        let bad_timelocks =
            types::timelocks_new(
                current_time + 1800,
                current_time + 3600,
                current_time + 1800,
                current_time + 4000
            );

        let immutables = Immutables {
            order_hash: vector::tabulate(32, |i| (i as u8)),
            hashlock,
            maker: types::address_from_u256(MAKER_ADDR as u256),
            taker: types::address_from_u256(TAKER_ADDR as u256),
            token: types::address_from_u256(0x1111),
            amount: 200000,
            safety_deposit: 25000,
            timelocks: bad_timelocks,
            parameters: vector::empty()
        };

        // This should fail due to invalid timing
        escrow_factory::create_dst_escrow<TestCoin>(
            &taker_account,
            immutables,
            current_time + 3600,
            FACTORY_ADDR
        );
    }
}
