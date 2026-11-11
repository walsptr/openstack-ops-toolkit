# Fixture tests/restore-network-state

Data contoh (bukan environment sungguhan). `live/` adalah state awal node palsu (stub `netstub`
berstate): `ipt4`/`ipt6` (format `iptables-save` tanpa komentar), `nft` (`nft list ruleset`,
dengan tabel iptables-nft bertanda `# Warning: ... managed by iptables-nft`), `routes4.json`,
`routes6.json`, `rules4.json`, `rules6.json` (format `ip -j`, iproute2 6.x).

Rute contoh mencakup kelas yang tidak boleh disentuh restore: default route, `proto kernel`,
link-local (`169.254.169.254`, `fe80::/64`), tabel `local`. String `OSOPS-RULE-MARKER-*`,
`10.99.42.*`, `10.98.*`, `fd00:99:42::` dipakai tes untuk memastikan isi aturan/route tidak
masuk log. Inventory dan `pcs status nodes` dipakai bersama dari `tests/collect-sosreport/fixtures/`.
