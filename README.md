## 環境準備

環境を準備するにはasdfかmiseを使用してください。

### asdf

[こちら](https://asdf-vm.com/guide/getting-started.html)を参考にインストールしてください。

ツールのインストール

```
$ cat .tool-versions | cut -d' ' -f1 | xargs -rd\\n -n1 asdf plugin add
$ asdf install
```

### mise

[こちら](https://mise.jdx.dev/getting-started.html)を参考にインストールしてください。

ツールのインストール

```
$ mise install
```

### aws-cli

- AWSにアクセスするため`aws configure`を実行します。

- 別のプロファイルを使用する場合は`aws configure --profile <profile-name>`を実行してください。

- ` aws sts get-caller-identity `コマンドを実行し、目的のAWSにアクセスできていることを確認してください。


## terraform 初期化

```
$ terraform init
```

## terraform 適用

```
$ terraform apply
```
