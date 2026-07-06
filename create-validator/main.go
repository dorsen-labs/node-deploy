package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"math/big"
	"os"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	validatorpb "github.com/prysmaticlabs/prysm/v5/proto/prysm/v1alpha1/validator-client"
	"github.com/prysmaticlabs/prysm/v5/validator/accounts/iface"
	"github.com/prysmaticlabs/prysm/v5/validator/accounts/wallet"
	"github.com/prysmaticlabs/prysm/v5/validator/keymanager"

	"create-validator/abi"
)

var (
	amount          = flag.Int("amount", 51, "amount of DC to delegate")
	rpcUrl          = flag.String("rpc-url", "http://127.0.0.1:8545", "rpc url")
	operatorKey     = flag.String("operator-key", "", "operator key")
	consensusKeyDir = flag.String("consensus-key-dir", "", "consensus keys dir")
	voteKeyDir      = flag.String("vote-key-dir", "", "vote keys dir")
	passwordPath    = flag.String("password-path", "", "password dir")
	moniker         = flag.String("moniker", "", "validator moniker")
	identity        = flag.String("identity", "", "validator identity")
	website         = flag.String("website", "", "validator website")
	details         = flag.String("details", "", "validator details")
)

func main() {
	flag.Parse()
	if *consensusKeyDir == "" {
		panic("consensus-key-dir is required")
	}
	if *voteKeyDir == "" {
		panic("vote-key-dir is required")
	}
	if *passwordPath == "" {
		panic("password-path is required")
	}
	if *operatorKey == "" {
		panic("operator-key is required (hex private key)")
	}
	if *moniker == "" || *identity == "" || *website == "" || *details == "" {
		panic("description flags required: --moniker, --identity, --website, --details")
	}
	client, err := ethclient.Dial(*rpcUrl)
	if err != nil {
		panic(err)
	}
	bz, err := os.ReadFile(*passwordPath)
	if err != nil {
		panic(err)
	}
	password := string(bytes.TrimSpace(bz))
	// Load consensus keystore — only for reading consensus address (NOT for signing)
	consensusKs := keystore.NewKeyStore(*consensusKeyDir+"/keystore", keystore.StandardScryptN, keystore.StandardScryptP)
	consensusAddr := consensusKs.Accounts()[0].Address
	// Load operator private key (signs the tx, has funds)
	operatorPrivKey, err := crypto.HexToECDSA(*operatorKey)
	if err != nil {
		panic(fmt.Errorf("invalid operator key: %w", err))
	}
	operatorAddr := crypto.PubkeyToAddress(operatorPrivKey.PublicKey)
	// Load BLS vote key + sign proof
	voteKm, err := getBlsKeymanager(*voteKeyDir+"/bls/wallet", password)
	if err != nil {
		panic(err)
	}
	pubkeys, err := voteKm.FetchValidatingPublicKeys(context.Background())
	if err != nil {
		panic(err)
	}
	pubKey := pubkeys[0]
	chainId, err := client.ChainID(context.Background())
	if err != nil {
		panic(err)
	}
	paddedChainIdBytes := make([]byte, 32)
	copy(paddedChainIdBytes[32-len(chainId.Bytes()):], chainId.Bytes())
	msgHash := crypto.Keccak256(append(operatorAddr.Bytes(), append(pubKey[:], paddedChainIdBytes...)...))
	req := validatorpb.SignRequest{
		PublicKey:   pubKey[:],
		SigningRoot: msgHash,
	}
	proof, err := voteKm.Sign(context.Background(), &req)
	if err != nil {
		panic(err)
	}
	delegation := new(big.Int).Mul(big.NewInt(int64(*amount)), big.NewInt(1e18))
	description := abi.StakeHubDescription{
		Moniker:  *moniker,
		Identity: *identity,
		Website:  *website,
		Details:  *details,
	}
	commission := abi.StakeHubCommission{
		Rate:          1000,
		MaxRate:       5000,
		MaxChangeRate: 5000,
	}
	stakeHubAbi, err := abi.StakeHubMetaData.GetAbi()
	if err != nil {
		panic(err)
	}
	data, err := stakeHubAbi.Pack("createValidator", consensusAddr, pubKey[:], proof.Marshal(), commission, description)
	if err != nil {
		panic(err)
	}
	nonce, err := client.PendingNonceAt(context.Background(), operatorAddr)
	if err != nil {
		panic(err)
	}
	gasPrice, err := client.SuggestGasPrice(context.Background())
	if err != nil {
		panic(err)
	}
	stakeHubAddr := common.HexToAddress("0x0000000000000000000000000000000000002002")
	tx := types.NewTx(&types.LegacyTx{
		Nonce:    nonce,
		To:       &stakeHubAddr,
		Value:    delegation,
		Gas:      2000000,
		GasPrice: gasPrice,
		Data:     data,
	})
	signer := types.NewEIP155Signer(chainId)
	signedTx, err := types.SignTx(tx, signer, operatorPrivKey)
	if err != nil {
		panic(err)
	}
	err = client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		panic(err)
	}
	fmt.Println("send createValidator. Tx hash:", signedTx.Hash().Hex())
	fmt.Printf("Operator:  %s\n", operatorAddr.Hex())
	fmt.Printf("Consensus: %s\n", consensusAddr.Hex())
	fmt.Printf("Delegation: %d DC\n", *amount)
}
func getBlsKeymanager(walletPath, password string) (keymanager.IKeymanager, error) {
	w, err := wallet.OpenWallet(context.Background(), &wallet.Config{
		WalletDir:      walletPath,
		WalletPassword: password,
	})
	if err != nil {
		panic(err)
	}
	km, err := w.InitializeKeymanager(context.Background(), iface.InitKeymanagerConfig{ListenForChanges: false})
	if err != nil {
		panic(err)
	}
	return km, nil
}
