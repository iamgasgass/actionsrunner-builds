# StikDebug-LC (patch)

Fork of StikDebug 3.2.2 that runs inside LiveContainer and enables JIT for another app in the **same**
LiveContainer. Full documentation: [LIVECONTAINER.md](LIVECONTAINER.md).

Rebuild the full repository from upstream:

```sh
git clone https://github.com/StephenDev0/StikDebug StikDebug-LC
cd StikDebug-LC
git checkout 7a80dfce28eeb501faca6498d1746949ac921e74
git apply --binary ../stikdebug-livecontainer.patch
```
