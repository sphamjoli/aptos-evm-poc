module fusion_aptos::types {
    use std::vector;
    use aptos_framework::timestamp;

    struct Address has copy, drop, store {
        value: u256
    }

    struct Timelocks has copy, drop, store {
        src_withdrawal: u64,
        src_cancellation: u64,
        dst_withdrawal: u64,
        dst_cancellation: u64,
        deployed_at: u64
    }

    struct Immutables has copy, drop, store {
        order_hash: vector<u8>,
        hashlock: vector<u8>,
        maker: Address,
        taker: Address,
        token: Address,
        amount: u256,
        safety_deposit: u256,
        timelocks: Timelocks,
        parameters: vector<u8>
    }

    struct DstImmutablesComplement has copy, drop, store {
        maker: Address,
        amount: u256,
        token: Address,
        safety_deposit: u256,
        chain_id: u256,
        parameters: vector<u8>
    }

    struct ExtraDataArgs has copy, drop, store {
        hashlock_info: vector<u8>,
        dst_chain_id: u256,
        dst_token: Address,
        deposits: u256,
        timelocks: Timelocks
    }

    struct ValidationData has copy, drop, store {
        leaf: vector<u8>,
        index: u256
    }

    struct Order has copy, drop, store {
        salt: u256,
        maker: Address,
        receiver: Address,
        maker_asset: Address,
        taker_asset: Address,
        making_amount: u256,
        taking_amount: u256,
        maker_traits: u256
    }

    public fun address_from_u256(value: u256): Address {
        Address { value }
    }

    public fun address_to_u256(addr: &Address): u256 {
        addr.value
    }

    public fun address_get(addr: &Address): address {
        @aptos_framework
    }

    public fun timelocks_new(
        src_withdrawal: u64,
        src_cancellation: u64,
        dst_withdrawal: u64,
        dst_cancellation: u64
    ): Timelocks {
        Timelocks {
            src_withdrawal,
            src_cancellation,
            dst_withdrawal,
            dst_cancellation,
            deployed_at: 0
        }
    }

    public fun timelocks_set_deployed_at(
        timelocks: Timelocks, deployed_at: u64
    ): Timelocks {
        Timelocks {
            src_withdrawal: timelocks.src_withdrawal,
            src_cancellation: timelocks.src_cancellation,
            dst_withdrawal: timelocks.dst_withdrawal,
            dst_cancellation: timelocks.dst_cancellation,
            deployed_at
        }
    }

    public fun timelocks_get_stage(timelocks: &Timelocks, stage: u8): u64 {
        if (stage == 0) {
            timelocks.src_withdrawal
        } else if (stage == 1) {
            timelocks.src_cancellation
        } else if (stage == 2) {
            timelocks.dst_withdrawal
        } else if (stage == 3) {
            timelocks.dst_cancellation
        } else { 0 }
    }

    public fun STAGE_SRC_WITHDRAWAL(): u8 {
        0
    }

    public fun STAGE_SRC_CANCELLATION(): u8 {
        1
    }

    public fun STAGE_DST_WITHDRAWAL(): u8 {
        2
    }

    public fun STAGE_DST_CANCELLATION(): u8 {
        3
    }

    public fun immutables_hash(immutables: &Immutables): vector<u8> {
        use std::bcs;
        use aptos_std::aptos_hash;

        let hash_data: vec<u8> = vector::empty<u8>();
        vector::append(&mut hash_data, immutables.order_hash);
        vector::append(&mut hash_data, immutables.hashlock);
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.maker.value));
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.taker.value));
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.token.value));
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.amount));
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.safety_deposit));
        vector::append(&mut hash_data, bcs::to_bytes(&immutables.timelocks));

        aptos_hash::keccak256(hash_data)
    }

    public fun maker_traits_allow_multiple_fills(maker_traits: u256): bool {
        let multiple_fills_flag =
            0x4000000000000000000000000000000000000000000000000000000000000000u256;
        (maker_traits & multiple_fills_flag) != 0
    }

    public fun extract_parts_amount(hashlock_info: &vector<u8>): u256 {
        // This is equivalent to uint256(extraDataArgs.hashlockInfo) >> 240
        if (vector::length(hashlock_info) < 32) {
            return 0
        };

        let first_bytes = vector::slice(hashlock_info, 0, 2);
        let result = 0u256;
        let i = 0;
        while (i < vector::length(&first_bytes)) {
            result = (result << 8) + (*vector::borrow(&first_bytes, i) as u256);
            i = i + 1;
        };
        result
    }
}
