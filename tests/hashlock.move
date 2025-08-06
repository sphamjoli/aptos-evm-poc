#[test_only]
module hashlock::cross_chain_integration_tests {
    use std::signer;
    use std::aptos_hash;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use hashlock::hashlock::{create_htlc, claim_htlc, refund_htlc, get_htlc_details};
    use hashlock::test_helpers::{setup, create_coin_and_mint};
    use aptos_framework::aptos_coin;
    use aptos_framework::genesis;

    struct USDCCoin has key {}

    struct EthereumData has drop {
        order_hash: vector<u8>,
        hash_lock: vector<u8>,
        escrow_address: vector<u8>,
        maker_address: vector<u8>,
        amount: u64
    }

    public fun get_eth_to_apt_data(): EthereumData {
        let preimage = b"cross_chain_secret_eth_apt";
        let hash_lock = aptos_hash::keccak256(preimage);
        EthereumData {
            order_hash: x"7dc03a955f48e68f8b72e85135e137e9644430e45e51f69576d2ea8705d85890",
            hash_lock,
            escrow_address: x"e54D0dfc2A3b7569F24F834326213C1aAc02551E",
            maker_address: x"4319E21132c13EabA87F390c12017d7cF9FbcF30",
            amount: 300000000000000000
        }
    }

    #[test(admin = @0x1, alice = @0x100, bob = @0x200)]
    fun test_eth_usdc_to_apt_successful_swap(
        admin: &signer, alice: &signer, bob: &signer
    ) {
        genesis::setup();
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        setup<AptosCoin>(admin);

        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        let bob_apt_balance = 1000000000;
        aptos_coin::mint(admin, bob_addr, bob_apt_balance);

        let eth_data = get_eth_to_apt_data();
        let apt_amount = 500000000;

        create_htlc<AptosCoin>(
            bob,
            alice_addr,
            apt_amount,
            eth_data.hash_lock,
            3600
        );

        let preimage = b"cross_chain_secret_eth_apt";
        claim_htlc<AptosCoin>(alice, bob_addr, 0, preimage);

        assert!(coin::balance<AptosCoin>(alice_addr) == apt_amount, 1);
        assert!(
            coin::balance<AptosCoin>(bob_addr) == bob_apt_balance - apt_amount,
            2
        );

        let (_, _, _, _, _, claimed, _) = get_htlc_details<AptosCoin>(bob_addr, 0);
        assert!(claimed, 3);
    }

    #[test(admin = @0x1, alice = @0x100, bob = @0x200)]
    fun test_apt_to_eth_usdc_successful_swap(
        admin: &signer, alice: &signer, bob: &signer
    ) {
        genesis::setup();
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        setup<USDCCoin>(admin);

        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        let alice_usdc_balance = 1000000000;
        let usdc_coins = create_coin_and_mint<USDCCoin>(admin, alice_usdc_balance);
        coin::register<USDCCoin>(alice);
        coin::deposit(alice_addr, usdc_coins);

        let preimage = b"apt_to_usdc_secret";
        let hash_lock = aptos_hash::keccak256(preimage);
        let usdc_amount = 300000000;

        create_htlc<USDCCoin>(alice, bob_addr, usdc_amount, hash_lock, 3600);

        coin::register<USDCCoin>(bob);
        claim_htlc<USDCCoin>(bob, alice_addr, 0, preimage);

        assert!(coin::balance<USDCCoin>(bob_addr) == usdc_amount, 1);
        assert!(
            coin::balance<USDCCoin>(alice_addr) == alice_usdc_balance - usdc_amount,
            2
        );

        let (_, _, _, _, _, claimed, _) = get_htlc_details<USDCCoin>(alice_addr, 0);
        assert!(claimed, 3);
    }

    #[test(admin = @0x1, alice = @0x100, bob = @0x200)]
    fun test_cross_chain_timeout_refund(
        admin: &signer, alice: &signer, bob: &signer
    ) {
        genesis::setup();
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        setup<AptosCoin>(admin);

        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);

        account::create_account_for_test(alice_addr);
        account::create_account_for_test(bob_addr);

        let initial_balance = 1000000000;
        aptos_coin::mint(admin, bob_addr, initial_balance);

        let preimage = b"failed_cross_chain_secret";
        let hash_lock = aptos_hash::keccak256(preimage);
        let amount = 400000000;

        create_htlc<AptosCoin>(bob, alice_addr, amount, hash_lock, 120);

        timestamp::fast_forward_seconds(121);
        refund_htlc<AptosCoin>(bob, 0);

        assert!(coin::balance<AptosCoin>(bob_addr) == initial_balance, 1);

        let (_, _, _, _, _, _, refunded) = get_htlc_details<AptosCoin>(bob_addr, 0);
        assert!(refunded, 2);
    }
}
