# perm-outlier

Find the files whose permission bits do not match the rest of the tree.

```
$ perm-outlier /var/www/html

Scanned 1,284 file(s) under /var/www/html

Permission distribution:
  644      1281 file(s)   99.8%  <- dominant
  604         1 file(s)    0.1%
  600         2 file(s)    0.2%

Files that differ from the dominant mode (644, 1281 file(s)):

  600    /var/www/html/.env
  600    /var/www/html/private.key
  604    /var/www/html/google1a2b3c4d5e.html
```

## Why

Permission bugs are usually hunted by asking "is this too loose?" or
"is this too tight?". That question misses the common case.

The file that breaks production is almost never the one with unusual
permissions in the abstract. It is the one that does not match everything
around it. A single `604` in a tree of `644` is the bug, and it is invisible
to a search for "insecure permissions" because, on paper, `604` grants read
access to everyone.

It does not.

**Permission checking stops at the first matching class.** If the process
belongs to the file's group, the kernel reads the group bits and stops.
The "other" bits are never consulted. So `604` — owner `rw-`, group `---`,
other `r--` — denies exactly the processes that reach the file through its
group, while appearing permissive to everyone else.

On shared hosting, where the webserver often reaches files through the
group, a `604` file returns nothing. The file exists. The path is right.
The content is right. And it is unreachable.

This tool looks for the difference, not the looseness.

## Install

No dependencies beyond a POSIX shell, `find`, `stat`, `awk`, `sort` and
`uniq`. Tested on GNU coreutils and BSD/macOS, and under `dash` as well as
`bash`.

```sh
curl -O https://raw.githubusercontent.com/karakihiroyuki/perm-outlier/main/perm-outlier.sh
chmod +x perm-outlier.sh
./perm-outlier.sh /path/to/check
```

Or clone and symlink it onto your `PATH`:

```sh
git clone https://github.com/karakihiroyuki/perm-outlier.git
ln -s "$PWD/perm-outlier/perm-outlier.sh" ~/bin/perm-outlier
```

## Usage

```
perm-outlier [options] [directory]

  -g, --group-unreadable   Only report files with no group-read bit.
  -x, --check-dirs         Also check directories for missing execute bits.
  -f, --print-fix          Print the chmod commands. Nothing is executed.
  -q, --quiet              Suppress the distribution summary.
  -h, --help               Show help.
  -V, --version            Show version.
```

Exit status is `0` when nothing differs, `1` when outliers are found, and
`2` on a usage or runtime error — so it drops into a deployment check
without further wrapping.

### Finding the files a webserver cannot read

```sh
perm-outlier -g /var/www/html
```

This reports every file whose group-read bit is unset, regardless of what
the dominant mode happens to be. On a host where the webserver reaches
files through the group, these are the files that will 403 or 404 for
reasons that have nothing to do with the path.

### Directories

```sh
perm-outlier -x /var/www/html
```

A directory without its execute bit cannot be traversed. Every file beneath
it is unreachable no matter how permissive the files themselves are. This
failure looks identical to a missing file, which is why it costs so much
time.

### Suggested fixes

```sh
perm-outlier -f /var/www/html
```

Prints `chmod` commands aligning the outliers with the dominant mode.
**Nothing is executed.**

Read the list before running any of it. Some files are restrictive on
purpose — private keys, certificates, credential files, configuration
holding database passwords. Aligning those with the majority would expose
them. The tool cannot tell the difference between a mistake and a decision;
that judgement is yours.

## Limitations

- Paths containing newline characters are skipped. `find -print0` is not
  POSIX, and portability was the higher priority here.
- Only the lower nine permission bits are compared. setuid, setgid and the
  sticky bit are not part of the comparison.
- The "dominant mode" is simply the most common one. In a tree with a
  genuinely mixed layout — a `bin/` of `755` executables beside a `conf/`
  of `640` files — run the tool against each subtree separately.
- ACLs and SELinux contexts are out of scope.

## Background

This came out of a real incident: a file placed at the right path with the
right content, returning nothing, because it alone was `604` in a tree of
`644`.

The write-up is here (Japanese):
[ファイルは置いたのに読めない：パーミッション604と、UNIX権限の「最初に一致した区分で確定する」評価順序](https://zenn.dev/karakihiroyuki/articles/c41658fe925510)

## License

MIT. See [LICENSE](LICENSE).

---

# perm-outlier（日本語）

ディレクトリ配下で、**権限が周囲と違うファイル**を見つけます。

## なぜ「緩さ」ではなく「差分」で見るのか

パーミッションの不具合は、普通「緩すぎないか」「厳しすぎないか」で探されます。この見方では、一番多いケースを取り逃します。

本番を止めるのは、絶対的に異常な権限のファイルではありません。**周囲と違うファイル**です。`644` が並ぶ中の `604` が1つ、というのが典型で、しかもこれは「緩すぎる権限」を探す検査には引っかかりません。`604` は字面の上では「全員に読み取りを許可」しているからです。

実際には違います。

**UNIX の権限判定は、最初に一致した区分でそこで確定します。** プロセスがファイルのグループに属していれば、カーネルはグループビットを見て、そこで終わります。other ビットは参照されません。つまり `604`（owner `rw-` / group `---` / other `r--`）は、**グループ経由でアクセスしてくる相手だけを狙い撃ちで拒否**します。

共用レンタルサーバーのように、Webサーバーがファイルのグループ側から来る構成では、`604` のファイルは読めません。ファイルは存在し、パスは正しく、中身も正しい。それでも届かない。

このツールは、緩さではなく差分を探します。

## 使い方

```sh
# 周囲と違う権限のファイルを探す
perm-outlier /var/www/html

# Webサーバーが読めない可能性のあるファイルだけ
perm-outlier -g /var/www/html

# ディレクトリの実行ビットも検査
perm-outlier -x /var/www/html

# 修正コマンドを表示（実行はしません）
perm-outlier -f /var/www/html
```

終了コードは、差分なしで `0`、検出で `1`、エラーで `2`。デプロイ時の検査にそのまま組み込めます。

## 注意

`-f` は `chmod` コマンドを表示するだけで、実行はしません。

**必ず目で確認してください。** 秘密鍵、証明書、認証情報、データベースのパスワードを含む設定ファイルなど、**意図的に厳しくしてあるファイル**が混ざっていることがあります。それを多数派に合わせると、公開してしまいます。

ツールには「間違い」と「判断」の区別がつきません。そこは人間の仕事です。

## 制限

- 改行を含むパスは対象外です（`find -print0` が POSIX でないため、移植性を優先しました）
- 比較するのは下位9ビットのみ。setuid / setgid / スティッキービットは比較対象外です
- 「最頻値」は単に一番多い権限です。`bin/` が `755`、`conf/` が `640` のように構成上分かれている場合は、サブツリーごとに実行してください
- ACL と SELinux は対象外です

## 背景

実際にあった出来事から作りました。正しいパスに、正しい内容で置いたファイルが、何も返さない。原因は、`644` が並ぶ中でそれだけが `604` だったことでした。

経緯はこちらに書いています。
[ファイルは置いたのに読めない：パーミッション604と、UNIX権限の「最初に一致した区分で確定する」評価順序](https://zenn.dev/karakihiroyuki/articles/c41658fe925510)
