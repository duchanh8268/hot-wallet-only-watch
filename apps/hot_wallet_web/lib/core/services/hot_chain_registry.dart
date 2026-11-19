import 'package:chain_core_interface/chain_core_interface.dart';
import '../../chains/cardano/cardano_hot_plugin.dart';
import '../../chains/evm/evm_hot_plugin.dart';

/// Registry of available Hot Wallet chain plugins.
class HotChainRegistry {
  final Map<ChainId, IHotChainPlugin> _plugins = {};

  HotChainRegistry() {
    registerPlugin(CardanoHotPlugin.instance);
    registerPlugin(EvmHotPlugin.ethereum);
    registerPlugin(EvmHotPlugin.hyperliquid);
  }

  void registerPlugin(IHotChainPlugin plugin) {
    _plugins[plugin.chainId] = plugin;
  }

  List<IHotChainPlugin> get allPlugins => List.unmodifiable(_plugins.values);

  IHotChainPlugin getPlugin(ChainId id) {
    final p = _plugins[id];
    if (p == null) {
      throw ArgumentError('Hot chain plugin not found for ${id.name}');
    }
    return p;
  }

  IHotChainPlugin? findPluginForUr(String urType) {
    for (final p in _plugins.values) {
      if (p.canHandleUr(urType)) {
        return p;
      }
    }
    return null;
  }
}
