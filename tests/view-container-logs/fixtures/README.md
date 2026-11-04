# Fixture tests/view-container-logs dan tests/search-container-logs

Data contoh, bukan data environment sungguhan. Inventory default memakai fixture
`tests/collect-sosreport/fixtures/inventory.yaml(.json)` (3 controller + 3 compute
`ComputeInstanceHA`, nilai palsu `os_auth_token` / `overcloud_admin_password`).

| File | Isi |
|---|---|
| `tree-controller.txt` | Daftar file contoh di `/var/log/containers` controller. `+` = file rotasi, `@host` = hanya ada di host itu (mis. `cinder-volume` aktif di satu controller), `!empty` = file aktif 0 byte setelah rotasi |
| `tree-compute.txt` | Daftar file contoh di compute |
| `inventory-nested.yaml.json` | Inventory yang sama dengan struktur grup `/home/stack/inventory.yaml` RHOSP 17.1.13: grup role, `allovercloud`, `overcloud`, `pacemaker`, `pacemaker_remote` berisi child berprefiks nama stack (`overcloud_Controller`, `overcloud_allovercloud`, ...) |
| `inventory-nested.yaml` | Placeholder (stub `ansible-inventory` membaca file `.json`) |

**Terverifikasi** di environment dev (RHOSP 17.1.13, 2026-11-05; hanya nama path dan struktur
grup, disamarkan): direktori per service, `httpd/<service>/` (termasuk `error_log` tanpa `.log`),
`stdouts/`, rotasi `.N` dan `.N.gz` (sampai `.14.gz`), file aktif 0 byte setelah rotasi, file
bernama UUID (dengan dan tanpa `.log`), `rabbitmq/log/`, `libvirt/qemu/instance-*.log`, tidak ada
nama dengan karakter di luar `A-Za-z0-9@_+.,=/-`, dan struktur grup inventory bersarang.

**Sintetis** (tidak ada di environment dev, hanya untuk menguji klasifikasi): rotasi
`-YYYYMMDD`, `.xz`, `.bz2`, `.zst`, dan `nova/bad name.log`.

`run.sh` membuat pohon file per host dari daftar ini (isi baris log dibuat oleh `common.sh`,
file `.gz` dikompres sungguhan; `.xz/.bz2/.zst` hanya nama karena tidak pernah dibaca).
