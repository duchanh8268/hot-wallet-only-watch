import 'dart:convert';
import 'dart:typed_data';

import 'package:chain_core_interface/chain_core_interface.dart';
import 'package:evm_core/evm_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hot_wallet_web/chains/evm/evm_hot_plugin.dart';
import 'package:hot_wallet_web/chains/evm/services/evm_rpc_service.dart';
import 'package:hot_wallet_web/chains/evm/services/hyperliquid_service.dart';
import 'package:hot_wallet_web/core/services/hot_chain_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('EvmHotPlugin & EVM Services Tests', () {
    test('HotChainRegistry contains Ethereum and Hyperliquid plugins', () {
      final registry = HotChainRegistry();
      final eth = registry.getPlugin(ChainId.ethereum);
      final hl = registry.getPlugin(ChainId.hyperliquid);

      expect(eth.chainId, equals(ChainId.ethereum));
      expect(hl.chainId, equals(ChainId.hyperliquid));

      expect(registry.findPluginForUr('eth-account'), isNotNull);
      expect(registry.findPluginForUr('eth-sign-request'), isNotNull);
      expect(registry.findPluginForUr('eth-sign-response'), isNotNull);
    });

    test('Assembles valid signed EIP-1559 transaction from Cold Wallet response', () {
      final plugin = EvmHotPlugin.ethereum;
      final tx = Eip1559Transaction(
        chainId: 1,
        nonce: BigInt.zero,
        maxPriorityFeePerGas: BigInt.from(2000000000),
        maxFeePerGas: BigInt.from(30000000000),
        gasLimit: BigInt.from(21000),
        to: '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045',
        value: BigInt.from(1000000000000000000),
      );

      final resp = EthSignResponseUr(
        requestId: hexDecode('00112233445566778899aabbccddeeff'),
        r: hexDecode('1111111111111111111111111111111111111111111111111111111111111111'),
        s: hexDecode('2222222222222222222222222222222222222222222222222222222222222222'),
        v: 0,
      );

      final signedBytes = plugin.assembleSignedEip1559Tx(tx, resp);
      expect(signedBytes[0], equals(0x02)); // EIP-1559 Type 2 prefix
      expect(signedBytes.length, greaterThan(70));
    });

    test('EvmRpcService interacts with mock RPC endpoint', () async {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String;

        if (method == 'eth_getBalance') {
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': '0xde0b6b3a7640000'}), // 1 ETH
            200,
          );
        } else if (method == 'eth_getTransactionCount') {
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': '0x5'}),
            200,
          );
        } else if (method == 'eth_sendRawTransaction') {
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': '0x9999999999999999999999999999999999999999999999999999999999999999'}),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final rpc = EvmRpcService(client: mockClient);
      final balance = await rpc.getBalance('mainnet', '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045');
      expect(balance, equals(BigInt.from(1000000000000000000)));

      final nonce = await rpc.getTransactionCount('mainnet', '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045');
      expect(nonce, equals(BigInt.from(5)));

      final txHash = await rpc.sendRawTransaction('mainnet', Uint8List(32));
      expect(txHash.startsWith('0x9999'), isTrue);
    });

    test('HyperliquidService interacts with mock L1 API', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/info')) {
          return http.Response(
            jsonEncode({
              'marginSummary': {'accountValue': '12500.50'},
            }),
            200,
          );
        } else if (request.url.path.endsWith('/exchange')) {
          return http.Response(
            jsonEncode({'status': 'ok', 'response': {'type': 'default'}}),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final hl = HyperliquidService(client: mockClient);
      final state = await hl.getUserState('mainnet', '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045');
      expect(state['marginSummary']['accountValue'], equals('12500.50'));

      final resp = await hl.submitAction(
        networkId: 'mainnet',
        action: {'type': 'usdSend'},
        nonce: 1700000000000,
        signature: {'r': '0x1', 's': '0x2', 'v': 27},
      );
      expect(resp['status'], equals('ok'));
    });
  });
}
