# Honk OpenWrt Feed

This repository is an independent feed scaffold for the immutable Honk source
commit `63e271065246bb68ecadf9ae53abecf748806ad3`.

`locks/` is the source of truth for build inputs. The ignored `.cache/dl/`
directory retains only checksum-verified immutable downloads and Cargo vendor
closures. It is disposable and regenerated only by the lock provisioning
workflow. No credential material is retained there.

Run focused Todo 1 checks with:

```sh
bash tests/run-todo1-tests.sh
```
