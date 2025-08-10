mod aptos;
mod eth;
use alloy::{
    dyn_abi::parser::Error,
    primitives::{Bytes, FixedBytes, U256},
};
use aptos::*;
use aptos_sdk::types::account_address::AccountAddress;
use eth::*;

fn main() -> Result<(), Error> {
    let config = EthereumConfig::load_from_env();
    let client = EthClient::new(config);
    let Ok(provider) = client.create_provider() else { panic!("Error creating provider") };

    Ok(())
}
