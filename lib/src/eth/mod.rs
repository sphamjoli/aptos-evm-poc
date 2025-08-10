use alloy::{
    network::EthereumWallet,
    primitives::{Address as EthAddress, FixedBytes, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::{Filter, Log},
    signers::{Signer, local::PrivateKeySigner},
    sol,
};
use aptos_sdk::types::account_address::AccountAddress;
use eyre::Result;
use std::str::FromStr;
use url::Url;

sol! {
    #[sol(rpc)]
    contract AggregationRouterV6 {
        type MakerTraits is uint256;
        type TakerTraits is uint256;
        type Address is uint256;

        struct Order {
            uint256 salt;
            Address maker;
            Address receiver;
            Address makerAsset;
            Address takerAsset;
            uint256 makingAmount;
            uint256 takingAmount;
            MakerTraits makerTraits;
        }

        function fillOrder(
            Order calldata order,
            bytes32 r,
            bytes32 vs,
            uint256 amount,
            TakerTraits takerTraits
        ) external payable returns (uint256, uint256, bytes32);

        function hashOrder(Order calldata order) external view returns (bytes32);

        error OrderExpired();
        error PartialFillNotAllowed();
        error BadSignature();
        error InvalidatedOrder();
        error PrivateOrder();

        event OrderFilled(bytes32 indexed orderHash, uint256 remainingAmount);
        event OrderCancelled(bytes32 indexed orderHash);
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

    #[sol(rpc)]
    interface IWETH9 {
        function deposit() external payable;
        function withdraw(uint256 wad) external;
        function balanceOf(address account) external view returns (uint256);
        function approve(address spender, uint256 amount) external returns (bool);
    }

    #[sol(rpc)]
    interface ISwapRouter {
        struct ExactInputSingleParams {
            address tokenIn;
            address tokenOut;
            uint24 fee;
            address recipient;
            uint256 deadline;
            uint256 amountIn;
            uint256 amountOutMinimum;
            uint160 sqrtPriceLimitX96;
        }

        function exactInputSingle(
            ExactInputSingleParams calldata params
        ) external payable returns (uint256 amountOut);
    }

    #[sol(rpc)]
    interface IQuoter {
        function quoteExactInputSingle(
            address tokenIn,
            address tokenOut,
            uint24 fee,
            uint256 amountIn,
            uint160 sqrtPriceLimitX96
        ) external returns (uint256 amountOut);
    }

    #[sol(rpc)]
    interface IEscrowFactory {
              type Address is uint256;
              type Timelocks is uint256;

 struct Immutables {
        bytes32 orderHash;
        bytes32 hashlock;
        Address maker;
        Address taker;
        Address token;
        uint256 amount;
        uint256 safetyDeposit;
        Timelocks timelocks;
    }
        struct ExtraDataArgs {
        bytes32 hashlockInfo;
        uint256 dstChainId;
        Address dstToken;
        uint256 deposits;
        Timelocks timelocks;
    }

    struct DstImmutablesComplement {
        Address maker;
        uint256 amount;
        Address token;
        uint256 safetyDeposit;
        uint256 chainId;
    }

    struct CreateEscrowParams {
        bytes32 hashlock;
        address maker;
        address taker;
        address token;
        uint256 amount;
        uint256 safety_deposit;
        uint256 timelock;
        uint64 dst_chain_id;
    }

    event EscrowCancelled();
    event EscrowWithdrawal(bytes32 secret);
    event SrcEscrowCreated(Immutables srcImmutables, DstImmutablesComplement dstImmutablesComplement);
    event DstEscrowCreated(address escrow, bytes32 hashlock, Address taker);
    function withdraw(bytes32 secret, Immutables calldata immutables) external;
     function createDstEscrow(Immutables calldata dstImmutables, uint256 srcCancellationTimestamp) external payable;
    function addressOfEscrowSrc(Immutables calldata immutables) external view returns (address);
    function addressOfEscrowDst(Immutables calldata immutables) external view returns (address);

    }


}

use AggregationRouterV6::Order;

use crate::eth::IEscrowFactory::{CreateEscrowParams, Immutables};

#[derive(Clone, Debug, Default)]
pub struct EthereumConfig {
    pub rpc_url: String,
    pub private_key: String,
    pub lop_address: EthAddress,
    pub escrow_factory_address: EthAddress,
    pub chain_id: u64,
    pub weth: EthAddress,
}

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
    pub order: Order,
    pub r: FixedBytes<32>,
    pub vs: FixedBytes<32>,
    pub amount: U256,
    pub taker_traits: U256,
}

pub const ALLOW_MULTIPLE_FILLS_FLAG: U256 = U256::from_limbs([0, 0, 0, 0x4000000000000000]);
pub const MAKER_AMOUNT_FLAG: U256 = U256::from_limbs([0, 0, 0, 0x8000000000000000]);
pub const UNWRAP_WETH_FLAG: U256 = U256::from_limbs([0, 0, 0, 0x0100000000000000]);

impl EthereumConfig {
    pub fn new(
        rpc_url: String,
        private_key: String,
        lop_address: EthAddress,
        escrow_factory_address: EthAddress,
        chain_id: u64,
        weth: EthAddress,
    ) -> Self {
        Self { rpc_url, private_key, lop_address, escrow_factory_address, chain_id, weth }
    }

    pub fn load_from_env() -> Self {
        let rpc_url = std::env::var("RPC_URL").expect("RPC_URL not set in ENVIRONMENT");
        let private_key =
            std::env::var("PRIVATE_KEY_ETH").expect("PRIVATE_KEY_ETH not set in ENVIRONMENT");
        let lop_address =
            EthAddress::from_str(&std::env::var("LOOP_ADDRESS").expect("LOOP_ADDRESS not set"))
                .unwrap();
        let escrow_factory_address = EthAddress::from_str(
            &std::env::var("ESCROW_FACTORY_ADDRESS").expect("ESCROW_FACTORY_ADDRESS not set"),
        )
        .unwrap();
        let chain_id =
            u64::from_str(&std::env::var("CHAIN_ID").expect("CHAIN_ID not set")).unwrap();
        let weth = EthAddress::from_str(&std::env::var("WETH").expect("WETH not set")).unwrap();
        Self { rpc_url, private_key, lop_address, escrow_factory_address, chain_id, weth }
    }
}

impl EthClient {
    pub fn new(config: EthereumConfig) -> Self {
        Self { config }
    }

    pub fn create_provider(&self) -> Result<impl Provider> {
        let url = Url::parse(&self.config.rpc_url)?;
        let pk_signer: PrivateKeySigner = self.config.private_key.parse()?;
        let wallet = EthereumWallet::new(pk_signer);
        Ok(ProviderBuilder::new().wallet(wallet).connect_http(url))
    }

    pub fn eth_address_to_custom_address(addr: EthAddress) -> U256 {
        U256::from_be_bytes(addr.into_word().0)
    }

    pub fn custom_address_to_eth_address(addr: U256) -> EthAddress {
        EthAddress::from_word(FixedBytes::from_slice(&addr.to_be_bytes::<32>()))
    }

    pub fn create_maker_traits_with_allowed_sender(allowed_sender: Option<EthAddress>) -> U256 {
        let mut traits = ALLOW_MULTIPLE_FILLS_FLAG;
        if let Some(sender) = allowed_sender {
            let sender_u160 = U256::from_be_bytes(sender.into_word().0);
            let mask = U256::from((1u128 << 80) - 1);
            traits |= sender_u160 & mask;
        }
        traits
    }

    pub fn create_taker_traits(use_maker_amount: bool) -> U256 {
        if use_maker_amount { MAKER_AMOUNT_FLAG } else { U256::ZERO }
    }

    pub fn create_order(
        salt: U256,
        maker: EthAddress,
        receiver: EthAddress,
        maker_asset: EthAddress,
        taker_asset: EthAddress,
        making_amount: U256,
        taking_amount: U256,
        maker_traits: U256,
    ) -> Order {
        Order {
            salt,
            maker: Self::eth_address_to_custom_address(maker),
            receiver: Self::eth_address_to_custom_address(receiver),
            makerAsset: Self::eth_address_to_custom_address(maker_asset),
            takerAsset: Self::eth_address_to_custom_address(taker_asset),
            makingAmount: making_amount,
            takingAmount: taking_amount,
            makerTraits: maker_traits,
        }
    }

    pub async fn get_order_hash(&self, order: &Order) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;
        let lop = AggregationRouterV6::new(self.config.lop_address, &provider);
        let order_hash = lop.hashOrder(order.clone()).call().await?;
        Ok(order_hash)
    }

    pub async fn sign_order(&self, order: &Order) -> Result<(FixedBytes<32>, FixedBytes<32>)> {
        let order_hash = self.get_order_hash(order).await?;
        let signer: PrivateKeySigner = self.config.private_key.parse()?;
        let signature = signer.sign_hash(&order_hash).await?;
        let r = signature.r();
        let mut s = signature.s();
        let v = signature.v();
        if v {
            s |= U256::from(1) << 255;
        }
        let r_bytes = FixedBytes::from_slice(&r.to_be_bytes::<32>());
        let vs_bytes = FixedBytes::from_slice(&s.to_be_bytes::<32>());
        Ok((r_bytes, vs_bytes))
    }

    pub async fn fill_order(&self, order_params: FillOrderParams) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;
        let lop = AggregationRouterV6::new(self.config.lop_address, &provider);
        let weth_address = Self::eth_address_to_custom_address(self.config.weth);
        let is_eth_taker = order_params.order.takerAsset == weth_address;
        let mut call = lop.fillOrder(
            order_params.order.clone(),
            order_params.r,
            order_params.vs,
            order_params.amount,
            order_params.taker_traits,
        );
        if is_eth_taker {
            call = call.value(order_params.amount);
        }
        let tx_hash = call.send().await?.watch().await?;
        Ok(tx_hash)
    }

    pub async fn create_dst_escrow(&self, params: CreateEscrowParams) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;
        let escrow_factory = IEscrowFactory::new(self.config.escrow_factory_address, &provider);

        let immutables = Immutables {
            orderHash: FixedBytes::ZERO,
            hashlock: params.hashlock,
            maker: Self::eth_address_to_custom_address(params.maker),
            taker: Self::eth_address_to_custom_address(params.taker),
            token: Self::eth_address_to_custom_address(params.token),
            amount: params.amount,
            safetyDeposit: params.safety_deposit,
            timelocks: params.timelock,
        };

        let mut call = escrow_factory.createDstEscrow(immutables, params.timelock);

        if params.token == self.config.weth {
            call = call.value(params.amount + params.safety_deposit);
        }

        let tx_hash = call.send().await?.watch().await?;
        Ok(tx_hash)
    }

    pub async fn withdraw_from_escrow(
        &self,
        secret: FixedBytes<32>,
        immutables: Immutables,
    ) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;
        let escrow_factory = IEscrowFactory::new(self.config.escrow_factory_address, &provider);
        let tx_hash = escrow_factory.withdraw(secret, immutables).send().await?.watch().await?;
        Ok(tx_hash)
    }

    pub async fn get_escrow_src_address(&self, immutables: Immutables) -> Result<EthAddress> {
        let provider = self.create_provider()?;
        let escrow_factory = IEscrowFactory::new(self.config.escrow_factory_address, &provider);
        let address = escrow_factory.addressOfEscrowSrc(immutables).call().await?;
        Ok(address)
    }

    pub async fn get_escrow_dst_address(&self, immutables: Immutables) -> Result<EthAddress> {
        let provider = self.create_provider()?;
        let escrow_factory = IEscrowFactory::new(self.config.escrow_factory_address, &provider);
        let address = escrow_factory.addressOfEscrowDst(immutables).call().await?;
        Ok(address)
    }

    pub async fn watch_escrow_events(&self, from_block: Option<u64>) -> Result<Vec<Log>> {
        let filter = Filter::new()
            .address(self.config.escrow_factory_address)
            .from_block(from_block.unwrap_or(0));
        let provider = self.create_provider()?;
        let logs = provider.get_logs(&filter).await?;
        Ok(logs)
    }

    pub async fn approve_token(
        &self,
        token: EthAddress,
        spender: EthAddress,
        amount: U256,
    ) -> Result<FixedBytes<32>> {
        let provider = self.create_provider()?;
        let token_contract = IERC20::new(token, &provider);
        let tx_hash = token_contract.approve(spender, amount).send().await?.watch().await?;
        Ok(tx_hash)
    }

    pub async fn get_token_balance(&self, token: EthAddress, account: EthAddress) -> Result<U256> {
        let provider = self.create_provider()?;
        let token_contract = IERC20::new(token, &provider);
        let balance = token_contract.balanceOf(account).call().await?;
        Ok(balance)
    }
}

#[cfg(test)]
mod tests {
    use crate::eth::IEscrowFactory::CreateEscrowParams;

    use super::*;
    use alloy::{
        node_bindings::{Anvil, AnvilInstance},
        primitives::{U160, U256, address, aliases::U24, keccak256},
        providers::ext::AnvilApi,
    };
    use eyre::Result;
    use std::{env, sync::LazyLock};

    const TEST_PRIVATE_KEY: &str =
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const TEST_PRIVATE_KEY_2: &str =
        "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
    const TEST_ADDRESS: EthAddress = address!("f39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    const TEST_ADDRESS_2: EthAddress = address!("70997970C51812dc3A010C7d01b50e0d17dc79C8");
    const USDC_ADDRESS: EthAddress = address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    const SWAP_ROUTER_ADDRESS: EthAddress = address!("E592427A0AEce92De3Edee1F18E0157C05861564");
    const WETH_ADDRESS: EthAddress = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");

    static ANVIL_INSTANCE: LazyLock<AnvilInstance> = LazyLock::new(|| {
        Anvil::new()
            .fork("https://gateway.tenderly.co/public/mainnet")
            .port(8544u16)
            .try_spawn()
            .expect("Failed to spawn anvil instance")
    });

    sol! {
        #[sol(rpc)]
        interface IWETH9 {
            function deposit() external payable;
            function withdraw(uint256 wad) external;
            function balanceOf(address account) external view returns (uint256);
            function approve(address spender, uint256 amount) external returns (bool);
        }

        #[sol(rpc)]
        interface ISwapRouter {
            struct ExactInputSingleParams {
                address tokenIn;
                address tokenOut;
                uint24 fee;
                address recipient;
                uint256 deadline;
                uint256 amountIn;
                uint256 amountOutMinimum;
                uint160 sqrtPriceLimitX96;
            }

            function exactInputSingle(
                ExactInputSingleParams calldata params
            ) external payable returns (uint256 amountOut);
        }
    }

    fn get_test_config(private_key: &str) -> EthereumConfig {
        EthereumConfig {
            rpc_url: ANVIL_INSTANCE.endpoint().into(),
            private_key: private_key.to_string(),
            lop_address: address!("111111125421cA6dc452d289314280a0f8842A65"),
            escrow_factory_address: address!("a7bCb4EAc8964306F9e3764f67Db6A7af6DdF99A"),
            chain_id: 1,
            weth: WETH_ADDRESS,
        }
    }

    async fn setup_user_with_tokens(
        provider: &impl Provider,
        user_address: EthAddress,
    ) -> Result<()> {
        provider
            .anvil_set_balance(user_address, U256::from(100) * U256::from(10).pow(U256::from(18)))
            .await?;

        let eth_amount = U256::from(5) * U256::from(10).pow(U256::from(17));
        let weth = IWETH9::new(WETH_ADDRESS, &provider);
        let usdc = IERC20::new(USDC_ADDRESS, &provider);
        let swap_router = ISwapRouter::new(SWAP_ROUTER_ADDRESS, &provider);

        weth.deposit().value(eth_amount).from(user_address).send().await?.watch().await?;

        weth.approve(SWAP_ROUTER_ADDRESS, eth_amount)
            .from(user_address)
            .send()
            .await?
            .watch()
            .await?;

        let deadline = U256::from(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
                + 300,
        );

        let swap_params = ISwapRouter::ExactInputSingleParams {
            tokenIn: WETH_ADDRESS,
            tokenOut: USDC_ADDRESS,
            fee: U24::from(3000),
            recipient: user_address,
            deadline,
            amountIn: eth_amount,
            amountOutMinimum: U256::ZERO,
            sqrtPriceLimitX96: U160::ZERO,
        };

        swap_router.exactInputSingle(swap_params).from(user_address).send().await?.watch().await?;

        let usdc_balance = usdc.balanceOf(user_address).call().await?;
        println!("USDC balance for {user_address}: {usdc_balance}");

        Ok(())
    }

    #[tokio::test]
    async fn test_client_creation() -> Result<()> {
        let config = get_test_config(TEST_PRIVATE_KEY);
        let client = EthClient::new(config.clone());

        assert_eq!(client.config.rpc_url, config.rpc_url);
        assert_eq!(client.config.private_key, config.private_key);
        assert_eq!(client.config.lop_address, config.lop_address);
        assert_eq!(client.config.escrow_factory_address, config.escrow_factory_address);
        assert_eq!(client.config.chain_id, config.chain_id);

        Ok(())
    }

    #[tokio::test]
    async fn test_provider_creation() -> Result<()> {
        let config = get_test_config(TEST_PRIVATE_KEY);
        let client = EthClient::new(config);

        let provider = client.create_provider()?;
        let chain_id = provider.get_chain_id().await?;
        assert!(chain_id == 1);

        Ok(())
    }

    #[tokio::test]
    async fn test_load_from_env() -> Result<()> {
        env::set_var("WETH", WETH_ADDRESS.to_string());
        env::set_var("PRIVATE_KEY_ETH", TEST_PRIVATE_KEY.to_string());
        env::set_var(
            "LOOP_ADDRESS",
            address!("111111125421cA6dc452d289314280a0f8842A65").to_string(),
        );
        env::set_var(
            "ESCROW_FACTORY_ADDRESS",
            address!("a7bCb4EAc8964306F9e3764f67Db6A7af6DdF99A").to_string(),
        );
        env::set_var("CHAIN_ID", "1");
        env::set_var("RPC_URL", ANVIL_INSTANCE.endpoint().to_string());

        let config = EthereumConfig::load_from_env();

        assert_eq!(config.weth, WETH_ADDRESS, "WETH address mismatch");
        assert_eq!(config.private_key, TEST_PRIVATE_KEY, "Private key mismatch");
        assert_eq!(
            config.lop_address,
            address!("111111125421cA6dc452d289314280a0f8842A65"),
            "Loop address mismatch"
        );
        assert_eq!(
            config.escrow_factory_address,
            address!("a7bCb4EAc8964306F9e3764f67Db6A7af6DdF99A"),
            "Escrow factory address mismatch"
        );
        assert_eq!(config.chain_id, 1, "Chain ID mismatch");
        assert_eq!(config.rpc_url, ANVIL_INSTANCE.endpoint(), "RPC URL mismatch");

        let client = EthClient::new(config);
        let provider = client.create_provider()?;
        let chain_id = provider.get_chain_id().await?;
        assert!(chain_id == 1);
        Ok(())
    }

    #[tokio::test]
    async fn test_address_conversion() -> Result<()> {
        let test_addr = TEST_ADDRESS;
        let converted = EthClient::eth_address_to_custom_address(test_addr);

        assert_ne!(converted, U256::ZERO);
        assert_eq!(converted, U256::from_be_bytes(test_addr.into_word().0));

        let back_converted = EthClient::custom_address_to_eth_address(converted);
        assert_eq!(back_converted, test_addr);

        Ok(())
    }

    #[tokio::test]
    async fn test_maker_traits_creation() -> Result<()> {
        let public_traits = EthClient::create_maker_traits_with_allowed_sender(None);
        assert_eq!(public_traits, ALLOW_MULTIPLE_FILLS_FLAG);

        let private_traits = EthClient::create_maker_traits_with_allowed_sender(Some(TEST_ADDRESS));
        assert_ne!(private_traits, ALLOW_MULTIPLE_FILLS_FLAG);

        let private_traits_2 =
            EthClient::create_maker_traits_with_allowed_sender(Some(TEST_ADDRESS_2));
        assert_ne!(private_traits_2, ALLOW_MULTIPLE_FILLS_FLAG);
        assert_ne!(private_traits, private_traits_2);

        Ok(())
    }

    #[tokio::test]
    async fn test_hash_order_simple() -> Result<()> {
        let config = get_test_config(TEST_PRIVATE_KEY);
        let client = EthClient::new(config);

        let order = EthClient::create_order(
            U256::from(1),
            TEST_ADDRESS,
            TEST_ADDRESS,
            WETH_ADDRESS,
            USDC_ADDRESS,
            U256::from(1),
            U256::from(1),
            EthClient::create_maker_traits_with_allowed_sender(None),
        );

        let hash = client.get_order_hash(&order).await?;
        assert_ne!(hash, FixedBytes::ZERO);

        Ok(())
    }

    #[tokio::test]
    async fn test_cross_address_order_address1_makes_address2_takes() -> Result<()> {
        let config1 = get_test_config(TEST_PRIVATE_KEY);
        let config2 = get_test_config(TEST_PRIVATE_KEY_2);
        let client1 = EthClient::new(config1.clone());
        let client2 = EthClient::new(config2.clone());
        let provider1 = client1.create_provider()?;
        let provider2 = client2.create_provider()?;
        setup_user_with_tokens(&provider1, TEST_ADDRESS).await?;
        setup_user_with_tokens(&provider2, TEST_ADDRESS_2).await?;

        let usdc = IERC20::new(USDC_ADDRESS, &provider1);
        usdc.approve(config1.lop_address, U256::MAX)
            .from(TEST_ADDRESS)
            .send()
            .await?
            .watch()
            .await?;

        let making_amount = U256::from(100_000_000);
        let taking_amount = U256::from(50_000_000_000_000_000u64);

        let order = EthClient::create_order(
            U256::from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
            ),
            TEST_ADDRESS,
            TEST_ADDRESS,
            USDC_ADDRESS,
            WETH_ADDRESS,
            making_amount,
            taking_amount,
            EthClient::create_maker_traits_with_allowed_sender(Some(TEST_ADDRESS_2)),
        );

        let (r, vs) = client1.sign_order(&order).await?;
        println!("Order signed by maker (TEST_ADDRESS)");

        let eth_balance = provider1.get_balance(TEST_ADDRESS_2).await?;
        println!("TEST_ADDRESS_2 ETH balance: {}", eth_balance);
        assert!(eth_balance >= taking_amount, "Insufficient ETH balance for taker");

        let fill_params =
            FillOrderParams { order, r, vs, amount: taking_amount, taker_traits: U256::ZERO };

        let tx_hash = client2.fill_order(fill_params).await?;

        let receipt = provider2.get_transaction_receipt(tx_hash).await?.unwrap();
        assert!(receipt.status());

        println!("Cross-address order (1->2) filled successfully: {tx_hash}");

        let usdc_balance_maker = usdc.balanceOf(TEST_ADDRESS).call().await?;
        let usdc_balance_taker = usdc.balanceOf(TEST_ADDRESS_2).call().await?;
        println!(
            "After trade - Maker USDC: {}, Taker USDC: {}",
            usdc_balance_maker, usdc_balance_taker
        );

        Ok(())
    }

    #[tokio::test]
    async fn test_cross_address_order_address2_makes_address1_takes() -> Result<()> {
        let config1 = get_test_config(TEST_PRIVATE_KEY);
        let config2 = get_test_config(TEST_PRIVATE_KEY_2);
        let client1 = EthClient::new(config1.clone());
        let client2 = EthClient::new(config2.clone());
        let provider1 = client1.create_provider()?;
        let provider2 = client2.create_provider()?;
        setup_user_with_tokens(&provider1, TEST_ADDRESS).await?;
        setup_user_with_tokens(&provider2, TEST_ADDRESS_2).await?;

        let usdc = IERC20::new(USDC_ADDRESS, &provider2);
        usdc.approve(config2.lop_address, U256::MAX)
            .from(TEST_ADDRESS_2)
            .send()
            .await?
            .watch()
            .await?;

        let making_amount = U256::from(50_000_000);
        let taking_amount = U256::from(25_000_000_000_000_000u64);

        let order = EthClient::create_order(
            U256::from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
            ),
            TEST_ADDRESS_2,
            TEST_ADDRESS_2,
            USDC_ADDRESS,
            WETH_ADDRESS,
            making_amount,
            taking_amount,
            EthClient::create_maker_traits_with_allowed_sender(None),
        );

        let (r, vs) = client2.sign_order(&order).await?;

        let fill_params =
            FillOrderParams { order, r, vs, amount: taking_amount, taker_traits: U256::ZERO };

        let tx_hash = client1.fill_order(fill_params).await?;
        let receipt = provider1.get_transaction_receipt(tx_hash).await?.unwrap();
        assert!(receipt.status());
        println!("Cross-address order (2->1) filled successfully: {tx_hash}");

        Ok(())
    }

    #[tokio::test]
    async fn test_private_order_cross_address() -> Result<()> {
        let config1 = get_test_config(TEST_PRIVATE_KEY);
        let config2 = get_test_config(TEST_PRIVATE_KEY_2);
        let client1 = EthClient::new(config1.clone());
        let client2 = EthClient::new(config2.clone());
        let provider1 = client1.create_provider()?;
        let provider2 = client2.create_provider()?;
        setup_user_with_tokens(&provider1, TEST_ADDRESS).await?;
        setup_user_with_tokens(&provider2, TEST_ADDRESS_2).await?;

        let usdc = IERC20::new(USDC_ADDRESS, &provider1);
        usdc.approve(config1.lop_address, U256::MAX)
            .from(TEST_ADDRESS)
            .send()
            .await?
            .watch()
            .await?;

        let making_amount = U256::from(100_000_000);
        let taking_amount = U256::from(50_000_000_000_000_000u64);

        let order = EthClient::create_order(
            U256::from(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
            ),
            TEST_ADDRESS,
            TEST_ADDRESS,
            USDC_ADDRESS,
            WETH_ADDRESS,
            making_amount,
            taking_amount,
            EthClient::create_maker_traits_with_allowed_sender(Some(TEST_ADDRESS_2)),
        );

        let (r, vs) = client1.sign_order(&order).await?;

        let fill_params =
            FillOrderParams { order, r, vs, amount: taking_amount, taker_traits: U256::ZERO };

        let tx_hash = client2.fill_order(fill_params).await?;
        let receipt = provider2.get_transaction_receipt(tx_hash).await?.unwrap();
        assert!(receipt.status());
        println!("Private order (restricted to address 2) filled successfully: {tx_hash}");

        Ok(())
    }

    #[tokio::test]
    async fn test_bidirectional_trading() -> Result<()> {
        let config1 = get_test_config(TEST_PRIVATE_KEY);
        let config2 = get_test_config(TEST_PRIVATE_KEY_2);
        let client1 = EthClient::new(config1.clone());
        let client2 = EthClient::new(config2.clone());
        let provider1 = client1.create_provider()?;
        let provider2 = client2.create_provider()?;
        setup_user_with_tokens(&provider1, TEST_ADDRESS).await?;
        setup_user_with_tokens(&provider2, TEST_ADDRESS_2).await?;

        let usdc = IERC20::new(USDC_ADDRESS, &provider1);
        usdc.approve(config1.lop_address, U256::MAX)
            .from(TEST_ADDRESS)
            .send()
            .await?
            .watch()
            .await?;
        let usdc = IERC20::new(USDC_ADDRESS, &provider2);
        usdc.approve(config2.lop_address, U256::MAX)
            .from(TEST_ADDRESS_2)
            .send()
            .await?
            .watch()
            .await?;

        let order1 = EthClient::create_order(
            U256::from(1001),
            TEST_ADDRESS,
            TEST_ADDRESS,
            USDC_ADDRESS,
            WETH_ADDRESS,
            U256::from(50_000_000),
            U256::from(25_000_000_000_000_000u64),
            EthClient::create_maker_traits_with_allowed_sender(None),
        );

        let (r1, vs1) = client1.sign_order(&order1).await?;
        let fill_params1 = FillOrderParams {
            order: order1,
            r: r1,
            vs: vs1,
            amount: U256::from(25_000_000_000_000_000u64),
            taker_traits: U256::ZERO,
        };

        let tx_hash1 = client2.fill_order(fill_params1).await?;
        let receipt1 = provider2.get_transaction_receipt(tx_hash1).await?.unwrap();
        assert!(receipt1.status());
        println!("First bidirectional trade completed: {tx_hash1}");

        let order2 = EthClient::create_order(
            U256::from(2002),
            TEST_ADDRESS_2,
            TEST_ADDRESS_2,
            USDC_ADDRESS,
            WETH_ADDRESS,
            U256::from(50_000_000),
            U256::from(25_000_000_000_000_000u64),
            EthClient::create_maker_traits_with_allowed_sender(None),
        );

        let (r2, vs2) = client2.sign_order(&order2).await?;
        let fill_params2 = FillOrderParams {
            order: order2,
            r: r2,
            vs: vs2,
            amount: U256::from(25_000_000_000_000_000u64),
            taker_traits: U256::ZERO,
        };

        let tx_hash2 = client1.fill_order(fill_params2).await?;
        let receipt2 = provider1.get_transaction_receipt(tx_hash2).await?.unwrap();
        assert!(receipt2.status());
        println!("Second bidirectional trade completed: {tx_hash2}");

        Ok(())
    }

    #[tokio::test]
    async fn test_escrow_address_calculation() -> Result<()> {
        let config1 = get_test_config(TEST_PRIVATE_KEY);
        let config2 = get_test_config(TEST_PRIVATE_KEY_2);
        let client1 = EthClient::new(config1.clone());
        let client2 = EthClient::new(config2.clone());
        let provider1 = client1.create_provider()?;
        let provider2 = client2.create_provider()?;
        setup_user_with_tokens(&provider1, TEST_ADDRESS).await?;
        setup_user_with_tokens(&provider2, TEST_ADDRESS_2).await?;

        let hashlock_bytes = hex::decode("6c9a2f9a94770336403e69e9ea5d88c97ef3b78a")?;
        let mut hashlock_array = [0u8; 32];
        hashlock_array[..hashlock_bytes.len()].copy_from_slice(&hashlock_bytes);

        let immutables = IEscrowFactory::Immutables {
            orderHash: FixedBytes::from([1u8; 32]),
            hashlock: FixedBytes::from(hashlock_array),
            maker: EthClient::eth_address_to_custom_address(TEST_ADDRESS),
            taker: EthClient::eth_address_to_custom_address(TEST_ADDRESS_2),
            token: EthClient::eth_address_to_custom_address(USDC_ADDRESS),
            amount: U256::from(100000000),
            safetyDeposit: U256::from(1000000),
            timelocks: U256::from(300),
        };

        let escrow_address1 = client1.get_escrow_src_address(immutables.clone()).await?;
        let escrow_address2 = client2.get_escrow_src_address(immutables).await?;

        assert_ne!(escrow_address1, EthAddress::ZERO);
        assert_eq!(escrow_address1, escrow_address2);
        Ok(())
    }

    #[tokio::test]
    async fn test_create_escrow_and_withdraw() -> Result<()> {
        let client = EthClient::new(get_test_config(TEST_PRIVATE_KEY));
        let secret = FixedBytes::from([1u8; 32]);
        let hashlock = keccak256(secret.as_slice());

        let params = CreateEscrowParams {
            hashlock,
            maker: TEST_ADDRESS,
            taker: TEST_ADDRESS_2,
            token: USDC_ADDRESS,
            amount: U256::from(1000000),
            safety_deposit: U256::from(100000),
            timelock: U256::from(1000000000),
            dst_chain_id: 1,
        };

        let immutables = Immutables {
            orderHash: FixedBytes::ZERO,
            hashlock,
            maker: EthClient::eth_address_to_custom_address(params.maker),
            taker: EthClient::eth_address_to_custom_address(params.taker),
            token: EthClient::eth_address_to_custom_address(params.token),
            amount: params.amount,
            safetyDeposit: params.safety_deposit,
            timelocks: params.timelock,
        };

        let escrow_address = client.get_escrow_dst_address(immutables.clone()).await?;
        assert_ne!(escrow_address, EthAddress::ZERO);

        Ok(())
    }

    #[tokio::test]
    async fn test_escrow_address_computation() -> Result<()> {
        let client = EthClient::new(get_test_config(TEST_PRIVATE_KEY));
        let hashlock = keccak256(b"test");

        let immutables = Immutables {
            orderHash: FixedBytes::ZERO,
            hashlock,
            maker: U256::from(1),
            taker: U256::from(2),
            token: U256::from(3),
            amount: U256::from(1000),
            safetyDeposit: U256::from(100),
            timelocks: U256::from(1000000),
        };

        let src_address = client.get_escrow_src_address(immutables.clone()).await?;
        let dst_address = client.get_escrow_dst_address(immutables).await?;

        assert_ne!(src_address, EthAddress::ZERO);
        assert_ne!(dst_address, EthAddress::ZERO);
        assert_ne!(src_address, dst_address);

        Ok(())
    }

    #[tokio::test]
    async fn test_evm_only_escrow_flow() -> Result<()> {
        let client = EthClient::new(get_test_config(TEST_PRIVATE_KEY));
        let secret = FixedBytes::from([42u8; 32]);
        let hashlock = keccak256(secret.as_slice());

        let maker = EthAddress::from([1u8; 20]);
        let taker = EthAddress::from([2u8; 20]);
        let token = EthAddress::from([3u8; 20]);

        let params = CreateEscrowParams {
            hashlock,
            maker,
            taker,
            token,
            amount: U256::from(5000000),
            safety_deposit: U256::from(500000),
            timelock: U256::from(2000000000),
            dst_chain_id: 31337,
        };

        let immutables = Immutables {
            orderHash: FixedBytes::ZERO,
            hashlock,
            maker: EthClient::eth_address_to_custom_address(maker),
            taker: EthClient::eth_address_to_custom_address(taker),
            token: EthClient::eth_address_to_custom_address(token),
            amount: params.amount,
            safetyDeposit: params.safety_deposit,
            timelocks: params.timelock,
        };

        let escrow_address = client.get_escrow_dst_address(immutables).await?;
        assert_ne!(escrow_address, EthAddress::ZERO);

        Ok(())
    }
}
