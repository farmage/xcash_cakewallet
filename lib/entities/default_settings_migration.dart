import 'dart:io' show File, Platform;
import 'package:cake_wallet/bitcoin/bitcoin_transaction_priority.dart';
import 'package:cake_wallet/entities/pathForWallet.dart';
import 'package:cake_wallet/entities/secret_store_key.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cake_wallet/entities/preferences_key.dart';
import 'package:cake_wallet/entities/wallet_type.dart';
import 'package:cake_wallet/entities/node.dart';
import 'package:cake_wallet/entities/balance_display_mode.dart';
import 'package:cake_wallet/entities/fiat_currency.dart';
import 'package:cake_wallet/entities/node_list.dart';
import 'package:cake_wallet/entities/monero_transaction_priority.dart';
import 'package:cake_wallet/entities/contact.dart';
import 'package:cake_wallet/entities/fs_migration.dart';
import 'package:cake_wallet/entities/wallet_info.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

const newCakeWalletMoneroUri = 'europe2.xcash.foundation:18281';
const cakeWalletBitcoinElectrumUri = 'electrum.cakewallet.com:50002';
const cakeWalletLitecoinElectrumUri = 'ltc-electrum.cakewallet.com:50002';

Future defaultSettingsMigration(
    {@required int version,
    @required SharedPreferences sharedPreferences,
    @required FlutterSecureStorage secureStorage,
    @required Box<Node> nodes,
    @required Box<WalletInfo> walletInfoSource,
    @required Box<Trade> tradeSource,
    @required Box<Contact> contactSource}) async {
  if (Platform.isIOS) {
    await ios_migrate_v1(walletInfoSource, tradeSource, contactSource);
  }

  final currentVersion = sharedPreferences
          .getInt(PreferencesKey.currentDefaultSettingsMigrationVersion) ??
      0;
  if (currentVersion >= version) {
    return;
  }

  final migrationVersionsLength = version - currentVersion;
  final migrationVersions = List<int>.generate(
      migrationVersionsLength, (i) => currentVersion + (i + 1));

  await Future.forEach(migrationVersions, (int version) async {
    try {
      switch (version) {
        case 1:
          await sharedPreferences.setString(
              PreferencesKey.currentFiatCurrencyKey,
              FiatCurrency.usd.toString());
          await sharedPreferences.setInt(
              PreferencesKey.currentTransactionPriorityKeyLegacy,
              MoneroTransactionPriority.standard.raw);
          await sharedPreferences.setInt(
              PreferencesKey.currentBalanceDisplayModeKey,
              BalanceDisplayMode.availableBalance.raw);
          await sharedPreferences.setBool('save_recipient_address', true);
          await resetToDefault(nodes);
          await changeMoneroCurrentNodeToDefault(
              sharedPreferences: sharedPreferences, nodes: nodes);
          await changeBitcoinCurrentElectrumServerToDefault(
              sharedPreferences: sharedPreferences, nodes: nodes);
          await changeLitecoinCurrentElectrumServerToDefault(
              sharedPreferences: sharedPreferences, nodes: nodes);

          break;
        case 2:
          await replaceNodesMigration(nodes: nodes);
          await replaceDefaultNode(
              sharedPreferences: sharedPreferences, nodes: nodes);

          break;
        case 3:
          await updateNodeTypes(nodes: nodes);
          await addBitcoinElectrumServerList(nodes: nodes);

          break;
        case 4:
          await changeBitcoinCurrentElectrumServerToDefault(
              sharedPreferences: sharedPreferences, nodes: nodes);
          break;

        case 5:
          await addAddressesForMoneroWallets(walletInfoSource);
          break;

        case 6:
          await updateDisplayModes(sharedPreferences);
          break;

        case 9:
          await generateBackupPassword(secureStorage);
          break;

        case 10:
          await changeTransactionPriorityAndFeeRateKeys(sharedPreferences);
          break;

        case 11:
          await changeDefaultMoneroNode(nodes, sharedPreferences);
          break;

        case 12:
          await checkCurrentNodes(nodes, sharedPreferences);
          break;

        case 13:
          await resetBitcoinElectrumServer(nodes, sharedPreferences);
          break;

        case 15:
          await addLitecoinElectrumServerList(nodes: nodes);
          await changeLitecoinCurrentElectrumServerToDefault(
              sharedPreferences: sharedPreferences, nodes: nodes);
          await checkCurrentNodes(nodes, sharedPreferences);
          break;

        default:
          break;
      }

      await sharedPreferences.setInt(
          'current_default_settings_migration_version', version);
    } catch (e) {
      print('Migration error: ${e.toString()}');
    }
  });

  await sharedPreferences.setInt(
      'current_default_settings_migration_version', version);
}

Future<void> replaceNodesMigration({@required Box<Node> nodes}) async {
  final replaceNodes = <String, Node>{
    'eu-node.cakewallet.io:18081':
        Node(uri: 'xmr-node-eu.cakewallet.com:18081', type: WalletType.monero),
    'node.cakewallet.io:18081': Node(
        uri: 'xmr-node-usa-east.cakewallet.com:18081', type: WalletType.monero),
    'node.xmr.ru:13666':
        Node(uri: 'node.monero.net:18081', type: WalletType.monero)
  };

  nodes.values.forEach((Node node) async {
    final nodeToReplace = replaceNodes[node.uri];

    if (nodeToReplace != null) {
      node.uriRaw = nodeToReplace.uriRaw;
      node.login = nodeToReplace.login;
      node.password = nodeToReplace.password;
      await node.save();
    }
  });
}

Future<void> changeMoneroCurrentNodeToDefault(
    {@required SharedPreferences sharedPreferences,
    @required Box<Node> nodes}) async {
  final node = getMoneroDefaultNode(nodes: nodes);
  final nodeId = node?.key as int ?? 0; // 0 - England

  await sharedPreferences.setInt('current_node_id', nodeId);
}

Node getBitcoinDefaultElectrumServer({@required Box<Node> nodes}) {
  return nodes.values.firstWhere(
          (Node node) => node.uri == cakeWalletBitcoinElectrumUri,
          orElse: () => null) ??
      nodes.values.firstWhere((node) => node.type == WalletType.bitcoin,
          orElse: () => null);
}

Node getLitecoinDefaultElectrumServer({@required Box<Node> nodes}) {
  return nodes.values.firstWhere(
          (Node node) => node.uri == cakeWalletLitecoinElectrumUri,
          orElse: () => null) ??
      nodes.values.firstWhere((node) => node.type == WalletType.litecoin,
          orElse: () => null);
}

Node getMoneroDefaultNode({@required Box<Node> nodes}) {
  final timeZone = DateTime.now().timeZoneOffset.inHours;
  var nodeUri = '';

  if (timeZone >= 1) {
    // Eurasia
    nodeUri = 'europe1.xcash.foundation:18281';
  } else if (timeZone <= -4) {
    // America
    nodeUri = 'europe2.xcash.foundation:18281';
  }

  return nodes.values
          .firstWhere((Node node) => node.uri == nodeUri, orElse: () => null) ??
      nodes.values.first;
}

Future<void> changeBitcoinCurrentElectrumServerToDefault(
    {@required SharedPreferences sharedPreferences,
    @required Box<Node> nodes}) async {
  final server = getBitcoinDefaultElectrumServer(nodes: nodes);
  final serverId = server?.key as int ?? 0;

  await sharedPreferences.setInt('current_node_id_btc', serverId);
}

Future<void> changeLitecoinCurrentElectrumServerToDefault(
    {@required SharedPreferences sharedPreferences,
    @required Box<Node> nodes}) async {
  final server = getLitecoinDefaultElectrumServer(nodes: nodes);
  final serverId = server?.key as int ?? 0;

  await sharedPreferences.setInt('current_node_id_ltc', serverId);
}

Future<void> replaceDefaultNode(
    {@required SharedPreferences sharedPreferences,
    @required Box<Node> nodes}) async {
  const nodesForReplace = <String>[
    'europe1.xcash.foundation:18281',
    'europe2.xcash.foundation:18281',
    'europe3.xcash.foundation:18281'
  ];
  final currentNodeId = sharedPreferences.getInt('current_node_id');
  final currentNode =
      nodes.values.firstWhere((Node node) => node.key == currentNodeId);
  final needToReplace =
      currentNode == null ? true : nodesForReplace.contains(currentNode.uri);

  if (!needToReplace) {
    return;
  }

  await changeMoneroCurrentNodeToDefault(
      sharedPreferences: sharedPreferences, nodes: nodes);
}

Future<void> updateNodeTypes({@required Box<Node> nodes}) async {
  nodes.values.forEach((node) async {
    if (node.type == null) {
      node.type = WalletType.monero;
      await node.save();
    }
  });
}

Future<void> addBitcoinElectrumServerList({@required Box<Node> nodes}) async {
  final serverList = await loadBitcoinElectrumServerList();
  await nodes.addAll(serverList);
}

Future<void> addLitecoinElectrumServerList({@required Box<Node> nodes}) async {
  final serverList = await loadLitecoinElectrumServerList();
  await nodes.addAll(serverList);
}

Future<void> addAddressesForMoneroWallets(
    Box<WalletInfo> walletInfoSource) async {
  final moneroWalletsInfo =
      walletInfoSource.values.where((info) => info.type == WalletType.monero);
  moneroWalletsInfo.forEach((info) async {
    try {
      final walletPath =
          await pathForWallet(name: info.name, type: WalletType.monero);
      final addressFilePath = '$walletPath.address.txt';
      final addressFile = File(addressFilePath);

      if (!addressFile.existsSync()) {
        return;
      }

      final addressText = await addressFile.readAsString();
      info.address = addressText;
      await info.save();
    } catch (e) {
      print(e.toString());
    }
  });
}

Future<void> updateDisplayModes(SharedPreferences sharedPreferences) async {
  final currentBalanceDisplayMode =
      sharedPreferences.getInt(PreferencesKey.currentBalanceDisplayModeKey);
  final balanceDisplayMode = currentBalanceDisplayMode < 2 ? 3 : 2;
  await sharedPreferences.setInt(
      PreferencesKey.currentBalanceDisplayModeKey, balanceDisplayMode);
}

Future<void> generateBackupPassword(FlutterSecureStorage secureStorage) async {
  final key = generateStoreKeyFor(key: SecretStoreKey.backupPassword);

  if ((await secureStorage.read(key: key))?.isNotEmpty ?? false) {
    return;
  }

  final password = encrypt.Key.fromSecureRandom(32).base16;
  await secureStorage.write(key: key, value: password);
}

Future<void> changeTransactionPriorityAndFeeRateKeys(
    SharedPreferences sharedPreferences) async {
  final legacyTransactionPriority = sharedPreferences
      .getInt(PreferencesKey.currentTransactionPriorityKeyLegacy);
  await sharedPreferences.setInt(
      PreferencesKey.moneroTransactionPriority, legacyTransactionPriority);
  await sharedPreferences.setInt(PreferencesKey.bitcoinTransactionPriority,
      BitcoinTransactionPriority.medium.serialize());
}

Future<void> changeDefaultMoneroNode(
    Box<Node> nodeSource, SharedPreferences sharedPreferences) async {
  const cakeWalletMoneroNodeUriPattern = '.cakewallet.com';
  final currentMoneroNodeId =
      sharedPreferences.getInt(PreferencesKey.currentNodeIdKey);
  final currentMoneroNode =
      nodeSource.values.firstWhere((node) => node.key == currentMoneroNodeId);
  final needToReplaceCurrentMoneroNode =
      currentMoneroNode.uri.toString().contains(cakeWalletMoneroNodeUriPattern);

  nodeSource.values.forEach((node) async {
    if (node.type == WalletType.monero &&
        node.uri.toString().contains(cakeWalletMoneroNodeUriPattern)) {
      await node.delete();
    }
  });

  final newCakeWalletNode =
      Node(uri: newCakeWalletMoneroUri, type: WalletType.monero);

  await nodeSource.add(newCakeWalletNode);

  if (needToReplaceCurrentMoneroNode) {
    await sharedPreferences.setInt(
        PreferencesKey.currentNodeIdKey, newCakeWalletNode.key as int);
  }
}

Future<void> checkCurrentNodes(
    Box<Node> nodeSource, SharedPreferences sharedPreferences) async {
  final currentMoneroNodeId =
      sharedPreferences.getInt(PreferencesKey.currentNodeIdKey);
  final currentBitcoinElectrumSeverId =
      sharedPreferences.getInt(PreferencesKey.currentBitcoinElectrumSererIdKey);
  final currentLitecoinElectrumSeverId = sharedPreferences
      .getInt(PreferencesKey.currentLitecoinElectrumSererIdKey);
  final currentMoneroNode = nodeSource.values.firstWhere(
      (node) => node.key == currentMoneroNodeId,
      orElse: () => null);
  final currentBitcoinElectrumServer = nodeSource.values.firstWhere(
      (node) => node.key == currentBitcoinElectrumSeverId,
      orElse: () => null);
  final currentLitecoinElectrumServer = nodeSource.values.firstWhere(
      (node) => node.key == currentLitecoinElectrumSeverId,
      orElse: () => null);

  if (currentMoneroNode == null) {
    final newCakeWalletNode =
        Node(uri: newCakeWalletMoneroUri, type: WalletType.monero);
    await nodeSource.add(newCakeWalletNode);
    await sharedPreferences.setInt(
        PreferencesKey.currentNodeIdKey, newCakeWalletNode.key as int);
  }

  if (currentBitcoinElectrumServer == null) {
    final cakeWalletElectrum =
        Node(uri: cakeWalletBitcoinElectrumUri, type: WalletType.bitcoin);
    await nodeSource.add(cakeWalletElectrum);
    await sharedPreferences.setInt(
        PreferencesKey.currentBitcoinElectrumSererIdKey,
        cakeWalletElectrum.key as int);
  }

  if (currentLitecoinElectrumServer == null) {
    final cakeWalletElectrum =
        Node(uri: cakeWalletLitecoinElectrumUri, type: WalletType.litecoin);
    await nodeSource.add(cakeWalletElectrum);
    await sharedPreferences.setInt(
        PreferencesKey.currentLitecoinElectrumSererIdKey,
        cakeWalletElectrum.key as int);
  }
}

Future<void> resetBitcoinElectrumServer(
    Box<Node> nodeSource, SharedPreferences sharedPreferences) async {
  final currentElectrumSeverId =
      sharedPreferences.getInt(PreferencesKey.currentBitcoinElectrumSererIdKey);
  final oldElectrumServer = nodeSource.values.firstWhere(
      (node) => node.uri.toString().contains('electrumx.cakewallet.com'),
      orElse: () => null);
  var cakeWalletNode = nodeSource.values.firstWhere(
      (node) => node.uri.toString() == cakeWalletBitcoinElectrumUri,
      orElse: () => null);

  if (cakeWalletNode == null) {
    cakeWalletNode =
        Node(uri: cakeWalletBitcoinElectrumUri, type: WalletType.bitcoin);
    await nodeSource.add(cakeWalletNode);
  }

  if (currentElectrumSeverId == oldElectrumServer?.key) {
    await sharedPreferences.setInt(
        PreferencesKey.currentBitcoinElectrumSererIdKey,
        cakeWalletNode.key as int);
  }

  await oldElectrumServer?.delete();
}
