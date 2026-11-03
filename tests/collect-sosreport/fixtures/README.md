# Fixture tests/collect-sosreport

Semua fixture berisi **data contoh** (hostname `overcloud-*`, domain `example.com`, IP default
TripleO seperti ctlplane `192.168.24.0/24` dan internal_api `172.17.0.0/24`, UUID dan ID palsu),
bukan data environment sungguhan. Strukturnya mengikuti RHOSP 17.1 (director/TripleO) dengan
Instance HA: 3 controller (grup `pacemaker`) dan 3 compute `ComputeInstanceHA` (grup
`pacemaker_remote`).

| File | Isi |
|---|---|
| `inventory.yaml` | Inventory contoh berformat `/home/stack/inventory.yaml` (grup role dengan `tripleo_role_name`, `allovercloud`/`overcloud`, grup `Undercloud` dengan `ansible_connection: ssh` dan key sendiri, grup service). `os_auth_token` dan `overcloud_admin_password` berisi nilai palsu agar tes bisa memastikan nilainya tidak bocor |
| `inventory.yaml.json` | Output `ansible-inventory -i inventory.yaml --list` (ansible-core 2.21) dari file di atas |
| `pcs-status-nodes.txt` | Contoh `sudo pcs status nodes` (pcs 0.11): node Pacemaker, remote node compute, guest bundle galera/rabbitmq |
| `pcs-status.txt` | Contoh `sudo pcs status` (cluster sehat, tanpa failed actions) |

Format kedua output pcs dan `pcs property config stonith-enabled` (`Cluster Properties:` +
` stonith-enabled: false`) mengikuti output pcs 0.11 di RHEL 9. Varian "tidak sehat" (node
offline, `Failed Resource Actions:`) dan "tanpa Instance HA" dibuat oleh `run.sh` dari salinan
fixture ini; format blok `Failed Resource Actions:` dan format `=` (pcs 0.11.5+) belum
diverifikasi. Format output `sosreport` di stub mengikuti source sos 4.x
(`Your sos report has been generated and saved in:`, baris ` sha256\t<hash>`, file
`<archive>.sha256`, nama `sosreport-<host>[-<case-id>]-<YYYY-MM-DD>-<acak>.tar.xz`).
