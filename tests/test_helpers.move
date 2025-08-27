#[test_only]
module fusion_aptos::test_helpers {
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

    fun setup_test_env(): (signer, signer, signer) {
        let factory_account = account::create_account_for_test(FACTORY_ADDR);
        let maker_account = account::create_account_for_test(MAKER_ADDR);
        let taker_account = account::create_account_for_test(TAKER_ADDR);

        timestamp::set_time_has_started_for_testing(&factory_account);
        timestamp::update_global_time_for_testing_secs(1000);

        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<TestCoin>(
                &factory_account,
                string::utf8(b"Test Coin"),
                string::utf8(b"TEST"),
                8,
                false
            );

        coin::register<TestCoin>(&maker_account);
        coin::register<TestCoin>(&taker_account);
        coin::register<TestCoin>(&factory_account);

        let maker_coins = coin::mint<TestCoin>(1000000, &mint_cap);
        let taker_coins = coin::mint<TestCoin>(1000000, &mint_cap);

        coin::deposit(MAKER_ADDR, maker_coins);
        coin::deposit(TAKER_ADDR, taker_coins);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_mint_cap(mint_cap);

        (factory_account, maker_account, taker_account)
    }

    fun create_test_immutables(): Immutables {
        create_test_immutables_with_hash(
            vector::tabulate(32, |i| (i as u8)),
            vector::tabulate(32, |i| ((i + 100) as u8))
        )
    }

    fun create_test_immutables_with_hash(
        order_hash: vector<u8>, hashlock: vector<u8>
    ): Immutables {
        Immutables {
            order_hash,
            hashlock,
            maker: types::address_from_u256(MAKER_ADDR as u256),
            taker: types::address_from_u256(TAKER_ADDR as u256),
            token: types::address_from_u256(0x1111),
            amount: 200000,
            safety_deposit: 25000,
            timelocks: create_test_timelocks(),
            parameters: vector::empty()
        }
    }
}
