#[derive(Clone, Debug)]
pub struct AptosConfig {
    pub rpc_url: String,
    pub private_key: String,
    pub contract_address: String,
    pub chain_id: u8,
}
