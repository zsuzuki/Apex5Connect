# Apex5Connect

## English

A small macOS menu bar app for re-pairing a Flydigi APEX5 controller when it
cannot reconnect normally.

The controller Bluetooth MAC address is not stored in source code. The app saves
it locally at:

```text
~/Library/Application Support/Apex5Connect/config.json
```

The app uses `blueutil` to remove the old pairing record, pair again, and then
connect to the saved address.

## 日本語

Flydigi APEX5 コントローラーが通常の再接続に失敗する場合に、Mac側の
ペアリング情報を削除してから再ペアリングするための小さなmacOSメニューバー
アプリです。

コントローラーのBluetooth MACアドレスはソースコードには保存しません。
アプリはローカルの次のファイルに保存します。

```text
~/Library/Application Support/Apex5Connect/config.json
```

内部では `blueutil` を使い、古いペアリング情報の削除、再ペアリング、
保存済みアドレスへの接続を実行します。
