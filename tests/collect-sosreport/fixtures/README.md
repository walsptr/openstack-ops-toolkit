# Fixture tests/collect-sosreport

| File | Sumber | Status |
|---|---|---|
| `inventory.yaml` | `/home/stack/inventory.yaml` environment RHOSP 17.1 (Instance HA). Grup service dibuat ulang dari daftar aslinya (urutan bisa berbeda). `os_auth_token` dan `overcloud_admin_password` diisi nilai **palsu** agar tes bisa memastikan nilainya tidak bocor | Asli (kecuali nilai sensitif) |
| `inventory.yaml.json` | Output `ansible-inventory -i inventory.yaml --list` (ansible-core 2.21, dijalankan di workstation, bukan undercloud) | Konversi dengan ansible-inventory, bukan manual |
| `pcs-status-nodes.txt` | `sudo pcs status nodes` dari cluster (3 controller, 3 compute Instance HA sebagai remote node, guest bundle galera/rabbitmq) | Asli |
| `pcs-status.txt` | `sudo pcs status` dari cluster yang sama (sehat, tanpa failed actions) | Asli |

Varian "tidak sehat" (node offline, `Failed Resource Actions:`) dan "tanpa Instance HA" dibuat
oleh `run.sh` dengan mengubah salinan fixture ini; format blok `Failed Resource Actions:` belum
diverifikasi dengan output asli.

Format `pcs property config stonith-enabled` di stub `pcs` (`Cluster Properties:` +
` stonith-enabled: false`) mengikuti sampel asli dari cluster; format `=` (pcs 0.11.5+)
belum diverifikasi. Format output `sosreport` di stub mengikuti source sos 4.x
(`Your sos report has been generated and saved in:`, baris ` sha256\t<hash>`,
file `<archive>.sha256`), belum diverifikasi dengan RHEL 9 sungguhan.
