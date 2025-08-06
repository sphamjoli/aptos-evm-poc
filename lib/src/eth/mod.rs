use alloy::{
    network::EthereumWallet,
    primitives::{Address, Bytes, FixedBytes, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::{Filter, Log},
    signers::local::PrivateKeySigner,
    sol,
};
use aptos_sdk::types::account_address::AccountAddress;
use eyre::Result;
use std::str::FromStr;
use url::Url;


sol! {
    #[allow(missing_docs)]
    #[sol(rpc)]
    interface ILimitOrderProtocol {
        struct Order {
            uint256 salt;
            address maker;
            address receiver;
            address makerAsset;
            address takerAsset;
            uint256 makingAmount;
            uint256 takingAmount;
            uint256 makerTraits;
        }

        function fillOrderArgs(
            Order memory order,
            bytes32 r,
            bytes32 vs,
            uint256 amount,
            uint256 takerTraits,
            bytes calldata args,
        ) external returns (
            uint256 actualMakingAmount,
            uint256 actualTakingAmount,
            bytes32 orderHash,
        );

        function hashOrder(
            Order memory order,
        ) external view returns (
            bytes32,
        );
    }

    #[sol(rpc)]
    interface IEscrowFactory {
        struct Immutables {
            bytes32 orderHash;
            bytes32 hashlock;
            address maker;
            address taker;
            address token;
            uint256 amount;
            uint256 safetyDeposit;
            uint256 timelocks;
        }

        struct DstImmutablesComplement {
            address maker;
            uint256 amount;
            address token;
            uint256 safetyDeposit;
            uint256 chainId;
        }

        function addressOfEscrowSrc(
            Immutables memory immutables,
        ) external view returns (
            address,
        );

        event SrcEscrowCreated(
            Immutables srcImmutables,
            DstImmutablesComplement dstImmutablesComplement,
        );
    }

    #[sol(rpc)]
    interface IBaseEscrow {
        function withdraw(
            bytes32 secret,
            IEscrowFactory.Immutables memory immutables,
        ) external;
    }

    #[sol(rpc)]
    interface IERC20 {
        function transfer(
            address to,
            uint256 amount,
        ) external returns (bool);

        function transferFrom(
            address from,
            address to,
            uint256 amount,
        ) external returns (bool);

        function approve(
            address spender,
            uint256 amount,
        ) external returns (bool);

        function balanceOf(
            address account,
        ) external view returns (uint256);
    }
}

#[derive(Clone, Debug, Default)]
pub struct EthereumConfig {
    pub rpc_url: String,
    pub private_key: String,
    pub lop_address: Address,
    pub escrow_factory_address: Address,
    pub chain_id: u64,
}

#[warn(allow_dead)]
#[derive(Clone, Debug, Default)]
pub struct EthClient {
    pub config: EthereumConfig,
}

#[derive(Debug, Clone)]
pub struct SwapParams {
    pub amount: u64,
    pub recipient: AccountAddress,
    pub timeout_seconds: u64,
    pub hashlock: FixedBytes<32>,
}


#[derive(Clone)]
pub struct FillOrderParams {
    pub order: ILimitOrderProtocol::Order,
    pub r: FixedBytes<32>,
    pub vs: FixedBytes<32>,
    pub amount: U256,
    pub taker_traits: U256,
    pub args: Bytes,
}

impl EthereumConfig {
    pub fn new(
        rpc_url: String,
        private_key: String,
        lop_address: Address,
        escrow_factory_address: Address,
        chain_id: u64,
    ) -> Self {
        Self { rpc_url, private_key, lop_address, escrow_factory_address, chain_id }
    }
    pub fn load_from_env() -> Self {
        let rpc_url = std::env::var("ETH_RPC_URL").expect("ETH_RPC_URL not set in .env file");
        let private_key =
            std::env::var("PRIVATE_KEY_ETH").expect("PRIVATE_KEY_ETH not set in .env file");
        let lop_address = match std::env::var("LOOP_ADDRESS") {
            Ok(address) => Address::from_str(&address).unwrap_or_else(|err| panic!("LOOP_ADDRESS {err:?}")),
            Err(err) => panic!("LOOP_ADDRESS {err:?}"),
        };
        let escrow_factory_address = match std::env::var("ESCROW_FACTORY_ADDRESS") {
            Ok(address) => Address::from_str(&address).unwrap_or_else(|err| panic!("ESCROW_FACTORY_ADDRESS {err:?}")),
            Err(err) => panic!("ESCROW_FACTORY_ADDRESS {err:?}"),
        };
        let chain_id = match std::env::var("CHAIN_ID") {
            Ok(id) => u64::from_str(&id).unwrap_or_else(|err|panic!("CHAIN_ID {err:?}")),
            Err(err) => panic!("CHAIN_ID {err:?}"),
        };
        Self { rpc_url, private_key, lop_address, escrow_factory_address, chain_id }
    }
}

impl EthClient {
    fn new(config: EthereumConfig) -> Self {
        Self { config }
    }

    fn create_provider(&self) -> Result<impl Provider> {
        let url = Url::parse(&self.config.rpc_url)
            .unwrap_or_else(|err| panic!("Error converting rpc url {err:?}"));
        let pk_signer: PrivateKeySigner = self.config.private_key.parse()?;
        let wallet = EthereumWallet::new(pk_signer);
        Ok(ProviderBuilder::new().wallet(wallet).connect_http(url))
    }

    pub async fn fill_order(&self, order_params: FillOrderParams) -> Result<FixedBytes<32>> {

        let provider = self.create_provider()?;
        let lop = ILimitOrderProtocol::new(self.config.lop_address, &provider);
        let tx_hash = lop
            .fillOrderArgs(
                order_params.order,
                order_params.r,
                order_params.vs,
                order_params.amount,
                order_params.taker_traits,
                order_params.args,
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(tx_hash)
    }

    pub async fn watch_escrow_events(&self, from_block: Option<u64>) -> Result<Vec<Log>> {
        let filter = Filter::new()
            .address(self.config.escrow_factory_address)
            .from_block(from_block.unwrap_or(0));
        let provider = self.create_provider()?;

        let logs = provider.get_logs(&filter).await?;
        Ok(logs)
    }
    pub async fn get_escrow_address(
        &self,
        immutables: IEscrowFactory::Immutables,
    ) -> Result<Address> {
        let provider = self.create_provider()?;

        let escrow_factory = IEscrowFactory::new(self.config.escrow_factory_address, &provider);

        let address = escrow_factory.addressOfEscrowSrc(immutables).call().await?.0;

        Ok(Address::from(address))
    }
    pub async fn withdraw_escrow(
        &self,
        escrow_address: Address,
        secret: FixedBytes<32>,
        immutables: IEscrowFactory::Immutables,
    ) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;

        let escrow = IBaseEscrow::new(escrow_address, &provider);

        let tx_hash = escrow.withdraw(secret, immutables).send().await?.watch().await?;

        Ok(tx_hash)
    }
}



#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        node_bindings::{Anvil, AnvilInstance},
        primitives::{address, U256},
        providers::ext::AnvilApi,
    };
    use eyre::Result;
    use std::sync::LazyLock;

    static ANVIL_INSTANCE: LazyLock<AnvilInstance> = LazyLock::new(|| {
        Anvil::new()
            .fork("wss://ethereum-rpc.publicnode.com")
            .port(8544u16)
            .try_spawn()
            .expect("Failed to spawn anvil instance")
    });

    const TEST_PRIVATE_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const TEST_ADDRESS: Address = address!("f39Fd6e51aad88F6F4ce6aB8827279cffFb92266");

    fn get_test_config() -> EthereumConfig {
        EthereumConfig {
            rpc_url: ANVIL_INSTANCE.endpoint(),
            private_key: TEST_PRIVATE_KEY.to_string(),
            lop_address: address!("111111125421cA6dc452d289314280a0f8842A65"),
            escrow_factory_address: address!("a7bCb4EAc8964306F9e3764f67Db6A7af6DdF99A"),
            chain_id: 1,
        }
    }

    async fn setup_token_balances(provider: &impl Provider) -> Result<()> {
        let whale = address!("aD354CfBAa4A8572DD6Df021514a3931A8329Ef5");
        
        provider.anvil_set_balance(whale, U256::from(100) * U256::from(10).pow(U256::from(18))).await?;
       // provider.anvil_impersonate_account(whale).await?;
        
        //let usdc = IERC20::new(address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), &provider);
        //let _= usdc.transfer(TEST_ADDRESS, U256::from(1000000000)).send().await?;
        
      //  provider.anvil_stop_impersonating_account(whale).await?;
        Ok(())
    }

    #[tokio::test]
    async fn test_fill_order_usdc_eth() -> Result<()> {
        let config = get_test_config();
        let client = EthClient::new(config);
                    let provider = client.create_provider()?;

        setup_token_balances(&provider).await?;

        let order = ILimitOrderProtocol::Order {
            salt: U256::from(12345),
            maker: TEST_ADDRESS,
            receiver: address!("70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            makerAsset: address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            takerAsset: address!("0000000000000000000000000000000000000000"),
            makingAmount: U256::from(100000000),
            takingAmount: U256::from(30000000000000000u64),
            makerTraits: U256::ZERO,
        };

        let fill_params = FillOrderParams {
            order,
            r: FixedBytes::from([1u8; 32]),
            vs: FixedBytes::from([2u8; 32]),
            amount: U256::from(100000000),
            taker_traits: U256::ZERO,
            args: Bytes::new(),
        };

        let result = client.fill_order(fill_params).await;
        assert!(result.is_err());

        Ok(())
    }

    #[tokio::test]
    async fn test_fill_order_eth_usdc() -> Result<()> {
        let config = get_test_config();
        let client = EthClient::new(config);
            let provider = client.create_provider()?;
        setup_token_balances(&provider).await?;

        let order = ILimitOrderProtocol::Order {
            salt: U256::from(54321),
            maker: TEST_ADDRESS,
            receiver: address!("70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            makerAsset: address!("0000000000000000000000000000000000000000"),
            takerAsset: address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            makingAmount: U256::from(30000000000000000u64),
            takingAmount: U256::from(100000000),
            makerTraits: U256::ZERO,
        };

        let fill_params = FillOrderParams {
            order,
            r: FixedBytes::from([3u8; 32]),
            vs: FixedBytes::from([4u8; 32]),
            amount: U256::from(30000000000000000u64),
            taker_traits: U256::ZERO,
            args: Bytes::new(),
        };
    
        match client.fill_order(fill_params).await  {
            Ok(results)=> {
                let Some(reciept) = provider.get_transaction_receipt(results).await? else {
                    panic!("error getting reciept test_fill_order_eth_usdc")
                };
                let status:bool = reciept.status().into();
                assert!(status)
                
            },
            Err(err)=> panic!("test_fill_order_eth_usdc failed {err:?}")
        }


        Ok(())
    }

    #[tokio::test]
    async fn test_get_escrow_address() -> Result<()> {
        let config = get_test_config();
        let client = EthClient::new(config);

        let hashlock_bytes = hex::decode("6c9a2f9a94770336403e69e9ea5d88c97ef3b78a")?;
        let mut hashlock_array = [0u8; 32];
        hashlock_array[..hashlock_bytes.len()].copy_from_slice(&hashlock_bytes);

        let immutables = IEscrowFactory::Immutables {
            orderHash: FixedBytes::from([1u8; 32]),
            hashlock: FixedBytes::from(hashlock_array),
            maker: TEST_ADDRESS,
            taker: address!("70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            token: address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            amount: U256::from(100000000),
            safetyDeposit: U256::from(1000000),
            timelocks: U256::from(300),
        };

        let escrow_address = client.get_escrow_address(immutables).await?;
        assert_ne!(escrow_address, Address::ZERO);

        Ok(())
    }

    #[tokio::test]
    async fn test_withdraw_escrow() -> Result<()> {
        let config = get_test_config();
        let client = EthClient::new(config);

        let hashlock_bytes = hex::decode("6c9a2f9a94770336403e69e9ea5d88c97ef3b78a")?;
        let mut hashlock_array = [0u8; 32];
        hashlock_array[..hashlock_bytes.len()].copy_from_slice(&hashlock_bytes);

        let immutables = IEscrowFactory::Immutables {
            orderHash: FixedBytes::from([2u8; 32]),
            hashlock: FixedBytes::from(hashlock_array),
            maker: TEST_ADDRESS,
            taker: address!("70997970C51812dc3A010C7d01b50e0d17dc79C8"),
            token: address!("0000000000000000000000000000000000000000"),
            amount: U256::from(30000000000000000u64),
            safetyDeposit: U256::from(1000000000000000u64),
            timelocks: U256::from(600),
        };

        let escrow_address = client.get_escrow_address(immutables.clone()).await?;
        
        let secret_bytes = hex::decode("6c9a2f9a94770336403e69e9ea5d88c97ef3b78a")?;
        let mut secret_array = [0u8; 32];
        secret_array[..secret_bytes.len()].copy_from_slice(&secret_bytes);
        let secret = FixedBytes::from(secret_array);

        let result = client.withdraw_escrow(escrow_address, secret, immutables).await;
        assert!(result.is_err());

        Ok(())
    }
}
