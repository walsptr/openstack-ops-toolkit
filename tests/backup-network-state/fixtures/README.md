# Fixture tests/backup-network-state

Data contoh (bukan environment sungguhan). Format mengikuti output tool di RHEL 9:

| File | Isi |
|---|---|
| `routes-v4.txt`, `routes-v6.txt` | `ip -4/-6 route show table all` |
| `rules-v4.txt`, `rules-v6.txt` | `ip -4/-6 rule show` |
| `*.json` | `ip -j ...` (iproute2 6.x) |
| `iptables-v4.rules`, `iptables-v6.rules` | `iptables-save -c` / `ip6tables-save -c` (1.8.x). Tanpa `-c` stub membuang counter aturan `[n:m] `; counter policy chain tetap ada, seperti tool aslinya |
| `nftables.ruleset` | `nft list ruleset` (dengan `-s` stub membuang `packets N bytes M`) |
| `nftables-xt.ruleset` | Ruleset dengan ekspresi `xt match` (iptables-nft compat), format seperti nftables 1.1 |

String `OSOPS-RULE-MARKER-*`, `10.99.42.*` dan `fd00:99:42::` dipakai tes untuk memastikan isi aturan/route
tidak pernah masuk log. Inventory dipakai bersama dari `tests/collect-sosreport/fixtures/`.
